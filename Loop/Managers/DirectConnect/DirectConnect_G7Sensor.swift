//
//  DirectConnect_G7Sensor.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — Runs each G7 connection: pair, request glucose, backfill, extras.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Portions derived from xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0:
//  the connection sequence follows CGMG7Transmitter's primary mode.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import CoreBluetooth
import Foundation
import LoopKit

enum DirectConnect_PairingFailure: Equatable {
    /// The sensor refused the applicator code (sensor name included).
    case wrongCode(String)
    /// While searching for a new sensor, a nearby sensor (usually the previous one) refused the
    /// code and was skipped; the search continues.
    case skippedSensor(String)
    /// The sensor refused to start pairing; not caused by the code. Retried at its next wake.
    case pakeRefused(String)
    /// The sensor accepted the code but refused the next pairing step. Retried at each wake.
    case certificateRefused(String)
    /// The saved key was refused; another app may own the sensor now.
    case keyRejected
    case protocolError(String)

    var message: String {
        switch self {
        case .wrongCode(let name):
            return String(format: NSLocalizedString("Sensor %@ did not accept the code. Check the 4 digits on the applicator.", comment: "DirectConnect wrong code (1: sensor name)"), name)
        case .skippedSensor(let name):
            return String(format: NSLocalizedString("Sensor %@ refused the code, so it is not the new sensor (it is probably your previous sensor). Loop is still searching for the new sensor. If nothing pairs within 15 minutes, check the 4 digits on the applicator and tap Pair New Sensor.", comment: "DirectConnect nearby sensor refused the new code during search (1: sensor name)"), name)
        case .pakeRefused(let name):
            return String(format: NSLocalizedString("Sensor %@ did not start pairing. If it is your new sensor, Loop tries again at its next wake (every 5 minutes).", comment: "DirectConnect sensor refused to start pairing (1: sensor name)"), name)
        case .certificateRefused(let name):
            return String(format: NSLocalizedString("Sensor %@ accepted the code but refused the next pairing step. Loop tries again at each sensor wake (every 5 minutes). A newly inserted sensor can refuse this step for 20 minutes or more.", comment: "DirectConnect certificate step refused (1: sensor name)"), name)
        case .keyRejected:
            return NSLocalizedString("Pairing lost. Another app may have connected to the sensor. Re-enter the code to pair again.", comment: "DirectConnect key rejected")
        case .protocolError(let detail):
            return String(format: NSLocalizedString("Pairing error: %@", comment: "DirectConnect protocol error (1: detail)"), detail)
        }
    }

    /// True for refusals the user cannot fix and Loop retries by itself; shown as a status
    /// line, not as a pairing problem.
    var isNotice: Bool {
        switch self {
        case .pakeRefused, .certificateRefused: return true
        case .wrongCode, .skippedSensor, .keyRejected, .protocolError: return false
        }
    }
}

protocol DirectConnect_G7SensorDelegate: AnyObject {
    func sensorDidConnect(_ sensor: DirectConnect_G7Sensor, name: String)
    func sensorDisconnected(_ sensor: DirectConnect_G7Sensor)
    func sensor(_ sensor: DirectConnect_G7Sensor, didPairWith name: String)
    func sensorDidAuthenticate(_ sensor: DirectConnect_G7Sensor, peripheralIdentifier: UUID)
    func sensor(_ sensor: DirectConnect_G7Sensor, didRead message: DirectConnect_G7GlucoseMessage, receivedAt: Date)
    func sensor(_ sensor: DirectConnect_G7Sensor, didReadBackfill backfill: [DirectConnect_G7BackfillMessage])
    func sensor(_ sensor: DirectConnect_G7Sensor, didReceive extendedVersion: DirectConnect_G7ExtendedVersion)
    func sensor(_ sensor: DirectConnect_G7Sensor, didReceive battery: DirectConnect_G7BatteryStatus)
    func sensor(_ sensor: DirectConnect_G7Sensor, didReceive versionInfo: DirectConnect_G7VersionInfo)
    func sensor(_ sensor: DirectConnect_G7Sensor, pairingDidFail failure: DirectConnect_PairingFailure)
    func sensor(_ sensor: DirectConnect_G7Sensor, calibrationDidChange queue: DirectConnect_CalibrationQueue)
    func sensor(_ sensor: DirectConnect_G7Sensor, log message: String)
    func sensor(_ sensor: DirectConnect_G7Sensor, didReadRSSI rssi: Int)
    func sensorConnectionStatusDidUpdate(_ sensor: DirectConnect_G7Sensor)
}

