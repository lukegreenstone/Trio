import Foundation

/// How a temporary glucose-alarm silence behaves.
/// Urgent low glucose is never fully silenced. See `AlarmSilencePolicy`.
enum AlarmSilenceStyle: String, Codable, Equatable, Sendable {
    case vibrateOnly
    case fullySilent
}

/// What the alert manager should do with one alert during a snooze window.
enum AlarmDelivery: Equatable, Sendable {
    /// Show the alert. `tone` false means no sound; the phone still vibrates when it can.
    case deliver(tone: Bool)
    case suppress
}

enum AlarmSilencePolicy {
    /// mg/dL. An urgent low at or below this value, and every urgent-low alarm, stays audible.
    static let urgentLowMgdl = 55.0
    static let presetHours = [1, 2, 4, 6]
    static let maximumMinutes = 12 * 60

    static func isUrgentFloor(isUrgentLow: Bool, glucoseMgdl: Double?) -> Bool {
        if isUrgentLow { return true }
        if let glucoseMgdl, glucoseMgdl < urgentLowMgdl { return true }
        return false
    }

    /// `style` nil is the existing notification-action snooze: hide non-urgent alarms.
    /// A critical alert (occlusion and any alarm marked critical) still sounds.
    /// An urgent low, or any glucose reading under 55 mg/dL, still sounds and vibrates.
    static func delivery(
        snoozed: Bool,
        style: AlarmSilenceStyle?,
        isUrgentLow: Bool,
        glucoseMgdl: Double? = nil,
        isCritical: Bool = false
    ) -> AlarmDelivery {
        if !snoozed { return .deliver(tone: true) }
        if isCritical || isUrgentFloor(isUrgentLow: isUrgentLow, glucoseMgdl: glucoseMgdl) {
            return .deliver(tone: true)
        }
        switch style {
        case .vibrateOnly:
            return .deliver(tone: false)
        case .fullySilent,
             .none:
            return .suppress
        }
    }

    /// Zero ends the silence. Any other value is kept between 1 minute and 12 hours.
    static func clampedMinutes(_ minutes: Int) -> Int {
        if minutes <= 0 { return 0 }
        return min(maximumMinutes, max(1, minutes))
    }
}

enum AlarmSilenceStore {
    static let styleKey = "rheos.alarmSilence.style"

    static func current(defaults: UserDefaults = .standard) -> AlarmSilenceStyle? {
        guard let raw = defaults.string(forKey: styleKey) else { return nil }
        return AlarmSilenceStyle(rawValue: raw)
    }

    static func set(_ style: AlarmSilenceStyle?, defaults: UserDefaults = .standard) {
        if let style {
            defaults.set(style.rawValue, forKey: styleKey)
        } else {
            defaults.removeObject(forKey: styleKey)
        }
    }
}

/// Glucose attached to the alert being issued, on this thread only.
/// Carbs-required and forecast alerts do not set it, because their number is not a glucose reading.
enum AlarmSilenceContext {
    private static let key = "rheos.alarmSilence.glucoseMgdl"

    static var currentMgdl: Double? {
        Thread.current.threadDictionary[key] as? Double
    }

    static func perform(glucoseMgdl: Double, _ work: () -> Void) {
        let previous = Thread.current.threadDictionary[key]
        Thread.current.threadDictionary[key] = glucoseMgdl
        work()
        if let previous {
            Thread.current.threadDictionary[key] = previous
        } else {
            Thread.current.threadDictionary.removeObject(forKey: key)
        }
    }
}
