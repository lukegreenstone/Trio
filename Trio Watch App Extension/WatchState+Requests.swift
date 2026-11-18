import Foundation
import WatchConnectivity

// MARK: - Send Data to Phone

extension WatchState {
    /// Sends a bolus insulin request to the paired iPhone
    /// - Parameters:
    ///   - amount: The insulin amount to be delivered
    func sendBolusRequest(_ amount: Decimal) {
        if handyFreiRunning {
            showCommsAnimation = true
            acknowledgementStatus = .pending
            Task { await HandyFreiSession.shared.manualBolus(self, units: Double(truncating: amount as NSNumber)) }
            return
        }
        guard let session = session, session.isReachable else {
            Task {
                await WatchLogger.shared.log("⌚️ Bolus request aborted: session unreachable")
            }
            return
        }

        Task {
            await WatchLogger.shared.log("⌚️ Sending bolus request: \(amount)U")
        }

        let message: [String: Any] = [
            WatchMessageKeys.bolus: amount
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            Task {
                await WatchLogger.shared.log("Error sending bolus request: \(error)")
            }
        }

        // Display pending communication animation
        showCommsAnimation = true
        Task {
            await WatchLogger.shared.log("⌚️ showCommsAnimation = true")
        }
    }

    /// Sends a carbohydrate entry request to the paired iPhone
    /// - Parameters:
    ///   - amount: The amount of carbs in grams
    ///   - date: The timestamp for the carb entry (defaults to current time)
    func sendCarbsRequest(_ amount: Int, _ date: Date = Date()) {
        let fat = fatAmount
        let protein = proteinAmount
        let name = pendingMealName
        let capped = min(amount, max(0, NSDecimalNumber(decimal: maxCarbs).intValue))
        fatAmount = 0
        proteinAmount = 0
        pendingMealName = ""
        if handyFreiRunning {
            HandyFreiSession.shared.recordCarbs(
                grams: capped,
                fat: min(fat, max(0, NSDecimalNumber(decimal: maxFat).intValue)),
                protein: min(protein, max(0, NSDecimalNumber(decimal: maxProtein).intValue)),
                name: name,
                date: date,
                state: self
            )
            let shown = cob ?? "0"
            handleAcknowledgment(success: true, message: "\(capped) g gespeichert. COB \(shown) g")
            return
        }
        guard let session = session, session.isReachable else {
            Task {
                await WatchLogger.shared.log("⌚️ Carbs request aborted: session unreachable")
            }
            return
        }

        Task {
            await WatchLogger.shared.log("⌚️ Sending carbs request: \(amount)g at \(date)")
        }

        let message: [String: Any] = [
            WatchMessageKeys.carbs: capped,
            WatchMessageKeys.date: date.timeIntervalSince1970,
            WatchMessageKeys.fat: fat,
            WatchMessageKeys.protein: protein,
            WatchMessageKeys.mealName: name,
            WatchMessageKeys.carbID: UUID().uuidString
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            Task {
                await WatchLogger.shared.log("Error sending carbs request: \(error)")
                await WatchLogger.shared.log("⌚️ Saving logs to disk as fallback!")
                await WatchLogger.shared.persistLogsLocally()
            }
        }

        // Display pending communication animation
        showCommsAnimation = true
        Task {
            await WatchLogger.shared.log("⌚️ showCommsAnimation = true")
        }
    }

    /// Sends a request to cancel the current override preset to the paired iPhone
    func sendCancelOverrideRequest() {
        if handyFreiRunning {
            handleAcknowledgment(success: false, message: "Override bleibt auf dem iPhone. Der Loop nutzt das Profil aus dem Schnappschuss.")
            return
        }
        guard let session = session, session.isReachable else {
            Task {
                await WatchLogger.shared.log("⌚️ Cancel override request aborted: session unreachable")
            }
            return
        }

        Task {
            await WatchLogger.shared.log("⌚️ Sending cancel override request")
        }

        let message: [String: Any] = [
            WatchMessageKeys.cancelOverride: true
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            Task {
                await WatchLogger.shared.log("⌚️ Error sending cancel override request: \(error)")
                await WatchLogger.shared.log("⌚️ Saving logs to disk as fallback!")
                await WatchLogger.shared.persistLogsLocally()
            }
        }

        // Display pending communication animation
        showCommsAnimation = true
        Task {
            await WatchLogger.shared.log("⌚️ showCommsAnimation = true")
        }
    }

