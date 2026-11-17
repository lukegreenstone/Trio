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

    func start(_ state: WatchState) {
        guard !state.handyFreiRunning else { return }
        state.handyFreiRunning = true
        doseEpoch += 1
        let epoch = doseEpoch
        state.handyFreiAlarm = ""
        log = []
        deliveries = []
        readings = []
        let address = state.handyFreiBleAddress
        let pin = Data(base64Encoded: state.handyFreiBlePIN) ?? Data()
        let phase5 = Data(base64Encoded: state.handyFreiPhase5) ?? Data()
        let pump = state.handyFreiPumpSerial
        let token = state.handyFreiSessionToken
        let backup = state.handyFreiBackupToken
        HandyFreiMedtrumLink.shared.onConnectionLost = {
            DispatchQueue.main.async {
                guard state.handyFreiRunning else { return }
                self.fail(state, "Pumpe weg. Bluetooth am iPhone wieder einschalten.")
            }
        }
        Task {
            guard state.handyFreiRunning, epoch == self.doseEpoch else { return }
            let allowed = await HandyFreiWorkout.shared.prepare { ended in
                DispatchQueue.main.async {
                    guard state.handyFreiRunning, ended else { return }
                    self.fail(state, "Die Workout-Sitzung ist zu Ende. Bluetooth am iPhone wieder einschalten.")
                }
            }
            guard allowed else {
                await MainActor.run {
                    self.fail(state, "HealthKit nicht erlaubt. Bluetooth am iPhone wieder einschalten.")
                }
                return
            }
            guard state.handyFreiRunning, epoch == self.doseEpoch else { return }
            var stage = "Pumpe"
            do {
                stage = "Pumpe"
                await self.mark(state, "Pumpe: suche")
                try await HandyFreiMedtrumLink.shared.connect(
                    pumpSerialBase64: pump,
                    sessionTokenBase64: token,
                    backupTokenBase64: backup
                )
                await self.mark(state, "Pumpe: verbunden")
                guard state.handyFreiRunning, epoch == self.doseEpoch else {
                    HandyFreiMedtrumLink.shared.stop()
                    return
                }
                stage = "Pumpe: Status"
                await self.mark(state, "Pumpe: Status lesen")
                try await HandyFreiMedtrumLink.shared.send(.readStatus)
                await self.mark(state, "Pumpe: Status gelesen")
                stage = "Pumpe: Verlauf"
                await self.mark(state, "Pumpe: Verlauf lesen")
                try await HandyFreiMedtrumLink.shared.send(.readHistory)
                await self.mark(state, "Pumpe: Verlauf gelesen")
                guard state.handyFreiRunning, epoch == self.doseEpoch else {
                    HandyFreiMedtrumLink.shared.stop()
                    return
                }
                stage = "Sensor"
                await self.mark(state, "Sensor: suche")
                try await HandyFreiLibreLink.reconnect(
                    bleAddress: address,
                    blePIN: pin,
                    phase5RawKey: phase5,
                    onGlucose: { mgdl in
                        DispatchQueue.main.async {
                            self.absorb(state, mgdl)
                        }
                    },
                    onDisconnect: {
                        DispatchQueue.main.async {
                            guard state.handyFreiRunning else { return }
                            self.fail(state, "Sensor weg. Bluetooth am iPhone wieder einschalten.")
                        }
                    },
                    onStatus: { text in
                        Task { await self.mark(state, text) }
                    }
                )
                await self.mark(state, "Sensor: verbunden, warte auf Werte")
            } catch {
                let text = Self.failureText(stage: stage, error: error)
                await self.mark(state, text)
                await MainActor.run {
                    guard state.handyFreiRunning else { return }
                    self.fail(state, text)
                }
            }
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
            switch link {
            case .bluetoothOff:
                headline = "Uhr-Bluetooth aus"
            case .bluetoothDenied:
                headline = "Uhr-Bluetooth nicht erlaubt"
            case .bluetoothUnsupported:
                headline = "Uhr-Bluetooth nicht unterstützt"
            case .notFound where stage == "Pumpe":
                headline = "Pumpe: nicht gefunden (Scan 90 s)"
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
        if device.batteryLevel >= 0, device.batteryLevel < 0.2 {
            fail(state, "Akku unter 20 Prozent. Bluetooth am iPhone wieder einschalten.")
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
        state.handyFreiStatus = outcome.reason
        log.append([
            "date": Date().timeIntervalSince1970,
            "kind": "determination",
            "text": outcome.reason
        ])
        if !outcome.deliver, outcome.cancelTemp {
            Task {
                try? await HandyFreiMedtrumLink.shared.send(.cancelTempBasal)
                await MainActor.run {
                    self.fail(state, outcome.reason)
                }
            }
            return
        }
        guard outcome.deliver || outcome.cancelTemp else { return }
        let epoch = doseEpoch
        Task {
            guard state.handyFreiRunning, epoch == self.doseEpoch else { return }
            do {
                if outcome.cancelTemp || outcome.rate <= 0 {
                    try await HandyFreiMedtrumLink.shared.send(.cancelTempBasal)
                } else if outcome.minutes > 0 {
                    let rate = min(outcome.rate, outcome.maxBasal)
                    try await HandyFreiMedtrumLink.shared.send(.setTempBasal(rate: rate, minutes: outcome.minutes))
                    deliveries.append(HandyFreiLoop.Delivery(kind: "temp", units: rate, minutes: outcome.minutes, date: Date()))
                    log.append(["date": Date().timeIntervalSince1970, "kind": "temp", "units": rate, "minutes": outcome.minutes])
                }
                if outcome.smb > 0, outcome.iob + outcome.smb <= outcome.maxIOB {
                    let units = min(outcome.smb, outcome.maxBolus)
                    try await HandyFreiMedtrumLink.shared.send(.bolus(units: units))
                    deliveries.append(HandyFreiLoop.Delivery(kind: "bolus", units: units, minutes: 0, date: Date()))
                    log.append(["date": Date().timeIntervalSince1970, "kind": "bolus", "units": units, "minutes": 0])
                }
            } catch {
                await MainActor.run {
                    self.fail(state, "Pumpenbefehl fehlgeschlagen. Bluetooth am iPhone wieder einschalten.")
                }
            }
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
final class HandyFreiWorkout: NSObject, HKWorkoutSessionDelegate {
    static let shared = HandyFreiWorkout()
    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
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
            session.delegate = self
            self.session = session
            session.startActivity(with: Date())
            return true
        } catch {
            return false
        }
    }

    func stop() {
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
}
