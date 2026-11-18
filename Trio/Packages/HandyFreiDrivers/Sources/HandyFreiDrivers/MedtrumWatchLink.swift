import CoreBluetooth
import Foundation

/// Medtrum reconnect using the same AuthorizePacket and command bytes as MedtrumKit.
/// Only the six Handy-frei commands can be built. Prime, activate, stop and suspend packets are not in this target.
public final class HandyFreiMedtrumLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    public static let shared = HandyFreiMedtrumLink()

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var sequence: UInt8 = 0
    private var pumpSN = Data()
    /// Advertisement serial is the stored serial reversed, same as MedtrumKit BluetoothManager.
    private var advertisedSN = Data()
    private var sessionToken = Data()
    private var backupToken = Data()
    private var lastPower: CBManagerState = .unknown
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var writeWaiter: CheckedContinuation<Void, Error>?
    private var pendingPacket: (any MedtrumBasePacketProtocol)?
    private var pendingSequence: UInt8 = 0
    private var writeGeneration = 0
    private var ready = false
    private var stopping = false
    /// Last synchronize/heartbeat. Dosing follows MedtrumPumpManager: no temp or bolus
    /// unless the patch is active, and an existing temp is cancelled before a new one.
    private var patchState: PatchState = .none
    private var basalIsTemp = false
    private var basalKnown = false
    private let queue = DispatchQueue(label: "handyfrei.medtrum")
    /// Fired once when the pump link drops on its own. Not fired when `stop()` closes it.
    public var onConnectionLost: (@Sendable () -> Void)?

    public func stop() {
        stopping = true
        if let peripheral, let central {
            central.cancelPeripheralConnection(peripheral)
        }
        central = nil
        peripheral = nil
        writeCharacteristic = nil
        ready = false
    }

    public func connect(pumpSerialBase64: String, sessionTokenBase64: String, backupTokenBase64: String = "") async throws {
        guard let serial = Data(base64Encoded: pumpSerialBase64), !serial.isEmpty,
              let token = Data(base64Encoded: sessionTokenBase64), !token.isEmpty
        else { throw HandyFreiLinkError.badKey }
        stopping = false
        ready = false
        lastPower = .unknown
        sequence = 0
        patchState = .none
        basalIsTemp = false
        basalKnown = false
        pumpSN = serial
        advertisedSN = Data(serial.reversed())
        sessionToken = token
        backupToken = Data(base64Encoded: backupTokenBase64) ?? Data()
        central = CBCentralManager(delegate: self, queue: queue)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.connectWaiter = continuation
                self.failPowerIfTerminal()
            }
            queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.failPowerIfStillWaiting()
            }
            queue.asyncAfter(deadline: .now() + 180) { [weak self] in
                self?.finishConnect(.failure(HandyFreiLinkError.notFound))
            }
        }
    }

    private func failPowerIfTerminal() {
        switch lastPower {
        case .poweredOff:
            finishConnect(.failure(HandyFreiLinkError.bluetoothOff))
        case .unauthorized:
            finishConnect(.failure(HandyFreiLinkError.bluetoothDenied))
        case .unsupported:
            finishConnect(.failure(HandyFreiLinkError.bluetoothUnsupported))
        case .poweredOn:
            central?.scanForPeripherals(withServices: nil)
        default:
            break
        }
    }

    private func failPowerIfStillWaiting() {
        queue.async {
            guard self.connectWaiter != nil, self.peripheral == nil, self.lastPower != .poweredOn else { return }
            switch self.lastPower {
            case .unauthorized:
                self.finishConnect(.failure(HandyFreiLinkError.bluetoothDenied))
            case .unsupported:
                self.finishConnect(.failure(HandyFreiLinkError.bluetoothUnsupported))
            default:
                self.finishConnect(.failure(HandyFreiLinkError.bluetoothOff))
            }
        }
    }

    /// Sends one allowlisted command. Refuses every other command code.
    public func send(_ command: HandyFreiMedtrumCommand) async throws {
        let packet: any MedtrumBasePacketProtocol
        switch command {
        case .readStatus:
            packet = GetTimePacket()
        case .readHistory:
            packet = SynchronizePacket()
        case .cancelTempBasal:
            packet = CancelTempBasalPacket()
        case let .setTempBasal(rate, minutes):
            packet = SetTempBasalPacket(rate: rate, duration: TimeInterval(minutes * 60))
        case let .bolus(units):
            packet = SetBolusPacket(bolusAmount: units)
        }
        let code = packet.commandType
        guard !HandyFreiMedtrumCommand.forbidden.contains(code) else {
            throw HandyFreiLinkError.pumpRefused("Befehl nicht erlaubt")
        }
        _ = try await write(packet)
    }

    /// Same order as `MedtrumPumpManager.enactTempBasal`. A temp that is already
    /// running must be cancelled before a new one. A suspended or unfinished
    /// patch is not resumed, primed, or activated.
    public func enactTemp(rate: Double, minutes: Int) async throws {
        let state = await pumpSnapshot()
        if let block = Self.dosingBlock(state.patch) {
            throw HandyFreiLinkError.pumpRefused("Tempbasal nicht gesendet. \(block)")
        }
        let cancelFirst = state.temp || !state.known
        if rate <= 0 || minutes <= 0 {
            guard cancelFirst else { return }
            try await send(.cancelTempBasal)
            return
        }
        if cancelFirst {
            do {
                try await send(.cancelTempBasal)
            } catch {
                throw HandyFreiLinkError.pumpRefused("cancelTempBasal gesendet. \(error.localizedDescription)")
            }
        }
        do {
            try await send(.setTempBasal(rate: rate, minutes: minutes))
        } catch {
            let prefix = cancelFirst ? "cancelTempBasal ausgeführt. " : ""
            throw HandyFreiLinkError.pumpRefused("\(prefix)setTempBasal gesendet. \(error.localizedDescription)")
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central else { return }
        lastPower = central.state
        switch central.state {
        case .poweredOn:
            central.scanForPeripherals(withServices: nil)
        case .poweredOff:
            finishConnect(.failure(HandyFreiLinkError.bluetoothOff))
        case .unauthorized:
            finishConnect(.failure(HandyFreiLinkError.bluetoothDenied))
        case .unsupported:
            finishConnect(.failure(HandyFreiLinkError.bluetoothUnsupported))
        default:
            break
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: NSNumber
    ) {
        guard central === self.central else { return }
        guard let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String, !name.isEmpty, name == "MT",
              let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              manufacturer.count >= 7,
              manufacturer.subdata(in: 2 ..< 6) == advertisedSN
        else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === self.central else { return }
        peripheral.discoverServices([CBUUID.SERVICE_UUID])
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == CBUUID.SERVICE_UUID }) else {
            fail(HandyFreiLinkError.notFound)
            return
        }
        peripheral.discoverCharacteristics([CBUUID.READ_UUID, CBUUID.WRITE_UUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil,
              let write = service.characteristics?.first(where: { $0.uuid == CBUUID.WRITE_UUID }),
              let read = service.characteristics?.first(where: { $0.uuid == CBUUID.READ_UUID })
        else {
            fail(HandyFreiLinkError.notFound)
            return
        }
        writeCharacteristic = write
        for characteristic in service.characteristics ?? [] {
            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        _ = read
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.authorize()
                try await self.write(SynchronizePacket())
                try await self.write(SubscribePacket())
                self.ready = true
                self.finishConnect(.success(()))
            } catch {
                self.finishConnect(.failure(error))
            }
        }
    }

    /// Same reply path as MedtrumKit PeripheralManager: sequence is byte 2, fragments use decode().
    public func peripheral(_: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if error != nil {
            finishWrite(.failure(HandyFreiLinkError.pumpRefused(error?.localizedDescription ?? "Notify")))
            return
        }
        guard let data = characteristic.value, !data.isEmpty else { return }
        if characteristic.uuid == CBUUID.READ_UUID {
            let note = NotificationPacket()
            note.totalData = data
            guard note.hasEnoughData else { return }
            remember(note.parseResponse())
            return
        }
        guard data.count > 2, data[2] == pendingSequence, var packet = pendingPacket else { return }
        packet.decode(data)
        pendingPacket = packet
        guard packet.isComplete else { return }
        let name = Self.commandName(packet.commandType)
        if packet.responseCode == 16384 {
            // Not the command response. Drop it, or the next frame is parsed as a fragment.
            if let base = packet as? MedtrumBasePacket {
                base.totalData = Data()
                base.dataSize = 0
                base.responseCode = 0
                base.failed = false
            }
            pendingPacket = packet
            return
        }
        if packet.responseCode != 0 {
            finishWrite(.failure(HandyFreiLinkError.pumpRefused("\(name) gesendet. Code \(packet.responseCode)")))
        } else if packet.failed || !packet.hasEnoughData {
            finishWrite(.failure(HandyFreiLinkError.pumpRefused("\(name) gesendet. Antwort ungültig")))
        } else {
            if let sync = packet as? SynchronizePacket {
                remember(sync.parseResponse())
            }
            if packet.commandType == CommandType.CANCEL_TEMP_BASAL {
                basalIsTemp = false
                basalKnown = true
            } else if packet.commandType == CommandType.SET_TEMP_BASAL {
                basalIsTemp = true
                basalKnown = true
            }
            finishWrite(.success(()))
        }
    }

    private func authorize() async throws {
        do {
            try await write(AuthorizePacket(pumpSN: pumpSN, sessionToken: sessionToken))
        } catch {
            guard !backupToken.isEmpty else { throw error }
            try await write(AuthorizePacket(pumpSN: pumpSN, sessionToken: backupToken))
        }
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral _: CBPeripheral, error _: Error?) {
        guard central === self.central, !stopping else { return }
        fail(HandyFreiLinkError.notFound)
        if ready { onConnectionLost?() }
    }

    private func write(_ packet: any MedtrumBasePacketProtocol) async throws {
        guard let peripheral, let writeCharacteristic else { throw HandyFreiLinkError.notFound }
        let name = Self.commandName(packet.commandType)
        if packet.commandType == CommandType.SET_TEMP_BASAL
            || packet.commandType == CommandType.CANCEL_TEMP_BASAL
            || packet.commandType == CommandType.SET_BOLUS
        {
            let state = await pumpSnapshot()
            if let block = Self.dosingBlock(state.patch) {
                throw HandyFreiLinkError.pumpRefused("\(name) nicht gesendet. \(block)")
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if self.writeWaiter != nil {
                    continuation.resume(throwing: HandyFreiLinkError.pumpRefused("\(name) nicht gesendet. Befehl läuft schon"))
                    return
                }
                let seq = self.sequence
                self.sequence = seq >= 253 ? 0 : seq &+ 1
                let packages = packet.encode(sequenceNumber: seq)
                self.writeGeneration += 1
                let generation = self.writeGeneration
                self.pendingSequence = seq
                self.pendingPacket = packet
                self.writeWaiter = continuation
                for package in packages {
                    peripheral.writeValue(package, for: writeCharacteristic, type: .withResponse)
                }
                self.queue.asyncAfter(deadline: .now() + 60) {
                    self.finishWrite(
                        .failure(HandyFreiLinkError.pumpRefused("\(name) gesendet. Zeitüberschreitung")),
                        generation: generation
                    )
                }
            }
        }
    }

    /// Releases a command that never answered, so the next loop is not stuck behind it.
    public func cancelPendingWrite() {
        queue.async {
            self.finishWrite(.failure(HandyFreiLinkError.pumpRefused("Zeitüberschreitung")))
        }
    }

    private func pumpSnapshot() async -> (patch: PatchState, temp: Bool, known: Bool) {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: (self.patchState, self.basalIsTemp, self.basalKnown))
            }
        }
    }

    /// Latest reservoir and completed bolus from the pump's synchronize reply.
    public private(set) var lastReservoirUnits: Double?
    public private(set) var lastBolusUnits: Double?
    /// Occlusion, empty reservoir, empty battery, or any other halted patch state.
    public private(set) var lastPatchAlarm: String?

    private func remember(_ response: SynchronizePacketResponse) {
        patchState = response.state
        var notes: [String] = []
        if let block = Self.dosingBlock(response.state) { notes.append(block) }
        if !response.activeAlarms.isEmpty {
            notes.append(response.activeAlarms.map { String(describing: $0) }.joined(separator: ", "))
        }
        if let reservoir = response.reservoir {
            if reservoir > 0 { lastReservoirUnits = reservoir }
            if reservoir <= 15 { notes.append(String(format: "Reservoir %.0f U", reservoir)) }
        }
        lastPatchAlarm = notes.isEmpty ? nil : notes.joined(separator: " · ")
        if let bolus = response.bolus, bolus.completed, bolus.delivered >= 0.05 {
            lastBolusUnits = bolus.delivered
        }
        if response.state.isDeliveryHalted || response.basal?.type.isSuspendedByPump() == true {
            basalKnown = true
            basalIsTemp = false
        } else if let basal = response.basal {
            basalKnown = true
            basalIsTemp = basal.type.isTempBasal()
        }
    }

    private static func dosingBlock(_ state: PatchState) -> String? {
        switch state {
        case .active, .active_alt, .none:
            return nil
        default:
            return "Patch \(state.description) (\(state.rawValue))"
        }
    }

    private static func commandName(_ code: UInt8) -> String {
        switch code {
        case CommandType.SET_TEMP_BASAL: return "setTempBasal"
        case CommandType.CANCEL_TEMP_BASAL: return "cancelTempBasal"
        case CommandType.SET_BOLUS: return "bolus"
        case CommandType.SYNCHRONIZE: return "synchronize"
        case CommandType.GET_TIME: return "getTime"
        case CommandType.AUTH_REQ: return "authorize"
        case CommandType.SUBSCRIBE: return "subscribe"
        default: return "Befehl \(code)"
        }
    }

    private func finishConnect(_ result: Result<Void, Error>) {
        queue.async {
            guard let waiter = self.connectWaiter else { return }
            self.connectWaiter = nil
            switch result {
            case .success:
                waiter.resume()
            case let .failure(error):
                waiter.resume(throwing: error)
            }
        }
    }

    private func finishWrite(_ result: Result<Void, Error>, generation: Int? = nil) {
        queue.async {
            if let generation, generation != self.writeGeneration { return }
            guard let waiter = self.writeWaiter else { return }
            self.writeWaiter = nil
            self.writeGeneration += 1
            switch result {
            case .success:
                waiter.resume()
            case let .failure(error):
                waiter.resume(throwing: error)
            }
        }
    }

    private func fail(_ error: Error) {
        finishConnect(.failure(error))
        finishWrite(.failure(error))
    }
}

public enum HandyFreiMedtrumCommand {
    case readStatus
    case readHistory
    case setTempBasal(rate: Double, minutes: Int)
    case cancelTempBasal
    case bolus(units: Double)

    /// Prime, activate, profile write, suspend, resume, stop, set patch, bolus motor.
    static let forbidden: Set<UInt8> = [16, 18, 21, 28, 29, 31, 35, 36]
}
