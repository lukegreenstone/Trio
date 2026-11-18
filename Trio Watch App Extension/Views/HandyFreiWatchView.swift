import HandyFreiDrivers
import HealthKit
import SwiftUI
import Trio
import WatchKit

/// Handy-frei on the watch. One start, sensor and pump together. No patch stop and no sensor activation.
struct HandyFreiWatchView: View {
    @Bindable var state: WatchState
    @State private var showingAdjustments = false
    @State private var customTarget = 110.0
    @State private var customMinutes = 60.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(state.handyFreiRunning ? "Handy-frei aktiv" : "Handy-frei")
                    .font(.headline)
                Text(state.handyFreiStatus)
                    .font(.footnote)
                if !state.handyFreiLoopLine.isEmpty, state.handyFreiLoopLine != state.handyFreiStatus {
                    Text(state.handyFreiLoopLine)
                        .font(.footnote)
                }
                if !state.handyFreiAlarm.isEmpty {
                    Text(state.handyFreiAlarm)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if !state.handyFreiRunning {
                    Button("Handy-frei aktivieren") {
                        state.activateHandyFrei()
                    }
                }
                if state.handyFreiRunning {
                    Button("Erneut versuchen") {
                        state.restartHandyFreiFromCache()
                    }
                }
                Button("Handy-frei neu starten") {
                    state.restartHandyFreiFromCache()
                }
                Button("Handy-frei beenden") {
                    state.stopHandyFrei()
                }
                Button("Mahlzeiten") {
                    state.showingMealPresets = true
                }
                if state.handyFreiRunning {
                    Button(showingAdjustments ? "Anpassungen schließen" : "Override und Temp-Ziel") {
                        showingAdjustments.toggle()
                    }
                    if showingAdjustments {
                        adjustments
                    }
                }
                if let copied = state.handyFreiSnapshotAt {
                    let hours = Int(Date().timeIntervalSince(copied) / 3600)
                    Text(hours < 1
                        ? "Letzte Kopie: vor weniger als einer Stunde."
                        : "Letzte Kopie: vor \(hours) Stunden. Ein alter Pumpentoken kann abgelehnt werden.")
                        .font(.footnote)
                }
                Text("Start geht sofort, auch ohne iPhone. Die letzte Kopie reicht. Die Kopplung bleibt auf dem iPhone. Ist Bluetooth am iPhone noch an, hält das iPhone die Pumpe, bis die Verbindung fällt.")
                    .font(.footnote)
            }
            .padding()
        }
        .sheet(isPresented: $state.showingMealPresets) {
            MealPresetListView(state: state)
        }
    }

    private var adjustments: some View {
        let overrides = HandyFreiLoop.savedOverrides(state.handyFreiFiles)
        let targets = HandyFreiLoop.savedTempTargets(state.handyFreiFiles)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Override").font(.footnote)
            if overrides.isEmpty {
                Text("Keine Override-Vorlagen in der Kopie.").font(.footnote)
            }
            ForEach(overrides, id: \.name) { preset in
                Button(preset.indefinite ? "\(preset.name) \(Int(preset.percentage)) %" : "\(preset.name) \(Int(preset.percentage)) % \(Int(preset.durationMinutes)) min") {
                    HandyFreiSession.shared.startOverride(state, preset)
                }
            }
            Button("Override beenden") { HandyFreiSession.shared.stopOverride(state) }
            Text("Temp-Ziel").font(.footnote)
            ForEach(targets, id: \.name) { preset in
                Button("\(preset.name) \(Int(preset.target)) \(Int(preset.durationMinutes)) min") {
                    HandyFreiSession.shared.startTempTarget(state, name: preset.name, target: preset.target, minutes: max(15, Int(preset.durationMinutes)))
                }
            }
            Text("Eigenes Ziel \(Int(customTarget)) mg/dL, \(Int(customMinutes)) min")
                .font(.footnote)
                .focusable()
                .digitalCrownRotation($customTarget, from: 80, through: 180, by: 5, sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
            Button("Dauer \(Int(customMinutes)) min") {
                customMinutes = customMinutes >= 120 ? 30 : customMinutes + 30
            }
            Button("Eigenes Temp-Ziel starten") {
                HandyFreiSession.shared.startTempTarget(state, name: "Eigenes", target: customTarget, minutes: Int(customMinutes))
            }
            Button("Temp-Ziel beenden") { HandyFreiSession.shared.stopTempTarget(state) }
        }
    }
}

struct MealPresetListView: View {
    @Bindable var state: WatchState

    var body: some View {
        List {
            if state.mealPresets.isEmpty {
                Text("Keine gespeicherten Mahlzeiten. Sie kommen mit der Kopie vom iPhone.")
                    .font(.footnote)
            }
            ForEach(state.mealPresets) { preset in
                Button {
                    state.stageMeal(preset)
                    state.showingMealPresets = false
                    state.mealNeedsBolus = true
                } label: {
                    VStack(alignment: .leading) {
                        Text(preset.name)
                        Text("\(Int(preset.carbs.rounded())) g · F \(Int(preset.fat.rounded())) · E \(Int(preset.protein.rounded()))")
                            .font(.footnote)
                    }
                }
            }
        }
        .navigationTitle("Mahlzeiten")
    }
}

extension WatchState {
    /// Phone already confirmed Bluetooth is off, or the phone can no longer be reached.
    func startHandyFrei() {
        HandyFreiSession.shared.start(self)
    }

    /// Starts at once. A reachable phone sends a fresh snapshot and pauses its loop. Otherwise the last copy is used.
    func activateHandyFrei() {
        guard !handyFreiRunning else { return }
        handyFreiStatus = "Handy-frei wird aktiviert…"
        guard let session, session.activationState == .activated, session.isReachable else {
            startHandyFrei()
            return
        }
        session.sendMessage(["handyFreiActivate": true], replyHandler: nil, errorHandler: { _ in
            DispatchQueue.main.async {
                guard !self.handyFreiRunning else { return }
                self.handyFreiStatus = "iPhone nicht erreicht. Start mit der letzten Kopie."
                self.startHandyFrei()
            }
        })
        // The phone is asked for a fresh copy, but the watch does not wait on it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            guard !self.handyFreiRunning else { return }
            self.handyFreiStatus = "Kein neuer Schnappschuss. Start mit der letzten Kopie."
            self.startHandyFrei()
        }
    }

    /// Restarts from the keys and profile already on the watch. Does not ask the iPhone.
    func restartHandyFreiFromCache() {
        HandyFreiSession.shared.restartFromCache(self)
    }

    /// One tap. Starts only after the phone confirms Bluetooth is off, or when the phone is unreachable.
    func requestHandyFrei() {
        activateHandyFrei()
    }

    func stopHandyFrei() {
        HandyFreiSession.shared.finish(self)
    }
}

/// Owns the workout, the Libre session and the pump commands for one stretch.
final class HandyFreiSession {
    static let shared = HandyFreiSession()
    private var log: [[String: Any]] = []
    private var deliveries: [HandyFreiLoop.Delivery] = []
    private var readings: [(date: Date, mgdl: Int)] = []
    /// Bumped when the stretch ends so a glucose task already in flight cannot dose afterwards.
    private var doseEpoch = 0
    private var dosing = false
    private var lastDose = Date.distantPast
    private var pumpRetries = 0
    private var sensorRetries = 0
    private var workoutRestarts = 0
    private var replacingSensor = false
    private var sensorGeneration = 0
    private var lastPacketAt: Date?
    private var lastStallAttempt = Date.distantPast
    private var stallAttempts = 0
    private var backoffTask: Task<Void, Never>?
    private var glucoseAgeTask: Task<Void, Never>?
    private var loopWatchTask: Task<Void, Never>?
    private var autosensTask: Task<Void, Never>?
    private var lastLoopAt = Date.distantPast
    private var doseStartedAt: Date?
    private var bolusUncertain = false
    private var determining = false
    private var lastSuccess = Date.distantPast
    private var lastReason = "Loop wartet auf den ersten Wert."
    private var lastIOB = 0.0
    private var lastCOB = 0.0
    /// Bumped when a meal is saved so a loop that started earlier cannot write COB 0 back over it.
    private var mealRevision = 0
    private var active = false
    private var carbs: [HandyFreiDisk.Carb] = []
    private var address = ""
    private var pin = Data()
    private var phase5 = Data()
    private var pumpSerial = ""
    private var sessionToken = ""
    private var backupToken = ""
    private var sensorPeripheralID = ""

