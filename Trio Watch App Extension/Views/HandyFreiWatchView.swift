import HandyFreiDrivers
import HealthKit
import SwiftUI
import Trio
import WatchKit

/// Handy-frei on the watch. One start, sensor and pump together. No patch stop and no sensor activation.
struct HandyFreiWatchView: View {
    @Bindable var state: WatchState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Handy-frei")
                    .font(.headline)
                Text(state.handyFreiStatus)
                    .font(.footnote)
                if !state.handyFreiAlarm.isEmpty {
                    Text(state.handyFreiAlarm)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if state.handyFreiReadyToConfirm, !state.handyFreiRunning {
                    Button("Übernehmen") {
                        state.requestHandyFrei()
                    }
                }
                Button("Handy-frei beenden") {
                    state.stopHandyFrei()
                }
                Text("Sensor, Loop und Pumpe laufen auf der Uhr. Nur die sechs erlaubten Befehle. Bei Abbruch Bluetooth am iPhone wieder einschalten.")
                    .font(.footnote)
            }
            .padding()
        }
    }
}

extension WatchState {
    /// Phone already confirmed Bluetooth is off, or the phone can no longer be reached.
    func startHandyFrei() {
        HandyFreiSession.shared.start(self)
    }

    /// One tap. Starts only after the phone confirms Bluetooth is off, or when the phone is unreachable.
    func requestHandyFrei() {
        guard !handyFreiRunning else { return }
        guard let session else {
            startHandyFrei()
            return
        }
        session.sendMessage(["handyFreiPhoneOff": true], replyHandler: nil, errorHandler: { _ in
            DispatchQueue.main.async {
                self.startHandyFrei()
            }
        })
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
        dosing = false
        lastDose = .distantPast
        pumpRetries = 0
        sensorRetries = 0
        workoutRestarts = 0
        replacingSensor = false
        let epoch = doseEpoch
        state.handyFreiAlarm = ""
        log = []
        deliveries = []
        readings = []
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
            let allowed = await HandyFreiWorkout.shared.prepare { ended in
                DispatchQueue.main.async {
                    guard state.handyFreiRunning, ended else { return }
                    Task { await self.keepAwake(state) }
                }
            }
            guard allowed else {
                await MainActor.run {
                    self.fail(state, "HealthKit nicht erlaubt. Bluetooth am iPhone wieder einschalten.")
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
                let started = Date()
                Task { await self.watchGlucoseAge(state, epoch: epoch, started: started) }
            } catch {
                let text = Self.failureText(stage: "Start", error: error)
                await self.mark(state, text)
                await MainActor.run {
                    guard state.handyFreiRunning else { return }
                    self.fail(state, text)
                }
            }
        }
    }

    /// No insulin once the newest reading is older than 12 minutes. The session stays up.
    private func watchGlucoseAge(_ state: WatchState, epoch: Int, started: Date) async {
        while state.handyFreiRunning, epoch == doseEpoch {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard state.handyFreiRunning, epoch == doseEpoch else { return }
            let newest = await MainActor.run { self.readings.map(\.date).max() ?? started }
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
        guard workoutRestarts <= 1 else {
            await MainActor.run {
                self.fail(state, "Die Workout-Sitzung ist zu Ende. Bluetooth am iPhone wieder einschalten.")
            }
            return
        }
        await mark(state, "Workout erneut")
        let allowed = await HandyFreiWorkout.shared.prepare { ended in
            DispatchQueue.main.async {
                guard state.handyFreiRunning, ended else { return }
                Task { await self.keepAwake(state) }
            }
        }
        guard allowed, state.handyFreiRunning else {
            await MainActor.run {
                self.fail(state, "HealthKit nicht erlaubt. Bluetooth am iPhone wieder einschalten.")
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
            await mark(state, "Pumpe: Verlauf gelesen")
            pumpRetries = 0
        } catch {
            HandyFreiMedtrumLink.shared.stop()
            guard attempt < 3, state.handyFreiRunning else { throw error }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            try await openPump(state, attempt: attempt + 1)
        }
    }

    private func openSensor(_ state: WatchState) async throws {
        replacingSensor = true
        HandyFreiLibreLink.stop()
        await mark(state, sensorRetries == 0 ? "Sensor: suche" : "Sensor: erneut \(sensorRetries)")
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
                    Task { await self.restoreSensor(state) }
                }
            },
            onStatus: { text in
                Task { await self.mark(state, text) }
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
            await MainActor.run {
                self.fail(state, "Pumpe weg. Bluetooth am iPhone wieder einschalten.")
            }
            return
        }
        do {
            try await openPump(state, attempt: pumpRetries)
        } catch {
            await MainActor.run {
                self.fail(state, "Pumpe weg. \(error.localizedDescription). Bluetooth am iPhone wieder einschalten.")
            }
        }
    }

