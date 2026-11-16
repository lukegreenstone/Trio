import CoreBluetooth
import Foundation
import RoundWhiteDiscWatch
import Security

/// Cached Libre reconnect from LibreLoopPairingService, without NFC and without the first-pair path.
public enum HandyFreiLibreLink {
    private static var heldScanner: SensorScannerNG?
    private static var heldMonitor: LibreLoopSensorMonitor?

    public static func stop() {
        heldMonitor = nil
        heldScanner = nil
    }

    public static func reconnect(
        bleAddress: String,
        blePIN: Data,
        phase5RawKey: Data,
        onGlucose: @escaping @Sendable (Int) -> Void,
        onDisconnect: @escaping @Sendable () -> Void = {}
    ) async throws {
        guard blePIN.count == 4, phase5RawKey.count == 16 else { throw HandyFreiLinkError.badKey }
        let scanner = SensorScannerNG()
        heldScanner = scanner
        let expected = bleAddress.replacingOccurrences(of: ":", with: "").uppercased()
        let events = scanner.events()
        let deadline = Date().addingTimeInterval(120)
        var peripheral: CBPeripheral?
        for await event in events {
            if Date() > deadline { throw HandyFreiLinkError.notFound }
            switch event {
            case let .stateChanged(state):
                if state == .poweredOn { scanner.startScan() }
                if state == .poweredOff || state == .unauthorized { throw HandyFreiLinkError.bluetoothOff }
            case let .didDiscover(found):
                let name = found.advertisementData[CBAdvertisementDataLocalNameKey] ?? found.name
                if name?.uppercased() == expected {
                    peripheral = found.peripheral
                    scanner.stopScan()
                    scanner.requestConnect(found.peripheral)
                }
            case let .didConnect(found) where found.identifier == peripheral?.identifier:
                let session = SensorSession(peripheral: found, queue: scanner.centralQueue)
                try await session.discoverAndSubscribe()
                let transport = SensorSessionTransport(session: session)
                let flow = PairingFlow(transport: transport, eventLogger: { _ in })
                let cached = try await flow.runCachedReconnectHandshake(
                    tail4: blePIN,
                    phase5RawKey: phase5RawKey,
                    r2Provider: {
                        var bytes = [UInt8](repeating: 0, count: 16)
                        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                            throw HandyFreiLinkError.badKey
                        }
                        return Data(bytes)
                    }
                )
                let material = cached.sessionMaterial
                let monitor = try LibreLoopSensorMonitor.make(
                    scanner: scanner,
                    session: session,
                    kEnc: material.kEnc,
                    ivEnc: material.ivEnc
                )
                monitor.setHandlers(
            onReading: { sample in
                guard sample.isActionable, !sample.hasBlockingIssue else { return }
                onGlucose(Int(sample.valueMgDL.rounded()))
            },
            onDisconnect: onDisconnect
        )
                monitor.start()
                heldMonitor = monitor
                return
            case let .didFailToConnect(found, _) where found.identifier == peripheral?.identifier:
                throw HandyFreiLinkError.notFound
            default:
                break
            }
        }
        throw HandyFreiLinkError.notFound
    }
}

public enum HandyFreiLinkError: Error {
    case badKey
    case bluetoothOff
    case notFound
    case pumpRefused
}
