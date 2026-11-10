import Foundation
import HealthKit
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
            now: now
        )
        store.saveDecision(decision)
        let care = RheosCare.report(
            dataset: dataset,
            sites: store.patchSites(),
            alcoholDates: store.announcements().filter { $0.kind == "alcohol" }.map(\.date),
            learned: decision.reason,
            now: now,
            calendar: .current
        )
        RheosCareNotifier.post(care)
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