    /// Sends a request to activate an override preset to the paired iPhone
    /// - Parameter presetName: The name of the override preset to activate
    func sendActivateOverrideRequest(presetName: String) {
        if handyFreiRunning {
            handleAcknowledgment(success: false, message: "Override \(presetName) bleibt auf dem iPhone. Der Loop nutzt das Profil aus dem Schnappschuss.")
            return
        }
        guard let session = session, session.isReachable else {
            Task {
                await WatchLogger.shared.log("⌚️ Activate override request aborted: session unreachable")
            }
            return
        }

        Task {
            await WatchLogger.shared.log("⌚️ Sending activate override request for preset: \(presetName)")
        }

        let message: [String: Any] = [
            WatchMessageKeys.activateOverride: presetName
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            Task {
                await WatchLogger.shared.log("⌚️ Error sending activate override request: \(error)")
                await WatchLogger.shared.log("⌚️ Saving logs to disk as fallback!")
                await WatchLogger.shared.persistLogsLocally()
            }
        }

        // Display pending communication animation
        showCommsAnimation = true
        Task {
            await WatchLogger.shared.log("⌚️ showCommsAnimation = true")
        }
    }

    /// Sends a request to cancel the current temporary target to the paired iPhone
    func sendCancelTempTargetRequest() {
        if handyFreiRunning {
            handleAcknowledgment(success: false, message: "Temp-Ziel bleibt auf dem iPhone. Der Loop nutzt das Profil aus dem Schnappschuss.")
            return
        }
        guard let session = session, session.isReachable else {
            Task {
                await WatchLogger.shared.log("⌚️ Cancel temp target request aborted: session unreachable")
            }
            return
        }

        Task {
            await WatchLogger.shared.log("⌚️ Sending cancel temp target request")
        }

        let message: [String: Any] = [
            WatchMessageKeys.cancelTempTarget: true
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            Task {
                await WatchLogger.shared.log("⌚️ Error sending cancel temp target request: \(error)")
                await WatchLogger.shared.log("⌚️ Saving logs to disk as fallback!")
                await WatchLogger.shared.persistLogsLocally()
            }
        }

        // Display pending communication animation
        showCommsAnimation = true
        Task {
            await WatchLogger.shared.log("⌚️ showCommsAnimation = true")
        }
    }

    /// Sends a request to activate a temporary target preset to the paired iPhone
    /// - Parameter presetName: The name of the temporary target preset to activate
    func sendActivateTempTargetRequest(presetName: String) {
        if handyFreiRunning {
            handleAcknowledgment(success: false, message: "Temp-Ziel \(presetName) bleibt auf dem iPhone. Der Loop nutzt das Profil aus dem Schnappschuss.")
            return
        }
        guard let session = session, session.isReachable else {
            Task {
                await WatchLogger.shared.log("⌚️ Activate temp target request aborted: session unreachable")
            }
            return
        }

        Task {
            await WatchLogger.shared.log("⌚️ Sending activate temp target request for preset: \(presetName)")
        }

        let message: [String: Any] = [
            WatchMessageKeys.activateTempTarget: presetName
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            Task {
                await WatchLogger.shared.log("⌚️ Error sending activate temp target request: \(error)")
                await WatchLogger.shared.log("⌚️ Saving logs to disk as fallback!")
                await WatchLogger.shared.persistLogsLocally()
            }
        }

        // Display pending communication animation
        showCommsAnimation = true
        Task {
            await WatchLogger.shared.log("⌚️ showCommsAnimation = true")
        }
    }