final class DirectConnect_G7Sensor {
    static let batteryReadInterval: TimeInterval = 2 * 3600

    weak var delegate: DirectConnect_G7SensorDelegate?

    /// Values read from the Bluetooth queue when deciding whether to connect.
    private struct ScanConfig {
        var sensorName: String?
        var sensorType: DirectConnect_SensorType
        var excludedName: String?
        /// The previous sensor, not connected to while searching for a new one.
        var excluded: DirectConnect_ExcludedSensor?
        var skipList = DirectConnect_SkipList()
        var authenticationBlocked = false
        /// Without a code a new sensor cannot be paired, so unknown sensors are not connected.
        var hasPairingCode = false
        /// The paired sensor's CoreBluetooth identifier from an earlier run.
        var knownIdentifier: UUID?
    }

    private let bluetoothManager: DirectConnect_BluetoothManager
    private let keyStore: DirectConnect_KeyStoring
    private let scanConfig: Locked<ScanConfig>
    private let writeGeneration = Locked<Int>(0)

    /// All mutable connection state below is confined to `stateQueue`.
    private let stateQueue = DispatchQueue(label: "com.loopkit.Loop.DirectConnect.Sensor", qos: .unspecified)
    private let delegateQueue = DispatchQueue(label: "com.loopkit.Loop.DirectConnect.SensorDelegate", qos: .unspecified)

    private var pairingCode: String?
    private var pairing: DirectConnect_G7Pairing?
    private var calibration = DirectConnect_CalibrationQueue()
    private var needsExtendedVersion = true
    private var needsVersionInfo = true
    private var batteryLastRead: Date?

    // Per connection
    private weak var activePeripheralManager: DirectConnect_PeripheralManager?
    private var connectionIdentity: String?
    private var authenticated = false
    private var glucoseRequested = false
    private var extraCommandSent = false
    private var clock: DirectConnect_ClockReference?
    private var backfillBuffer: [DirectConnect_G7BackfillMessage] = []

    init(sensorName: String?, sensorType: DirectConnect_SensorType, pairingCode: String?, excludedName: String?, excluded: DirectConnect_ExcludedSensor?, knownPeripheralIdentifier: UUID?, keyStore: DirectConnect_KeyStoring) {
        self.keyStore = keyStore
        self.pairingCode = pairingCode
        let known = sensorName == nil ? nil : knownPeripheralIdentifier
        scanConfig = Locked(ScanConfig(sensorName: sensorName, sensorType: sensorType, excludedName: excludedName, excluded: excluded, hasPairingCode: pairingCode != nil, knownIdentifier: known))
        bluetoothManager = DirectConnect_BluetoothManager()
        bluetoothManager.setKnownPeripheral(known)
        bluetoothManager.delegate = self
    }

    // MARK: - Commands from the CGM manager

    /// Forgets the current sensor and looks for a new one of `type`, pairing with `pairingCode`.
    func scanForNewSensor(type: DirectConnect_SensorType, pairingCode: String, excludedName: String?, excluded: DirectConnect_ExcludedSensor?) {
        stateQueue.sync {
            self.pairingCode = pairingCode
            self.pairing = nil
            self.needsExtendedVersion = true
            self.needsVersionInfo = true
            self.batteryLastRead = nil
            self.calibration.clear()
        }
        scanConfig.mutate {
            $0.sensorName = nil
            $0.sensorType = type
            $0.excludedName = excludedName
            $0.excluded = excluded
            $0.skipList = DirectConnect_SkipList()
            $0.authenticationBlocked = false
            $0.hasPairingCode = true
            $0.knownIdentifier = nil
        }
        bluetoothManager.disconnect()
        bluetoothManager.forgetPeripheral()
        bluetoothManager.scanForPeripheral()
    }

    /// Re-pair the followed sensor with a (possibly corrected) code.
    func repair(pairingCode: String) {
        let name = scanConfig.value.sensorName
        stateQueue.sync {
            self.pairingCode = pairingCode
            self.pairing = nil
        }
        if let name = name {
            keyStore.delete(sensor: name)
        }
        scanConfig.mutate {
            $0.authenticationBlocked = false
            $0.skipList = DirectConnect_SkipList()
            $0.hasPairingCode = true
        }
        bluetoothManager.scanForPeripheral()
    }

