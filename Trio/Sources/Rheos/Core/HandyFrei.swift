import Foundation

/// Phone-free stretch. The watch may only issue the commands in `WatchCommand`.
/// Pairing keys and peripheral ids stay on the iPhone. This type never talks to a pump or a sensor.
enum HandyFrei {
    static let enabledKey = "handyfrei.experimental"

    /// Missing key means off.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? false
    }

    static func setEnabled(_ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: enabledKey)
        // Older builds stored a second pump switch. Dosing is part of Handy-frei now.
        defaults.removeObject(forKey: "handyfrei.phase2")
    }

    /// Commands the watch is allowed to ask for. There is no case for deactivate, prime,
    /// unpair, reset, expire, or a new Libre activation.
    enum WatchCommand: Equatable {
        case readStatus
        case readGlucose
        case readHistory
        case setTempBasal(unitsPerHour: Double, minutes: Int)
        case cancelTempBasal
        case bolus(units: Double)
    }

    enum Enact: Equatable {
        case accepted(WatchCommand)
        case refused(String)
    }

    struct Fingerprint: Equatable {
        var pumpPeripheralID: String?
        var pumpSerial: String?
        var sensorSerial: String?
        var sensorPeripheralID: String?
    }

    struct Limits: Equatable {
        var maxBolus: Double
        var maxIOB: Double
        var currentIOB: Double
    }

    /// A copy for the watch. The iPhone keychain is not written.
    struct Snapshot: Equatable {
        var pumpSerial: String?
        var sessionToken: String?
        var backupSessionToken: String?
        var patchId: String?
        var patchActivatedAt: Date?
        var patchExpiresAt: Date?
        var blePIN: String?
        var phase5RawKey: String?
        var kEnc: String?
        var ivEnc: String?
        var receiverID: String?
        var sensorSerial: String?
        var bleAddress: String?
        var iob: Double
        var cob: Double
        var maxBolus: Double
        var maxIOB: Double
        var rheosBasal: [Double]
        var rheosISF: [Double]
        var rheosCarbRatio: [Double]
        var loopFiles: [String: String]
        var glucose: Double?
        /// Set when a required Libre key is missing. Handy-frei must not start.
        var refusal: String? = nil

        var plist: [String: Any] {
            var raw: [String: Any] = [
                "iob": iob,
                "cob": cob,
                "maxBolus": maxBolus,
                "maxIOB": maxIOB,
                "rheosBasal": rheosBasal,
                "rheosISF": rheosISF,
                "rheosCarbRatio": rheosCarbRatio,
                "loopFiles": loopFiles
            ]
            if let pumpSerial { raw["pumpSerial"] = pumpSerial }
            if let sessionToken { raw["sessionToken"] = sessionToken }
            if let backupSessionToken { raw["backupSessionToken"] = backupSessionToken }
            if let patchId { raw["patchId"] = patchId }
            if let patchActivatedAt { raw["patchActivatedAt"] = patchActivatedAt.timeIntervalSince1970 }
            if let patchExpiresAt { raw["patchExpiresAt"] = patchExpiresAt.timeIntervalSince1970 }
            if let blePIN { raw["blePIN"] = blePIN }
            if let phase5RawKey { raw["phase5RawKey"] = phase5RawKey }
            if let kEnc { raw["kEnc"] = kEnc }
            if let ivEnc { raw["ivEnc"] = ivEnc }
            if let receiverID { raw["receiverID"] = receiverID }
            if let bleAddress { raw["bleAddress"] = bleAddress }
            if let sensorSerial { raw["sensorSerial"] = sensorSerial }
            if let glucose { raw["glucose"] = glucose }
            return raw
        }
    }

    enum Step: Equatable {
        case idle
        case offered
        case watchAcked
        case watchOwning
        case failed(String)
    }

    struct Session: Equatable {
        var step: Step
        var enabled: Bool
        var phoneOwnsRadio: Bool
        var watchOwnsRadio: Bool
        var phoneLoopPaused: Bool
        var watchSetTempBasal: Bool
        var keysDeleted: Bool
        var fingerprint: Fingerprint
        var watchCopy: Fingerprint?
        var note: String
    }

    static func idle(fingerprint: Fingerprint) -> Session {
        Session(
            step: .idle,
            enabled: false,
            phoneOwnsRadio: true,
            watchOwnsRadio: false,
            phoneLoopPaused: false,
            watchSetTempBasal: false,
            keysDeleted: false,
            fingerprint: fingerprint,
            watchCopy: nil,
            note: "Handy-frei ist aus."
        )
    }

    /// Copies the fingerprint. Does not clear the phone's copy.
    static func offer(enabled: Bool, fingerprint: Fingerprint) -> Session {
        guard enabled else {
            var session = idle(fingerprint: fingerprint)
            session.step = .failed("Handy-frei (experimentell) ist aus.")
            session.note = "Handy-frei (experimentell) ist aus."
            return session
        }
        return Session(
            step: .offered,
            enabled: true,
            phoneOwnsRadio: true,
            watchOwnsRadio: false,
            phoneLoopPaused: false,
            watchSetTempBasal: false,
            keysDeleted: false,
            fingerprint: fingerprint,
            watchCopy: fingerprint,
            note: "Angebot. Das iPhone hält die Verbindung noch."
        )
    }

    static func watchAck(_ session: Session) -> Session {
        guard session.step == .offered, session.phoneOwnsRadio, !session.watchOwnsRadio else {
            var failed = session
            failed.step = .failed("Die Uhr darf nicht quittieren, solange das Angebot nicht offen ist.")
            failed.note = "Keine Quittung."
            return failed
        }
        var next = session
        next.step = .watchAcked
        next.note = "Uhr ist bereit. Das iPhone hat noch nicht gelöst."
        return next
    }

    /// `canRelease` is true only when the link can be dropped without deleting keys or peripheral ids.
    static func releaseRadio(_ session: Session, canRelease: Bool) -> Session {
        guard session.step == .watchAcked else {
            var failed = session
            failed.step = .failed("Lösen nur nach der Quittung der Uhr.")
            failed.phoneOwnsRadio = true
            failed.watchOwnsRadio = false
            failed.phoneLoopPaused = false
            failed.note = "Nicht gelöst."
            return failed
        }
        guard canRelease else {
            var failed = session
            failed.step = .failed("Die Verbindung lässt sich nicht lösen, ohne die Kopplung zu löschen. Handy-frei startet nicht.")
            failed.phoneOwnsRadio = true
            failed.watchOwnsRadio = false
            failed.phoneLoopPaused = false
            failed.keysDeleted = false
            failed.note = "Die Verbindung lässt sich nicht lösen, ohne die Kopplung zu löschen. Handy-frei startet nicht."
            return failed
        }
        var next = session
        next.step = .watchOwning
        next.phoneOwnsRadio = false
        next.watchOwnsRadio = true
        next.phoneLoopPaused = true
        next.keysDeleted = false
        next.note = "Die Uhr hat die Verbindung. Das iPhone loopt nicht."
        return next
    }

    static func enact(_ command: WatchCommand, session: Session, limits: Limits) -> (Session, Enact) {
        guard session.watchOwnsRadio, !session.phoneOwnsRadio, session.step == .watchOwning else {
            return (session, .refused("Die Uhr sendet nichts, solange das iPhone die Geräte hält."))
        }
        switch command {
        case .readStatus, .readGlucose, .readHistory:
            return (session, .accepted(command))
        case .cancelTempBasal:
            var next = session
            next.watchSetTempBasal = false
            return (next, .accepted(command))
        case let .setTempBasal(rate, minutes):
            guard rate >= 0, minutes > 0, minutes <= 30 else {
                return (session, .refused("Temporäres Basal nur mit Rate ab 0 und höchstens 30 Minuten."))
            }
            var next = session
            next.watchSetTempBasal = true
            return (next, .accepted(command))
        case let .bolus(units):
            guard units > 0, units <= limits.maxBolus, limits.currentIOB + units <= limits.maxIOB + 0.000_1 else {
                return (session, .refused("Bolus bleibt in den bestehenden Grenzen Max Bolus und Max IOB."))
            }
            return (session, .accepted(command))
        }
    }

    /// Failure path. If the watch set a temp basal, the only pump command left is to cancel it.
    static func fail(_ session: Session, reason: String) -> (Session, WatchCommand?) {
        let cancel: WatchCommand? = session.watchSetTempBasal ? .cancelTempBasal : nil
        var next = session
        next.watchSetTempBasal = false
        next.watchOwnsRadio = false
        next.phoneOwnsRadio = true
        next.phoneLoopPaused = false
        next.keysDeleted = false
        next.step = .failed(reason)
        next.note = reason
        return (next, cancel)
    }

    static func stop(_ session: Session) -> (Session, WatchCommand?) {
        fail(session, reason: "Handy-frei beendet. Das iPhone verbindet sich mit der bestehenden Kopplung.")
    }

    /// Luke turns iPhone Bluetooth off himself. Drivers are not asked to disconnect.
    static func prepare(enabled: Bool, fingerprint: Fingerprint) -> Session {
        var session = offer(enabled: enabled, fingerprint: fingerprint)
        guard session.step == .offered else { return session }
        session.note = "Jetzt in den Einstellungen Bluetooth am iPhone ausschalten. Die Uhr startet dann von allein, sonst einmal auf der Uhr tippen. Die Kopplung bleibt gespeichert."
        return session
    }

    /// Only after Bluetooth is really off. Keys stay. The phone loop pauses.
    static func bluetoothIsOff(_ session: Session) -> Session {
        guard session.step == .offered || session.step == .watchAcked else {
            var failed = session
            failed.phoneLoopPaused = false
            failed.watchOwnsRadio = false
            failed.phoneOwnsRadio = true
            failed.note = "Bluetooth-Aus gilt nur nach der Vorbereitung."
            return failed
        }
        var next = session
        next.step = .watchOwning
        next.phoneOwnsRadio = false
        next.watchOwnsRadio = true
        next.phoneLoopPaused = true
        next.keysDeleted = false
        next.note = "Bluetooth am iPhone ist aus. Die Uhr ist die Steuerung. Das iPhone loopt nicht."
        return next
    }

    /// The loop stays paused until the watch log is stored.
    static func resumeAfterLog(_ session: Session, logImported: Bool) -> Session {
        guard logImported else {
            var waiting = session
            waiting.phoneLoopPaused = true
            waiting.phoneOwnsRadio = false
            waiting.watchOwnsRadio = false
            waiting.keysDeleted = false
            waiting.note = "Protokoll fehlt noch. Der Loop bleibt aus, die Kopplung bleibt."
            return waiting
        }
        var next = session
        next.step = .idle
        next.phoneOwnsRadio = true
        next.watchOwnsRadio = false
        next.phoneLoopPaused = false
        next.watchSetTempBasal = false
        next.keysDeleted = false
        next.note = "Protokoll ist da. Bluetooth am iPhone wieder einschalten, dann loopt das iPhone mit der alten Kopplung."
        return next
    }

    /// Request body for a temp basal, same layout as Medtrum SetTempBasalPacket. Not a stop or prime.
    static func tempBasalBody(rate: Double, minutes: Int) -> Data {
        var body = Data([6])
        let units = UInt16(max(0, Int((rate / 0.05).rounded())))
        let length = UInt16(max(0, minutes))
        body.append(UInt8(units & 0xFF))
        body.append(UInt8((units >> 8) & 0xFF))
        body.append(UInt8(length & 0xFF))
        body.append(UInt8((length >> 8) & 0xFF))
        return body
    }

    static func commandCode(_ command: WatchCommand) -> UInt8? {
        switch command {
        case .readStatus: return 11
        case .readGlucose: return nil
        case .readHistory: return 99
        case .setTempBasal: return 24
        case .cancelTempBasal: return 25
        case .bolus: return 19
        }
    }

    static let forbiddenCommandCodes: [UInt8] = [16, 18, 21, 28, 29, 31, 35, 36]

    static func shadowLine(glucose: Double?, iob: Double) -> String {
        guard let glucose else {
            return "Schatten. Keine Glukose in der Kopie. Kein Befehl."
        }
        return "Schatten. Glukose \(Int(glucose)) mg/dL, IOB \(format(iob)) E. Kein Befehl an Pumpe oder Sensor."
    }

    static func command(named name: String) -> WatchCommand? {
        switch name {
        case "readStatus": return .readStatus
        case "readGlucose": return .readGlucose
        case "readHistory": return .readHistory
        case "cancelTempBasal": return .cancelTempBasal
        default: return nil
        }
    }

    /// Names that must never become a watch command.
    static let forbiddenNames = [
        "deactivate", "deactivatePatch", "unpair", "prime", "primePatch",
        "reset", "expire", "stopSensor", "nfc", "activate", "reactivate"
    ]

    static func roundTripHolds(_ before: Fingerprint, _ after: Session) -> Bool {
        after.fingerprint == before && after.keysDeleted == false && !(after.phoneOwnsRadio && after.watchOwnsRadio)
    }

    static func checklist(before: Fingerprint, after: Session) -> [String] {
        [
            after.fingerprint == before ? "iPhone-Kennung unverändert" : "iPhone-Kennung hat sich geändert",
            after.keysDeleted ? "Schlüssel wurden gelöscht" : "Schlüssel bleiben auf dem iPhone",
            (after.phoneOwnsRadio && after.watchOwnsRadio) ? "beide verbunden" : "nie beide verbunden",
            after.watchCopy == nil || after.watchCopy == before ? "Uhr hat nur eine Kopie" : "Kopie weicht ab"
        ]
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value).replacingOccurrences(of: ".", with: ",")
    }
}

/// Phone loop pause. The watch process has its own copy and never pauses the phone.
enum HandyFreiGate {
    private static let lock = NSLock()
    private static var paused = false

    static var phoneLoopPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return paused
    }

    static func setPhoneLoopPaused(_ value: Bool) {
        lock.lock()
        paused = value
        lock.unlock()
    }
}
