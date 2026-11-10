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