    func resumeScanning() {
        bluetoothManager.scanForPeripheral()
    }

    /// Re-issues the pending connection when the watchdog finds the link silent.
    func restartConnection() {
        bluetoothManager.restartConnection()
    }

    func stopScanning() {
        bluetoothManager.disconnect()
    }

    /// Permanently stops this sensor's Bluetooth activity (Delete CGM).
    func shutDown() {
        bluetoothManager.shutDown()
    }

    var isScanning: Bool { bluetoothManager.isScanning }
    var isConnected: Bool { bluetoothManager.isConnected }
    var bluetoothState: CBManagerState { bluetoothManager.bluetoothState }
    var sensorName: String? { scanConfig.value.sensorName }
    var authenticationBlocked: Bool { scanConfig.value.authenticationBlocked }

    func restoreSessionInfo(calibration: DirectConnect_CalibrationQueue, needsExtendedVersion: Bool, needsVersionInfo: Bool, batteryLastRead: Date?) {
        stateQueue.async {
            self.calibration = calibration
            self.needsExtendedVersion = needsExtendedVersion
            self.needsVersionInfo = needsVersionInfo
            self.batteryLastRead = batteryLastRead
        }
    }

    /// Called once a minute so "Processing" ends on time even when the sensor is not waking.
    func expireCalibrationIfOverdue(now: Date = Date()) {
        stateQueue.async {
            guard self.calibration.expireIfOverdue(now: now) else { return }
            self.log("Calibration result never arrived; status set to unconfirmed")
            let queue = self.calibration
            self.notify { $0.sensor(self, calibrationDidChange: queue) }
        }
    }

    func enqueueCalibration(glucose: Double, date: Date) -> Bool {
        let (accepted, queue) = stateQueue.sync { () -> (Bool, DirectConnect_CalibrationQueue) in
            let accepted = calibration.enqueue(glucose: glucose, date: date)
            return (accepted, calibration)
        }
        if accepted {
            notify { $0.sensor(self, calibrationDidChange: queue) }
        }
        return accepted
    }

    func readRSSI() {
        stateQueue.async { self.activePeripheralManager?.readRSSI() }
    }

    // MARK: - Delegate helper

    private func notify(_ block: @escaping (DirectConnect_G7SensorDelegate) -> Void) {
        delegateQueue.async {
            guard let delegate = self.delegate else { return }
            block(delegate)
        }
    }

    private func log(_ message: String) {
        notify { $0.sensor(self, log: message) }
    }

    // MARK: - Connection lifecycle (stateQueue)

    private func beginConnection(_ peripheralManager: DirectConnect_PeripheralManager, identity: String) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        // iOS can report one physical connection twice. Starting over on the second report would
        // reset pairing midway and the sensor would refuse the out-of-order steps.
        if activePeripheralManager === peripheralManager, connectionIdentity != nil {
            log("Duplicate connection report ignored")
            return
        }
        activePeripheralManager = peripheralManager
        connectionIdentity = identity
        authenticated = false
        glucoseRequested = false
        extraCommandSent = false
        clock = nil
        backfillBuffer = []

        if pairing?.sensorName != identity {
            pairing = DirectConnect_G7Pairing(sensorName: identity, pairingCode: pairingCode, keyStore: keyStore)
        } else {
            pairing?.pairingCode = pairingCode
            pairing?.resetForConnection()
        }
        pairing?.forceFullPairing = scanConfig.value.sensorName == nil