    func start(_ state: WatchState) {
        guard !state.handyFreiRunning else { return }
        state.handyFreiRunning = true
        doseEpoch += 1
        backoffTask?.cancel()
        backoffTask = nil
        glucoseAgeTask?.cancel()
        glucoseAgeTask = nil
        loopWatchTask?.cancel()
        loopWatchTask = nil
        autosensTask?.cancel()
        autosensTask = nil
        dosing = false
        doseStartedAt = nil
        bolusUncertain = false
        determining = false
        pumpRetries = 0
        sensorRetries = 0
        workoutRestarts = 0
        replacingSensor = false
        lastPacketAt = nil
        lastStallAttempt = .distantPast
        stallAttempts = 0
        let epoch = doseEpoch
        state.handyFreiAlarm = ""
        active = true
        log = []
        deliveries = []
        readings = []
        carbs = []
        lastSuccess = .distantPast
        lastDose = .distantPast
        lastReason = "Loop wartet auf den ersten Wert."
        HandyFreiDisk.restore(into: state, session: self)
        self.seedSnapshotGlucose(state)
        self.showSnapshotTotals(state)
        HandyFreiDisk.save(session: self)
        self.scheduleRefresh()
        lastLoopAt = lastSuccess == .distantPast ? Date() : lastSuccess
        address = state.handyFreiBleAddress
        pin = Data(base64Encoded: state.handyFreiBlePIN) ?? Data()
        phase5 = Data(base64Encoded: state.handyFreiPhase5) ?? Data()
        pumpSerial = state.handyFreiPumpSerial
        sessionToken = state.handyFreiSessionToken
        backupToken = state.handyFreiBackupToken
        sensorPeripheralID = state.handyFreiSensorPeripheralID
        HandyFreiMedtrumLink.shared.onConnectionLost = { [weak self] in
            DispatchQueue.main.async {
                guard let self, state.handyFreiRunning else { return }
                Task { await self.restorePump(state) }
            }
        }
        Task {
            guard state.handyFreiRunning, epoch == self.doseEpoch else { return }
            self.startLoopWatch(state, epoch: epoch)
            self.startAutosensRefresh(state, epoch: epoch)
            let allowed = await HandyFreiWorkout.shared.prepare { ended in
                DispatchQueue.main.async {
                    guard state.handyFreiRunning, ended else { return }
                    Task { await self.keepAwake(state) }
                }
            }
            guard allowed else {
                await MainActor.run {
                    self.giveUpOrRetry(state, "HealthKit nicht erlaubt.")
                }
                return
            }
            guard state.handyFreiRunning, epoch == self.doseEpoch else { return }
            do {
                try await self.openPump(state, attempt: 1)
                guard state.handyFreiRunning, epoch == self.doseEpoch else {
                    HandyFreiMedtrumLink.shared.stop()
                    return
                }
                try await self.openSensor(state)
                self.startGlucoseWatch(state, epoch: epoch)
            } catch {
                let text = Self.failureText(stage: "Start", error: error)
                await self.mark(state, text)
                await MainActor.run {
                    guard state.handyFreiRunning else { return }
                    self.giveUpOrRetry(state, text)
                }
            }
        }
    }

    /// No insulin once the newest reading is older than 12 minutes. The session stays up.
    private func startLoopWatch(_ state: WatchState, epoch: Int) {
        loopWatchTask?.cancel()
        loopWatchTask = Task { await self.watchLoop(state, epoch: epoch) }
    }

    /// Recalculates autosens off the loop. It waits until the snapshot ratio is half an hour old.
    private func startAutosensRefresh(_ state: WatchState, epoch: Int) {
        autosensTask?.cancel()
        autosensTask = Task { [weak self] in
            guard let self else { return }
            while state.handyFreiRunning, epoch == self.doseEpoch, !Task.isCancelled {
                self.scheduleRefresh()
                await MainActor.run { state.reportHandyFreiHeartbeat() }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard state.handyFreiRunning, epoch == self.doseEpoch else { return }
                let snapshot = await MainActor.run { () -> (
                    files: [String: String], readings: [(date: Date, mgdl: Int)],
                    deliveries: [HandyFreiLoop.Delivery], carbs: [HandyFreiLoop.WatchCarb]
                ) in
                    (state.handyFreiFiles, self.readings, self.deliveries, self.loopCarbs())
                }
                let age = HandyFreiLoop.autosensAgeMinutes(snapshot.files, now: Date())
                guard age == nil || (age ?? 0) >= 30 else { continue }
                let files = snapshot.files
                let readings = snapshot.readings
                let deliveries = snapshot.deliveries
                let carbs = snapshot.carbs
                let json = await Task.detached(priority: .utility) {
                    HandyFreiLoop.recomputeAutosens(
                        files: files, glucose: readings, deliveries: deliveries, watchCarbs: carbs, now: Date()
                    )
                }.value
                guard let json, !json.isEmpty else { continue }
                await MainActor.run {
                    state.handyFreiFiles["autosens"] = json
                    state.handyFreiStatus = "\(Self.clock()) Autosens neu berechnet."
                }
            }
        }
    }

    func startOverride(_ state: WatchState, _ preset: HandyFreiLoop.SavedOverride) {
        HandyFreiLoop.startOverride(&state.handyFreiFiles, preset, now: Date())
        log.append([
            "date": Date().timeIntervalSince1970, "kind": "override", "name": preset.name,
            "percentage": preset.percentage, "minutes": Int(preset.durationMinutes),
            "text": "Override \(preset.name) \(Int(preset.percentage)) %"
        ])
        state.handyFreiStatus = "Override \(preset.name) aktiv."
        HandyFreiDisk.save(session: self)
    }

    func stopOverride(_ state: WatchState) {
        HandyFreiLoop.stopOverride(&state.handyFreiFiles, now: Date())
        log.append(["date": Date().timeIntervalSince1970, "kind": "overrideStop", "text": "Override aus"])
        state.handyFreiStatus = "Override beendet."
        HandyFreiDisk.save(session: self)
    }

    func startTempTarget(_ state: WatchState, name: String, target: Double, minutes: Int) {
        HandyFreiLoop.startTempTarget(&state.handyFreiFiles, name: name, target: target, minutes: minutes, halfBasal: 160, now: Date())
        log.append([
            "date": Date().timeIntervalSince1970, "kind": "tempTarget", "name": name,
            "target": target, "minutes": minutes, "text": "Temp-Ziel \(name) \(Int(target)) \(minutes) min"
        ])
        state.handyFreiStatus = "Temp-Ziel \(Int(target)) für \(minutes) min."
        HandyFreiDisk.save(session: self)
    }

    func stopTempTarget(_ state: WatchState) {
        HandyFreiLoop.stopTempTarget(&state.handyFreiFiles, now: Date())
        log.append(["date": Date().timeIntervalSince1970, "kind": "tempTargetStop", "text": "Temp-Ziel aus"])
        state.handyFreiStatus = "Temp-Ziel beendet."
        HandyFreiDisk.save(session: self)
    }

