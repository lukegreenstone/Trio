import Foundation
import Swinject

/// Optional online photo estimate. Uses the same Keychain key as the Rheos chat.
/// Offline, or without a key, the caller keeps the typed carbs, fat and protein.
enum RheosMealAssist {
    static func estimate(description: String, resolver: Resolver) async -> (RheosMealEstimate?, String) {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, "Bitte Gramm eintragen") }
        let prompt = RheosMealText.prompt(for: trimmed)
        if RheosCloudPolicy.allowsCloud(), let text = await RheosCloudChat.reply(prompt: prompt, resolver: resolver),
           let estimate = RheosMealParser.estimate(in: text) {
            return (estimate, "Cloud-Modell")
        }
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            do {
                let text = try await RheosFoundationChat.reply(prompt: prompt)
                if let estimate = RheosMealParser.estimate(in: text) {
                    return (estimate, "Apple Foundation Models, auf dem Gerät")
                }
            } catch {
                // On-device model unavailable. The caller asks for grams.
            }
        }
        #endif
        return (nil, "Bitte Kohlenhydrate, Fett und Protein in Gramm eintragen")
    }

    static func estimate(jpeg: Data, resolver: Resolver) async -> RheosMealEstimate? {
        guard RheosCloudPolicy.allowsCloud() else { return nil }
        guard let keychain = resolver.resolve(Keychain.self),
              let key = try? keychain.getValue(String.self, forKey: RheosCloudChat.keychainKey).get(),
              !key.isEmpty else { return nil }
        var base = UserDefaults.standard.string(forKey: RheosCloudChat.baseURLKey)
            .flatMap { $0.isEmpty ? nil : $0 } ?? RheosCloudChat.defaultBaseURL
        while base.hasSuffix("/") { base.removeLast() }
        let model = UserDefaults.standard.string(forKey: RheosCloudChat.modelKey)
            .flatMap { $0.isEmpty ? nil : $0 } ?? RheosCloudChat.defaultModel
        guard let url = URL(string: base + "/chat/completions") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let encoded = jpeg.base64EncodedString()
        let body: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": "Schätze Kohlenhydrate, Fett und Protein in Gramm. Antworte nur mit JSON: {\"carbs\":0,\"fat\":0,\"protein\":0,\"kcal\":0}"],
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(encoded)"]]
                    ]
                ]
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
        return RheosMealParser.estimate(in: content)
    }
}

enum RheosLoopFactorLoader {
    /// Reads the current Autosens file and the newest dynamic ISF already stored
    /// on a determination. The band stays the intersection already used by the hook.
    static func reading(resolver: Resolver, states: [RheosStatePoint], now: Date) -> RheosLoopReading {
        var ratio = 1.0
        if let storage = resolver.resolve(FileStorage.self),
           let autosens = storage.retrieve(OpenAPS.Settings.autosense, as: Autosens.self) {
            ratio = NSDecimalNumber(decimal: autosens.ratio).doubleValue
        }
        let dynamic = states.max { $0.date < $1.date }?.dynamicISF
        return RheosLoopReading(autosensRatio: ratio, dynamicISF: dynamic, recordedAt: now)
    }
}