        peripheralManager.readRSSI()
        // Auth_Stream first: the sensor can announce a J-PAKE phase and stream its payload
        // immediately, so the stream must already be notifying when the control channel opens.
        peripheralManager.perform { manager in
            do {
                try Self.retryOnce { try manager.setNotify(true, for: .authStream) }
                try Self.retryOnce { try manager.setNotify(true, for: .authentication) }
                self.stateQueue.async {
                    guard self.activePeripheralManager === manager, let pairing = self.pairing else { return }
                    self.handle([pairing.start()], on: manager)
                }
            } catch {
                self.log("Could not enable authentication notifications: \(error)")
                self.bluetoothManager.disconnect(manager)
            }
        }
    }

    private func endConnection(_ peripheralManager: DirectConnect_PeripheralManager) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard activePeripheralManager === peripheralManager || activePeripheralManager == nil else { return }
        writeGeneration.mutate { $0 += 1 }
        flushBackfill()
        calibration.connectionDidEnd()
        let queue = calibration
        notify { $0.sensor(self, calibrationDidChange: queue) }
        pairing?.resetForConnection()
        activePeripheralManager = nil
        connectionIdentity = nil
        authenticated = false
        glucoseRequested = false
        extraCommandSent = false
        clock = nil
        notify { $0.sensorDisconnected(self) }
    }

    // MARK: - Pairing events (stateQueue)

    private func handle(_ events: [DirectConnect_PairingEvent], on manager: DirectConnect_PeripheralManager) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        for event in events {
            switch event {
            case .writes(let writes):
                schedule(writes, on: manager)

            case .authenticated:
                didAuthenticate(on: manager)

            case .rejectedSavedKey:
                scanConfig.mutate { $0.authenticationBlocked = true }
                log("Saved pairing key was rejected; stopping reconnects")
                notify { $0.sensor(self, pairingDidFail: .keyRejected) }
                bluetoothManager.disconnect(manager)

            case .needsCleanReconnect:
                log("Sensor reports incomplete ownership; reconnecting to pair again")
                bluetoothManager.disconnect(manager)

            case .codeRejected:
                let name = connectionIdentity ?? "?"
                let searching = scanConfig.value.sensorName == nil
                if searching {
                    // While scanning, a nearby sensor that is not the user's also refuses the
                    // code. Skip it for a while and keep looking.
                    let identifier = manager.peripheral.identifier
                    scanConfig.mutate { $0.skipList.skip(identifier, now: Date()) }
                    // The watchdog does not run during a search, so nothing else would scan again
                    // when the skip ends.
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + DirectConnect_SkipList.duration + 5) { [weak self] in
                        self?.bluetoothManager.scanForPeripheral()
                    }
                }
                log("Sensor \(name) rejected the applicator code")
                let failure: DirectConnect_PairingFailure = searching ? .skippedSensor(name) : .wrongCode(name)
                notify { $0.sensor(self, pairingDidFail: failure) }
                bluetoothManager.disconnect(manager)

            case .pakeRefused:
                let name = connectionIdentity ?? "?"
                log("Sensor \(name) did not start pairing")
                notify { $0.sensor(self, pairingDidFail: .pakeRefused(name)) }
                bluetoothManager.disconnect(manager)

            case .certificateRefused:
                let name = connectionIdentity ?? "?"
                log("Sensor \(name) accepted the code but refused the certificate step")
                notify { $0.sensor(self, pairingDidFail: .certificateRefused(name)) }
                bluetoothManager.disconnect(manager)

            case .failed(let reason):
                log("Pairing failed: \(reason)")
                notify { $0.sensor(self, pairingDidFail: .protocolError(reason)) }
                bluetoothManager.disconnect(manager)
            }
        }
    }

    private func schedule(_ writes: [DirectConnect_AuthWrite], on manager: DirectConnect_PeripheralManager) {
        let generation = writeGeneration.value
        for write in writes {
            let uuid: DirectConnect_CharacteristicUUID = write.target == .control ? .authentication : .authStream
            let operation = { [weak self] in
                manager.perform { manager in
                    guard let self = self, self.writeGeneration.value == generation else { return }
                    do {
                        try manager.write(write.data, to: uuid, withResponse: write.target == .control)
                    } catch {
                        self.log("Authentication write failed: \(error)")
                    }
                }
            }
            if write.delay <= 0 {
                operation()
            } else {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + write.delay, execute: operation)
            }
        }
    }

    private func didAuthenticate(on manager: DirectConnect_PeripheralManager) {
        authenticated = true
        if scanConfig.value.sensorName == nil, let name = connectionIdentity {
            scanConfig.mutate { $0.sensorName = name }
            bluetoothManager.adoptAsActive(manager)
            notify { $0.sensor(self, didPairWith: name) }
        }
        let identifier = manager.peripheral.identifier
        scanConfig.mutate { $0.knownIdentifier = identifier }
        bluetoothManager.setKnownPeripheral(identifier)
        notify { $0.sensorDidAuthenticate(self, peripheralIdentifier: identifier) }

        manager.perform { manager in
            do {
                try Self.retryOnce { try manager.setNotify(true, for: .control) }
                self.stateQueue.async { self.requestGlucose(on: manager) }
            } catch {
                self.log("Could not enable control notifications: \(error)")
                self.bluetoothManager.disconnect(manager)
            }
        }
    }

    private func requestGlucose(on manager: DirectConnect_PeripheralManager) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard authenticated, !glucoseRequested, activePeripheralManager === manager else { return }
        // One request per connection; the sensor wakes again in about five minutes.
        glucoseRequested = true
        writeControl(DirectConnect_G7Requests.glucose, on: manager)
    }

    /// One retry for transient Bluetooth timeouts; a G7 wake is short, so a second attempt
    /// is cheaper than losing the whole five-minute cycle.
    private static func retryOnce(_ operation: () throws -> Void) throws {
        do {
            try operation()
        } catch {
            try operation()
        }
    }

    private func writeControl(_ data: Data, on manager: DirectConnect_PeripheralManager) {
        let generation = writeGeneration.value
        manager.perform { manager in
            guard self.writeGeneration.value == generation else { return }
            do {
                try Self.retryOnce { try manager.write(data, to: .control, withResponse: true) }
            } catch {
                self.log("Control write \(data.dcHex) failed: \(error)")
            }
        }
    }

    // MARK: - Incoming data (stateQueue)

    private func receive(_ value: Data, on characteristic: DirectConnect_CharacteristicUUID, from manager: DirectConnect_PeripheralManager) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard activePeripheralManager === manager else { return }

        switch characteristic {
        case .authentication:
            guard let pairing = pairing else { return }
            handle(pairing.receiveControl(value), on: manager)
        case .authStream:
            guard let pairing = pairing else { return }
            handle(pairing.receiveStream(value), on: manager)
        case .control:
            handleControl(value, on: manager)
        case .backfill:
            if let message = DirectConnect_G7BackfillMessage(data: value) {
                backfillBuffer.append(message)
            }
        case .communication:
            break
        }
    }

    private func handleControl(_ value: Data, on manager: DirectConnect_PeripheralManager) {
        guard let first = value.first, let opcode = DirectConnect_G7Opcode(rawValue: first) else {
            log("Control RX \(value.dcHex)")
            return
        }

        switch opcode {
        case .glucose:
            guard let message = DirectConnect_G7GlucoseMessage(data: value) else {
                log("Unparseable glucose packet \(value.dcHex)")
                return
            }
            let receivedAt = Date()
            if message.responseStatus == 0 {
                // Clock reference for calibration timing, as xDrip4iOS establishes it.
                clock = DirectConnect_ClockReference(transmitterTime: message.messageTimestamp,
                                                     referenceDate: receivedAt.addingTimeInterval(-TimeInterval(message.age)))
            }
            notify { $0.sensor(self, didRead: message, receivedAt: receivedAt) }
            if message.responseStatus == 0 {
                manager.perform { manager in
                    try? manager.setNotify(true, for: .backfill)
                    self.stateQueue.async { self.sendExtraCommand(on: manager) }
                }
            }

        case .extendedVersion:
            if let version = DirectConnect_G7ExtendedVersion(data: value) {
                needsExtendedVersion = false
                notify { $0.sensor(self, didReceive: version) }
            }

        case .transmitterVersion:
            if let info = DirectConnect_G7VersionInfo(data: value) {
                needsVersionInfo = false
                notify { $0.sensor(self, didReceive: info) }
            }

        case .batteryStatus:
            if let battery = DirectConnect_G7BatteryStatus(data: value) {
                batteryLastRead = Date()
                notify { $0.sensor(self, didReceive: battery) }
            }

        case .calibrate:
            log("Calibration response \(value.dcHex)")
            let followUp = calibration.handleCommandResponse(value)
            let queue = calibration
            notify { $0.sensor(self, calibrationDidChange: queue) }
            if let followUp = followUp {
                writeControl(followUp, on: manager)
            }

        case .calibrationBounds:
            log("Calibration bounds \(value.dcHex)")
            if !calibration.handleBounds(value) {
                log("Calibration bounds ignored: they do not describe the calibration being processed")
            }
            let queue = calibration
            notify { $0.sensor(self, calibrationDidChange: queue) }

        case .backfillFinished:
            flushBackfill()

        default:
            log("Control RX \(value.dcHex)")
        }
    }

    /// At most one extra command per wake so metadata never delays the next glucose cycle.
    /// Priority: calibration → session length → firmware → battery.
    private func sendExtraCommand(on manager: DirectConnect_PeripheralManager) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard !extraCommandSent, activePeripheralManager === manager else { return }

        let command: Data?
        let calibrationBefore = calibration
        let calibrationCommand = calibration.nextCommand(clock: clock, now: Date())
        if calibration != calibrationBefore {
            // Also covers changes with no command to send (dropped as stale, or gave up waiting),
            // which earlier left the screen showing the old status.
            let queue = calibration
            notify { $0.sensor(self, calibrationDidChange: queue) }
        }
        if let calibrationCommand = calibrationCommand {
            command = calibrationCommand
            log("Calibration TX \(calibrationCommand.dcHex) (status \(calibration.status))")
        } else if needsExtendedVersion {
            command = DirectConnect_G7Requests.extendedVersion
        } else if needsVersionInfo {
            command = DirectConnect_G7Requests.version
        } else if batteryLastRead.map({ Date().timeIntervalSince($0) >= Self.batteryReadInterval }) ?? true {
            command = DirectConnect_G7Requests.battery
        } else {
            command = nil
        }

        if let command = command {
            extraCommandSent = true
            writeControl(command, on: manager)
        }
    }

    private func flushBackfill() {
        guard !backfillBuffer.isEmpty else { return }
        let backfill = backfillBuffer
        backfillBuffer = []
        notify { $0.sensor(self, didReadBackfill: backfill) }
    }
}

