import CoreBluetooth
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
                    ? "Phase 2 ist an. Befehle bleiben in der erlaubten Liste und werden hier nur ins Protokoll geschrieben."
                    : "Phase 1: Schatten. Die Pumpe wird nicht gestellt.")
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
        HandyFreiScan.shared.lookForSensor(named: state.handyFreiBleAddress) { found in
            if !found {
                fail("Sensor nicht gesehen. Bluetooth am iPhone wieder einschalten.")
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
        HandyFreiWorkout.shared.stop()
        HandyFreiScan.shared.stop()
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
        HandyFreiScan.shared.stop()
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

/// Looks for a Libre by its advertised name. It never writes to the sensor.
final class HandyFreiScan: NSObject, CBCentralManagerDelegate {
    static let shared = HandyFreiScan()
    private var central: CBCentralManager?
    private var done: ((Bool) -> Void)?

    func lookForSensor(named: String?, found: @escaping (Bool) -> Void) {
        wantedName = named ?? ""
        done = found
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func stop() {
        if let central, central.state == .poweredOn {
            central.stopScan()
        }
        central = nil
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            if central.state == .poweredOff { done?(false) }
            return
        }
        central.scanForPeripherals(withServices: nil)
    }

    private var wantedName = ""

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertised = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let expected = wantedName.replacingOccurrences(of: ":", with: "").uppercased()
        guard expected.isEmpty || advertised.uppercased().contains(expected) else { return }
        central.stopScan()
        central.connect(peripheral)
        done?(true)
        done = nil
    }
}
