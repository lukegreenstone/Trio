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
        peripheralID: UUID? = nil,
        onGlucose: @escaping @Sendable (Int) -> Void,
        onDisconnect: @escaping @Sendable () -> Void = {},
        onStatus: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws {
        guard blePIN.count == 4, phase5RawKey.count == 16 else { throw HandyFreiLinkError.badKey }
        let scanner = SensorScannerNG()
        heldScanner = scanner
        // Same token as LibreLoopPairingService.scanForSensorNG: the NFC address
        // with colons removed. The sensor puts that token in the local name,
        // which is often only in the scan response.
        let expected = String(bleAddress.uppercased().filter(\.isHexDigit).suffix(12))
        guard expected.count == 12 else { throw HandyFreiLinkError.badKey }
        let events = scanner.events()
        let powerDeadline = Date().addingTimeInterval(10)
        let deadline = Date().addingTimeInterval(180)
        let progress = LibreScanProgress()
        var poweredOn = false
        var peripheral: CBPeripheral?
        var lastLine = ""
        var scanPass = 0
        var lastRestart = Date.distantPast
        var triedKnown = false
        let ticker = Task { [scanner] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                scanner.reemitState()
            }
        }
        defer { ticker.cancel() }
        func publish(searching: Bool) {
            let line = progress.line(searching: searching, expected: expected)
            guard line != lastLine else { return }
            lastLine = line
            onStatus(line)
        }
        func beginScan() {
            let services: [CBUUID]?
            switch scanPass % 3 {
            case 0:
                // Name and service UUID are often only in the scan response.
                // A service filter never sees that advertisement.
                services = nil
            case 1:
                services = [LibreSensorGATT.serviceUUID]
            default:
                services = [LibreSensorGATT.serviceUUID, LibreSensorGATT.securityServiceUUID]
            }
            scanPass += 1
            lastRestart = Date()
            scanner.stopScan()
            // Duplicates stay on so a later scan response that finally carries
            // the local name is not dropped. The iPhone scan leaves this off
            // because reconnect there uses the saved peripheral id first.
            scanner.startScan(services: services, allowDuplicates: true)
        }
        func connectIfKnown() {
            guard peripheral == nil, !triedKnown else { return }
            triedKnown = true
            // The iPhone id rarely resolves on the watch (each central mints
            // its own). retrieveConnectedPeripherals still finds a sensor the
            // watch already holds, which is the phone's first reconnect path.
            var known: [CBPeripheral] = []
            if let peripheralID {
                known = scanner.retrievePeripherals(withIdentifiers: [peripheralID])
            }
            let connected = scanner.retrieveConnectedPeripherals(serviceUUIDs: [
                LibreSensorGATT.serviceUUID,
                LibreSensorGATT.securityServiceUUID
            ])
            var pool: [CBPeripheral] = []
            for candidate in known + connected where !pool.contains(where: { $0.identifier == candidate.identifier }) {
                pool.append(candidate)
            }
            let named = pool.first {
                Self.advertisementMatches(name: $0.name, localName: nil, manufacturerHex: nil, expected: expected)
            }
            let unnamed = pool.filter { ($0.name ?? "").isEmpty }
            guard let match = named ?? (unnamed.count == 1 ? unnamed.first : nil) else { return }
            peripheral = match
            scanner.stopScan()
            scanner.requestConnect(match)
            onStatus("Sensor: bekanntes Gerät, verbinde")
        }
        for await event in events {
            if peripheral == nil {
                if !poweredOn, Date() > powerDeadline { throw HandyFreiLinkError.bluetoothOff }
                if poweredOn, Date() > deadline {
                    throw HandyFreiLinkError.sensorNotSeen(progress.line(searching: false, expected: expected))
                }
            }
            switch event {
            case let .stateChanged(state):
                switch state {
                case .poweredOn:
                    poweredOn = true
                    if peripheral == nil, Date().timeIntervalSince(lastRestart) >= 20 {
                        triedKnown = false
                        connectIfKnown()
                        if peripheral == nil {
                            beginScan()
                            publish(searching: true)
                        }
                    }
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
                guard peripheral == nil else { continue }
                let local = found.advertisementData[CBAdvertisementDataLocalNameKey]
                let named = Self.advertisementMatches(
                    name: found.name,
                    localName: local,
                    manufacturerHex: found.advertisementData["manufacturerHex"],
                    expected: expected
                )
                progress.note(
                    id: found.id,
                    name: local ?? found.name,
                    libre: found.advertisedServices.contains(where: {
                        $0.uuidString.caseInsensitiveCompare(LibreSensorGATT.serviceUUID.uuidString) == .orderedSame
                    })
                )
                let unnamedLibre = progress.libreCount == 1
                    && progress.saw(found.id)
                    && (local ?? found.name)?.isEmpty != false
                    && Date().timeIntervalSince(progress.started) >= 45
                if named || unnamedLibre {
                    peripheral = found.peripheral
                    scanner.stopScan()
                    scanner.requestConnect(found.peripheral)
                    onStatus(named ? "Sensor: gefunden, verbinde" : "Sensor: ein Libre-Gerät, verbinde")
                } else {
                    publish(searching: true)
                }
            case let .didConnect(found) where found.identifier == peripheral?.identifier:
                ticker.cancel()
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
                        // Same rule as the iPhone: a "not actionable" flag still
                        // carries a glucose number. Only a real sensor fault is dropped.
                        guard !sample.hasBlockingIssue else {
                            onStatus("Sensor: Wert blockiert. \(sample.qualityIssue ?? "Fehler")")
                            return
                        }
                        let mgdl = Int(sample.valueMgDL.rounded())
                        onStatus("Sensor: \(mgdl) mg/dL")
                        onGlucose(mgdl)
                    },
                    onDisconnect: onDisconnect,
                    onStatus: onStatus
                )
                onStatus("Sensor: verbunden, warte auf Werte")
                monitor.start()
                heldMonitor = monitor
                return
            case let .didFailToConnect(found, _) where found.identifier == peripheral?.identifier:
                // The sensor can still be held by the iPhone for a while after
                // that radio goes off. Keep scanning until the deadline.
                peripheral = nil
                triedKnown = false
                lastRestart = .distantPast
                onStatus("Sensor: Verbindung abgelehnt, suche weiter")
            default:
                break
            }
        }
        throw HandyFreiLinkError.sensorNotSeen(progress.line(searching: false, expected: expected))
    }

    /// Libre 3 identity, same fields the iPhone scan compares: advertised local
    /// name, `peripheral.name`, then manufacturer data. Comparison is the
    /// 12 hex digits of the BLE address, ignoring case and separators.
    static func advertisementMatches(name: String?, localName: String?, manufacturerHex: String?, expected: String) -> Bool {
        for raw in [localName, name].compactMap({ $0 }) {
            let token = raw.uppercased().filter(\.isHexDigit)
            if token == expected || token.contains(expected) { return true }
        }
        if let manufacturerHex, manufacturerHex.uppercased().contains(expected) { return true }
        return false
    }
}

