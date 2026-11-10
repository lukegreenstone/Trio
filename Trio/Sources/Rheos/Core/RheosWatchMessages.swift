import Foundation

/// One Rheos row the phone sends to the watch. Confirming it stores a note.
/// It does not contain an insulin amount.
struct RheosWatchSuggestionLine: Equatable, Codable, Identifiable {
    var id: String
    var kind: String
    var title: String
    var note: String
}

struct RheosWatchSnapshot: Equatable {
    var mode: String
    var suggestions: [RheosWatchSuggestionLine]
    var chatReply: String
}

enum RheosWatchCatalog {
    static func lines(care: RheosCareReport?, chat: [RheosChatSuggestion], limit: Int = 6) -> [RheosWatchSuggestionLine] {
        var lines: [RheosWatchSuggestionLine] = []
        if let patch = care?.patchCheck, !patch.isEmpty {
            lines.append(RheosWatchSuggestionLine(id: "care-patch", kind: "note", title: "Pflaster", note: clip(patch)))
        }
        if let hypo = care?.hypoSuggestion, !hypo.isEmpty {
            lines.append(RheosWatchSuggestionLine(id: "care-hypo", kind: "note", title: "Hypo", note: clip(hypo)))
        }
        if let alcohol = care?.alcohol, !alcohol.isEmpty {
            lines.append(RheosWatchSuggestionLine(id: "care-alcohol", kind: "note", title: "Alkohol", note: clip(alcohol)))
        }
        for suggestion in chat where RheosWatchMessages.allowedKinds.contains(suggestion.kind) {
            lines.append(RheosWatchSuggestionLine(
                id: suggestion.id,
                kind: suggestion.kind,
                title: suggestion.kind,
                note: clip(suggestion.text)
            ))
        }
        return Array(lines.prefix(limit))
    }

    static func clip(_ text: String) -> String {
        String(text.prefix(180))
    }
}

enum RheosWatchAction: Equatable {
    case silence(minutes: Int, style: AlarmSilenceStyle?)
    case confirm(kind: String, note: String, suggestionID: String?)
    case reject(kind: String, note: String, suggestionID: String?)
    case chat(String)
}

struct RheosWatchFields: Equatable {
    var snoozeMinutes: Int?
    var snoozeStyle: String?
    var decision: String?
    var kind: String?
    var note: String?
    var suggestionID: String?
    var chat: String?
    var containsBolusOrCarbs: Bool = false
}

enum RheosWatchMessages {
    /// Kinds a watch tap is allowed to store. There is no bolus kind.
    static let allowedKinds: Set<String> = [
        "sport", "urlaub", "krank", "fasten", "showtime", "meal", "alcohol", "snack", "note"
    ]

    static func action(_ fields: RheosWatchFields) -> RheosWatchAction? {
        if fields.containsBolusOrCarbs { return nil }
        if let minutes = fields.snoozeMinutes {
            let style = fields.snoozeStyle.flatMap(AlarmSilenceStyle.init(rawValue:))
            return .silence(minutes: AlarmSilencePolicy.clampedMinutes(minutes), style: style)
        }
        if let decision = fields.decision, let kind = fields.kind, allowedKinds.contains(kind) {
            let note = String((fields.note ?? "").prefix(240))
            let identifier = fields.suggestionID.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }
            if decision == "confirm" {
                return .confirm(kind: kind, note: note, suggestionID: identifier)
            }
            if decision == "reject" {
                return .reject(kind: kind, note: note, suggestionID: identifier)
            }
        }
        if let chat = fields.chat {
            let trimmed = chat.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return .chat(String(trimmed.prefix(240)))
        }
        return nil
    }

    /// Watch confirmations never carry a dose. Bolus stays on Trio's watch bolus request.
    static func changesInsulin(_: RheosWatchAction) -> Bool {
        false
    }
}
