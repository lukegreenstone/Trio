import Foundation

enum RheosSchema {
    /// Bump this when the on-disk document gains a field. Add a step in
    /// `RheosMigrator.migrate` that fills the new field from the old document.
    /// Never delete a file because its version changed.
    static let current = 3
    static let stateFile = "rheos-state.json"
}

struct RheosAnnouncement: Codable, Equatable, Identifiable {
    var id: String
    var date: Date
    var kind: String
    var note: String
}

/// Everything Rheos has learned. One file, one schema version, restored as a whole.
struct RheosStateDocument: Codable, Equatable {
    var schemaVersion: Int
    var dataset: RheosDataset
    var bounds: RheosBounds
    var decision: RheosProfileDecision?
    var applied: RheosAppliedState?
    var applications: [RheosApplicationLog]
    var announcements: [RheosAnnouncement]
    var patchSites: [RheosPatchSite]

    static let empty = RheosStateDocument(
        schemaVersion: RheosSchema.current,
        dataset: RheosDataset(),
        bounds: RheosBounds(),
        decision: nil,
        applied: nil,
        applications: [],
        announcements: [],
        patchSites: []
    )

    var containsUserData: Bool {
        !dataset.glucose.isEmpty || !dataset.meals.isEmpty || applied != nil || !applications.isEmpty
    }
}

enum RheosMigrator {
    enum Failure: Error {
        case notJSON
    }

    static func schemaVersion(of data: Data) -> Int {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        return object["schemaVersion"] as? Int ?? 0
    }