    /// Sends a request to calculate a bolus recommendation based on the current carbs amount
    func requestBolusRecommendation() {
        if handyFreiRunning {
            let settings = HandyFreiLoop.mealSettings(handyFreiFiles)
            let context = HandyFreiLoop.bolusContext(handyFreiFiles)
            let glucose = Double(handyFreiGlucose ?? 0)
            let units = HandyFreiLoop.recommendBolus(
                carbs: Double(carbsAmount),
                glucose: glucose,
                delta: 0,
                iob: Double(iob ?? "") ?? 0,
                cob: Double(cob ?? "") ?? 0,
                isf: context.isf,
                carbRatio: context.carbRatio,
                target: context.target,
                basal: context.basal,
                fraction: NSDecimalNumber(decimal: bolusFraction).doubleValue,
                fatty: useReducedBolus && settings.fatty,
                fattyFactor: NSDecimalNumber(decimal: fattyMealFactor).doubleValue,
                sweet: useSuperBolus && settings.sweet,
                sweetFactor: NSDecimalNumber(decimal: sweetMealFactor).doubleValue,
                maxBolus: NSDecimalNumber(decimal: maxBolus).doubleValue,
                maxIOB: context.maxIOB,
                maxCOB: context.maxCOB,
                increment: NSDecimalNumber(decimal: bolusIncrement).doubleValue,
                minPredBG: glucose,
                lastLoop: Date(),
                now: Date()
            )
            recommendedBolus = NSDecimalNumber(value: units).decimalValue
            return
        }
        guard let session = session, session.isReachable else {
            Task {
                await WatchLogger.shared.log("⌚️ Bolus recommendation request aborted: session unreachable")
            }
            return
        }

        Task {
            await WatchLogger.shared.log("⌚️ Requesting bolus recommendation for carbs: \(carbsAmount)")
        }

        // Show a progress indicator until the phone replies. This keeps the user from
        // tapping the (0 U) "Log Carbs" button before the recommendation has landed.
        DispatchQueue.main.async {
            self.showBolusCalculationProgress = true
        }

        // The phone drops the reply silently if its session is unreachable at reply
        // time, so there is no guaranteed response to clear the flag. Fall back to a
        // timeout that reveals the normal UI.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if self.showBolusCalculationProgress {
                self.showBolusCalculationProgress = false
            }
        }

        let message: [String: Any] = [
            WatchMessageKeys.requestBolusRecommendation: true,
            WatchMessageKeys.carbs: carbsAmount,
            "useFattyMeal": useReducedBolus && fattyMeals,
            "useSuperBolus": useSuperBolus && sweetMeals
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            Task {
                await WatchLogger.shared.log("Error requesting bolus recommendation: \(error)")
                await WatchLogger.shared.log("⌚️ Saving logs to disk as fallback!")
                await WatchLogger.shared.persistLogsLocally()
            }
            DispatchQueue.main.async {
                self.showBolusCalculationProgress = false
            }
        }
    }

    /// Asks the phone to silence glucose alarms. Urgent low under 55 mg/dL still sounds there.
    func sendAlarmSilence(minutes: Int, style: String) {
        sendToPhone(
            [
                WatchMessageKeys.snoozeDuration: minutes,
                WatchMessageKeys.snoozeStyle: style
            ],
            log: "⌚️ Silence \(minutes) min (\(style))"
        )
        if minutes <= 0 {
            silenceUntil = nil
        } else {
            silenceUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        }
    }

    /// Records a Rheos note on the phone. This is not a bolus.
    func sendRheosConfirm(kind: String, note: String, suggestionID: String? = nil) {
        var message: [String: Any] = [
            WatchMessageKeys.rheosDecision: "confirm",
            WatchMessageKeys.rheosKind: kind,
            WatchMessageKeys.rheosNote: note
        ]
        if let suggestionID {
            message[WatchMessageKeys.rheosSuggestionID] = suggestionID
        }
        sendToPhone(message, log: "⌚️ Rheos confirm \(kind)")
    }

    func sendRheosReject(kind: String, note: String, suggestionID: String) {
        sendToPhone(
            [
                WatchMessageKeys.rheosDecision: "reject",
                WatchMessageKeys.rheosKind: kind,
                WatchMessageKeys.rheosNote: note,
                WatchMessageKeys.rheosSuggestionID: suggestionID
            ],
            log: "⌚️ Rheos reject \(kind)"
        )
    }

    func sendRheosChat(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sendToPhone(
            [WatchMessageKeys.rheosChat: String(trimmed.prefix(240))],
            log: "⌚️ Rheos chat"
        )
    }

    /// Same delivery Trio already uses for a watch snooze: immediate when the
    /// phone is reachable, queued transfer when it is nearby but not in front.
    private func sendToPhone(_ message: [String: Any], log: String) {
        guard WCSession.isSupported() else { return }
        let active = session ?? WCSession.default
        Task { await WatchLogger.shared.log(log) }
        if active.isReachable, active.activationState == .activated {
            active.sendMessage(message, replyHandler: nil) { _ in
                active.transferUserInfo(message)
            }
        } else {
            active.transferUserInfo(message)
        }
        showCommsAnimation = true
    }

    func requestWatchStateUpdate() {
        guard let session = session else {
            Task {
                await WatchLogger.shared.log("⌚️ No session available for state update")
            }
            return
        }

        guard session.activationState == .activated else {
            Task {
                await WatchLogger.shared.log("⌚️ Session not activated. Activating...")
            }
            session.activate()
            return
        }

        if session.isReachable {
            Task {
                await WatchLogger.shared.log("⌚️ Requesting WatchState update from iPhone")
            }

            let message = [WatchMessageKeys.requestWatchUpdate: WatchMessageKeys.watchState]

            session.sendMessage(message, replyHandler: nil) { error in
                Task {
                    await WatchLogger.shared.log("⌚️ Error requesting WatchState update: \(error)")
                    await WatchLogger.shared.log("⌚️ Saving logs to disk as fallback!")
                    await WatchLogger.shared.persistLogsLocally()
                }
            }
        } else {
            Task {
                await WatchLogger.shared.log("⌚️ Phone not reachable for WatchState update")
            }
        }
    }
}
