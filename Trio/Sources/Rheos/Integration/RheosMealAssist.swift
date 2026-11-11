import Foundation
import Swinject

/// Optional online photo estimate. Uses the same Keychain key as the Rheos chat.
/// Offline, or without a key, the caller keeps the typed carbs, fat and protein.
enum RheosMealHandoff {
    static let openKey = "rheos.openTreatments"

    /// The home sheet is already presented, so Treatments opens only after that sheet closes.
    static func requestOpenAfterDismiss() {
        UserDefaults.standard.set(true, forKey: openKey)
        debug(.default, "Rheos meal handoff waits for the home sheet to close")
    }

    static func consumeOpen() -> Bool {
        let open = UserDefaults.standard.bool(forKey: openKey)
        if open { UserDefaults.standard.set(false, forKey: openKey) }
        return open
    }

    /// Nil when the draft is stored. Otherwise the message to show.
    static func saveForTreatments(_ draft: RheosMealEstimate) -> String? {
        guard draft.carbs > 0 || draft.fat > 0 || draft.protein > 0 else {
            return "Keine Gramm zum Übernehmen. Bitte Kohlenhydrate, Fett oder Protein eintragen."
        }
        guard RheosMealDraftStore.save(draft) else {
            return "Die Werte konnten nicht gespeichert werden. Bitte noch einmal versuchen."
        }
        debug(.default, "Rheos meal draft stored carbs=\(draft.carbs) fat=\(draft.fat) protein=\(draft.protein)")
        return nil
    }
}

enum RheosMealAssist {
    static func estimate(description: String, resolver: Resolver) async -> (RheosMealEstimate?, String) {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            debug(.default, "Rheos meal text empty")
            return (nil, "Bitte eine Beschreibung oder Gramm eintragen.")
        }
        let prompt = RheosMealText.prompt(for: trimmed)
        if RheosCloudPolicy.allowsCloud() {
            guard hasCloudKey(resolver) else {
                debug(.default, "Rheos meal text: cloud on, no key")
                return await onDeviceOrGrams(prompt, missing: "Cloud-Auswertung ist an, aber im Schlüsselbund liegt kein API-Schlüssel.")
            }
            let cloud = await RheosCloudChat.reply(prompt: prompt, resolver: resolver)
            if let cloud, let estimate = RheosMealParser.estimate(in: cloud) {
                debug(.default, "Rheos meal text from cloud")
                return (estimate, "Cloud-Modell")
            }
            debug(.default, "Rheos meal text: cloud gave no usable estimate")
            return await onDeviceOrGrams(prompt, missing: "Das Cloud-Modell hat keine verwertbare Schätzung geliefert.")
        }
        debug(.default, "Rheos meal text: cloud switch off")
        return await onDeviceOrGrams(prompt, missing: "Cloud-Auswertung ist aus.")
    }

    static func estimate(jpeg: Data, resolver: Resolver) async -> (RheosMealEstimate?, String) {
        guard RheosCloudPolicy.allowsCloud() else {
            debug(.default, "Rheos meal photo: cloud switch off")
            return (nil, "Foto-Schätzung braucht die Cloud-Auswertung. Sie ist aus. Bitte Gramm eintragen. Ein Foto geht nicht an Apple Foundation Models.")
        }
        guard hasCloudKey(resolver) else {
            debug(.default, "Rheos meal photo: no key")
            return (nil, "Foto-Schätzung braucht einen API-Schlüssel im Schlüsselbund. Bitte Gramm eintragen.")
        }
        guard let keychain = resolver.resolve(Keychain.self),
              let key = try? keychain.getValue(String.self, forKey: RheosCloudChat.keychainKey).get(),
              !key.isEmpty else { return (nil, "Foto-Schätzung braucht einen API-Schlüssel im Schlüsselbund. Bitte Gramm eintragen.") }
        var base = UserDefaults.standard.string(forKey: RheosCloudChat.baseURLKey)
            .flatMap { $0.isEmpty ? nil : $0 } ?? RheosCloudChat.defaultBaseURL
        while base.hasSuffix("/") { base.removeLast() }
        let model = UserDefaults.standard.string(forKey: RheosCloudChat.modelKey)
            .flatMap { $0.isEmpty ? nil : $0 } ?? RheosCloudChat.defaultModel
        guard let url = URL(string: base + "/chat/completions") else {
            return (nil, "Die Cloud-Adresse ist ungültig. Bitte Gramm eintragen.")
        }
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
            debug(.default, "Rheos meal photo request failed")
            return (nil, "Das Cloud-Modell hat nicht geantwortet. Bitte Gramm eintragen.")
        }
        let (data, response) = downloaded
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              let estimate = RheosMealParser.estimate(in: content) else {
            debug(.default, "Rheos meal photo: unusable response")
            return (nil, "Das Foto ergab keine verwertbare Schätzung. Bitte Gramm eintragen.")
        }
        debug(.default, "Rheos meal photo from cloud")
        return (estimate, "Cloud-Modell, Foto")
    }

    private static func hasCloudKey(_ resolver: Resolver) -> Bool {
        guard let keychain = resolver.resolve(Keychain.self),
              let key = try? keychain.getValue(String.self, forKey: RheosCloudChat.keychainKey).get() else { return false }
        return !key.isEmpty
    }

    private static func onDeviceOrGrams(_ prompt: String, missing: String) async -> (RheosMealEstimate?, String) {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            do {
                let text = try await RheosFoundationChat.reply(prompt: prompt)
                if let estimate = RheosMealParser.estimate(in: text) {
                    debug(.default, "Rheos meal text from Apple on device")
                    return (estimate, "Apple Foundation Models, auf dem Gerät")
                }
            } catch {
                debug(.default, "Rheos Apple model unavailable")
            }
            return (nil, "\(missing) Apple Foundation Models auf diesem iPhone hat keine Schätzung geliefert. Bitte Gramm eintragen.")
        }
        #endif
        return (nil, "\(missing) Apple Foundation Models braucht iOS 26. Bitte Gramm eintragen.")
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
