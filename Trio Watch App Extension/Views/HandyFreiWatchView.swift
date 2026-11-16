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

    func start(_ state: WatchState) {
        guard !state.handyFreiRunning else { return }
        state.handyFreiRunning = true
        state.handyFreiAlarm = ""
        log = []
        deliveries = []
        readings = []
        HandyFreiWorkout.shared.start { ended in
            DispatchQueue.main.async {
                guard state.handyFreiRunning, ended else { return }
                self.fail(state, "Die Workout-Sitzung ist zu Ende. Bluetooth am iPhone wieder einschalten.")
            }
        }
        let address = state.handyFreiBleAddress
        let pin = Data(base64Encoded: state.handyFreiBlePIN) ?? Data()
        let phase5 = Data(base64Encoded: state.handyFreiPhase5) ?? Data()
        let pump = state.handyFreiPumpSerial
        let token = state.handyFreiSessionToken
        HandyFreiMedtrumLink.shared.onConnectionLost = {
            DispatchQueue.main.async {
                guard state.handyFreiRunning else { return }
                self.fail(state, "Pumpe weg. Bluetooth am iPhone wieder einschalten.")
            }
        }
        Task {
            guard state.handyFreiRunning else { return }
            do {
                try await HandyFreiMedtrumLink.shared.connect(pumpSerialBase64: pump, sessionTokenBase64: token)
                guard state.handyFreiRunning else {
                    HandyFreiMedtrumLink.shared.stop()
                    return
                }
                try await HandyFreiMedtrumLink.shared.send(.readStatus)
                try await HandyFreiMedtrumLink.shared.send(.readHistory)
                guard state.handyFreiRunning else {
                    HandyFreiMedtrumLink.shared.stop()
                    return
                }
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
                    }
                )
            } catch {
                await MainActor.run {
                    guard state.handyFreiRunning else { return }
                    self.fail(state, "Verbindung fehlgeschlagen. Bluetooth am iPhone wieder einschalten.")
                }
            }
        }
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
        Task {
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

    func start(onEnd: @escaping (Bool) -> Void) {
        self.onEnd = onEnd
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .unknown
        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            session.delegate = self
            self.session = session
            session.startActivity(with: Date())
        } catch {
            onEnd(true)
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