    private func restoreSensor(_ state: WatchState) async {
        guard state.handyFreiRunning, !replacingSensor else { return }
        sensorRetries += 1
        guard sensorRetries <= 3 else {
            await MainActor.run {
                self.fail(state, "Sensor weg. Bluetooth am iPhone wieder einschalten.")
            }
            return
        }
        do {
            try await openSensor(state)
        } catch {
            await restoreSensor(state)
        }
    }

    private func mark(_ state: WatchState, _ text: String) async {
        await MainActor.run {
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
                return "\(detail). Bluetooth am iPhone wieder einschalten."
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
        return "\(headline). \(error.localizedDescription). Bluetooth am iPhone wieder einschalten."
    }

    private func absorb(_ state: WatchState, _ mgdl: Int) {
        guard state.handyFreiRunning else { return }
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        if device.batteryLevel >= 0, device.batteryLevel < 0.1 {
            fail(state, "Akku unter 10 Prozent. Bluetooth am iPhone wieder einschalten.")
            return
        }
        readings.append((Date(), mgdl))
        if readings.count > 36 { readings.removeFirst(readings.count - 36) }
        let outcome = HandyFreiLoop.tick(
            files: state.handyFreiFiles,
            rheosBasal: state.handyFreiBasal,
            rheosISF: state.handyFreiISF,
            rheosCarbRatio: state.handyFreiCarbRatio,
            glucose: readings,
            deliveries: deliveries,
            now: Date()
        )
        state.handyFreiGlucose = mgdl
        state.handyFreiStatus = "\(mgdl) mg/dL. \(outcome.reason)"
        log.append([
            "date": Date().timeIntervalSince1970,
            "kind": "determination",
            "text": "\(mgdl) mg/dL. \(outcome.reason)"
        ])
        guard outcome.deliver || outcome.cancelTemp else { return }
        guard !dosing else { return }
        // Same cadence as the phone loop. Glucose still updates on every reading.
        guard Date().timeIntervalSince(lastDose) >= 5 * 60 else { return }
        dosing = true
        lastDose = Date()
        let epoch = doseEpoch
        let rate = Self.medtrumStep(min(outcome.rate, outcome.maxBasal))
        let units = Self.medtrumStep(min(outcome.smb, outcome.maxBolus))
        Task {
            defer { Task { @MainActor in self.dosing = false } }
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
                }
            }
            guard sent, outcome.smb > 0, units > 0, outcome.iob + units <= outcome.maxIOB else { return }
            let bolusSent = await self.deliverBolus(state, units: units)
            if bolusSent {
                await MainActor.run {
                    self.deliveries.append(HandyFreiLoop.Delivery(kind: "bolus", units: units, minutes: 0, date: Date()))
                    self.log.append(["date": Date().timeIntervalSince1970, "kind": "bolus", "units": units, "minutes": 0])
                }
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
                guard attempt == 1, state.handyFreiRunning else { break }
                await mark(state, "Pumpe: Sync, dann erneut")
                try? await HandyFreiMedtrumLink.shared.send(.readHistory)
            }
        }
        await mark(state, "Pumpe: \(label) übersprungen. Loop läuft weiter.")
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
                guard attempt == 1, state.handyFreiRunning else { break }
                await mark(state, "Pumpe: Sync, dann Bolus erneut")
                try? await HandyFreiMedtrumLink.shared.send(.readHistory)
            }
        }
        await mark(state, "Pumpe: bolus übersprungen. Loop läuft weiter.")
        return false
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
        state.handyFreiRunning = false
        HandyFreiWorkout.shared.stop()
        HandyFreiLibreLink.stop()
        Task {
            try? await HandyFreiMedtrumLink.shared.send(.cancelTempBasal)
            HandyFreiMedtrumLink.shared.stop()
        }
        state.handyFreiStatus = "Handy-frei beendet. Bluetooth am iPhone wieder einschalten."
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
