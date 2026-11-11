import Foundation
import HealthKit
import LoopKit
import Swinject
import UIKit

/// Starts Rheos logging when the mode is not Aus.
///
/// Refresh reads Trio's stored therapy data and HealthKit. It does not enact
/// insulin. The only automatic dosing effect is the profile hook in
/// `OpenAPS.createProfiles`, and only while Scharf is on and the model passed.
final class RheosCoordinator {
    private let resolver: Resolver
    private var started = false
    private var isRefreshing = false
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var careReport: RheosCareReport?
    private var chatSuggestions: [RheosChatSuggestion] = []
    private var watchChatReply = ""

    init(resolver: Resolver) {
        self.resolver = resolver
    }

    func start() {
        guard !started else { return }
        started = true
        RheosStore.shared.backupDirectory = { RheosICloudBackup.directory() }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 20, repeating: 15 * 60)
        timer.setEventHandler { [weak self] in
            Task { await self?.refresh() }
        }
        timer.resume()
        self.timer = timer

        let center: Foundation.NotificationCenter = Foundation.NotificationCenter.default
        let modeName: Foundation.Notification.Name = Foundation.Notification.Name.rheosModeDidChange
        let foregroundName: Foundation.Notification.Name = UIApplication.willEnterForegroundNotification
        let mainQueue: OperationQueue = OperationQueue.main
        observers.append(center.addObserver(forName: modeName, object: nil, queue: mainQueue) { [weak self] (_: Foundation.Notification) in
            Task { await self?.refresh() }
        })
        observers.append(center.addObserver(
            forName: foregroundName,
            object: nil,
            queue: mainQueue
        ) { [weak self] (_: Foundation.Notification) in
            Task { await self?.refresh() }
        })
        Task { await refresh() }
    }

    func setMode(_ mode: RheosMode) {
        RheosModeStore.set(mode)
        var state = RheosStore.shared.loadDocument()
        state.scharfSince = mode == .scharf ? Date() : nil
        RheosStore.shared.saveDocument(state)
    }

    func scharfPreview() -> String {
        let store = RheosStore.shared
        let state = store.loadDocument()
        let dataset = state.dataset
        let bounds = state.bounds.sanitized()
        let targets = RheosTargetLoader.schedule(resolver: resolver)
        let decision = RheosLearner.evaluate(
            dataset: dataset,
            mode: .scharf,
            bounds: bounds,
            previous: state.applied,
            autosensMin: autosensMin(),
            autosensMax: autosensMax(),
            targets: targets,
            scharfSince: Date(),
            now: Date()
        )
        let step = RheosRamp.maxStep(now: Date(), scharfSince: Date(), bounds: bounds, calendar: .current)
        return RheosRamp.preview(learned: decision.learnedFactors, step: step, shadow: state.shadow)
    }

    func refresh() async {
        guard RheosModeStore.current != .aus else { return }
        guard beginRefresh() else { return }
        defer { endRefresh() }

        let store = RheosStore.shared
        let previous = store.loadDataset()
        var dataset = await RheosSnapshotReader.read()
        var acknowledged: [String: Bool] = [:]
        for meal in previous.meals {
            acknowledged[meal.id] = meal.acknowledged
        }
        dataset.meals = dataset.meals.map { meal in
            var copy = meal
            copy.acknowledged = acknowledged[meal.id] ?? false
            return copy
        }
        dataset.body = previous.body
        dataset.bodyHistory = previous.bodyHistory
        let now = Date()
        dataset.loopReading = RheosLoopFactorLoader.reading(resolver: resolver, states: dataset.states, now: now)
        let scharfSince = store.loadDocument().scharfSince

        if let healthStore = resolver.resolve(HKHealthStore.self) {
            await RheosHealthReader.requestReadAccess(store: healthStore)
            let health = await RheosHealthReader.read(store: healthStore)
            dataset.wearableDays = health.days
            dataset.workouts = health.workouts
            dataset.sleep = health.sleep
            let measured = await RheosHealthReader.readBody(store: healthStore, now: now)
            let merged = RheosBodyRecord.merging(current: previous.body, health: measured)
            if !RheosBodyRecord.sameMeasurements(merged, previous.body) {
                dataset.body = merged
                dataset.bodyHistory = RheosBodyRecord.appending(
                    previous.bodyHistory,
                    inputs: merged,
                    source: "health",
                    now: now
                )
            }
        } else {
            dataset.wearableDays = previous.wearableDays
            dataset.workouts = previous.workouts
            dataset.sleep = previous.sleep
        }

        store.saveDataset(dataset, now: now)
        let decision = RheosLearner.evaluate(
            dataset: dataset,
            mode: RheosModeStore.current,
            bounds: store.loadBounds(),
            previous: store.loadApplied(),
            autosensMin: autosensMin(),
            autosensMax: autosensMax(),
            targets: RheosTargetLoader.schedule(resolver: resolver),
            scharfSince: scharfSince,
            acceptedSignals: store.loadDocument().acceptedSignals,
            dynamicISFOn: resolver.resolve(SettingsManager.self)?.preferences.useNewFormula == true,
            wake: store.loadDocument().wake,
            sites: store.patchSites(),
            now: now
        )
        store.saveDecision(decision)
        let accepted = store.loadDocument().acceptedSignals
        let fit = RheosCoreModel.fit(
            dataset: dataset,
            targets: RheosTargetLoader.schedule(resolver: resolver),
            band: store.loadBounds().effectiveRange(autosensMin: autosensMin(), autosensMax: autosensMax()),
            acceptedSignals: accepted,
            calendar: .current
        )
        var recorded = store.loadDocument()
        recorded.shadow = RheosShadowStatus(
            trained: fit.trained,
            source: fit.chosen,
            mae: fit.weights.mae,
            networkMAE: fit.weights.networkMAE,
            ridgeMAE: fit.weights.ridgeMAE,
            baselineMAE: fit.weights.baselineMAE,
            sampleCount: fit.weights.sampleCount
        )
        recorded.coreWeights = fit.weights
        store.saveDocument(recorded)
        let care = RheosCare.report(
            dataset: dataset,
            sites: store.patchSites(),
            alcoholDates: store.announcements().filter { $0.kind == "alcohol" }.map(\.date),
            learned: decision.reason,
            now: now,
            calendar: .current
        )
        RheosCareNotifier.post(care)
        let sunday = UserDefaults.standard.bool(forKey: RheosCareNotifier.sundayKey)
            && Calendar.current.component(.weekday, from: now) == 1
        let weeklyText: String
        if sunday {
            let prose = await weeklyProse(care.weekly)
            weeklyText = prose.0
        } else {
            weeklyText = care.weekly
        }
        RheosCareNotifier.sundayReport(enabled: sunday, text: weeklyText, now: now)
        promptExpiredPresets(now: now)
        recordHour(dataset: dataset, decision: decision, now: now)
        postUpkeep(dataset: dataset, now: now)
        let ends = dataset.sleep.map(\.end)
        updateWake(samples: RheosWake.samples(glucose: dataset.glucose, sleepEnds: ends, calendar: .current), lastWake: ends.max())
        replaceCare(care)
        if decision.applied {
            // Persist the slow model. The context nudge stays in the decision
            // the profile hook reads, and is recomputed next time.
            store.saveApplied(RheosAppliedState(factors: decision.slowFactors ?? decision.factors, appliedAt: now))
        } else {
            store.clearAppliedFactors()
        }
    }

    /// Optional note. It does not change a preset and does not deliver insulin.
    /// Scharf already adjusts ISF, carb ratio and basal from data without this.
    /// The watch uses this same method. A suggestion id only removes that row from the watch list.
    func confirmKind(kind: String, note: String, suggestionID: String? = nil) async -> String {
        let noted = announce(kind: kind, note: note, suggestionID: suggestionID)
        let preset: String
        switch kind {
        case "sport":
            preset = await startSavedPreset(named: "Sport")
        case "showtime":
            preset = await startSavedPreset(named: "Showtime")
        case "krank":
            preset = await startSavedPreset(named: "Krank")
        default:
            return noted
        }
        return noted + "\n" + preset
    }

    func startSavedPreset(named name: String) async -> String {
        guard let manager = resolver.resolve(AdjustmentManager.self) else {
            return "Die Trio-Anpassungen sind nicht erreichbar. Nichts geändert."
        }
        let now = Date()
        do {
            let outcome = try await manager.activateOverride(.presetName(name), source: .app)
            remember(name: name, outcome: outcome, now: now)
            return RheosPresetPlan.startedMessage(name: name, kind: "Override")
        } catch AdjustmentError.presetNotFound {
            do {
                let outcome = try await manager.activateTempTarget(.presetName(name), source: .app)
                remember(name: name, outcome: outcome, now: now)
                return RheosPresetPlan.startedMessage(name: name, kind: "Temp-Target")
            } catch AdjustmentError.presetNotFound {
                return RheosPresetPlan.missingMessage(name: name)
            } catch {
                return "Temp-Target „\(name)“ konnte nicht starten. \(error.localizedDescription)"
            }
        } catch {
            return "Override „\(name)“ konnte nicht starten. \(error.localizedDescription)"
        }
    }

    func decideSignal(_ name: String, accepted: Bool) {
        guard RheosSignalCatalog.names.contains(name) else { return }
        var state = RheosStore.shared.loadDocument()
        state.acceptedSignals.removeAll { $0 == name }
        state.rejectedSignals.removeAll { $0 == name }
        if accepted {
            state.acceptedSignals.append(name)
        } else {
            state.rejectedSignals.append(name)
        }
        RheosStore.shared.saveDocument(state)
    }

    func storeWeekComparison(now: Date = Date()) -> RheosWeekComparison {
        let store = RheosStore.shared
        var state = store.loadDocument()
        let bounds = state.bounds.sanitized()
        let fit = RheosCoreModel.fit(
            dataset: state.dataset,
            targets: RheosTargetLoader.schedule(resolver: resolver),
            band: bounds.effectiveRange(autosensMin: autosensMin(), autosensMax: autosensMax()),
            acceptedSignals: state.acceptedSignals,
            calendar: .current
        )
        let comparison = RheosShadowCompare.week(dataset: state.dataset, fit: fit, now: now, calendar: .current)
        state.weeklyComparisons.removeAll { $0.id == comparison.id }
        state.weeklyComparisons.append(comparison)
        store.saveDocument(state)
        return comparison
    }

    func announce(kind: String, note: String, suggestionID: String? = nil) -> String {
        guard RheosWatchMessages.allowedKinds.contains(kind) else {
            return "Unbekannter Hinweis. Nichts gespeichert und kein Bolus."
        }
        let text = announcementText(kind: kind)
        RheosStore.shared.addAnnouncement(
            RheosAnnouncement(id: UUID().uuidString, date: Date(), kind: kind, note: note)
        )
        noteConfirmation(text)
        dismissWatchSuggestion(id: suggestionID)
        return text
    }

    /// The user declined a suggestion. The note is stored and nothing is dosed.
    func reject(kind: String, note: String, suggestionID: String? = nil) -> String {
        guard RheosWatchMessages.allowedKinds.contains(kind) else {
            return "Unbekannter Hinweis. Nichts gespeichert und kein Bolus."
        }
        let text = "Abgelehnt: \(kind). Kein Bolus und keine Änderung der Grenzen."
        RheosStore.shared.addAnnouncement(
            RheosAnnouncement(id: UUID().uuidString, date: Date(), kind: "reject", note: "\(kind): \(note)")
        )
        noteConfirmation(text)
        dismissWatchSuggestion(id: suggestionID)
        return text
    }

    /// Short reply for the watch. The model can only add confirmable notes, never a bolus.
    func replyFromWatch(question: String) async -> String {
        let trimmed = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        guard !trimmed.isEmpty else { return "" }
        let store = RheosStore.shared
        let report = RheosReportBuilder.build(
            dataset: store.loadDataset(),
            mode: RheosModeStore.current,
            bounds: store.loadBounds(),
            previous: store.loadApplied(),
            autosensMin: autosensMin(),
            autosensMax: autosensMax(),
            targets: RheosTargetLoader.schedule(resolver: resolver),
            now: Date()
        )
        let result = await RheosChatEngine.reply(question: trimmed, report: report, resolver: resolver)
        let reply = String(result.text.prefix(280))
        storeWatchChat(reply: reply, suggestions: result.suggestions)
        return reply
    }

    /// Synchronous so NSLock is not taken inside an async function.
    private func remember(name: String, outcome: AdjustmentOutcome, now: Date) {
        let minutes = outcome.started?.duration.map { NSDecimalNumber(decimal: $0).doubleValue }
        var state = RheosStore.shared.loadDocument()
        state.presetRuns.append(
            RheosPresetRun(
                id: UUID().uuidString,
                name: name,
                started: now,
                ends: RheosPresetPlan.ends(started: now, minutes: minutes),
                prompted: false
            )
        )
        RheosStore.shared.saveDocument(state)
    }

    private func promptExpiredPresets(now: Date) {
        var state = RheosStore.shared.loadDocument()
        var changed = false
        for index in state.presetRuns.indices where !state.presetRuns[index].prompted && state.presetRuns[index].ends <= now {
            RheosCareNotifier.extendPreset(name: state.presetRuns[index].name)
            state.presetRuns[index].prompted = true
            changed = true
        }
        if changed { RheosStore.shared.saveDocument(state) }
    }

    func basalProposal() -> RheosBasalProposal {
        let state = RheosStore.shared.loadDocument()
        let storage = resolver.resolve(FileStorage.self)
        let profile = storage?.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? []
        let rates = profile.map { (minutes: $0.minutes, rate: NSDecimalNumber(decimal: $0.rate).doubleValue) }
        let factors = state.decision?.learnedFactors.basal ?? Array(repeating: 1, count: 24)
        let dawn = state.wake?.kind == RheosWakeKind.dawn.rawValue
            ? "Der morgendliche Anstieg hängt an der Uhrzeit und steckt in diesem Stundenprofil. "
            : "Ein Anstieg nach dem Aufwachen ist kein neues Basalprofil. "
        return RheosBasalRecommendation.propose(
            rates: rates,
            factors: factors,
            previous: state.lastProposedBasal,
            dawnNote: dawn
        )
    }

    func adoptBasalProposal() async -> String {
        let proposal = basalProposal()
        guard proposal.material || proposal.slots.contains(where: { $0.proposed > 0 }) else {
            return "Nichts zu übernehmen."
        }
        let entries = proposal.slots.filter { $0.proposed > 0 }.map {
            BasalProfileEntry(start: String(format: "%02d:00:00", $0.hour), minutes: $0.hour * 60, rate: Decimal($0.proposed))
        }
        guard !entries.isEmpty, let storage = resolver.resolve(FileStorage.self) else {
            return "Basalprofil nicht gefunden. Nichts geschrieben."
        }
        if let pump = resolver.resolve(APSManager.self)?.pumpManager {
            let sync = entries.map { RepeatingScheduleValue(startTime: TimeInterval($0.minutes * 60), value: Double($0.rate)) }
            let saved: Bool = await withCheckedContinuation { continuation in
                pump.syncBasalRateSchedule(items: sync) { result in
                    if case .success = result {
                        storage.save(entries, as: OpenAPS.Settings.basalProfile)
                        continuation.resume(returning: true)
                    } else {
                        continuation.resume(returning: false)
                    }
                }
            }
            guard saved else { return "Die Pumpe hat das Basalprofil nicht übernommen. Die Datei bleibt unverändert." }
        } else {
            storage.save(entries, as: OpenAPS.Settings.basalProfile)
        }
        var state = RheosStore.shared.loadDocument()
        state.lastProposedBasal = proposal.slots.map(\.proposed)
        RheosStore.shared.saveDocument(state)
        return "Basalprofil übernommen. Trio kann es als Fallback ohne iPhone nutzen. Rheos gibt keinen Bolus."
    }

    func learningNarrative() async -> (String, String) {
        let state = RheosStore.shared.loadDocument()
        let weekly = RheosCare.weeklyReport(
            glucose: RheosStore.shared.loadDataset().glucose,
            learned: state.decision?.reason ?? "",
            now: Date()
        )
        let local = RheosLearningReport.local(
            decisionReason: state.decision?.reason ?? "Noch keine Auswertung.",
            shadow: RheosCoreMLAdapter.statusLine(state.shadow),
            confidence: RheosLearningReport.confidence(samples: state.shadow.sampleCount, trained: state.shadow.trained)
        )
        let combined = local + "\n" + weekly
        let result = await weeklyProse(combined)
        return result
    }

    private func weeklyProse(_ local: String) async -> (String, String) {
        let prompt = "Formuliere knapp und ohne Bolus, ohne einzelne Glukosewerte: \(local)"
        if RheosCloudPolicy.allowsCloud() {
            if let text = await RheosCloudChat.reply(prompt: prompt, resolver: resolver) {
                return (text, "Cloud-Modell")
            }
        }
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            do {
                let text = try await RheosFoundationChat.reply(prompt: prompt)
                return (text, "Apple Foundation Models, auf dem Gerät")
            } catch {
                return (local, "Lokale Auswertung")
            }
        }
        #endif
        return (local, "Lokale Auswertung")
    }

    func updateWake(samples: [RheosWakeSample], lastWake: Date?) {
        var state = RheosStore.shared.loadDocument()
        var wake = state.wake ?? RheosWakeState()
        let kind = RheosWake.classify(samples)
        if RheosWake.shouldAskAgain(previous: wake.pattern, current: kind) {
            wake.confirmed = false
        }
        if kind != .unclear { wake.pattern = kind.rawValue; wake.kind = kind.rawValue }
        wake.lastWake = lastWake ?? wake.lastWake
        state.wake = wake
        RheosStore.shared.saveDocument(state)
    }

    func setWake(enabled: Bool? = nil, confirmed: Bool? = nil) {
        var state = RheosStore.shared.loadDocument()
        var wake = state.wake ?? RheosWakeState()
        if let enabled { wake.enabled = enabled }
        if let confirmed { wake.confirmed = confirmed }
        state.wake = wake
        RheosStore.shared.saveDocument(state)
    }

    private func recordHour(dataset: RheosDataset, decision: RheosProfileDecision, now: Date) {
        let entry = RheosDecisionLog.entry(
            now: now,
            factors: decision.applied ? decision.factors : decision.learnedFactors,
            inputs: "IOB/Mahlzeiten/Uhrzeit, Autosens \(dataset.loopReading?.autosensRatio ?? 1)",
            reason: decision.reason,
            autosensRatio: dataset.loopReading?.autosensRatio,
            applied: decision.applied
        )
        var state = RheosStore.shared.loadDocument()
        state.hourLog = RheosDecisionLog.appending(state.hourLog, entry)
        RheosStore.shared.saveDocument(state)
    }

    private func postUpkeep(dataset: RheosDataset, now: Date) {
        let lastExport = UserDefaults.standard.object(forKey: RheosUpkeep.exportKey) as? Date
        if let text = RheosUpkeep.exportReminder(lastExport: lastExport, hasData: !dataset.glucose.isEmpty, now: now) {
            let stampKey = "rheos.notify.export.shown"
            let shown = UserDefaults.standard.object(forKey: stampKey) as? Date
            if shown == nil || now.timeIntervalSince(shown ?? now) >= 14 * 86400 {
                UserDefaults.standard.set(now, forKey: stampKey)
                RheosCareNotifier.postPlain(id: "rheos.suggestion.export", body: text)
            }
        }
        let lastLoop = dataset.states.map(\.date).max()
        if let text = RheosUpkeep.loopWarning(lastLoop: lastLoop, now: now) {
            RheosCareNotifier.postPlain(id: "rheos.suggestion.loop", body: text)
        }
    }

    private func beginRefresh() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isRefreshing { return false }
        isRefreshing = true
        return true
    }

    private func endRefresh() {
        lock.lock()
        defer { lock.unlock() }
        isRefreshing = false
    }

    private func storeWatchChat(reply: String, suggestions: [RheosChatSuggestion]) {
        lock.lock()
        defer { lock.unlock() }
        watchChatReply = reply
        chatSuggestions = suggestions
    }

    func watchSnapshot() -> RheosWatchSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return RheosWatchSnapshot(
            mode: RheosModeStore.current.rawValue,
            suggestions: RheosWatchCatalog.lines(care: careReport, chat: chatSuggestions),
            chatReply: watchChatReply
        )
    }

    func replaceCare(_ care: RheosCareReport) {
        lock.lock()
        careReport = care
        lock.unlock()
    }

    func dismissWatchSuggestion(id: String?) {
        guard let id, !id.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        switch id {
        case "care-patch": careReport?.patchCheck = nil
        case "care-hypo": careReport?.hypoSuggestion = nil
        case "care-alcohol": careReport?.alcohol = nil
        default: chatSuggestions.removeAll { $0.id == id }
        }
    }

    private func announcementText(kind: String) -> String {
        switch kind {
        case "alcohol":
            return "Alkohol notiert. Rheos kann ein späteres Hypo-Risiko erwähnen. Kein Temp Target und kein Bolus."
        case "stress":
            return "Stress notiert. Kein Preset, kein Temp Target und kein Bolus."
        case "snack":
            return "Snack notiert: kleine Kohlenhydrate, beobachten. Kein Bolus."
        case "note":
            return "Hinweis gesehen. Kein Bolus."
        case "meal":
            return RheosContextInference.suggestion(forAnnouncement: "meal")
        default:
            let mode = RheosContextMode(rawValue: kind) ?? .sport
            let effect = RheosApplicationPoint.effect(of: .contextMode(mode))
            if case let .suggestion(suggestion) = effect {
                return suggestion
            }
            return RheosContextInference.suggestion(forAnnouncement: kind)
        }
    }

    /// Records where the new Medtrum patch sits. Does not change insulin.
    func recordPatchSite(_ place: String) {
        let trimmed = place.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        RheosStore.shared.addPatchSite(RheosPatchSite(id: UUID().uuidString, place: trimmed, started: Date()))
    }

    /// Records that the user saw a meal outcome. Does not deliver insulin.
    func acknowledgeMeal(id: String) {
        let effect = RheosApplicationPoint.effect(of: .mealObservation(id: id))
        guard effect == .none else { return }
        let store = RheosStore.shared
        var dataset = store.loadDataset()
        guard let index = dataset.meals.firstIndex(where: { $0.id == id }) else { return }
        dataset.meals[index].acknowledged = true
        store.saveDataset(dataset)
        noteConfirmation("Mahlzeit \(id) zur Kenntnis genommen. Kein Bolus.")
    }

    func saveBody(_ inputs: RheosBodyInputs) {
        let store = RheosStore.shared
        var dataset = store.loadDataset()
        let marked = RheosBodyRecord.markingManual(inputs)
        let now = Date()
        dataset.body = marked
        dataset.bodyHistory = RheosBodyRecord.appending(dataset.bodyHistory, inputs: marked, source: "manual", now: now)
        store.saveDataset(dataset, now: now)
    }

    /// Reads Health body measurements and keeps fields the user already typed.
    func importBodyFromHealth() async -> String {
        guard let healthStore = resolver.resolve(HKHealthStore.self) else {
            return "Apple Health ist hier nicht verfügbar."
        }
        await RheosHealthReader.requestReadAccess(store: healthStore)
        let measured = await RheosHealthReader.readBody(store: healthStore)
        let store = RheosStore.shared
        var dataset = store.loadDataset()
        let merged = RheosBodyRecord.merging(current: dataset.body, health: measured)
        if RheosBodyRecord.sameMeasurements(merged, dataset.body) {
            return "Health hat keine neuen Werte, oder die Felder sind manuell gesetzt."
        }
        let now = Date()
        dataset.body = merged
        dataset.bodyHistory = RheosBodyRecord.appending(dataset.bodyHistory, inputs: merged, source: "health", now: now)
        store.saveDataset(dataset, now: now)
        return "Health-Werte übernommen. Manuell gesetzte Felder bleiben. Nichts wird als Insulin übernommen."
    }

    func saveBounds(_ bounds: RheosBounds) {
        RheosStore.shared.saveBounds(bounds)
    }

    func exportFiles() throws -> [URL] {
        try RheosStore.shared.exportFiles()
    }

    /// Restores dataset, bounds, the learned factors and the decision.
    /// The file is kept when it cannot be read; the current state stays.
    func importArchive(from url: URL) throws {
        try RheosStore.shared.importArchive(from: url)
    }

    private func autosensMin() -> Double {
        guard let value = resolver.resolve(SettingsManager.self)?.preferences.autosensMin else {
            return RheosReference.defaultMinimumMultiplier
        }
        return NSDecimalNumber(decimal: value).doubleValue
    }

    private func autosensMax() -> Double {
        guard let value = resolver.resolve(SettingsManager.self)?.preferences.autosensMax else {
            return RheosReference.defaultMaximumMultiplier
        }
        return NSDecimalNumber(decimal: value).doubleValue
    }

    private func noteConfirmation(_ reason: String) {
        let hour = Calendar.current.component(.hour, from: Date())
        RheosStore.shared.appendApplication(
            RheosApplicationLog(
                date: Date(),
                applied: false,
                code: .shadow,
                reason: reason,
                hour: hour,
                basal: 1,
                isf: 1,
                carbRatio: 1,
                bandMinimum: RheosReference.defaultMinimumMultiplier,
                bandMaximum: RheosReference.defaultMaximumMultiplier
            )
        )
    }
}
