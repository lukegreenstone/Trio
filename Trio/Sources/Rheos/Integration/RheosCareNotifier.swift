import Foundation
import UserNotifications

/// Local notices for Rheos suggestions.
///
/// Identifiers start with `rheos.suggestion.` so they are not Trio glucose alarms
/// (`glucose.*`). This type never removes, mutes, or replaces those alarms.
enum RheosCareNotifier {
    static func post(_ report: RheosCareReport) {
        if let text = report.patchCheck {
            post(id: "rheos.suggestion.patch", body: text)
        }
        if let text = report.hypoSuggestion {
            post(id: "rheos.suggestion.hypo", body: text)
        }
        if let text = report.alcohol, text.contains("Temp-Target") {
            post(id: "rheos.suggestion.alcohol", body: text)
        }
    }

    static let sundayKey = "rheos.weeklySunday"
    private static let sundayStamp = "rheos.notify.weeklySunday"

    /// Off unless `rheos.weeklySunday` is true. One notice per calendar week.
    static func sundayReport(enabled: Bool, text: String, now: Date, calendar: Calendar = .current) {
        guard enabled, calendar.component(.weekday, from: now) == 1, !text.isEmpty else { return }
        let week = calendar.component(.weekOfYear, from: now)
        let year = calendar.component(.yearForWeekOfYear, from: now)
        let stamp = "\(year)-\(week)"
        if UserDefaults.standard.string(forKey: sundayStamp) == stamp { return }
        UserDefaults.standard.set(stamp, forKey: sundayStamp)
        let content = UNMutableNotificationContent()
        content.title = "Rheos Wochenbericht"
        content.body = String(text.prefix(180))
        content.sound = nil
        let request = UNNotificationRequest(identifier: "rheos.suggestion.weekly", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    static func postPlain(id: String, body: String) {
        post(id: id, body: body)
    }

    static func extendPreset(name: String) {
        post(id: "rheos.suggestion.preset.\(name)", body: "„\(name)“ ist abgelaufen. In Rheos kannst du es verlängern. Rheos ändert das Preset nicht von selbst.")
    }

    private static func post(id: String, body: String) {
        let defaults = UserDefaults.standard
        let key = "rheos.notify." + id
        if let last = defaults.object(forKey: key) as? Date, Date().timeIntervalSince(last) < 3 * 3600 {
            return
        }
        defaults.set(Date(), forKey: key)
        let content = UNMutableNotificationContent()
        content.title = "Rheos Hinweis"
        content.body = body
        content.sound = nil
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
