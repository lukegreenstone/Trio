import Foundation

struct RheosChatSuggestion: Equatable, Identifiable {
    var id: String { "\(kind)-\(text)" }
    var kind: String
    var text: String
}

enum RheosChatParser {
    /// Pulls optional suggestion blocks out of a reply.
    /// A suggestion is a note the user can confirm. It is not a dose and not a limit change.
    static func suggestions(in reply: String) -> [RheosChatSuggestion] {
        let pattern = #"\[\[suggestion kind=([a-z]+)\]\]([\s\S]*?)\[\[/suggestion\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(reply.startIndex..., in: reply)
        return regex.matches(in: reply, range: range).compactMap { match in
            guard let kindRange = Range(match.range(at: 1), in: reply),
                  let textRange = Range(match.range(at: 2), in: reply) else { return nil }
            let kind = String(reply[kindRange])
            guard ["sport", "urlaub", "krank", "fasten", "showtime", "meal"].contains(kind) else { return nil }
            let text = reply[textRange].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return RheosChatSuggestion(kind: kind, text: text)
        }
    }

    static func instructions() -> String {
        """
        Du erklärst den Rheos-Schattenbericht dieser einen Person. Antworte in der Sprache der Frage.
        Du darfst Muster beschreiben und optionale Hinweise geben.
        Du darfst keinen Bolus, keine Basalrate und keine Änderung von Max IOB, Max Basal, Max Bolus, Max SMB oder Autosens anordnen.
        Wenn du einen freiwilligen Hinweis gibst, schreibe ihn genau so:
        [[suggestion kind=sport]]
        kurzer Text
        [[/suggestion]]
        Erlaubte kind-Werte: sport, urlaub, krank, fasten, showtime, meal.
        Ein Hinweis wird erst nach einer Bestätigung in der App notiert und dosiert nie.
        """
    }
}
