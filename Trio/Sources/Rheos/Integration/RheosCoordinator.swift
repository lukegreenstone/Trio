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

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .rheosModeDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { await self?.refresh() }
        })
        observers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.refresh() }
        })
        Task { await refresh() }
    }

    func setMode(_ mode: RheosMode) {
        RheosModeStore.set(mode)
    }

    func refresh() async {
        guard RheosModeStore.current != .aus else { return }
        let shouldStart: Bool = {
            lock.lock()
            defer { lock.unlock() }
            if isRefreshing { return false }
            isRefreshing = true
            return true
        }()
        guard shouldStart else { return }
        defer {
            lock.lock()
            isRefreshing = false
            lock.unlock()
        }

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

        if let healthStore = resolver.resolve(HKHealthStore.self) {
            await RheosHealthReader.requestReadAccess(store: healthStore)
            let health = await RheosHealthReader.read(store: healthStore)
            dataset.wearableDays = health.days
            dataset.workouts = health.workouts
            dataset.sleep = health.sleep
        } else {
            dataset.wearableDays = previous.wearableDays
            dataset.workouts = previous.workouts
            dataset.sleep = previous.sleep
        }

        let now = Date()
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
    func announce(kind: String, note: String) -> String {
        let effect = RheosApplicationPoint.effect(of: .contextMode(kind == "meal" ? .showtime : .sport))
        let text: String
        if kind == "meal" {
            text = RheosContextInference.suggestion(forAnnouncement: "meal")
        } else if case let .suggestion(suggestion) = effect {
            text = suggestion
        } else {
            text = RheosContextInference.suggestion(forAnnouncement: kind)
        }
        RheosStore.shared.addAnnouncement(
            RheosAnnouncement(id: UUID().uuidString, date: Date(), kind: kind, note: note)
        )
        noteConfirmation(text)
        return text
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
        dataset.body = inputs
        store.saveDataset(dataset)
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
