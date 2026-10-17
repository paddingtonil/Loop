//
//  DirectConnect_BluetoothManager.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — CoreBluetooth central: scanning, connecting and state restoration.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Adapted from LoopKit G7SensorKit G7BluetoothManager (MIT, © 2022 LoopKit Authors).
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import CoreBluetooth
import Foundation
import LoopKit

protocol DirectConnect_BluetoothManagerDelegate: AnyObject {
    /// Connected and ready. Returns true if scanning should stop.
    func bluetoothManager(_ manager: DirectConnect_BluetoothManager, readied peripheralManager: DirectConnect_PeripheralManager) -> Bool
    func bluetoothManager(_ manager: DirectConnect_BluetoothManager, readyingFailed peripheralManager: DirectConnect_PeripheralManager, with error: Error)
    func bluetoothManager(_ manager: DirectConnect_BluetoothManager, shouldConnectPeripheral peripheral: CBPeripheral) -> DirectConnect_ConnectDecision
    func bluetoothManager(_ manager: DirectConnect_BluetoothManager, peripheralManager: DirectConnect_PeripheralManager, didReceive value: Data, on characteristic: DirectConnect_CharacteristicUUID)
    func bluetoothManager(_ manager: DirectConnect_BluetoothManager, peripheralManager: DirectConnect_PeripheralManager, didReadRSSI rssi: Int)
    func bluetoothManagerScanningStatusDidChange(_ manager: DirectConnect_BluetoothManager)
    func peripheralDidDisconnect(_ manager: DirectConnect_BluetoothManager, peripheralManager: DirectConnect_PeripheralManager, wasRemoteDisconnect: Bool)
}

final class DirectConnect_BluetoothManager: NSObject {
    /// Must differ from G7SensorKit's "com.loudnate.CGMBLEKit" so iOS restores the right central.
    static let restoreIdentifier = "com.loopkit.Loop.DirectConnect"

    weak var delegate: DirectConnect_BluetoothManagerDelegate?

    private let log = DiagnosticLog(category: "DirectConnect.Bluetooth")

    /// Isolated to `managerQueue`.
    private var centralManager: CBCentralManager! = nil
    private var managedPeripherals: [UUID: DirectConnect_PeripheralManager] = [:]
    private var activePeripheralManager: DirectConnect_PeripheralManager? {
        didSet {
            oldValue?.delegate = nil
            lockedPeripheralIdentifier.value = activePeripheralManager?.peripheral.identifier
        }
    }
    private var activePeripheral: CBPeripheral? { activePeripheralManager?.peripheral }

    private let lockedPeripheralIdentifier = Locked<UUID?>(nil)
    var activePeripheralIdentifier: UUID? { lockedPeripheralIdentifier.value }

    /// The paired sensor's identifier saved from an earlier app run. With it, Loop queues a
    /// connection to that exact sensor at launch instead of waiting for a background scan.
    private let knownPeripheralIdentifier = Locked<UUID?>(nil)

    func setKnownPeripheral(_ identifier: UUID?) {
        knownPeripheralIdentifier.value = identifier
    }

    private let managerQueue = DispatchQueue(label: "com.loopkit.Loop.DirectConnect.BluetoothManager", qos: .unspecified)

