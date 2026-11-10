import Foundation

/// On-device Rheos files. This store never reads or writes Trio's settings,
/// profile, preferences, or pump history files.
///
/// The canonical file is `rheos-state.json` inside Application Support/Rheos,
/// which stays in this app's container for the same bundle ID. App updates do
/// not move or wipe it. Schema changes run forward and keep a copy of the
/// previous bytes. A newer schema than this build understands is not rewritten
/// down.
final class RheosStore {
    static let shared = RheosStore(directory: RheosStore.defaultDirectory())

    let directory: URL
    /// Nil when iCloud Documents is not in the provisioning profile. Local storage still works.
    var backupDirectory: () -> URL? = { nil }

    private let lock = NSLock()
    private var cached: RheosStateDocument?
    private var preserveNewerSchema = false

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS) || os(macOS)
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        var mutable = directory
        try? mutable.setResourceValues(values)
        #endif
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Rheos", isDirectory: true)
    }

    func loadDataset() -> RheosDataset {
        lock.lock()
        defer { lock.unlock() }
        return document().dataset
    }

    func saveDataset(_ dataset: RheosDataset, now _: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        var state = document()
        state.dataset = dataset
        persist(state)
    }

    func loadBounds() -> RheosBounds {
        lock.lock()
        defer { lock.unlock() }
        return document().bounds.sanitized()
    }

    func saveBounds(_ bounds: RheosBounds) {
        lock.lock()
        defer { lock.unlock() }
        var state = document()
        state.bounds = bounds.sanitized()
        persist(state)
    }

    func loadDecision() -> RheosProfileDecision? {
        lock.lock()
        defer { lock.unlock() }
        return document().decision
    }

    func saveDecision(_ decision: RheosProfileDecision) {
        lock.lock()
        defer { lock.unlock() }
        var state = document()
        state.decision = decision
        persist(state)
    }

    func loadApplied() -> RheosAppliedState? {
        lock.lock()
        defer { lock.unlock() }
        return document().applied
    }

    func saveApplied(_ applied: RheosAppliedState) {
        lock.lock()
        defer { lock.unlock() }
        var state = document()
        state.applied = applied
        persist(state)
    }

    func clearAppliedFactors() {
        lock.lock()
        defer { lock.unlock() }
        var state = document()
        state.applied = nil
        persist(state)
    }

    func disarmApplication(mode: RheosMode, reason: String, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        var state = document()
        var decision = state.decision ?? RheosProfileDecision.inactive(mode: mode, reason: reason, now: now)
        decision.mode = mode
        decision.applied = false
        decision.code = mode == .aus ? .off : .shadow
        decision.factors = .identity
        decision.reason = reason
        decision.evaluatedAt = now
        state.decision = decision
        state.applied = nil
        persist(state)
    }

    func applicationLogs() -> [RheosApplicationLog] {
        lock.lock()
        defer { lock.unlock() }
        return document().applications
    }

    func appendApplication(_ entry: RheosApplicationLog) {
        lock.lock()
        defer { lock.unlock() }
        var state = document()
        if let last = state.applications.last,
           last.applied == entry.applied,
           last.code == entry.code,
           last.hour == entry.hour,
           abs(last.basal - entry.basal) < 0.000_001,
           abs(last.isf - entry.isf) < 0.000_001,
           abs(last.carbRatio - entry.carbRatio) < 0.000_001,
           abs(entry.date.timeIntervalSince(last.date)) < 3600 {
            return
        }
        state.applications.append(entry)
        if state.applications.count > 1500 {
            state.applications.removeFirst(state.applications.count - 1500)
        }
        persist(state)
    }

    func announcements() -> [RheosAnnouncement] {
        lock.lock()
        defer { lock.unlock() }
        return document().announcements
    }

    func addAnnouncement(_ announcement: RheosAnnouncement) {
        lock.lock()
        defer { lock.unlock() }
        var state = document()
        state.announcements.append(announcement)
        persist(state)
    }

    /// Replaces the learning state with an exported archive. The previous file is kept beside it.
    /// Throws without changing anything when the archive cannot be read.
    func importArchive(from url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        let data = try Data(contentsOf: url)
        let migrated = try RheosMigrator.document(from: data)
        let currentURL = file(RheosSchema.stateFile)
        if let current = try? Data(contentsOf: currentURL), !current.isEmpty {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try? RheosFileProtection.write(current, to: file("rheos-state.pre-import-\(stamp).json"))
        }
        preserveNewerSchema = RheosMigrator.schemaVersion(of: data) > RheosSchema.current
        try writeDocument(migrated, overwriting: currentURL)
        cached = migrated
    }

    func exportFiles(now: Date = Date()) throws -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        let state = document()
        let folder = directory.appendingPathComponent("Export", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let jsonURL = folder.appendingPathComponent("rheos-\(stamp).json")
        let csvURL = folder.appendingPathComponent("rheos-\(stamp).csv")
        try RheosFileProtection.write(try RheosCoding.encoder().encode(state), to: jsonURL)
        try RheosCoding.csv(dataset: state.dataset, logs: state.applications)
            .write(to: csvURL, atomically: true, encoding: .utf8)
        return [jsonURL, csvURL]
    }

    private func document() -> RheosStateDocument {
        if let cached { return cached }
        let loaded = loadFromDisk()
        cached = loaded
        return loaded
    }

    private func loadFromDisk() -> RheosStateDocument {
        let url = file(RheosSchema.stateFile)
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            let version = RheosMigrator.schemaVersion(of: data)
            if version > RheosSchema.current {
                preserveNewerSchema = true
                return (try? RheosMigrator.document(from: data)) ?? RheosMigrator.salvage(data) ?? .empty
            }
            do {
                let migrated = try RheosMigrator.document(from: data)
                if version < RheosSchema.current {
                    let backup = file("rheos-state.v\(version).bak")
                    if !FileManager.default.fileExists(atPath: backup.path) {
                        try? RheosFileProtection.write(data, to: backup)
                    }
                    try? writeDocument(migrated, overwriting: url)
                }
                return migrated
            } catch {
                return RheosMigrator.salvage(data) ?? .empty
            }
        }
        let legacy = loadLegacySplitFiles()
        if legacy.containsUserData {
            try? writeDocument(legacy, overwriting: url)
        }
        return legacy
    }

    private func loadLegacySplitFiles() -> RheosStateDocument {
        let dataset = decodeFile(RheosDataset.self, name: "dataset.json") ?? RheosDataset()
        let bounds = (decodeFile(RheosBounds.self, name: "bounds.json") ?? RheosBounds()).sanitized()
        let decision = decodeFile(RheosProfileDecision.self, name: "decision.json")
        let applied = decodeFile(RheosAppliedState.self, name: "applied.json")
        let applications = decodeFile([RheosApplicationLog].self, name: "applications.json") ?? []
        return RheosMigrator.legacyDocument(
            dataset: dataset,
            bounds: bounds,
            decision: decision,
            applied: applied,
            applications: applications
        )
    }

    private func persist(_ state: RheosStateDocument) {
        var copy = state
        copy.schemaVersion = max(copy.schemaVersion, RheosSchema.current)
        copy.bounds = copy.bounds.sanitized()
        cached = copy
        try? writeDocument(copy, overwriting: file(RheosSchema.stateFile))
    }

    private func writeDocument(_ state: RheosStateDocument, overwriting url: URL) throws {
        let data: Data
        if preserveNewerSchema, let existing = try? Data(contentsOf: url), !existing.isEmpty {
            data = try RheosMigrator.merging(state, into: existing)
        } else {
            data = try RheosCoding.encoder().encode(state)
        }
        try RheosFileProtection.write(data, to: url)
        if let backup = backupDirectory() {
            try? FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            try? RheosFileProtection.write(data, to: backup.appendingPathComponent(RheosSchema.stateFile))
        }
    }

    private func decodeFile<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let data = try? Data(contentsOf: file(name)) else { return nil }
        return try? RheosCoding.decoder().decode(type, from: data)
    }

    private func file(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }
}