    /// Keeps the countdown moving, and starts the loop when it reaches zero.
    private func watchLoop(_ state: WatchState, epoch: Int) async {
        while state.handyFreiRunning, epoch == doseEpoch, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard state.handyFreiRunning, epoch == doseEpoch, !Task.isCancelled else { return }
            let stuck = await MainActor.run { () -> Bool in
                guard let started = self.doseStartedAt, self.dosing else { return false }
                return Date().timeIntervalSince(started) > 70
            }
            if stuck {
                HandyFreiMedtrumLink.shared.cancelPendingWrite()
                await MainActor.run {
                    self.dosing = false
                    self.doseStartedAt = nil
                    self.bolusUncertain = true
                    let line = "\(Self.clock()) Pumpe: Zeitüberschreitung. Loop läuft weiter. SMB wartet auf den Verlauf."
                    state.handyFreiStatus = line
                    state.handyFreiLoopLine = line
                }
            }
            await MainActor.run {
                let remain = self.secondsUntilLoop()
                let quiet = Date().timeIntervalSince(self.lastLoopAt)
                let watchdog = quiet > 7 * 60 && !self.determining && !self.dosing
                guard let last = self.readings.max(by: { $0.date < $1.date }) else {
                    if watchdog {
                        state.handyFreiStatus = "\(Self.clock()) Loop-Wächter: letzter Lauf vor \(Int(quiet / 60)) min. Noch kein Glukosewert."
                    }
                    return
                }
                if watchdog {
                    state.handyFreiStatus = "\(Self.clock()) Loop-Wächter: letzter Lauf vor \(Int(quiet / 60)) min, starte neu."
                    self.evaluate(state, mgdl: last.mgdl, appendReading: false, force: true)
                } else if remain > 0 {
                    self.showWaiting(state, mgdl: last.mgdl, remain: remain)
                } else {
                    self.evaluate(state, mgdl: last.mgdl, appendReading: false, force: false)
                }
            }
        }
    }

    private func seedSnapshotGlucose(_ state: WatchState) {
        guard readings.isEmpty else { return }
        readings = HandyFreiLoop.snapshotReadings(state.handyFreiFiles)
        if readings.count > 36 { readings.removeFirst(readings.count - 36) }
    }

    private func showSnapshotTotals(_ state: WatchState) {
        guard let mgdl = readings.max(by: { $0.date < $1.date })?.mgdl else { return }
        let outcome = HandyFreiLoop.tick(
            files: state.handyFreiFiles,
            rheosBasal: state.handyFreiBasal,
            rheosISF: state.handyFreiISF,
            rheosCarbRatio: state.handyFreiCarbRatio,
            glucose: readings,
            deliveries: deliveries,
            watchCarbs: loopCarbs(),
            now: Date()
        )
        guard !outcome.failed else { return }
        lastIOB = outcome.iob
        lastCOB = outcome.cob
        state.iob = String(format: "%.1f", outcome.iob)
        state.cob = String(format: "%.0f", outcome.cob)
        state.handyFreiGlucose = mgdl
    }

    func recordCarbs(grams: Int, fat: Int = 0, protein: Int = 0, name: String = "", id: String = UUID().uuidString, date: Date, state: WatchState) {
        mealRevision += 1
        let revision = mealRevision
        let entry = HandyFreiDisk.Carb(
            id: id,
            date: date.timeIntervalSince1970,
            grams: Double(grams),
            fat: Double(fat),
            protein: Double(protein),
            name: name,
            isFPU: false,
            fpuID: (fat > 0 || protein > 0) ? id : nil
        )
        carbs.append(entry)
        var parent: [String: Any] = [
            "date": date.timeIntervalSince1970,
            "kind": "carb",
            "id": id,
            "grams": Double(grams),
            "fat": Double(fat),
            "protein": Double(protein),
            "name": name,
            "text": "\(name.isEmpty ? "Mahlzeit" : name) \(grams) g KH, \(fat) g Fett, \(protein) g Eiweiß"
        ]
        if fat > 0 || protein > 0 {
            parent["fpuID"] = id
        }
        log.append(parent)
        var fpuCount = 0
        let settings = HandyFreiLoop.mealSettings(state.handyFreiFiles)
        if settings.fpu, fat > 0 || protein > 0 {
            let future = FatProteinConversion.futureEntries(
                fat: NSDecimalNumber(value: fat).decimalValue,
                protein: NSDecimalNumber(value: protein).decimalValue,
                createdAt: date,
                actualDate: date,
                fpuID: id,
                adjustment: settings.adjustment,
                delayMinutes: settings.delay,
                intervalMinutes: settings.interval
            )
            fpuCount = future.count
            for item in future {
                let when = item.actualDate ?? date
                let child = HandyFreiDisk.Carb(
                    id: item.id ?? UUID().uuidString,
                    date: when.timeIntervalSince1970,
                    grams: NSDecimalNumber(decimal: item.carbs).doubleValue,
                    fat: 0,
                    protein: 0,
                    name: "FPU",
                    isFPU: true,
                    fpuID: id
                )
                carbs.append(child)
                log.append([
                    "date": when.timeIntervalSince1970,
                    "kind": "fpu",
                    "id": child.id,
                    "grams": child.grams,
                    "fat": 0.0,
                    "protein": 0.0,
                    "name": "FPU",
                    "fpuID": id,
                    "text": "FPU \(Int(child.grams)) g"
                ])
            }
        }
        prune()
        HandyFreiLoop.rememberCarbs(&state.handyFreiFiles, loopCarbs())
        HandyFreiDisk.save(session: self)
        let saved = "Mahlzeit \(Self.clockMinute(date)): \(grams) g KH + \(fpuCount) FPU-Einträge gespeichert"
        state.handyFreiStatus = saved
        state.handyFreiLoopLine = saved
        guard let mgdl = readings.max(by: { $0.date < $1.date })?.mgdl else { return }
        let outcome = HandyFreiLoop.tick(
            files: state.handyFreiFiles,
            rheosBasal: state.handyFreiBasal,
            rheosISF: state.handyFreiISF,
            rheosCarbRatio: state.handyFreiCarbRatio,
            glucose: readings,
            deliveries: deliveries,
            watchCarbs: loopCarbs(),
            now: Date()
        )
        guard revision == mealRevision, !outcome.failed else { return }
        lastIOB = outcome.iob
        lastCOB = outcome.cob
        lastReason = outcome.reason
        state.iob = String(format: "%.1f", outcome.iob)
        state.cob = String(format: "%.0f", outcome.cob)
        state.handyFreiGlucose = mgdl
        state.handyFreiLoopLine = "\(saved) · COB \(state.cob ?? "0")"
    }

    private func startGlucoseWatch(_ state: WatchState, epoch: Int) {
        glucoseAgeTask?.cancel()
        let started = Date()
        glucoseAgeTask = Task { await self.watchGlucoseAge(state, epoch: epoch, started: started) }
    }

    private func watchGlucoseAge(_ state: WatchState, epoch: Int, started: Date) async {
        while state.handyFreiRunning, epoch == doseEpoch, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard state.handyFreiRunning, epoch == doseEpoch else { return }
            let snapshot = await MainActor.run { () -> (date: Date, hasReading: Bool) in
                (self.readings.map(\.date).max() ?? started, !self.readings.isEmpty)
            }
            let newest = snapshot.date
            if snapshot.hasReading {
                let quiet = Date().timeIntervalSince(newest)
                if quiet > 5 * 60, Date().timeIntervalSince(lastStallAttempt) > 5 * 60 {
                    await reconnectStalledSensor(state, quietMinutes: Int(quiet / 60))
                }
            }
            guard Date().timeIntervalSince(newest) > 12 * 60 else { continue }
            await mark(state, "Glukose älter als 12 Minuten. Kein Insulin.")
            let busy = await MainActor.run { () -> Bool in
                if self.dosing { return true }
                self.dosing = true
                return false
            }
            guard !busy else { continue }
            _ = await deliverTemp(state, rate: 0, minutes: 0)
            await MainActor.run { self.dosing = false }
        }
    }

    private func keepAwake(_ state: WatchState) async {
        guard state.handyFreiRunning else { return }
        workoutRestarts += 1
        await mark(state, "Workout erneut \(workoutRestarts). Die Uhr bleibt in Handy-frei.")
        let allowed = await HandyFreiWorkout.shared.prepare { ended in
            DispatchQueue.main.async {
                guard state.handyFreiRunning, ended else { return }
                Task { await self.keepAwake(state) }
            }
        }
        guard allowed, state.handyFreiRunning else {
            await MainActor.run {
                self.giveUpOrRetry(state, "HealthKit nicht erlaubt.")
            }
            return
        }
    }

    /// Three tries, then the phone takes the radio back. Reconnect uses the saved token. It does not pair again.
    private func openPump(_ state: WatchState, attempt: Int) async throws {
        await mark(state, attempt == 1 ? "Pumpe: suche" : "Pumpe: erneut \(attempt)")
        do {
            HandyFreiMedtrumLink.shared.stop()
            try await HandyFreiMedtrumLink.shared.connect(
                pumpSerialBase64: pumpSerial,
                sessionTokenBase64: sessionToken,
                backupTokenBase64: backupToken
            )
            await mark(state, "Pumpe: verbunden")
            await mark(state, "Pumpe: Status lesen")
            try await HandyFreiMedtrumLink.shared.send(.readStatus)
            await mark(state, "Pumpe: Status gelesen")
            await mark(state, "Pumpe: Verlauf lesen")
            try await HandyFreiMedtrumLink.shared.send(.readHistory)
            await MainActor.run { self.adoptPumpReading(state) }
            await mark(state, "Pumpe: Verlauf gelesen")
            pumpRetries = 0
        } catch {
            HandyFreiMedtrumLink.shared.stop()
            guard attempt < 3, state.handyFreiRunning else { throw error }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            try await openPump(state, attempt: attempt + 1)
        }
    }

    /// The synchronize reply has the latest completed bolus and reservoir. A bolus already
    /// in the snapshot within 10 minutes is not added again.
    private func adoptPumpReading(_ state: WatchState) {
        let link = HandyFreiMedtrumLink.shared
        if let units = link.lastReservoirUnits, units > 0 {
            state.handyFreiFiles["reservoir"] = String(units)
        }
        if let alarm = link.lastPatchAlarm, !alarm.isEmpty {
            state.handyFreiAlarm = "\(Self.clockMinute()) \(alarm)"
        }
        if let units = link.lastBolusUnits, units >= 0.05 {
            let already = deliveries.contains {
                $0.kind == "bolus" && abs($0.units - units) < 0.051 && Date().timeIntervalSince($0.date) < 10 * 60
            }
            if !already {
                deliveries.append(HandyFreiLoop.Delivery(kind: "bolus", units: units, minutes: 0, date: Date()))
                log.append([
                    "date": Date().timeIntervalSince1970,
                    "kind": "bolus",
                    "units": units,
                    "minutes": 0,
                    "text": "Bolus aus dem Pumpenverlauf"
                ])
                HandyFreiDisk.save(session: self)
            }
        }
    }

    /// The BLE link can stay "connected" while notifications stop. A new cached
    /// handshake uses the same phase-5 key. It does not re-pair or deactivate.
    private func reconnectStalledSensor(_ state: WatchState, quietMinutes: Int) async {
        guard state.handyFreiRunning, !replacingSensor else { return }
        lastStallAttempt = Date()
        stallAttempts += 1
        guard stallAttempts <= 3 else {
            stallAttempts = 0
            await MainActor.run {
                self.giveUpOrRetry(state, "Sensor steht seit \(quietMinutes) min.")
            }
            return
        }
        let stamp = lastPacketAt.map { Self.clock($0) } ?? "--"
        let line = "Sensor: steht seit \(quietMinutes) min, letztes Paket \(stamp). Verbindung neu (\(stallAttempts))"
        do {
            try await openSensor(state, announce: line)
        } catch {
            await mark(state, "Sensor: Verbindung neu (\(stallAttempts)) fehlgeschlagen. \(error.localizedDescription)")
        }
    }

    private func openSensor(_ state: WatchState, announce: String? = nil) async throws {
        sensorGeneration += 1
        let generation = sensorGeneration
        replacingSensor = true
        HandyFreiLibreLink.stop()
        await mark(state, announce ?? (sensorRetries == 0 ? "Sensor: suche" : "Sensor: erneut \(sensorRetries)"))
        do {
            try await HandyFreiLibreLink.reconnect(
            bleAddress: address,
            blePIN: pin,
            phase5RawKey: phase5,
            peripheralID: UUID(uuidString: sensorPeripheralID),
            onGlucose: { mgdl in
                DispatchQueue.main.async {
                    self.absorb(state, mgdl)
                }
            },
            onDisconnect: { [weak self] in
                DispatchQueue.main.async {
                    guard let self, state.handyFreiRunning, !self.replacingSensor else { return }
                    // A link we already replaced must not start a second session.
                    guard generation == self.sensorGeneration else { return }
                    Task { await self.restoreSensor(state) }
                }
            },
            onStatus: { text in
                Task { await self.noteSensor(state, text) }
            }
            )
        } catch {
            replacingSensor = false
            throw error
        }
        replacingSensor = false
        sensorRetries = 0
        await mark(state, "Sensor: verbunden, warte auf Werte")
    }

    private func restorePump(_ state: WatchState) async {
        guard state.handyFreiRunning else { return }
        pumpRetries += 1
        guard pumpRetries <= 3 else {
            pumpRetries = 0
            await MainActor.run {
                self.giveUpOrRetry(state, "Pumpe weg.")
            }
            return
        }
        do {
            try await openPump(state, attempt: pumpRetries)
        } catch {
            await MainActor.run {
                self.giveUpOrRetry(state, "Pumpe weg. \(error.localizedDescription)")
            }
        }
    }

    private func restoreSensor(_ state: WatchState) async {
        guard state.handyFreiRunning, !replacingSensor else { return }
        sensorRetries += 1
        guard sensorRetries <= 3 else {
            sensorRetries = 0
            await MainActor.run {
                self.giveUpOrRetry(state, "Sensor weg.")
            }
            return
        }
        do {
            try await openSensor(state)
        } catch {
            await restoreSensor(state)
        }
    }

    private func noteSensor(_ state: WatchState, _ text: String) async {
        if text.hasPrefix("Sensor: Paket") || text.contains("mg/dL") {
            await MainActor.run { self.lastPacketAt = Date() }
        }
        let lowered = text.lowercased()
        if lowered.contains("warm") || lowered.contains("expired") || lowered.contains("abgelaufen") || lowered.contains("endet") {
            await MainActor.run {
                state.handyFreiAlarm = "\(Self.clockMinute()) \(text)"
            }
        }
        await mark(state, text)
    }

    private func mark(_ state: WatchState, _ text: String) async {
        await MainActor.run {
            guard state.handyFreiStatus != text else { return }
            state.handyFreiStatus = text
            log.append([
                "date": Date().timeIntervalSince1970,
                "kind": "stage",
                "text": text
            ])
        }
        await WatchLogger.shared.log("Handy-frei \(text)")
    }

    private static func failureText(stage: String, error: Error) -> String {
        let headline: String
        if let link = error as? HandyFreiLinkError {
            if case let .sensorNotSeen(detail) = link {
                return "\(detail). Die Uhr sucht weiter, auch ohne iPhone."
            }
            switch link {
            case .bluetoothOff:
                headline = "Uhr-Bluetooth aus"
            case .bluetoothDenied:
                headline = "Uhr-Bluetooth nicht erlaubt"
            case .bluetoothUnsupported:
                headline = "Uhr-Bluetooth nicht unterstützt"
            case .notFound where stage == "Pumpe":
                headline = "Pumpe: nicht gefunden (Scan 180 s)"
            case .pumpRefused(_) where stage == "Pumpe":
                headline = "Pumpe: Anmeldung abgelehnt"
            case .pumpRefused(_) where stage == "Pumpe: Status":
                headline = "Pumpe: Status lesen Zeitüberschreitung"
            case .badKey where stage == "Sensor":
                headline = "Sensor: Schlüssel unvollständig"
            case .notFound where stage == "Sensor":
                headline = "Sensor: nicht gefunden"
            case .handshake(_) where stage == "Sensor":
                headline = "Sensor: Handshake"
            default:
                headline = stage == "Pumpe: Verlauf" ? "Pumpe: Verlauf lesen" : "\(stage): \(error.localizedDescription)"
            }
        } else if stage == "Pumpe: Verlauf" {
            headline = "Pumpe: Verlauf lesen"
        } else {
            headline = "\(stage): \(error.localizedDescription)"
        }
        return "\(headline). \(error.localizedDescription). Die Uhr sucht weiter."
    }

    private func absorb(_ state: WatchState, _ mgdl: Int) {
        guard state.handyFreiRunning else { return }
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        if device.batteryLevel >= 0, device.batteryLevel < 0.1 {
            state.handyFreiStatus = "Akku unter 10 Prozent. Kein Insulin."
            state.handyFreiLoopLine = state.handyFreiStatus
            return
        }
        evaluate(state, mgdl: mgdl, appendReading: true)
    }

    private func secondsUntilLoop() -> Int {
        guard lastSuccess != .distantPast else { return 0 }
        return max(0, Int((5 * 60) - Date().timeIntervalSince(lastSuccess)))
    }

    /// Shown between determinations. This is not a failure.
    private func showWaiting(_ state: WatchState, mgdl: Int, remain: Int) {
        let line = "\(Self.clockMinute()) \(mgdl) mg/dL · nächster Loop in \(remain)s · \(lastReason)"
        state.handyFreiGlucose = mgdl
        state.handyFreiStatus = line
        state.handyFreiLoopLine = line
    }

    private func loopCarbs() -> [HandyFreiLoop.WatchCarb] {
        carbs.map {
            HandyFreiLoop.WatchCarb(
                id: $0.id,
                date: Date(timeIntervalSince1970: $0.date),
                grams: $0.grams,
                fat: $0.fat,
                protein: $0.protein,
                isFPU: $0.isFPU,
                fpuID: $0.fpuID
            )
        }
    }

    /// Keeps a day of glucose, doses, meals and the hand-back log. Older rows are dropped.
    private func prune() {
        let cutoff = Date().addingTimeInterval(-24 * 3600).timeIntervalSince1970
        readings.removeAll { $0.date.timeIntervalSince1970 < cutoff }
        if readings.count > 1500 { readings.removeFirst(readings.count - 1500) }
        deliveries.removeAll { $0.date.timeIntervalSince1970 < cutoff }
        carbs.removeAll { $0.date < cutoff }
        if log.count > 4000 { log.removeFirst(log.count - 4000) }
    }

    /// One loop pass. A minute that arrives while a run is in progress, or before five minutes are up, does not start another determination.
    private func evaluate(_ state: WatchState, mgdl: Int, appendReading: Bool, force: Bool = false) {
        if appendReading {
            readings.append((Date(), mgdl))
            stallAttempts = 0
            prune()
            log.append(["date": Date().timeIntervalSince1970, "kind": "glucose", "mgdl": mgdl])
            HandyFreiDisk.save(session: self)
        }
        let revision = mealRevision
        let remain = secondsUntilLoop()
        if determining || dosing || (!force && remain > 0) {
            if appendReading {
                let age = lastSuccess == .distantPast ? 0 : Int(Date().timeIntervalSince(lastSuccess) / 60)
                state.applyHandyFreiDisplay(
                    mgdl: mgdl,
                    iob: lastIOB,
                    cob: lastCOB,
                    loopLine: state.handyFreiLoopLine,
                    loopAgeMinutes: age
                )
            }
            if determining || dosing {
                state.handyFreiStatus = "\(Self.clockMinute()) \(mgdl) mg/dL · Loop läuft · \(lastReason)"
            } else {
                showWaiting(state, mgdl: mgdl, remain: remain)
            }
            return
        }
        determining = true
        let outcome = HandyFreiLoop.tick(
            files: state.handyFreiFiles,
            rheosBasal: state.handyFreiBasal,
            rheosISF: state.handyFreiISF,
            rheosCarbRatio: state.handyFreiCarbRatio,
            glucose: readings,
            deliveries: deliveries,
            watchCarbs: loopCarbs(),
            now: Date()
        )
        determining = false
        guard revision == mealRevision else { return }
        lastLoopAt = Date()
        let watched = force ? "Loop-Wächter. " : ""
        if outcome.failed {
            lastSuccess = Date()
            lastLoopAt = lastSuccess
            lastReason = outcome.reason
            let line = "\(watched)\(Self.clockMinute()) \(mgdl) mg/dL · \(outcome.reason)"
            state.handyFreiGlucose = mgdl
            state.handyFreiStatus = line
            state.handyFreiLoopLine = line
            log.append(["date": Date().timeIntervalSince1970, "kind": "determination", "text": line])
            HandyFreiDisk.save(session: self)
            return
        }
        lastSuccess = Date()
        lastDose = lastSuccess
        lastReason = outcome.reason
        lastIOB = outcome.iob
        lastCOB = outcome.cob
        let preview = "\(watched)\(Self.clockMinute()) \(mgdl) mg/dL · Temp \(String(format: "%.2f", outcome.rate)) U/h \(outcome.minutes) min · SMB \(String(format: "%.2f", outcome.smb)) U · \(outcome.reason)"
        state.handyFreiGlucose = mgdl
        state.handyFreiStatus = preview
        state.handyFreiLoopLine = preview
        state.iob = String(format: "%.1f", outcome.iob)
        state.cob = String(format: "%.0f", outcome.cob)
        if appendReading {
            state.applyHandyFreiDisplay(
                mgdl: mgdl,
                iob: outcome.iob,
                cob: outcome.cob,
                loopLine: preview,
                loopAgeMinutes: 0
            )
        }
        log.append([
            "date": Date().timeIntervalSince1970,
            "kind": "determination",
            "text": preview,
            "iob": outcome.iob,
            "cob": outcome.cob,
            "mgdl": mgdl
        ])
        HandyFreiDisk.save(session: self)
        guard outcome.deliver || outcome.cancelTemp else { return }
        guard !dosing else { return }
        dosing = true
        doseStartedAt = Date()
        lastDose = Date()
        let epoch = doseEpoch
        let rate = Self.medtrumStep(min(outcome.rate, outcome.maxBasal))
        let units = Self.medtrumStep(min(outcome.smb, outcome.maxBolus))
        let uncertain = bolusUncertain
        Task {
            var finished = preview
            defer {
                let line = finished
                Task { @MainActor in
                    self.dosing = false
                    self.doseStartedAt = nil
                    state.handyFreiStatus = line
                    state.handyFreiLoopLine = line
                }
            }
            guard state.handyFreiRunning, epoch == self.doseEpoch else { return }
            let deliverTemp = !outcome.cancelTemp && rate > 0 && outcome.minutes > 0
            let sent = await self.deliverTemp(
                state,
                rate: deliverTemp ? rate : 0,
                minutes: deliverTemp ? outcome.minutes : 0
            )
            if sent, deliverTemp {
                await MainActor.run {
                    self.deliveries.append(HandyFreiLoop.Delivery(kind: "temp", units: rate, minutes: outcome.minutes, date: Date()))
                    self.log.append(["date": Date().timeIntervalSince1970, "kind": "temp", "units": rate, "minutes": outcome.minutes])
                    HandyFreiDisk.save(session: self)
                }
                finished = "Pumpe \(Self.clockMinute()): Temp \(String(format: "%.2f", rate)) U/h ok"
            } else if sent {
                finished = "Pumpe \(Self.clockMinute()): Temp abgebrochen ok"
            } else {
                finished = await MainActor.run { state.handyFreiLoopLine }
            }
            let underStep = outcome.smb > 0 && units <= 0
            let overCap = units > 0 && outcome.iob + units > outcome.maxIOB
            if underStep || overCap {
                finished += underStep ? " · SMB unter 0,05 U nicht gesendet" : " · SMB über Max IOB nicht gesendet"
                return
            }
            guard units > 0 else {
                await self.refreshTotals(state, mgdl: mgdl, line: finished)
                return
            }
            if uncertain {
                let cleared = await self.confirmBolusState(state)
                finished += cleared
                    ? " · SMB wartet. Verlauf gelesen, der unsichere Bolus zählt weiter."
                    : " · SMB nicht gesendet, vorheriger Bolus unsicher"
                return
            }
            let bolusSent = await self.deliverBolus(state, units: units)
            if bolusSent {
                await MainActor.run {
                    self.bolusUncertain = false
                    self.deliveries.append(HandyFreiLoop.Delivery(kind: "bolus", units: units, minutes: 0, date: Date()))
                    self.log.append(["date": Date().timeIntervalSince1970, "kind": "bolus", "units": units, "minutes": 0])
                    HandyFreiDisk.save(session: self)
                }
                finished += " · SMB \(String(format: "%.2f", units)) U ok"
                await self.refreshTotals(state, mgdl: mgdl, line: finished)
            } else {
                await MainActor.run {
                    self.bolusUncertain = true
                    self.deliveries.append(HandyFreiLoop.Delivery(kind: "bolus", units: units, minutes: 0, date: Date()))
                    self.log.append(["date": Date().timeIntervalSince1970, "kind": "bolus", "units": units, "minutes": 0, "text": "SMB unsicher"])
                    HandyFreiDisk.save(session: self)
                }
                finished += " · SMB unsicher, kein zweiter Bolus"
            }
        }
    }

    /// Reads the pump before another SMB when the last bolus reply was missing.
    private func confirmBolusState(_ state: WatchState) async -> Bool {
        await MainActor.run {
            state.handyFreiStatus = "\(Self.clockMinute()) Pumpe: Verlauf, bevor ein neues SMB geht."
        }
        do {
            try await HandyFreiMedtrumLink.shared.send(.readStatus)
            try await HandyFreiMedtrumLink.shared.send(.readHistory)
            await MainActor.run { self.bolusUncertain = false }
            return true
        } catch {
            await MainActor.run { self.bolusUncertain = true }
            return false
        }
    }

    private func refreshTotals(_ state: WatchState, mgdl: Int, line: String) async {
        let outcome = HandyFreiLoop.tick(
            files: state.handyFreiFiles,
            rheosBasal: state.handyFreiBasal,
            rheosISF: state.handyFreiISF,
            rheosCarbRatio: state.handyFreiCarbRatio,
            glucose: readings,
            deliveries: deliveries,
            watchCarbs: loopCarbs(),
            now: Date()
        )
        guard !outcome.failed else { return }
        await MainActor.run {
            self.lastIOB = outcome.iob
            self.lastCOB = outcome.cob
            state.iob = String(format: "%.1f", outcome.iob)
            state.cob = String(format: "%.0f", outcome.cob)
            state.handyFreiStatus = line
            state.handyFreiLoopLine = line
        }
    }

    /// Manual bolus from the + button. Uses the saved pump session. Does not pair again.
    func manualBolus(_ state: WatchState, units: Double) async {
        let cap = Double(truncating: state.maxBolus as NSNumber)
        let newest = await MainActor.run { state.handyFreiGlucoseDate ?? Date.distantPast }
        if Date().timeIntervalSince(newest) > 12 * 60 {
            await MainActor.run {
                state.handleAcknowledgment(success: false, message: "Glukose älter als 12 Minuten. Kein Bolus.")
            }
            return
        }
        guard units > 0, units <= cap + 0.001 else {
            await MainActor.run {
                state.handleAcknowledgment(success: false, message: "Über Max Bolus \(String(format: "%.2f", cap)) U.")
            }
            return
        }
        let busy = await MainActor.run { dosing }
        guard !busy else {
            await MainActor.run {
                state.handleAcknowledgment(success: false, message: "Loop spricht gerade mit der Pumpe. Kurz warten.")
            }
            return
        }
        await MainActor.run { self.dosing = true }
        let amount = Self.medtrumStep(units)
        let sent = await deliverBolus(state, units: amount)
        await MainActor.run {
            self.dosing = false
            if sent {
                self.deliveries.append(HandyFreiLoop.Delivery(kind: "bolus", units: amount, minutes: 0, date: Date()))
                self.log.append(["date": Date().timeIntervalSince1970, "kind": "bolus", "units": amount, "minutes": 0])
                HandyFreiDisk.save(session: self)
                state.handyFreiLoopLine = "\(Self.clock()) Bolus \(String(format: "%.2f", amount)) U · Pumpe ok"
                state.handleAcknowledgment(success: true, message: "Bolus \(String(format: "%.2f", amount)) U")
            } else {
                self.bolusUncertain = true
                self.deliveries.append(HandyFreiLoop.Delivery(kind: "bolus", units: amount, minutes: 0, date: Date()))
                self.log.append([
                    "date": Date().timeIntervalSince1970,
                    "kind": "bolus",
                    "units": amount,
                    "minutes": 0,
                    "text": "Bolus unsicher"
                ])
                HandyFreiDisk.save(session: self)
                state.handleAcknowledgment(success: false, message: "Bolus nicht bestätigt. Er zählt vorsorglich, bis der Verlauf ihn zeigt.")
            }
        }
    }

    /// One retry after a fresh synchronize. A second failure is logged and the loop stays up.
    private func deliverTemp(_ state: WatchState, rate: Double, minutes: Int) async -> Bool {
        let label = rate <= 0 ? "cancelTempBasal" : "setTempBasal \(rate)"
        for attempt in 1 ... 2 {
            await MainActor.run { state.handyFreiStatus = "Pumpe: \(label)" }
            do {
                try await HandyFreiMedtrumLink.shared.enactTemp(rate: rate, minutes: minutes)
                return true
            } catch {
                await noteUncertain(error)
                guard attempt == 1, state.handyFreiRunning else {
                    await self.showPumpFailure(state, command: label, error: error)
                    break
                }
                await mark(state, "Pumpe: Sync, dann erneut")
                try? await HandyFreiMedtrumLink.shared.send(.readHistory)
            }
        }
        return false
    }

    private func deliverBolus(_ state: WatchState, units: Double) async -> Bool {
        for attempt in 1 ... 2 {
            await MainActor.run { state.handyFreiStatus = "Pumpe: bolus \(units)" }
            do {
                try await HandyFreiMedtrumLink.shared.send(.bolus(units: units))
                return true
            } catch {
                await noteUncertain(error)
                guard attempt == 1, state.handyFreiRunning else {
                    await self.showPumpFailure(state, command: "bolus", error: error)
                    break
                }
                await mark(state, "Pumpe: Sync, dann Bolus erneut")
                try? await HandyFreiMedtrumLink.shared.send(.readHistory)
            }
        }
        return false
    }

    /// Shown on the watch. A missing session is not queued to the iPhone.
    private func showPumpFailure(_ state: WatchState, command: String, error: Error) async {
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let text = detail == "nicht gefunden"
            ? "\(Self.clock()) \(command): Pumpe nicht verbunden"
            : "\(Self.clock()) \(command) fehlgeschlagen. \(detail)"
        await MainActor.run { state.handyFreiLoopLine = text }
        await mark(state, text)
    }

    private static func clock(_ date: Date = Date()) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    private static func clockMinute(_ date: Date = Date()) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    private static func medtrumStep(_ value: Double) -> Double {
        (value / 0.05).rounded() * 0.05
    }

    /// The command may already be on the pump. The iPhone reads the pump history after it reconnects.
    private func noteUncertain(_ error: Error) async {
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        await MainActor.run {
            log.append([
                "date": Date().timeIntervalSince1970,
                "kind": "uncertain",
                "text": "Pumpenbefehl unsicher. \(detail). iPhone soll den Pumpenverlauf lesen."
            ])
        }
    }

    func finish(_ state: WatchState) {
        log.append([
            "date": Date().timeIntervalSince1970,
            "kind": "stop",
            "text": "Temporäres Basal abbrechen, falls eines gesetzt wurde. Verbindung zu."
        ])
        sendLog(state)
        doseEpoch += 1
        active = false
        HandyFreiDisk.save(session: self)
        state.handyFreiRunning = false
        HandyFreiWorkout.shared.stop()
        HandyFreiLibreLink.stop()
        Task {
            try? await HandyFreiMedtrumLink.shared.send(.cancelTempBasal)
            HandyFreiMedtrumLink.shared.stop()
        }
        state.handyFreiStatus = "Handy-frei beendet. „Handy-frei aktivieren“ startet wieder, auch ohne iPhone."
        state.reportHandyFreiHeartbeat()
    }

    private func phoneReachable(_ state: WatchState) -> Bool {
        guard let session = state.session else { return false }
        return session.activationState == .activated && session.isReachable
    }

    /// Ends the session only when the iPhone can take the radio back. Otherwise keeps retrying.
    private func giveUpOrRetry(_ state: WatchState, _ text: String) {
        guard state.handyFreiRunning else { return }
        if phoneReachable(state) {
            fail(state, text)
            return
        }
        state.handyFreiAlarm = "\(Self.clockMinute()) \(text)"
        state.handyFreiStatus = "\(Self.clockMinute()) \(text) Nächster Versuch in 90 s. Die Uhr macht weiter, auch ohne iPhone."
        state.handyFreiLoopLine = ""
        log.append([
            "date": Date().timeIntervalSince1970,
            "kind": "alarm",
            "text": state.handyFreiStatus
        ])
        guard backoffTask == nil else { return }
        let epoch = doseEpoch
        backoffTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.doseEpoch == epoch { self.backoffTask = nil }
            }
            while state.handyFreiRunning, epoch == self.doseEpoch {
                try? await Task.sleep(nanoseconds: 90_000_000_000)
                guard state.handyFreiRunning, epoch == self.doseEpoch else { return }
                if self.phoneReachable(state) {
                    await MainActor.run {
                        self.fail(state, "iPhone ist wieder da. Steuerung zurück.")
                    }
                    return
                }
                await self.mark(state, "Verbindung neu. Pumpenverlauf zuerst, dann der Sensor.")
                self.sensorRetries = 0
                self.pumpRetries = 0
                self.stallAttempts = 0
                await self.keepAwake(state)
                do {
                    try await self.openPump(state, attempt: 1)
                    guard state.handyFreiRunning, epoch == self.doseEpoch else { return }
                    try await self.openSensor(state)
                    await self.mark(state, "Sensor und Pumpe: Versuch geschafft.")
                    await MainActor.run { self.startGlucoseWatch(state, epoch: epoch) }
                    return
                } catch {
                    await self.mark(state, "Noch nicht verbunden. Nächster Versuch in 90 s. \(error.localizedDescription)")
                }
            }
        }
    }

    private weak var boundState: WatchState?

    /// The view that owns the buttons. A background wake uses the same object.
    func bind(_ state: WatchState) {
        boundState = state
    }

    /// After a crash, kill, or reboot, the next launch reads the saved session and starts the workout and the scan again.
    func resumeIfNeeded(_ state: WatchState) {
        bind(state)
        guard !state.handyFreiRunning, HandyFreiDisk.wasActive() else { return }
        state.handyFreiStatus = "Handy-frei wird aus der letzten Kopie fortgesetzt."
        restartFromCache(state)
    }

    func wakeFromBackground() {
        guard HandyFreiDisk.wasActive() || boundState?.handyFreiRunning == true else { return }
        scheduleRefresh()
        guard let state = boundState else { return }
        if state.handyFreiRunning {
            Task { await self.keepAwake(state) }
        } else {
            resumeIfNeeded(state)
        }
    }

    private func scheduleRefresh() {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(15 * 60),
            userInfo: nil
        ) { _ in }
    }

    func restartFromCache(_ state: WatchState) {
        backoffTask?.cancel()
        backoffTask = nil
        doseEpoch += 1
        state.handyFreiRunning = false
        state.handyFreiAlarm = ""
        HandyFreiLibreLink.stop()
        HandyFreiMedtrumLink.shared.stop()
        start(state)
    }

    private func fail(_ state: WatchState, _ text: String) {
        guard state.handyFreiRunning else { return }
        doseEpoch += 1
        state.handyFreiRunning = false
        state.handyFreiAlarm = text
        WKInterfaceDevice.current().play(.notification)
        log.append([
            "date": Date().timeIntervalSince1970,
            "kind": "alarm",
            "text": text
        ])
        sendLog(state)
        active = false
        HandyFreiDisk.save(session: self)
        state.reportHandyFreiHeartbeat()
        HandyFreiWorkout.shared.stop()
        HandyFreiLibreLink.stop()
        Task {
            try? await HandyFreiMedtrumLink.shared.send(.cancelTempBasal)
            HandyFreiMedtrumLink.shared.stop()
        }
    }

    private func sendLog(_ state: WatchState) {
        let message = ["handyFreiLog": log]
        if let session = state.session, session.isReachable {
            session.sendMessage(message, replyHandler: nil) { _ in
                session.transferUserInfo(message)
            }
        } else {
            state.session?.transferUserInfo(message)
        }
    }

    enum HandyFreiDisk {
        struct Carb: Codable {
            var id: String
            var date: TimeInterval
            var grams: Double
            var fat: Double
            var protein: Double
            var name: String
            var isFPU: Bool
            var fpuID: String?

            init(id: String, date: TimeInterval, grams: Double, fat: Double, protein: Double, name: String, isFPU: Bool = false, fpuID: String? = nil) {
                self.id = id
                self.date = date
                self.grams = grams
                self.fat = fat
                self.protein = protein
                self.name = name
                self.isFPU = isFPU
                self.fpuID = fpuID
            }

            private enum CodingKeys: String, CodingKey {
                case id, date, grams, fat, protein, name, isFPU, fpuID
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(String.self, forKey: .id)
                date = try container.decode(TimeInterval.self, forKey: .date)
                grams = try container.decode(Double.self, forKey: .grams)
                fat = try container.decodeIfPresent(Double.self, forKey: .fat) ?? 0
                protein = try container.decodeIfPresent(Double.self, forKey: .protein) ?? 0
                name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
                isFPU = try container.decodeIfPresent(Bool.self, forKey: .isFPU) ?? false
                fpuID = try container.decodeIfPresent(String.self, forKey: .fpuID)
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(id, forKey: .id)
                try container.encode(date, forKey: .date)
                try container.encode(grams, forKey: .grams)
                try container.encode(fat, forKey: .fat)
                try container.encode(protein, forKey: .protein)
                try container.encode(name, forKey: .name)
                try container.encode(isFPU, forKey: .isFPU)
                try container.encodeIfPresent(fpuID, forKey: .fpuID)
            }
        }

        struct StoredDelivery: Codable {
            var kind: String
            var units: Double
            var minutes: Int
            var date: TimeInterval
        }

        struct Reading: Codable {
            var date: TimeInterval
            var mgdl: Int
        }

        struct File: Codable {
            var files: [String: String] = [:]
            var basal: [Double] = []
            var isf: [Double] = []
            var carbRatio: [Double] = []
            var presets: [MealPresetWatch] = []
            var deliveries: [StoredDelivery] = []
            var carbs: [Carb] = []
            var readings: [Reading] = []
            var lastSuccess: TimeInterval = 0
            var lastReason: String = ""
            var lastIOB: Double = 0
            var lastCOB: Double = 0
            var bleAddress = ""
            var sensorPeripheralID = ""
            var blePIN = ""
            var phase5 = ""
            var pumpSerial = ""
            var sessionToken = ""
            var backupToken = ""
            var snapshotAt: TimeInterval = 0
            var logJSON: Data = Data()
            var active = false

            private enum CodingKeys: String, CodingKey {
                case files
                case basal
                case isf
                case carbRatio
                case presets
                case deliveries
                case carbs
                case readings
                case lastSuccess
                case lastReason
                case lastIOB
                case lastCOB
                case bleAddress
                case sensorPeripheralID
                case blePIN
                case phase5
                case pumpSerial
                case sessionToken
                case backupToken
                case snapshotAt
                case logJSON
                case active
            }

            init() {}

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                files = try container.decodeIfPresent([String: String].self, forKey: .files) ?? [:]
                basal = try container.decodeIfPresent([Double].self, forKey: .basal) ?? []
                isf = try container.decodeIfPresent([Double].self, forKey: .isf) ?? []
                carbRatio = try container.decodeIfPresent([Double].self, forKey: .carbRatio) ?? []
                presets = (try? container.decode([MealPresetWatch].self, forKey: .presets)) ?? []
                deliveries = try container.decodeIfPresent([StoredDelivery].self, forKey: .deliveries) ?? []
                carbs = try container.decodeIfPresent([Carb].self, forKey: .carbs) ?? []
                readings = try container.decodeIfPresent([Reading].self, forKey: .readings) ?? []
                lastSuccess = try container.decodeIfPresent(TimeInterval.self, forKey: .lastSuccess) ?? 0
                lastReason = try container.decodeIfPresent(String.self, forKey: .lastReason) ?? ""
                lastIOB = try container.decodeIfPresent(Double.self, forKey: .lastIOB) ?? 0
                lastCOB = try container.decodeIfPresent(Double.self, forKey: .lastCOB) ?? 0
                bleAddress = try container.decodeIfPresent(String.self, forKey: .bleAddress) ?? ""
                sensorPeripheralID = try container.decodeIfPresent(String.self, forKey: .sensorPeripheralID) ?? ""
                blePIN = try container.decodeIfPresent(String.self, forKey: .blePIN) ?? ""
                phase5 = try container.decodeIfPresent(String.self, forKey: .phase5) ?? ""
                pumpSerial = try container.decodeIfPresent(String.self, forKey: .pumpSerial) ?? ""
                sessionToken = try container.decodeIfPresent(String.self, forKey: .sessionToken) ?? ""
                backupToken = try container.decodeIfPresent(String.self, forKey: .backupToken) ?? ""
                snapshotAt = try container.decodeIfPresent(TimeInterval.self, forKey: .snapshotAt) ?? 0
                logJSON = try container.decodeIfPresent(Data.self, forKey: .logJSON) ?? Data()
                active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? false
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(files, forKey: .files)
                try container.encode(basal, forKey: .basal)
                try container.encode(isf, forKey: .isf)
                try container.encode(carbRatio, forKey: .carbRatio)
                try container.encode(presets, forKey: .presets)
                try container.encode(deliveries, forKey: .deliveries)
                try container.encode(carbs, forKey: .carbs)
                try container.encode(readings, forKey: .readings)
                try container.encode(lastSuccess, forKey: .lastSuccess)
                try container.encode(lastReason, forKey: .lastReason)
                try container.encode(lastIOB, forKey: .lastIOB)
                try container.encode(lastCOB, forKey: .lastCOB)
                try container.encode(bleAddress, forKey: .bleAddress)
                try container.encode(sensorPeripheralID, forKey: .sensorPeripheralID)
                try container.encode(blePIN, forKey: .blePIN)
                try container.encode(phase5, forKey: .phase5)
                try container.encode(pumpSerial, forKey: .pumpSerial)
                try container.encode(sessionToken, forKey: .sessionToken)
                try container.encode(backupToken, forKey: .backupToken)
                try container.encode(snapshotAt, forKey: .snapshotAt)
                try container.encode(logJSON, forKey: .logJSON)
                try container.encode(active, forKey: .active)
            }
        }

        static func save(session: HandyFreiSession) {
            var file = load() ?? File()
            file.deliveries = session.deliveries.map {
                StoredDelivery(kind: $0.kind, units: $0.units, minutes: $0.minutes, date: $0.date.timeIntervalSince1970)
            }
            file.carbs = session.carbs
            file.readings = session.readings.map { Reading(date: $0.date.timeIntervalSince1970, mgdl: $0.mgdl) }
            file.lastSuccess = session.lastSuccess.timeIntervalSince1970
            file.lastReason = session.lastReason
            file.lastIOB = session.lastIOB
            file.lastCOB = session.lastCOB
            file.logJSON = (try? JSONSerialization.data(withJSONObject: session.log)) ?? file.logJSON
            file.active = session.active
            write(file)
        }

        static func wasActive() -> Bool {
            load()?.active == true
        }

        static func saveSnapshot(_ state: WatchState) {
            var file = load() ?? File()
            if !state.handyFreiFiles.isEmpty { file.files = state.handyFreiFiles }
            file.basal = state.handyFreiBasal
            file.isf = state.handyFreiISF
            file.carbRatio = state.handyFreiCarbRatio
            file.presets = state.mealPresets
            file.bleAddress = state.handyFreiBleAddress
            file.sensorPeripheralID = state.handyFreiSensorPeripheralID
            file.blePIN = state.handyFreiBlePIN
            file.phase5 = state.handyFreiPhase5
            file.pumpSerial = state.handyFreiPumpSerial
            file.sessionToken = state.handyFreiSessionToken
            file.backupToken = state.handyFreiBackupToken
            if let copied = state.handyFreiSnapshotAt { file.snapshotAt = copied.timeIntervalSince1970 }
            write(file)
        }

        static func restore(into state: WatchState, session: HandyFreiSession) {
            guard let file = load() else { return }
            if !file.files.isEmpty { state.handyFreiFiles = file.files }
            if state.handyFreiBasal.isEmpty { state.handyFreiBasal = file.basal }
            if state.handyFreiISF.isEmpty { state.handyFreiISF = file.isf }
            if state.handyFreiCarbRatio.isEmpty { state.handyFreiCarbRatio = file.carbRatio }
            if state.mealPresets.isEmpty { state.mealPresets = file.presets }
            if state.handyFreiBleAddress.isEmpty { state.handyFreiBleAddress = file.bleAddress }
            if state.handyFreiSensorPeripheralID.isEmpty { state.handyFreiSensorPeripheralID = file.sensorPeripheralID }
            if state.handyFreiBlePIN.isEmpty { state.handyFreiBlePIN = file.blePIN }
            if state.handyFreiPhase5.isEmpty { state.handyFreiPhase5 = file.phase5 }
            if state.handyFreiPumpSerial.isEmpty { state.handyFreiPumpSerial = file.pumpSerial }
            if state.handyFreiSessionToken.isEmpty { state.handyFreiSessionToken = file.sessionToken }
            if state.handyFreiBackupToken.isEmpty { state.handyFreiBackupToken = file.backupToken }
            if state.handyFreiSnapshotAt == nil, file.snapshotAt > 0 {
                state.handyFreiSnapshotAt = Date(timeIntervalSince1970: file.snapshotAt)
            }
            session.deliveries = file.deliveries.map {
                HandyFreiLoop.Delivery(
                    kind: $0.kind,
                    units: $0.units,
                    minutes: $0.minutes,
                    date: Date(timeIntervalSince1970: $0.date)
                )
            }
            session.carbs = file.carbs
            session.readings = file.readings.map { (date: Date(timeIntervalSince1970: $0.date), mgdl: $0.mgdl) }
            if file.lastSuccess > 1_000_000_000 {
                session.lastSuccess = Date(timeIntervalSince1970: file.lastSuccess)
                session.lastDose = session.lastSuccess
            }
            if !file.lastReason.isEmpty { session.lastReason = file.lastReason }
            session.lastIOB = file.lastIOB
            session.lastCOB = file.lastCOB
            if let restored = try? JSONSerialization.jsonObject(with: file.logJSON) as? [[String: Any]] {
                session.log = restored
            }
        }

        private static func load() -> File? {
            guard let url = fileURL(), let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(File.self, from: data)
        }

        private static func write(_ file: File) {
            guard let url = fileURL(), let data = try? JSONEncoder().encode(file) else { return }
            try? data.write(to: url, options: .atomic)
        }

        private static func fileURL() -> URL? {
            guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                return nil
            }
            let folder = base.appendingPathComponent("HandyFrei", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder.appendingPathComponent("snapshot.json")
        }
    }
}

