import Foundation

/// The glucose snapshot shown on the Apple Watch face.
/// The complication reads this from the existing Trio app group. It does not dose.
struct WatchFaceReading: Codable, Equatable {
    var glucose: String
    var trend: String
    var readingDate: Date
    var rheosMode: String

    func ageMinutes(at now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(readingDate) / 60))
    }

    func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(readingDate) >= WatchFaceBudget.staleAfter
    }

    func ageLabel(at now: Date) -> String {
        let minutes = ageMinutes(at: now)
        if minutes < 1 { return "<1m" }
        if minutes >= 24 * 60 { return ">1d" }
        if minutes >= 60 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    var trendArrow: String {
        WatchFaceTrend.arrow(for: trend)
    }

    var modeLabel: String {
        switch rheosMode.lowercased() {
        case "aus": return "Aus"
        case "schatten": return "Schatten"
        case "scharf": return "Scharf"
        default: return rheosMode.isEmpty ? "Aus" : rheosMode
        }
    }

    var inlineText: String {
        "\(displayGlucose) \(trendArrow)"
    }

    var displayGlucose: String {
        let trimmed = glucose.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "--" ? "--" : trimmed
    }
}

enum WatchFaceTrend {
    static func arrow(for raw: String) -> String {
        switch raw {
        case "TripleUp", "↑↑↑": return "↑↑↑"
        case "DoubleUp", "↑↑": return "↑↑"
        case "SingleUp", "↑": return "↑"
        case "FortyFiveUp", "↗": return "↗"
        case "Flat", "→": return "→"
        case "FortyFiveDown", "↘": return "↘"
        case "SingleDown", "↓": return "↓"
        case "DoubleDown", "↓↓": return "↓↓"
        case "TripleDown", "↓↓↓": return "↓↓↓"
        default: return "·"
        }
    }
}

/// How often the watch face may ask WidgetKit for a new timeline.
///
/// WidgetKit gives complications a small daily reload budget and may defer
/// requests. A 1-minute CGM must not call `reloadTimelines` every minute.
/// The watch app asks for a reload at most every 5 minutes, and only when the
/// glucose, trend, or Rheos mode changed. Between those reloads the timeline
/// already contains one entry per minute so the age label moves. A reading
/// older than 15 minutes is shown as stale. On a worn watch the face is
/// typically within about 5 minutes of the latest value the watch app stored,
/// and can be later when the system is saving budget or the phone is away.
enum WatchFaceBudget {
    static let kind = "TrioWatchComplication"
    static let minimumReloadInterval: TimeInterval = 5 * 60
    static let staleAfter: TimeInterval = 15 * 60
    static let timelineStep: TimeInterval = 60
    static let timelineSteps = 15

    static func shouldReload(lastReload: Date?, contentChanged: Bool, now: Date) -> Bool {
        guard let lastReload else { return true }
        let elapsed = now.timeIntervalSince(lastReload)
        if contentChanged { return elapsed >= minimumReloadInterval }
        return elapsed >= TimeInterval(timelineSteps) * timelineStep
    }

    static func entryDates(from now: Date) -> [Date] {
        (0 ..< timelineSteps).map { now.addingTimeInterval(TimeInterval($0) * timelineStep) }
    }
}

enum WatchFaceStore {
    static let readingKey = "trio.watchface.reading"
    static let reloadKey = "trio.watchface.lastReload"

    static func sharedDefaults() -> UserDefaults? {
        guard let name = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String,
              !name.isEmpty,
              !name.contains("$(")
        else { return nil }
        return UserDefaults(suiteName: name)
    }

    static func save(_ reading: WatchFaceReading, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(reading) else { return }
        defaults.set(data, forKey: readingKey)
    }

    static func load(defaults: UserDefaults) -> WatchFaceReading? {
        guard let data = defaults.data(forKey: readingKey) else { return nil }
        return try? JSONDecoder().decode(WatchFaceReading.self, from: data)
    }

    static func lastReload(defaults: UserDefaults) -> Date? {
        let interval = defaults.double(forKey: reloadKey)
        guard interval > 0 else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    static func markReloaded(_ date: Date, defaults: UserDefaults) {
        defaults.set(date.timeIntervalSince1970, forKey: reloadKey)
    }
}
