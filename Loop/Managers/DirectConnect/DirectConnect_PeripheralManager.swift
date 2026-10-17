//
//  DirectConnect_PeripheralManager.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — Serialized GATT operations on one G7 peripheral.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Adapted from LoopKit G7SensorKit G7PeripheralManager (MIT, © 2022 LoopKit Authors).
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import CoreBluetooth
import Foundation
import LoopKit

// MARK: - Services and characteristics

enum DirectConnect_ServiceUUID: String {
    case advertisement = "FEBC"
    case cgmService = "F8083532-849E-531C-C594-30F1F86A4EA5"

    var cbUUID: CBUUID { CBUUID(string: rawValue) }
}

enum DirectConnect_CharacteristicUUID: String, CaseIterable {
    case communication = "F8083533-849E-531C-C594-30F1F86A4EA5"
    /// Write_Control: data requests and responses.
    case control = "F8083534-849E-531C-C594-30F1F86A4EA5"
    /// Receive_Authentication: authentication control packets.
    case authentication = "F8083535-849E-531C-C594-30F1F86A4EA5"
    case backfill = "F8083536-849E-531C-C594-30F1F86A4EA5"
    /// Auth_Stream: large pairing payloads. Not used by the listen-only G7SensorKit.
    case authStream = "F8083538-849E-531C-C594-30F1F86A4EA5"

    var cbUUID: CBUUID { CBUUID(string: rawValue) }

    init?(_ uuid: CBUUID) {
        self.init(rawValue: uuid.uuidString.uppercased())
    }
}

enum DirectConnect_PeripheralError: Error {
    case cbPeripheralError(Error)
    case notReady
    case invalidConfiguration
    case timeout
    case unknownCharacteristic
}

protocol DirectConnect_PeripheralManagerDelegate: AnyObject {
    func peripheralManager(_ manager: DirectConnect_PeripheralManager, didUpdateValueFor characteristic: CBCharacteristic)
    func peripheralManager(_ manager: DirectConnect_PeripheralManager, didReadRSSI RSSI: NSNumber, error: Error?)
}

final class DirectConnect_PeripheralManager: NSObject {
    private let log = DiagnosticLog(category: "DirectConnect.Peripheral")

    /// Mutable because CBPeripheral instances can become invalid and be re-fetched.
    var peripheral: CBPeripheral {
        didSet {
            guard oldValue !== peripheral else { return }
            oldValue.delegate = nil
            peripheral.delegate = self
            // Async: this runs on the Bluetooth queue, and a sync hop would wait for any command in
            // progress, which itself waits for a callback on the Bluetooth queue (up to its timeout).
            queue.async { self.needsConfiguration = true }
        }
    }

    /// Serializes all operations on the peripheral.
    let queue = DispatchQueue(label: "com.loopkit.Loop.DirectConnect.PeripheralManager", qos: .unspecified)

    private let commandLock = NSCondition()
    private var commandConditions = [CommandCondition]()
    private var commandError: Error?
    private(set) weak var central: CBCentralManager?
    private var needsConfiguration = true

    weak var delegate: DirectConnect_PeripheralManagerDelegate?

    private static let requiredCharacteristics: [CBUUID] = [
        DirectConnect_CharacteristicUUID.authentication.cbUUID,
        DirectConnect_CharacteristicUUID.control.cbUUID,
        DirectConnect_CharacteristicUUID.backfill.cbUUID,
        DirectConnect_CharacteristicUUID.authStream.cbUUID,
    ]

    enum CommandCondition {
        case notificationStateUpdate(characteristicUUID: CBUUID, enabled: Bool)
        case write(characteristic: CBCharacteristic)
        case discoverServices
        case discoverCharacteristicsForService(serviceUUID: CBUUID)
    }

    init(peripheral: CBPeripheral, centralManager: CBCentralManager) {
        self.peripheral = peripheral
        self.central = centralManager
        super.init()
        peripheral.delegate = self
        perform { _ in }
    }

    // MARK: - Operation sequencing

    /// Runs `block` on the peripheral queue after (re)discovering services if needed.
    func perform(_ block: @escaping (_ manager: DirectConnect_PeripheralManager) -> Void) {
        queue.async {
            if self.needsConfiguration || self.peripheral.services == nil {
                do {
                    try self.applyConfiguration()
                    self.needsConfiguration = false
                } catch {
                    self.log.error("Peripheral configuration failed: %{public}@", String(describing: error))
                }
            }
            block(self)
        }
    }

    private func applyConfiguration(timeout: TimeInterval = 5) throws {
        try discoverServices([DirectConnect_ServiceUUID.cgmService.cbUUID], timeout: timeout)
        guard let service = peripheral.services?.first(where: { $0.uuid == DirectConnect_ServiceUUID.cgmService.cbUUID }) else {
            throw DirectConnect_PeripheralError.invalidConfiguration
        }
        try discoverCharacteristics(Self.requiredCharacteristics, for: service, timeout: timeout)
    }

    // MARK: - Characteristic helpers

    func findCharacteristic(_ uuid: DirectConnect_CharacteristicUUID) -> CBCharacteristic? {
        peripheral.services?
            .first(where: { $0.uuid == DirectConnect_ServiceUUID.cgmService.cbUUID })?
            .characteristics?
            .first(where: { $0.uuid == uuid.cbUUID })
    }