/// Workout session keeps the watch app awake. It does not dose.
final class HandyFreiWorkout: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    static let shared = HandyFreiWorkout()
    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var onEnd: ((Bool) -> Void)?

    func prepare(onEnd: @escaping (Bool) -> Void) async -> Bool {
        self.onEnd = onEnd
        let workout = HKObjectType.workoutType()
        do {
            try await store.requestAuthorization(toShare: [workout], read: [workout])
        } catch {
            return false
        }
        guard store.authorizationStatus(for: workout) == .sharingAuthorized else { return false }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .unknown
        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.delegate = self
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
            session.delegate = self
            self.session = session
            self.builder = builder
            session.startActivity(with: Date())
            try? await builder.beginCollection(at: Date())
            return true
        } catch {
            return false
        }
    }

    func stop() {
        let collected = builder
        builder = nil
        collected?.endCollection(withEnd: Date()) { _, _ in }
        session?.end()
        session = nil
    }

    func workoutSession(_: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from _: HKWorkoutSessionState, date _: Date) {
        if toState == .ended || toState == .stopped {
            onEnd?(true)
        }
    }

    func workoutSession(_: HKWorkoutSession, didFailWithError _: Error) {
        onEnd?(true)
    }

    func workoutBuilderDidCollectEvent(_: HKLiveWorkoutBuilder) {}

    func workoutBuilder(_: HKLiveWorkoutBuilder, didCollectDataOf _: Set<HKSampleType>) {}
}
