import CoreBluetooth
import CoreData
import Foundation
import LibreLoop
import MedtrumKit
import WatchConnectivity

/// Prepares Handy-frei. It never asks a driver to disconnect and never deletes a key.
enum HandyFreiPhone {
    private static let statusKey = "handyfrei.status"
    private static let logKey = "handyfrei.log"
    private static let lock = NSLock()
    private static var pending: HandyFrei.Session?
    private static var logImported = false

    static var status: String {
        UserDefaults.standard.string(forKey: statusKey) ?? "Handy-frei ist aus."
    }

    static func prepare(fingerprint: HandyFrei.Fingerprint, snapshot: HandyFrei.Snapshot) -> HandyFrei.Session {
        let session = HandyFrei.prepare(enabled: HandyFrei.isEnabled(), fingerprint: fingerprint)
        lock.lock()
        pending = session
        logImported = false
        lock.unlock()
        if session.step != .offered {
            HandyFreiGate.setPhoneLoopPaused(false)
        }
        store(session)
        HandyFreiBluetoothWatch.shared.start()
        if session.step == .offered {
            send(session, snapshot: snapshot, kind: "prepare")
        }
        return session
    }

    /// Called when iPhone Bluetooth reports poweredOff, or when the watch asks and it really is off.
    static func bluetoothIsOff() {
        lock.lock()
        let current = pending
        lock.unlock()
        guard let current else { return }
        let session = HandyFrei.bluetoothIsOff(current)
        guard session.phoneLoopPaused else {
            store(session)
            return
        }
        HandyFreiGate.setPhoneLoopPaused(true)
        lock.lock()
        pending = session
        lock.unlock()
        store(session)
        send(session, snapshot: nil, kind: "watch-owns")
    }

    static func watchSaysPhoneIsOff() {
        guard HandyFreiBluetoothWatch.shared.isPoweredOff else {
            var note = pending
            note?.note = "Bluetooth am iPhone ist noch an. Bitte in den Einstellungen ausschalten."
            if let note { store(note) }
            return
        }
        bluetoothIsOff()
    }

    /// Stores the watch log, then lets the loop run again. Order is fixed: log first.
    static func importLog(_ entries: [[String: Any]]) {
        let data = try? JSONSerialization.data(withJSONObject: entries)
        if let data {
            UserDefaults.standard.set(data, forKey: logKey)
        }
        storeDeliveries(entries)
        lock.lock()
        logImported = true
        let current = pending ?? HandyFrei.idle(fingerprint: HandyFrei.Fingerprint(
            pumpPeripheralID: nil, pumpSerial: nil, sensorSerial: nil, sensorPeripheralID: nil
        ))
        lock.unlock()
        let session = HandyFrei.resumeAfterLog(current, logImported: true)
        HandyFreiGate.setPhoneLoopPaused(false)
        lock.lock()
        pending = session
        lock.unlock()
        store(session)
    }

    static func stop(fingerprint: HandyFrei.Fingerprint) -> HandyFrei.Session {
        let (session, _) = HandyFrei.stop(HandyFrei.idle(fingerprint: fingerprint))
        HandyFreiGate.setPhoneLoopPaused(false)
        lock.lock()
        pending = session
        lock.unlock()
        store(session)
        return session
    }

    static func collectSnapshot(
        pump: Any?,
        cgm: Any?,
        iob: Double,
        cob: Double,
        maxBolus: Double,
        maxIOB: Double,
        rheosBasal: [Double],
        rheosISF: [Double],
        rheosCarbRatio: [Double],
        loopFiles: [String: String],
        glucose: Double?
    ) -> HandyFrei.Snapshot {
        var snapshot = HandyFrei.Snapshot(
            iob: iob, cob: cob, maxBolus: maxBolus, maxIOB: maxIOB,
            rheosBasal: rheosBasal, rheosISF: rheosISF, rheosCarbRatio: rheosCarbRatio,
            loopFiles: loopFiles, glucose: glucose
        )
        if let medtrum = pump as? MedtrumPumpManager {
            let state = medtrum.state
            snapshot.pumpSerial = state.pumpSN.base64EncodedString()
            snapshot.sessionToken = state.sessionToken.base64EncodedString()
            snapshot.patchId = state.patchId.base64EncodedString()
            snapshot.patchActivatedAt = state.patchActivatedAt
            snapshot.patchExpiresAt = state.patchExpiresAt
        }
        if let libre = cgm as? LibreLoopCGMManager {
            let state = libre.state
            snapshot.sensorSerial = mirrorString(state, "sensorSerial")
            snapshot.bleAddress = mirrorString(state, "bleAddress")
            snapshot.blePIN = mirrorData(state, "blePIN")?.base64EncodedString()
            if let serial = snapshot.sensorSerial {
                let keys = HandyFreiKeyCopy.read(serial: serial)
                snapshot.kEnc = keys?.kEnc.base64EncodedString()
                snapshot.ivEnc = keys?.ivEnc.base64EncodedString()
                snapshot.phase5RawKey = keys?.phase5.base64EncodedString()
                if let receiver = keys?.receiverID {
                    snapshot.receiverID = String(receiver)
                }
            }
        }
        return snapshot
    }

