import HandyFreiDrivers
import HealthKit
import SwiftUI
import WatchKit

/// Handy-frei on the watch. It scans and may connect. It does not write a patch-stop or a sensor activation.
struct HandyFreiWatchView: View {
    @Bindable var state: WatchState
    @State private var alarm = ""
    @State private var log: [[String: Any]] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Handy-frei")
                    .font(.headline)
                Text(state.handyFreiStatus)
                    .font(.footnote)
                if !alarm.isEmpty {
                    Text(alarm)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if state.handyFreiReadyToConfirm {
                    Button("iPhone-Bluetooth ist aus") {
                        confirmPhoneOff()
                    }
                }
                Button("Handy-frei beenden") {
                    finish()
                }
                Text(state.handyFreiPhase2
                    ? "Phase 2 ist an. Die Uhr liest den Libre und darf nur die sechs erlaubten Pumpenbefehle senden."
                    : "Phase 1: die Uhr liest den Libre und rechnet im Schatten. Die Pumpe wird nicht gestellt.")
                    .font(.footnote)
            }
            .padding()
        }
    }

    private func confirmPhoneOff() {
        state.session?.sendMessage(["handyFreiPhoneOff": true], replyHandler: nil) { _ in }
        HandyFreiWorkout.shared.start { ended in
            if ended {
                fail("Die Workout-Sitzung ist zu Ende. Bluetooth am iPhone wieder einschalten.")
            }
        }
        let address = state.handyFreiBleAddress
        let pin = Data(base64Encoded: state.handyFreiBlePIN) ?? Data()
        let phase5 = Data(base64Encoded: state.handyFreiPhase5) ?? Data()
        let pump = state.handyFreiPumpSerial
        let token = state.handyFreiSessionToken
        let phase2 = state.handyFreiPhase2
        Task {
            do {
                try await HandyFreiLibreLink.reconnect(bleAddress: address, blePIN: pin, phase5RawKey: phase5) { mgdl in
                    DispatchQueue.main.async {
                        self.state.handyFreiGlucose = mgdl
                        self.state.handyFreiStatus = HandyFrei.shadowLine(glucose: Double(mgdl), iob: 0)
                    }
                }
                guard phase2 else { return }
                try await HandyFreiMedtrumLink.shared.connect(pumpSerialBase64: pump, sessionTokenBase64: token)
                try await HandyFreiMedtrumLink.shared.send(.readStatus)
                try await HandyFreiMedtrumLink.shared.send(.readHistory)
            } catch {
                await MainActor.run {
                    fail("Verbindung fehlgeschlagen. Bluetooth am iPhone wieder einschalten.")
                }
            }
        }
    }

    private func finish() {
        log.append([
            "date": Date().timeIntervalSince1970,
            "kind": "stop",
            "text": "Temporäres Basal abbrechen, falls eines gesetzt wurde. Verbindung zu."
        ])
        let message = ["handyFreiLog": log]
        if let session = state.session, session.isReachable {
            session.sendMessage(message, replyHandler: nil) { _ in
                session.transferUserInfo(message)
            }
        } else {
            state.session?.transferUserInfo(message)
        }
        if state.handyFreiPhase2 {
            Task {
                try? await HandyFreiMedtrumLink.shared.send(.cancelTempBasal)
                HandyFreiMedtrumLink.shared.stop()
            }
        }
        HandyFreiLibreLink.stop()
        HandyFreiWorkout.shared.stop()
        state.handyFreiStatus = "Handy-frei beendet. Bluetooth am iPhone wieder einschalten."
    }

    private func fail(_ text: String) {
        alarm = text
        WKInterfaceDevice.current().play(.notification)
        log.append([
            "date": Date().timeIntervalSince1970,
            "kind": "alarm",
            "text": text
        ])
        HandyFreiLibreLink.stop()
        HandyFreiMedtrumLink.shared.stop()
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

    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        if toState == .ended || toState == .stopped {
            onEnd?(true)
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        onEnd?(true)
    }
}
