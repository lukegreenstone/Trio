import Foundation
import Swinject

struct RheosChatResult: Equatable {
    var text: String
    var suggestions: [RheosChatSuggestion]
    var source: String
}

enum RheosChatEngine {
    static func reply(
        question: String,
        report: RheosReport,
        resolver: Resolver,
        settingsNote: String = ""
    ) async -> RheosChatResult {
        let prompt = prompt(question: question, report: report, settingsNote: settingsNote)
        if RheosCloudPolicy.allowsCloud(), let text = await RheosCloudChat.reply(prompt: prompt, resolver: resolver) {
            return packaged(text, source: "Cloud-Modell, Schlüssel aus dem Schlüsselbund")
        }
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            do {
                let text = try await RheosFoundationChat.reply(prompt: prompt)
                return packaged(text, source: "Apple Foundation Models, auf dem Gerät")
            } catch {
                // The on-device model is unavailable. The local report answers.
            }
        }
        #endif
        let local = RheosChatStub.reply(question: question, report: report, settingsNote: settingsNote)
        return packaged(local, source: "Lokale Auswertung, ohne Sprachmodell")
    }

    static func packaged(_ text: String, source: String) -> RheosChatResult {
        RheosChatResult(text: text, suggestions: RheosChatParser.suggestions(in: text), source: source)
    }

    static func prompt(question: String, report: RheosReport, settingsNote: String = "") -> String {
        let contexts = report.contexts.map { "\($0.title): \($0.summary)" }.joined(separator: "\n")
        let presets = report.mealPresets.map(\.suggestion).joined(separator: "\n")
        return """
        \(RheosChatParser.instructions())

        Bericht:
        \(report.stability.summary)
        \(report.decision.reason)
        \(report.dawn.summary)
        \(contexts)
        \(presets)

        Trio-Einstellungen, nur gelesen:
        \(settingsNote)

        Frage: \(question)
        """
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26, *)
enum RheosFoundationChat {
    static func reply(prompt: String) async throws -> String {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw CancellationError()
        }
        let session = LanguageModelSession(instructions: RheosChatParser.instructions())
        let response = try await session.respond(to: prompt)
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CancellationError() }
        return text
    }
}
#endif

enum RheosCloudChat {
    static let keychainKey = "rheos.llm.apiKey"
    static let baseURLKey = "rheos.llm.baseURL"
    static let modelKey = "rheos.llm.model"
    static let defaultBaseURL = "https://api.openai.com/v1"
    static let defaultModel = "gpt-4o-mini"

    static func reply(prompt: String, resolver: Resolver) async -> String? {
        guard let keychain = resolver.resolve(Keychain.self),
              let key = try? keychain.getValue(String.self, forKey: keychainKey).get(),
              !key.isEmpty else { return nil }
        var base = UserDefaults.standard.string(forKey: baseURLKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultBaseURL
        while base.hasSuffix("/") { base.removeLast() }
        let model = UserDefaults.standard.string(forKey: modelKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel
        guard let url = URL(string: base + "/chat/completions") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": RheosChatParser.instructions()],
                ["role": "user", "content": prompt]
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let downloaded: (Data, URLResponse)
        do {
            downloaded = try await URLSession.shared.data(for: request)
        } catch {
            return nil
        }
        let (data, response) = downloaded
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
