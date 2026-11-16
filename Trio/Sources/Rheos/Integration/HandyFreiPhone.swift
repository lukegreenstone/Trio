import Foundation
import WatchConnectivity

/// Starts and stops Handy-frei on the iPhone.
/// It never deletes pairing keys and never calls a patch or sensor deactivate.
enum HandyFreiPhone {
    private static let statusKey = "handyfrei.status"
    private static let lock = NSLock()
    private static var pending: HandyFrei.Session?
    private static var limits = HandyFrei.Limits(maxBolus: 0, maxIOB: 0, currentIOB: 0)
    private static var glucose: Double?

    static var status: String {
        UserDefaults.standard.string(forKey: statusKey) ?? "Handy-frei ist aus."
    }

    /// This driver set cannot drop the live link without clearing the stored peripheral id.
    static func canReleaseRadioWithoutDeletingKeys() -> Bool {
        false
    }

    @discardableResult
    static func start(fingerprint: HandyFrei.Fingerprint, limits: HandyFrei.Limits, glucose: Double?) -> HandyFrei.Session {
        let session = HandyFrei.offer(enabled: HandyFrei.isEnabled(), fingerprint: fingerprint)
        lock.lock()
        pending = session
        self.limits = limits
        self.glucose = glucose
        lock.unlock()
        HandyFreiGate.setPhoneLoopPaused(false)
        store(session)
        if session.step == .offered {
            send(session, kind: "offer")
        }
        return session
    }

    /// Watch ack. The phone still refuses to release the radio when that would delete keys.
    @discardableResult
    static func receiveAck() -> HandyFrei.Session {
        lock.lock()
        let current = pending ?? HandyFrei.idle(fingerprint: HandyFrei.Fingerprint(
            pumpPeripheralID: nil, pumpSerial: nil, sensorSerial: nil, sensorPeripheralID: nil
        ))
        let limits = self.limits
        let glucose = self.glucose
        lock.unlock()
        var session = HandyFrei.watchAck(current)
        if session.step == .watchAcked {
            session = HandyFrei.releaseRadio(session, canRelease: canReleaseRadioWithoutDeletingKeys())
        }
        HandyFreiGate.setPhoneLoopPaused(session.phoneLoopPaused)
        lock.lock()
        pending = session
        lock.unlock()
        store(session)
        send(session, kind: "result", limits: limits, glucose: glucose)
        return session
    }

    @discardableResult
    static func stop(fingerprint: HandyFrei.Fingerprint) -> HandyFrei.Session {
        let (session, _) = HandyFrei.stop(HandyFrei.idle(fingerprint: fingerprint))
        HandyFreiGate.setPhoneLoopPaused(false)
        lock.lock()
        pending = session
        lock.unlock()
        store(session)
        send(session, kind: "stopped")
        return session
    }

    private static func store(_ session: HandyFrei.Session) {
        UserDefaults.standard.set(session.note, forKey: statusKey)
    }

    private static func send(
        _ session: HandyFrei.Session,
        kind: String,
        limits: HandyFrei.Limits? = nil,
        glucose: Double? = nil
    ) {
        guard WCSession.isSupported() else { return }
        let link = WCSession.default
        guard link.activationState == .activated, link.isReachable else { return }
        var payload: [String: Any] = [
            "kind": kind,
            "note": session.note,
            "ownsRadio": session.watchOwnsRadio
        ]
        if let limits {
            payload["shadow"] = HandyFrei.shadowLine(glucose: glucose, iob: limits.currentIOB)
        }
        link.sendMessage(["handyFrei": payload], replyHandler: nil) { _ in }
    }
}