// MARK: - Bluetooth manager events (called on the Bluetooth queue)

extension DirectConnect_G7Sensor: DirectConnect_BluetoothManagerDelegate {
    func bluetoothManager(_ manager: DirectConnect_BluetoothManager, shouldConnectPeripheral peripheral: CBPeripheral) -> DirectConnect_ConnectDecision {
        let config = scanConfig.value
        if config.skipList.isSkipped(peripheral.identifier, now: Date()) {
            return .ignore
        }
        if config.sensorName == nil,
           DirectConnect_isExcluded(peripheralName: peripheral.name, identifier: peripheral.identifier, excluded: config.excluded) {
            return .ignore
        }
        if config.sensorName == nil && !config.hasPairingCode {
            return .ignore
        }
        if let known = config.knownIdentifier, peripheral.identifier == known, config.sensorName != nil {
            return config.authenticationBlocked ? .ignore : .makeActive
        }
        let decision = DirectConnect_shouldConnect(peripheralName: peripheral.name,
                                                   followedName: config.sensorName,
                                                   excludedName: config.excludedName,
                                                   expectedType: config.sensorType)
        // After a refused saved key, do not keep reconnecting and disturbing whoever owns it.
        if decision == .makeActive && config.authenticationBlocked {
            return .ignore
        }
        return decision
    }

