import Foundation

extension Foundation.Notification.Name {
    static let rheosModeDidChange = Foundation.Notification.Name("rheosModeDidChange")
}

/// Rheos mode lives in UserDefaults, not in TrioSettings or preferences.
/// Missing key means Aus, so an existing install does not change behaviour.
enum RheosModeStore {
    static let key = "rheos.mode"

    static var current: RheosMode {
        RheosMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .aus
    }

    static func set(_ mode: RheosMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: key)
        if mode != .scharf {
            let reason = mode == .aus
                ? "Rheos ist aus. Trio rechnet unverändert."
                : "Schattenmodus. Gelernte Faktoren werden nicht angewendet."
            RheosStore.shared.disarmApplication(mode: mode, reason: reason)
            let hour = Calendar.current.component(.hour, from: Date())
            RheosStore.shared.appendApplication(
                RheosApplicationLog(
                    date: Date(),
                    applied: false,
                    code: mode == .aus ? .off : .shadow,
                    reason: reason,
                    hour: hour,
                    basal: 1,
                    isf: 1,
                    carbRatio: 1,
                    bandMinimum: 1,
                    bandMaximum: 1
                )
            )
        }
        Foundation.NotificationCenter.default.post(
            name: Foundation.Notification.Name.rheosModeDidChange,
            object: mode
        )
    }
}