    private static func mirrorString(_ value: Any, _ name: String) -> String? {
        for child in Mirror(reflecting: value).children where child.label == name {
            if let text = child.value as? String { return text }
            let inner = Mirror(reflecting: child.value)
            if inner.displayStyle == .optional, let nested = inner.children.first?.value as? String {
                return nested
            }
        }
        return nil
    }

    private static func mirrorData(_ value: Any, _ name: String) -> Data? {
        for child in Mirror(reflecting: value).children where child.label == name {
            if let data = child.value as? Data { return data }
            let inner = Mirror(reflecting: child.value)
            if inner.displayStyle == .optional, let nested = inner.children.first?.value as? Data {
                return nested
            }
        }
        return nil
    }

    private static func storeDeliveries(_ entries: [[String: Any]]) {
        let context = CoreDataStack.shared.newTaskContext()
        context.performAndWait {
            for entry in entries {
                let kind = entry["kind"] as? String ?? ""
                guard kind == "temp" || kind == "bolus" else { continue }
                let date = Date(timeIntervalSince1970: entry["date"] as? TimeInterval ?? Date().timeIntervalSince1970)
                let units = entry["units"] as? Double ?? 0
                let minutes = entry["minutes"] as? Int ?? 0
                let sync = "handyfrei-\(Int(date.timeIntervalSince1970))-\(kind)"
                let request = PumpEventStored.fetchRequest()
                request.predicate = NSPredicate(format: "syncIdentifier == %@", sync)
                if let found = try? context.fetch(request), !found.isEmpty { continue }
                let row = PumpEventStored(context: context)
                row.id = UUID().uuidString
                row.timestamp = date
                row.syncIdentifier = sync
                row.isMutable = false
                row.isUploadedToNS = false
                row.isUploadedToHealth = false
                row.isUploadedToTidepool = false
                if kind == "bolus" {
                    row.type = PumpEventStored.EventType.smb.rawValue
                    let bolus = BolusStored(context: context)
                    bolus.pumpEvent = row
                    bolus.amount = NSDecimalNumber(value: units)
                    bolus.programmedAmount = NSDecimalNumber(value: units)
                    bolus.isSMB = true
                    bolus.isExternal = false
                } else {
                    row.type = PumpEventStored.EventType.tempBasal.rawValue
                    let temp = TempBasalStored(context: context)
                    temp.pumpEvent = row
                    temp.rate = NSDecimalNumber(value: units)
                    temp.duration = NSDecimalNumber(value: minutes)
                    temp.startDate = date
                    temp.endDate = date.addingTimeInterval(TimeInterval(minutes * 60))
                    temp.tempType = TempType.absolute.rawValue
                    temp.isScheduledBasal = false
                }
            }
            try? context.save()
        }
    }

    private static func store(_ session: HandyFrei.Session) {
        UserDefaults.standard.set(session.note, forKey: statusKey)
    }

    private static func send(_ session: HandyFrei.Session, snapshot: HandyFrei.Snapshot?, kind: String) {
        guard WCSession.isSupported() else { return }
        let link = WCSession.default
        guard link.activationState == .activated else { return }
        var payload: [String: Any] = [
            "kind": kind,
            "note": session.note,
            "phase2": HandyFrei.phase2Enabled(),
            "ownsRadio": session.watchOwnsRadio
        ]
        if let snapshot {
            payload["shadow"] = HandyFrei.shadowLine(glucose: snapshot.glucose, iob: snapshot.iob)
            payload["snapshot"] = snapshot.plist
        }
        let message = ["handyFrei": payload]
        if link.isReachable {
            link.sendMessage(message, replyHandler: nil) { _ in
                link.transferUserInfo(message)
            }
        } else {
            link.transferUserInfo(message)
        }
    }
}

/// Reads the Libre session item. It never deletes it.
enum HandyFreiKeyCopy {
    static let service = "org.loopkit.LibreLoop.sessionKeys"

    struct Keys {
        var kEnc: Data
        var ivEnc: Data
        var phase5: Data?
        var receiverID: UInt32?
    }

    static func read(serial: String) -> Keys? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: serial,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return parse(data)
    }

    static func parse(_ data: Data) -> Keys? {
        if data.count >= 45, data.first == 0x03 || data.first == 0x04 {
            let receiver = UInt32(data[41])
                | (UInt32(data[42]) << 8)
                | (UInt32(data[43]) << 16)
                | (UInt32(data[44]) << 24)
            return Keys(
                kEnc: data.subdata(in: 1 ..< 17),
                ivEnc: data.subdata(in: 17 ..< 25),
                phase5: data.subdata(in: 25 ..< 41),
                receiverID: receiver
            )
        }
        if data.count == 41, data.first == 0x02 {
            return Keys(
                kEnc: data.subdata(in: 1 ..< 17),
                ivEnc: data.subdata(in: 17 ..< 25),
                phase5: data.subdata(in: 25 ..< 41),
                receiverID: nil
            )
        }
        return nil
    }
}

final class HandyFreiBluetoothWatch: NSObject, CBCentralManagerDelegate {
    static let shared = HandyFreiBluetoothWatch()
    private var central: CBCentralManager?

    func start() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil, options: [
                CBCentralManagerOptionShowPowerAlertKey: false
            ])
        }
    }

    var isPoweredOff: Bool { central?.state == .poweredOff }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOff {
            HandyFreiPhone.bluetoothIsOff()
        }
    }
}