    /// Reads any known generation and returns the current document.
    /// A newer file is decoded without being rewritten by this function.
    static func document(from data: Data) throws -> RheosStateDocument {
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.notJSON
        }
        let version = json["schemaVersion"] as? Int ?? 0
        if version > RheosSchema.current {
            return try decode(complete(json))
        }
        if version < 1 {
            json = migrateUnversioned(json)
        }
        if (json["schemaVersion"] as? Int ?? 1) < 2 {
            json = migrate1to2(json)
        }
        if (json["schemaVersion"] as? Int ?? 2) < 3 {
            json = migrate2to3(json)
        }
        json["schemaVersion"] = RheosSchema.current
        return try decode(complete(json))
    }

    /// Keeps keys this build does not understand, and refuses to lower the schema number.
    static func merging(_ document: RheosStateDocument, into existing: Data) throws -> Data {
        let encoded = try RheosCoding.encoder().encode(document)
        guard let latest = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              var previous = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
            throw Failure.notJSON
        }
        let storedVersion = previous["schemaVersion"] as? Int ?? RheosSchema.current
        for (key, value) in latest {
            previous[key] = value
        }
        previous["schemaVersion"] = max(storedVersion, RheosSchema.current)
        return try JSONSerialization.data(withJSONObject: previous, options: [.prettyPrinted, .sortedKeys])
    }

    /// Pulls glucose out of a file that no longer matches a decoder, so a bad
    /// migration still does not present an empty history.
    static func salvage(_ data: Data) -> RheosStateDocument? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let readings = (json["glucoseReadings"] as? [[String: Any]])
            ?? ((json["dataset"] as? [String: Any])?["glucose"] as? [[String: Any]])
            ?? (json["glucose"] as? [[String: Any]])
        guard let readings, !readings.isEmpty else { return nil }
        let glucose: [RheosGlucosePoint] = readings.compactMap { item in
            let rawDate = (item["t"] as? String) ?? (item["date"] as? String)
            let mgdl = (item["mgdl"] as? NSNumber)?.doubleValue ?? (item["mgdl"] as? Double)
            guard let rawDate, let mgdl, let date = ISO8601DateFormatter().date(from: rawDate) else { return nil }
            return RheosGlucosePoint(date: date, mgdl: mgdl)
        }
        guard !glucose.isEmpty else { return nil }
        var document = RheosStateDocument.empty
        document.dataset.glucose = glucose
        return document
    }

    static func legacyDocument(dataset: RheosDataset, bounds: RheosBounds, decision: RheosProfileDecision?, applied: RheosAppliedState?, applications: [RheosApplicationLog]) -> RheosStateDocument {
        RheosStateDocument(
            schemaVersion: RheosSchema.current,
            dataset: dataset,
            bounds: bounds,
            decision: decision,
            applied: applied,
            applications: applications,
            announcements: [],
            patchSites: []
        )
    }

    private static func migrateUnversioned(_ json: [String: Any]) -> [String: Any] {
        if json["dataset"] != nil || json["glucoseReadings"] != nil {
            var copy = json
            copy["schemaVersion"] = 1
            return copy
        }
        if json["glucose"] != nil {
            return [
                "schemaVersion": 1,
                "dataset": json
            ]
        }
        var copy = json
        copy["schemaVersion"] = 1
        return copy
    }

    /// Version 1 stored glucose as `glucoseReadings` and the learned basal vector
    /// as `learnedBasal`. Those rows are copied, not dropped.
    private static func migrate1to2(_ json: [String: Any]) -> [String: Any] {
        var copy = json
        if copy["dataset"] == nil {
            let readings = copy["glucoseReadings"] as? [[String: Any]] ?? []
            let glucose = readings.map { item -> [String: Any] in
                [
                    "date": item["t"] ?? item["date"] ?? "1970-01-01T00:00:00Z",
                    "mgdl": item["mgdl"] ?? 0
                ]
            }
            copy["dataset"] = ["glucose": glucose]
        }
        if copy["applied"] == nil, let learned = copy["learnedBasal"] as? [Any] {
            let basal = padded(learned)
            let ones = Array(repeating: 1.0, count: 24)
            copy["applied"] = [
                "factors": ["basal": basal, "isf": ones, "carbRatio": ones],
                "appliedAt": copy["learnedAt"] ?? "1970-01-01T00:00:00Z"
            ]
        }
        return copy
    }

    /// Version 2 had age, weight and height on `dataset.body` and no history.
    /// Those values stay. The history starts empty.
    private static func migrate2to3(_ json: [String: Any]) -> [String: Any] {
        var copy = json
        var dataset = copy["dataset"] as? [String: Any] ?? [:]
        if dataset["bodyHistory"] == nil { dataset["bodyHistory"] = [Any]() }
        if var body = dataset["body"] as? [String: Any] {
            if body["manualFields"] == nil { body["manualFields"] = [Any]() }
            if body["muscleComesFromLeanMass"] == nil { body["muscleComesFromLeanMass"] = false }
            dataset["body"] = body
        }
        copy["dataset"] = dataset
        return copy
    }

    private static func complete(_ json: [String: Any]) -> [String: Any] {
        var copy = json
        copy["schemaVersion"] = copy["schemaVersion"] ?? RheosSchema.current
        var dataset = copy["dataset"] as? [String: Any] ?? [:]
        for key in ["glucose", "insulin", "meals", "states", "adjustments", "notes", "wearableDays", "workouts", "sleep"] {
            if dataset[key] == nil { dataset[key] = [Any]() }
        }
        if dataset["body"] == nil { dataset["body"] = [String: Any]() }
        if var body = dataset["body"] as? [String: Any] {
            if body["manualFields"] == nil { body["manualFields"] = [Any]() }
            if body["muscleComesFromLeanMass"] == nil { body["muscleComesFromLeanMass"] = false }
            dataset["body"] = body
        }
        if dataset["bodyHistory"] == nil { dataset["bodyHistory"] = [Any]() }
        copy["dataset"] = dataset
        var bounds = copy["bounds"] as? [String: Any] ?? [:]
        func fill(_ key: String, _ value: Any) {
            if bounds[key] == nil { bounds[key] = value }
        }
        fill("minimumMultiplier", RheosReference.defaultMinimumMultiplier)
        fill("maximumMultiplier", RheosReference.defaultMaximumMultiplier)
        fill("maxDailyChange", RheosReference.defaultMaxDailyChange)
        fill("maxContextNudge", RheosReference.defaultMaxContextNudge)
        fill("minimumDays", 14)
        fill("minimumGlucoseSamples", 500)
        fill("minimumImprovement", 0.02)
        copy["bounds"] = bounds
        if copy["applications"] == nil { copy["applications"] = [Any]() }
        if copy["announcements"] == nil { copy["announcements"] = [Any]() }
        if copy["patchSites"] == nil { copy["patchSites"] = [Any]() }
        return copy
    }

    private static func padded(_ values: [Any]) -> [Double] {
        var numbers = values.compactMap { ($0 as? NSNumber)?.doubleValue ?? ($0 as? Double) }
        if numbers.count < 24 {
            numbers.append(contentsOf: Array(repeating: 1, count: 24 - numbers.count))
        }
        return Array(numbers.prefix(24))
    }

    private static func decode(_ json: [String: Any]) throws -> RheosStateDocument {
        let data = try JSONSerialization.data(withJSONObject: json)
        return try RheosCoding.decoder().decode(RheosStateDocument.self, from: data)
    }
}
