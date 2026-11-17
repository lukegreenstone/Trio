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
        let powerDeadline = Date().addingTimeInterval(10)
        let deadline = Date().addingTimeInterval(120)
        var poweredOn = false
        var peripheral: CBPeripheral?
        for await event in events {
            if !poweredOn, Date() > powerDeadline { throw HandyFreiLinkError.bluetoothOff }
            if poweredOn, Date() > deadline { throw HandyFreiLinkError.notFound }
            switch event {
            case let .stateChanged(state):
                switch state {
                case .poweredOn:
                    poweredOn = true
                    scanner.startScan()
                case .poweredOff:
                    throw HandyFreiLinkError.bluetoothOff
                case .unauthorized:
                    throw HandyFreiLinkError.bluetoothDenied
                case .unsupported:
                    throw HandyFreiLinkError.bluetoothUnsupported
                default:
                    break
                }
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
                let cached: CachedReconnectHandshakeResult
                do {
                    cached = try await flow.runCachedReconnectHandshake(
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
                } catch let error as HandyFreiLinkError {
                    throw error
                } catch {
                    throw HandyFreiLinkError.handshake(error.localizedDescription)
                }
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

public enum HandyFreiLinkError: LocalizedError {
    case badKey
    case bluetoothOff
    case bluetoothDenied
    case bluetoothUnsupported
    case notFound
    case pumpRefused(String)
    case handshake(String)

    public var errorDescription: String? {
        switch self {
        case .badKey:
            return "Schlüssel unvollständig"
        case .bluetoothOff:
            return "Bluetooth aus"
        case .bluetoothDenied:
            return "Bluetooth nicht erlaubt"
        case .bluetoothUnsupported:
            return "Bluetooth nicht unterstützt"
        case .notFound:
            return "nicht gefunden"
        case let .pumpRefused(detail):
            return detail.isEmpty ? "Anmeldung abgelehnt" : detail
        case let .handshake(detail):
            return detail.isEmpty ? "Handshake" : detail
        }
    }
}
