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
        var cloudFailure = ""
        if RheosCloudPolicy.allowsCloud() {
            let outcome = await RheosCloudChat.reply(prompt: prompt, resolver: resolver)
            if case let .success(text, model) = outcome {
                return packaged(text, source: RheosCloudChat.sourceName(model: model))
            }
            if case let .failure(message) = outcome {
                cloudFailure = message
            }
        }
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            do {
                let text = try await RheosFoundationChat.reply(prompt: prompt)
                let prefix = cloudFailure.isEmpty ? "" : cloudFailure + " Apple hat geantwortet.\n\n"
                return packaged(prefix + text, source: "Apple auf dem Gerät")
            } catch {
                debug(.default, "Rheos Apple chat model unavailable")
            }
        }
        #endif
        let local = RheosChatStub.reply(question: question, report: report, settingsNote: settingsNote)
        let text = cloudFailure.isEmpty ? local : cloudFailure + "\n\n" + local
        return packaged(text, source: "lokal")
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

enum RheosCloudOutcome: Equatable {
    case success(text: String, model: String)
    case failure(String)
}

enum RheosCloudChat {
    static let keychainKey = "rheos.llm.apiKey"
    static let baseURLKey = "rheos.llm.baseURL"
    static let modelKey = "rheos.llm.model"
    static let defaultBaseURL = "https://api.x.ai/v1"
    static let defaultModel = "grok-4.7"
    static let previousBaseURL = "https://api.openai.com/v1"
    static let previousModel = "gpt-4o-mini"
    static let requestTimeout: TimeInterval = 120

    static func sourceName(model: String) -> String {
        if model.lowercased().contains("grok") { return "Grok" }
        return "Cloud \(model)"
    }

    /// True only when the user already stored the old OpenAI pair. Those values stay.
    static func showsPreviousOpenAIChoice(defaults: UserDefaults = .standard) -> Bool {
        let base = defaults.string(forKey: baseURLKey) ?? ""
        let model = defaults.string(forKey: modelKey) ?? ""
        return base.contains("api.openai.com") && model == previousModel
    }

    static func saveEndpoint(base: String, model: String, defaults: UserDefaults = .standard) {
        saveBase(base, defaults: defaults)
        saveModel(model, defaults: defaults)
    }

    /// Writes one field only when it actually changed, so loading the screen cannot replace the other field.
    static func saveBase(_ value: String, defaults: UserDefaults = .standard) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let stored = defaults.string(forKey: baseURLKey) ?? ""
        guard trimmed != stored else { return }
        defaults.set(trimmed, forKey: baseURLKey)
    }

    static func saveModel(_ value: String, defaults: UserDefaults = .standard) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let stored = defaults.string(forKey: modelKey) ?? ""
        guard trimmed != stored else { return }
        defaults.set(trimmed, forKey: modelKey)
    }

    static func reply(prompt: String, resolver: Resolver) async -> RheosCloudOutcome {
        let body: [String: Any] = [
            "messages": [
                ["role": "system", "content": RheosChatParser.instructions()],
                ["role": "user", "content": prompt]
            ]
        ]
        return await perform(extra: body, resolver: resolver)
    }

    static func perform(extra: [String: Any], resolver: Resolver) async -> RheosCloudOutcome {
        guard let keychain = resolver.resolve(Keychain.self) else {
            return .failure("Grok: der Schlüsselbund ist nicht erreichbar.")
        }
        guard let key = try? keychain.getValue(String.self, forKey: keychainKey).get(), !key.isEmpty else {
            return .failure("Grok: kein API-Schlüssel im Schlüsselbund.")
        }
        var base = UserDefaults.standard.string(forKey: baseURLKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if base.isEmpty { base = defaultBaseURL }
        while base.hasSuffix("/") { base.removeLast() }
        var model = UserDefaults.standard.string(forKey: modelKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if model.isEmpty { model = defaultModel }
        let name = sourceName(model: model)
        guard let url = URL(string: base + "/chat/completions") else {
            return .failure("\(name): die Basis-URL ist ungültig.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        var payload = extra
        payload["model"] = model
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        let downloaded: (Data, URLResponse)
        do {
            downloaded = try await URLSession.shared.data(for: request)
        } catch {
            let timedOut = (error as? URLError)?.code == .timedOut
            debug(.default, "Rheos cloud request failed, timeout=\(timedOut)")
            if timedOut {
                return .failure("\(name): Zeitüberschreitung nach 120 Sekunden.")
            }
            return .failure("\(name): keine Verbindung.")
        }
        let (data, response) = downloaded
        guard let http = response as? HTTPURLResponse else {
            return .failure("\(name): keine HTTP-Antwort.")
        }
        guard (200 ... 299).contains(http.statusCode) else {
            debug(.default, "Rheos cloud HTTP \(http.statusCode)")
            return .failure(httpFailure(name: name, status: http.statusCode, data: data))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = RheosCloudContent.text(from: message["content"]) else {
            return .failure("\(name): leere Antwort.")
        }
        return .success(text: content, model: model)
    }

    static func httpFailure(name: String, status: Int, data: Data) -> String {
        if status == 401 || status == 403 {
            return "\(name): \(status), Schlüssel ungültig."
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        let clipped = String(raw.replacingOccurrences(of: "\n", with: " ").prefix(160))
        if clipped.isEmpty { return "\(name): HTTP \(status)." }
        return "\(name): HTTP \(status), \(clipped)"
    }
}
