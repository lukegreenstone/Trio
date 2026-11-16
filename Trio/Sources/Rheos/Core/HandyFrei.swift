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