enum RheosFileProtection {
    static func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        #if os(iOS) || os(macOS)
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        var mutable = url
        try? mutable.setResourceValues(values)
        #endif
    }
}

enum RheosCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func csv(dataset: RheosDataset, logs: [RheosApplicationLog]) -> String {
        var lines = ["section,date,a,b,c,d,e,f"]
        let formatter = ISO8601DateFormatter()
        for point in dataset.glucose {
            lines.append("glucose,\(formatter.string(from: point.date)),\(point.mgdl),,,,,")
        }
        for meal in dataset.meals {
            lines.append(
                "meal,\(formatter.string(from: meal.date)),\(meal.carbs),\(meal.fat),\(meal.protein),\(csv(meal.note)),\(meal.acknowledged),"
            )
        }
        for event in dataset.insulin {
            lines.append("insulin,\(formatter.string(from: event.date)),\(event.units),\(csv(event.kind)),,,,")
        }
        for state in dataset.states {
            lines.append(
                "state,\(formatter.string(from: state.date)),\(num(state.iob)),\(num(state.cob)),,,,"
            )
        }
        for day in dataset.wearableDays {
            lines.append(
                "wearable,\(formatter.string(from: day.day)),\(num(day.restingHeartRate)),\(num(day.hrvSDNN)),\(num(day.steps)),\(num(day.sleepHours)),\(num(day.workoutMinutes)),"
            )
        }
        for workout in dataset.workouts {
            lines.append(
                "workout,\(formatter.string(from: workout.start)),\(csv(workout.activity)),\(workout.durationMinutes),\(num(workout.averageHeartRate)),,,,"
            )
        }
        for sleep in dataset.sleep {
            lines.append("sleep,\(formatter.string(from: sleep.start)),\(formatter.string(from: sleep.end)),\(csv(sleep.stage)),,,,")
        }
        for log in logs {
            lines.append(
                "application,\(formatter.string(from: log.date)),\(log.applied),\(log.code.rawValue),\(log.basal),\(log.isf),\(log.carbRatio),\(csv(log.reason))"
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func num(_ value: Double?) -> String {
        value.map { String($0) } ?? ""
    }

    private static func csv(_ text: String) -> String {
        "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
