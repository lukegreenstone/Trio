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
            let outcome = await RheosCloudChat.reply(prompt: prompt, resolver: resolver)
            switch outcome {
            case let .success(text, model):
                if let estimate = RheosMealParser.estimate(in: text) {
                    debug(.default, "Rheos meal text from \(model)")
                    return (estimate, RheosCloudChat.sourceName(model: model))
                }
                debug(.default, "Rheos meal text: cloud text had no usable grams")
                return await onDeviceOrGrams(prompt, missing: "\(RheosCloudChat.sourceName(model: model)): die Antwort hatte keine brauchbaren Gramm. 0/0/0 zählt nicht.")
            case let .failure(message):
                debug(.default, "Rheos meal text cloud failure")
                return await onDeviceOrGrams(prompt, missing: message)
            }
        }
        debug(.default, "Rheos meal text: cloud switch off")
        return await onDeviceOrGrams(prompt, missing: "Cloud-Auswertung ist aus.")
    }

    static func estimate(jpeg: Data, resolver: Resolver) async -> (RheosMealEstimate?, String) {
        guard RheosCloudPolicy.allowsCloud() else {
            debug(.default, "Rheos meal photo: cloud switch off")
            return (nil, "Foto-Schätzung braucht die Cloud-Auswertung. Sie ist aus. Bitte Gramm eintragen. Ein Foto geht nicht an Apple Foundation Models.")
        }
        let encoded = jpeg.base64EncodedString()
        let body: [String: Any] = [
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": RheosMealText.photoPrompt],
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(encoded)"]]
                    ]
                ]
            ]
        ]
        let outcome = await RheosCloudChat.perform(extra: body, resolver: resolver)
        switch outcome {
        case let .success(text, model):
            if let estimate = RheosMealParser.estimate(in: text) {
                debug(.default, "Rheos meal photo from \(model)")
                return (estimate, "\(RheosCloudChat.sourceName(model: model)), Foto")
            }
            return (nil, "\(RheosCloudChat.sourceName(model: model)): das Foto ergab keine brauchbaren Gramm. 0/0/0 zählt nicht. Bitte Gramm eintragen.")
        case let .failure(message):
            return (nil, message + " Bitte Gramm eintragen.")
        }
    }

    private static func onDeviceOrGrams(_ prompt: String, missing: String) async -> (RheosMealEstimate?, String) {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            do {
                let meal = try await RheosFoundationChat.meal(from: prompt)
                debug(.default, "Rheos meal from guided Apple model")
                return (meal, "Apple auf dem Gerät")
            } catch {
                debug(.default, "Rheos guided Apple meal failed, trying text")
            }
            do {
                let text = try await RheosFoundationChat.reply(prompt: prompt)
                if let estimate = RheosMealParser.estimate(in: text) {
                    debug(.default, "Rheos meal text from Apple on device")
                    return (estimate, "Apple auf dem Gerät")
                }
            } catch {
                debug(.default, "Rheos Apple model unavailable")
            }
            return (nil, "\(missing) Apple auf dem Gerät hat keine brauchbaren Gramm geliefert. Bitte Gramm eintragen.")
        }
        #endif
        return (nil, "\(missing) Apple auf dem Gerät braucht iOS 26. Bitte Gramm eintragen.")
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