    func bluetoothManager(_ manager: DirectConnect_BluetoothManager, readied peripheralManager: DirectConnect_PeripheralManager) -> Bool {
        let config = scanConfig.value
        let peripheralName = peripheralManager.peripheral.name
        // The followed sensor's stored DX name is the authentication identity, even if iOS
        // now reports the longer "Dexcomxx" name.
        guard let identity = config.sensorName ?? peripheralName else { return false }
        let isFollowed = config.sensorName != nil

        notify { $0.sensorDidConnect(self, name: identity) }
        stateQueue.async { self.beginConnection(peripheralManager, identity: identity) }
        return isFollowed
    }

    func bluetoothManager(_ manager: DirectConnect_BluetoothManager, readyingFailed peripheralManager: DirectConnect_PeripheralManager, with error: Error) {
        log("Bluetooth error: \(error.localizedDescription)")
    }

    func bluetoothManager(_ manager: DirectConnect_BluetoothManager, peripheralManager: DirectConnect_PeripheralManager, didReceive value: Data, on characteristic: DirectConnect_CharacteristicUUID) {
        stateQueue.async { self.receive(value, on: characteristic, from: peripheralManager) }
    }

    func bluetoothManager(_ manager: DirectConnect_BluetoothManager, peripheralManager: DirectConnect_PeripheralManager, didReadRSSI rssi: Int) {
        notify { $0.sensor(self, didReadRSSI: rssi) }
    }

    func bluetoothManagerScanningStatusDidChange(_ manager: DirectConnect_BluetoothManager) {
        notify { $0.sensorConnectionStatusDidUpdate(self) }
    }

    func peripheralDidDisconnect(_ manager: DirectConnect_BluetoothManager, peripheralManager: DirectConnect_PeripheralManager, wasRemoteDisconnect: Bool) {
        stateQueue.async { self.endConnection(peripheralManager) }
        notify { $0.sensorConnectionStatusDidUpdate(self) }
    }
}