private final class LibreScanProgress: @unchecked Sendable {
    struct Seen {
        var name: String?
        var libre: Bool
    }

    let started = Date()
    private var devices: [UUID: Seen] = [:]
    private(set) var packets = 0

    var deviceCount: Int { devices.count }
    var libreCount: Int { devices.values.filter(\.libre).count }

    func saw(_ id: UUID) -> Bool {
        devices[id]?.libre == true
    }

    func note(id: UUID, name: String?, libre: Bool) {
        packets += 1
        var seen = devices[id] ?? Seen(name: nil, libre: false)
        if let name, !name.isEmpty, seen.name == nil {
            seen.name = name
        }
        if libre { seen.libre = true }
        devices[id] = seen
    }

    func line(searching: Bool, expected: String) -> String {
        let head = searching ? "Sensor: suche" : "Sensor: nicht gefunden"
        var text = "\(head) (\(devices.count) Geräte gesehen"
        if packets != devices.count {
            text += ", \(packets) Pakete"
        }
        text += ")"
        let tail = String(expected.suffix(4))
        let ranked = devices.values.compactMap(\.name).sorted { lhs, rhs in
            lhs.uppercased().hasSuffix(tail) && !rhs.uppercased().hasSuffix(tail)
        }
        let masked = ranked.prefix(3).map { raw -> String in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 4 else { return "····" }
            return "…" + String(trimmed.suffix(4))
        }
        if !masked.isEmpty {
            text += ", ähnlich \(masked.joined(separator: ", "))"
        }
        let libres = libreCount
        if libres > 0 {
            text += ", Libre-Dienst \(libres)"
        }
        return text
    }
}

public enum HandyFreiLinkError: LocalizedError {
    case badKey
    case bluetoothOff
    case bluetoothDenied
    case bluetoothUnsupported
    case notFound
    case sensorNotSeen(String)
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
        case let .sensorNotSeen(detail):
            return detail
        case let .pumpRefused(detail):
            return detail.isEmpty ? "Anmeldung abgelehnt" : detail
        case let .handshake(detail):
            return detail.isEmpty ? "Handshake" : detail
        }
    }
}
