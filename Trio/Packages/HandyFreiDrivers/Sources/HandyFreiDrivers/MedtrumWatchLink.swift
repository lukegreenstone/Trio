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
    private var sessionToken = Data()
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var writeWaiter: CheckedContinuation<Void, Error>?
    private var expected: UInt8 = 0
    private var writeGeneration = 0
    private var stopping = false
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
    }

    public func connect(pumpSerialBase64: String, sessionTokenBase64: String) async throws {
        guard let serial = Data(base64Encoded: pumpSerialBase64), !serial.isEmpty,
              let token = Data(base64Encoded: sessionTokenBase64), !token.isEmpty
        else { throw HandyFreiLinkError.badKey }
        stopping = false
        pumpSN = serial
        sessionToken = token
        central = CBCentralManager(delegate: self, queue: queue)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.connectWaiter = continuation
            }
            queue.asyncAfter(deadline: .now() + 45) { [weak self] in
                self?.finishConnect(.failure(HandyFreiLinkError.notFound))
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
        guard !HandyFreiMedtrumCommand.forbidden.contains(code) else { throw HandyFreiLinkError.pumpRefused }
        try await write(packet)
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: nil)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: NSNumber
    ) {
        guard let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String, name == "MT",
              let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              manufacturer.count >= 6,
              manufacturer.subdata(in: 2 ..< 6) == pumpSN
        else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
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
        peripheral.setNotifyValue(true, for: read)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.write(AuthorizePacket(pumpSN: self.pumpSN, sessionToken: self.sessionToken))
                try await self.write(SynchronizePacket())
                try await self.write(SubscribePacket())
                self.finishConnect(.success(()))
            } catch {
                self.finishConnect(.failure(error))
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value, data.count > 2, data[1] == expected else { return }
        finishWrite(.success(()))
    }

    public func centralManager(_: CBCentralManager, didDisconnectPeripheral _: CBPeripheral, error _: Error?) {
        guard !stopping else { return }
        fail(HandyFreiLinkError.notFound)
        onConnectionLost?()
    }

    private func write(_ packet: any MedtrumBasePacketProtocol) async throws {
        guard let peripheral, let writeCharacteristic else { throw HandyFreiLinkError.notFound }
        let packages = packet.encode(sequenceNumber: sequence)
        sequence = sequence &+ 1
        expected = packet.commandType
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.writeGeneration += 1
                let generation = self.writeGeneration
                self.writeWaiter = continuation
                for package in packages {
                    peripheral.writeValue(package, for: writeCharacteristic, type: .withResponse)
                }
                self.queue.asyncAfter(deadline: .now() + 30) {
                    self.finishWrite(.failure(HandyFreiLinkError.pumpRefused), generation: generation)
                }
            }
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