    func isNotifying(_ uuid: DirectConnect_CharacteristicUUID) -> Bool {
        findCharacteristic(uuid)?.isNotifying ?? false
    }

    /// Enables notifications and waits for the peripheral to confirm. Must run on `queue`.
    func setNotify(_ enabled: Bool, for uuid: DirectConnect_CharacteristicUUID, timeout: TimeInterval = 5) throws {
        guard let characteristic = findCharacteristic(uuid) else { throw DirectConnect_PeripheralError.unknownCharacteristic }
        guard characteristic.isNotifying != enabled else { return }
        try runCommand(timeout: timeout) {
            addCondition(.notificationStateUpdate(characteristicUUID: characteristic.uuid, enabled: enabled))
            peripheral.setNotifyValue(enabled, for: characteristic)
        }
    }

    /// Writes a value. With response it waits for the acknowledgement; without response it
    /// returns immediately. Must run on `queue`.
    func write(_ data: Data, to uuid: DirectConnect_CharacteristicUUID, withResponse: Bool, timeout: TimeInterval = 5) throws {
        guard let characteristic = findCharacteristic(uuid) else { throw DirectConnect_PeripheralError.unknownCharacteristic }
        try runCommand(timeout: timeout) {
            if withResponse {
                addCondition(.write(characteristic: characteristic))
            }
            peripheral.writeValue(data, for: characteristic, type: withResponse ? .withResponse : .withoutResponse)
        }
    }

    func readRSSI() {
        queue.async {
            guard self.peripheral.state == .connected else { return }
            self.peripheral.readRSSI()
        }
    }

    // MARK: - Synchronous commands

    private func runCommand(timeout: TimeInterval, command: () -> Void) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard central?.state == .poweredOn && peripheral.state == .connected else {
            throw DirectConnect_PeripheralError.notReady
        }

        commandLock.lock()
        defer { commandLock.unlock() }

        guard commandConditions.isEmpty else { throw DirectConnect_PeripheralError.invalidConfiguration }

        command()

        guard !commandConditions.isEmpty else { return }

        let signaled = commandLock.wait(until: Date(timeIntervalSinceNow: timeout))
        defer {
            commandError = nil
            commandConditions = []
        }
        guard signaled else { throw DirectConnect_PeripheralError.timeout }
        if let error = commandError { throw DirectConnect_PeripheralError.cbPeripheralError(error) }
    }

    /// Only valid while holding `commandLock` inside `runCommand`.
    private func addCondition(_ condition: CommandCondition) {
        commandConditions.append(condition)
    }

    private func discoverServices(_ uuids: [CBUUID], timeout: TimeInterval) throws {
        let known = peripheral.services?.map(\.uuid) ?? []
        guard uuids.contains(where: { !known.contains($0) }) else { return }
        try runCommand(timeout: timeout) {
            addCondition(.discoverServices)
            peripheral.discoverServices(uuids)
        }
    }

    private func discoverCharacteristics(_ uuids: [CBUUID], for service: CBService, timeout: TimeInterval) throws {
        let known = service.characteristics?.map(\.uuid) ?? []
        let missing = uuids.filter { !known.contains($0) }
        guard !missing.isEmpty else { return }
        try runCommand(timeout: timeout) {
            addCondition(.discoverCharacteristicsForService(serviceUUID: service.uuid))
            peripheral.discoverCharacteristics(missing, for: service)
        }
    }

    private func completeCondition(error: Error?, where matches: (CommandCondition) -> Bool) {
        commandLock.lock()
        if let index = commandConditions.firstIndex(where: matches) {
            commandConditions.remove(at: index)
            commandError = error
            if commandConditions.isEmpty {
                commandLock.broadcast()
            }
        }
        commandLock.unlock()
    }
}

// MARK: - CBPeripheralDelegate (called on the central's queue)

extension DirectConnect_PeripheralManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        completeCondition(error: error) {
            if case .discoverServices = $0 { return true }
            return false
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        completeCondition(error: error) {
            if case .discoverCharacteristicsForService(serviceUUID: service.uuid) = $0 { return true }
            return false
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        completeCondition(error: error) {
            if case .notificationStateUpdate(characteristicUUID: characteristic.uuid, enabled: characteristic.isNotifying) = $0 { return true }
            // A failed enable leaves isNotifying false; still release the waiting command.
            if error != nil, case .notificationStateUpdate(characteristicUUID: characteristic.uuid, enabled: _) = $0 { return true }
            return false
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        completeCondition(error: error) {
            if case .write(characteristic: characteristic) = $0 { return true }
            return false
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // G7SensorKit drops unsolicited notifications while any command is pending. During
        // pairing the sensor notifies while our writes are awaiting acknowledgement, so every
        // notification is forwarded here.
        guard error == nil else {
            log.error("Value update error on %{public}@: %{public}@", characteristic.uuid.uuidString, String(describing: error))
            return
        }
        delegate?.peripheralManager(self, didUpdateValueFor: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        delegate?.peripheralManager(self, didReadRSSI: RSSI, error: error)
    }
}

// MARK: - Central events forwarded by the Bluetooth manager

extension DirectConnect_PeripheralManager {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            perform { _ in }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        queue.async { self.needsConfiguration = true }
    }
}