    override init() {
        super.init()
        managerQueue.sync {
            centralManager = CBCentralManager(delegate: self, queue: managerQueue, options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier])
        }
    }

    // MARK: - Actions

    func scanForPeripheral() {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))
        managerQueue.sync { managerQueue_scanForPeripheral() }
    }

    func forgetPeripheral() {
        knownPeripheralIdentifier.value = nil
        managerQueue.sync {
            activePeripheralManager = nil
            managedPeripherals.removeAll()
        }
    }

    /// Re-issues the pending connection (and scans if no sensor is known). Used by the watchdog
    /// when the sensor has not connected for longer than two wake cycles.
    func restartConnection() {
        managerQueue.async {
            guard !self.isShutDown else { return }
            if let peripheral = self.activePeripheral, peripheral.state != .connected {
                self.centralManager.cancelPeripheralConnection(peripheral)
                self.centralManager.connect(peripheral)
            }
            self.managerQueue_scanForPeripheral()
        }
    }

    func stopScanning() {
        managerQueue.sync { managerQueue_stopScanning() }
    }

    func disconnect() {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))
        managerQueue.sync {
            managerQueue_stopScanning()
            for manager in managedPeripherals.values where manager.peripheral.state != .disconnected {
                centralManager.cancelPeripheralConnection(manager.peripheral)
            }
        }
    }

    /// Disconnects only the given peripheral, leaving reconnection logic in place.
    func disconnect(_ peripheralManager: DirectConnect_PeripheralManager) {
        managerQueue.async {
            self.centralManager.cancelPeripheralConnection(peripheralManager.peripheral)
        }
    }

    var isScanning: Bool {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))
        return managerQueue.sync { centralManager.isScanning }
    }

    var isConnected: Bool {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))
        return managerQueue.sync { activePeripheral?.state == .connected }
    }

    var bluetoothState: CBManagerState {
        managerQueue.sync { centralManager.state }
    }

    // MARK: - Queue-confined implementation

    private func managerQueue_stopScanning() {
        if centralManager.isScanning {
            centralManager.stopScan()
            delegate?.bluetoothManagerScanningStatusDidChange(self)
        }
    }

    /// Set by `shutDown()`; on `managerQueue` only.
    private var isShutDown = false

    /// Stops scanning, cancels every connection and forgets the sensor, then refuses any later
    /// scan or reconnect. Used when the CGM is deleted, so the old manager cannot keep a link open.
    func shutDown() {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))
        managerQueue.sync {
            isShutDown = true
            managerQueue_stopScanning()
            for manager in managedPeripherals.values where manager.peripheral.state != .disconnected {
                centralManager.cancelPeripheralConnection(manager.peripheral)
            }
            activePeripheralManager = nil
            managedPeripherals.removeAll()
        }
        knownPeripheralIdentifier.value = nil
    }

    private func managerQueue_scanForPeripheral() {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        guard !isShutDown, centralManager.state == .poweredOn else { return }
        guard (activePeripheral?.state ?? .disconnected) != .connected else { return }

        if let identifier = activePeripheralIdentifier ?? knownPeripheralIdentifier.value,
           let peripheral = centralManager.retrievePeripherals(withIdentifiers: [identifier]).first {
            handleDiscoveredPeripheral(peripheral)
        } else {
            for peripheral in centralManager.retrieveConnectedPeripherals(withServices: [DirectConnect_ServiceUUID.advertisement.cbUUID, DirectConnect_ServiceUUID.cgmService.cbUUID]) {
                handleDiscoveredPeripheral(peripheral)
            }
        }

        if activePeripheral == nil {
            log.default("Scanning for G7-family sensors")
            centralManager.registerForConnectionEvents(options: [
                CBConnectionEventMatchingOption.serviceUUIDs: [DirectConnect_ServiceUUID.advertisement.cbUUID, DirectConnect_ServiceUUID.cgmService.cbUUID]
            ])
            centralManager.scanForPeripherals(withServices: [DirectConnect_ServiceUUID.advertisement.cbUUID], options: nil)
            delegate?.bluetoothManagerScanningStatusDidChange(self)
        }
    }

    /// The sensor sleeps between readings and iOS only re-wakes the app while it is scanning or
    /// has a pending connection, so a fresh scan is started shortly after each disconnect.
    private func scanAfterDelay() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.scanForPeripheral()
        }
    }

    private func handleDiscoveredPeripheral(_ peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        guard !isShutDown, let delegate = delegate else { return }

        switch delegate.bluetoothManager(self, shouldConnectPeripheral: peripheral) {
        case .makeActive:
            log.default("Making peripheral active: %{public}@", peripheral.identifier.uuidString)
            if let manager = activePeripheralManager {
                manager.peripheral = peripheral
            } else {
                let manager = DirectConnect_PeripheralManager(peripheral: peripheral, centralManager: centralManager)
                manager.delegate = self
                activePeripheralManager = manager
            }
            managedPeripherals[peripheral.identifier] = activePeripheralManager
            // iOS restores the sensor before Bluetooth reports powered on; connecting then is
            // rejected ("API MISUSE"). The powered-on callback scans again and connects.
            if centralManager.state == .poweredOn {
                centralManager.connect(peripheral)
            }

        case .connect:
            // Discovery and connection events repeat while a connection is under way; connecting
            // again would produce a second didConnect for the same link.
            if let existing = managedPeripherals[peripheral.identifier],
               existing.peripheral.state == .connecting || existing.peripheral.state == .connected {
                return
            }
            log.default("Connecting to candidate sensor: %{public}@", peripheral.identifier.uuidString)
            let manager = managedPeripherals[peripheral.identifier] ?? DirectConnect_PeripheralManager(peripheral: peripheral, centralManager: centralManager)
            manager.delegate = self
            managedPeripherals[peripheral.identifier] = manager
            if centralManager.state == .poweredOn {
                centralManager.connect(peripheral)
            }

        case .ignore:
            break
        }
    }

    /// Called by the sensor once a candidate peripheral has been paired, so later wakes treat it
    /// as the followed peripheral.
    func adoptAsActive(_ peripheralManager: DirectConnect_PeripheralManager) {
        managerQueue.async {
            self.activePeripheralManager = peripheralManager
            for (identifier, manager) in self.managedPeripherals where manager !== peripheralManager {
                if manager.peripheral.state != .disconnected {
                    self.centralManager.cancelPeripheralConnection(manager.peripheral)
                }
                self.managedPeripherals.removeValue(forKey: identifier)
            }
            self.managerQueue_stopScanning()
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension DirectConnect_BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        activePeripheralManager?.centralManagerDidUpdateState(central)
        log.default("Central state: %{public}@", String(describing: central.state.rawValue))
        if central.state == .poweredOn {
            managerQueue_scanForPeripheral()
        } else if central.isScanning {
            central.stopScan()
            delegate?.bluetoothManagerScanningStatusDidChange(self)
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in peripherals {
                log.default("Restoring peripheral: %{public}@", peripheral.identifier.uuidString)
                handleDiscoveredPeripheral(peripheral)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, connectionEventDidOccur event: CBConnectionEvent, for peripheral: CBPeripheral) {
        if activePeripheralIdentifier == nil {
            handleDiscoveredPeripheral(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        handleDiscoveredPeripheral(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log.default("Connected: %{public}@", peripheral.identifier.uuidString)
        guard let manager = managedPeripherals[peripheral.identifier] else { return }
        manager.centralManager(central, didConnect: peripheral)
        if let delegate = delegate, central.state == .poweredOn, peripheral.state == .connected {
            if delegate.bluetoothManager(self, readied: manager) {
                managerQueue_stopScanning()
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log.default("Disconnected: %{public}@ error: %{public}@", peripheral.identifier.uuidString, String(describing: error))
        let remote = (error as NSError?).map { CBError(_nsError: $0).code == .peripheralDisconnected } ?? false
        if let error = error, !remote, let manager = managedPeripherals[peripheral.identifier] {
            delegate?.bluetoothManager(self, readyingFailed: manager, with: error)
        }
        if let manager = managedPeripherals[peripheral.identifier] {
            delegate?.peripheralDidDisconnect(self, peripheralManager: manager, wasRemoteDisconnect: remote)
        }
        if peripheral != activePeripheral {
            managedPeripherals.removeValue(forKey: peripheral.identifier)
        }
        scanAfterDelay()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log.error("Failed to connect: %{public}@", String(describing: error))
        if let error = error, let manager = managedPeripherals[peripheral.identifier] {
            delegate?.bluetoothManager(self, readyingFailed: manager, with: error)
        }
        if peripheral != activePeripheral {
            managedPeripherals.removeValue(forKey: peripheral.identifier)
        }
        scanAfterDelay()
    }
}

// MARK: - Peripheral events

extension DirectConnect_BluetoothManager: DirectConnect_PeripheralManagerDelegate {
    func peripheralManager(_ manager: DirectConnect_PeripheralManager, didUpdateValueFor characteristic: CBCharacteristic) {
        guard let value = characteristic.value, let uuid = DirectConnect_CharacteristicUUID(characteristic.uuid) else { return }
        delegate?.bluetoothManager(self, peripheralManager: manager, didReceive: value, on: uuid)
    }

    func peripheralManager(_ manager: DirectConnect_PeripheralManager, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        delegate?.bluetoothManager(self, peripheralManager: manager, didReadRSSI: RSSI.intValue)
    }
}
