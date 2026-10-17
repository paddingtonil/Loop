//
//  DirectConnect_G7CGMManager.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — The CGM manager Loop talks to for directly connected G7-family sensors.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Adapted from LoopKit G7SensorKit G7CGMManager (MIT, © 2022 LoopKit Authors).
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import Foundation
import HealthKit
import LoopKit

protocol DirectConnect_StateObserver: AnyObject {
    func directConnectStateDidUpdate(_ state: DirectConnect_G7State)
    func directConnectConnectionStatusDidChange()
}

enum DirectConnect_LifecycleState: Equatable {
    case notPaired
    case searching
    case warmup
    case ok
    case failed
    case gracePeriod
    case expired
}

final class DirectConnect_G7CGMManager: CGMManager {
    static let pluginIdentifier = "PowerPackDirectConnectG7"
    static let displayTitle = NSLocalizedString("Dexcom G7/ONE+ using DirectConnect ⚡️", comment: "DirectConnect CGM display title")
    /// Title in the Add CGM action sheet. No bolt: with the purple title color that sheet draws
    /// the emoji as a missing-glyph box.
    static let pickerTitle = NSLocalizedString("Dexcom G7/ONE+ using DirectConnect", comment: "DirectConnect title in the Add CGM list")

    /// How long to keep following a sensor after a suspected session end before scanning.
    static let suspectedSessionEndGracePeriod: TimeInterval = 15 * 60
    /// A current G7 reading is at most a few minutes old when delivered. Ten minutes or more means
    /// the sensor is returning a cached reading instead of live data.
    static let staleReadingAge: UInt16 = 600
    private static let displayUnitKey = "com.loopkit.Loop.directConnect.displayUnitIsMmol"

    private let log = DiagnosticLog(category: "DirectConnect.CGMManager")

    var localizedTitle: String { Self.displayTitle }
    let isOnboarded = true
    let providesBLEHeartbeat = true
    var managedDataInterval: TimeInterval? { .hours(3) }

    let sensor: DirectConnect_G7Sensor
    private let keyStore: DirectConnect_KeyStoring
    private let lockedState: Locked<DirectConnect_G7State>
    private let observers = WeakSynchronizedSet<DirectConnect_StateObserver>()
    private let delegate = WeakSynchronizedDelegate<CGMManagerDelegate>()
    private var monitorTimer: DispatchSourceTimer?
    private let lastWatchdogKick = Locked<Date?>(nil)
    private let lockedRSSI = Locked<Int?>(nil)

    // MARK: - Init

    convenience init() {
        self.init(state: DirectConnect_G7State(), keyStore: DirectConnect_KeychainKeyStore())
    }

    convenience init?(rawState: RawStateValue) {
        self.init(state: DirectConnect_G7State(rawValue: rawState), keyStore: DirectConnect_KeychainKeyStore())
    }

    init(state: DirectConnect_G7State, keyStore: DirectConnect_KeyStoring) {
        self.keyStore = keyStore
        lockedState = Locked(state)
        sensor = DirectConnect_G7Sensor(sensorName: state.sensorID,
                                        sensorType: state.sensorType,
                                        pairingCode: state.pairingCode,
                                        excludedName: state.previousSensorID,
                                        excluded: state.sensorID == nil ? DirectConnect_previousSensorToExclude(name: state.previousSensorID, code: state.previousPairingCode, identifier: state.previousPeripheralIdentifier, newCode: state.pairingCode ?? "") : nil,
                                        knownPeripheralIdentifier: state.peripheralIdentifier.flatMap(UUID.init(uuidString:)),
                                        keyStore: keyStore)
        sensor.restoreSessionInfo(calibration: state.calibration,
                                  needsExtendedVersion: state.extendedVersion == nil,
                                  needsVersionInfo: state.versionInfo == nil,
                                  batteryLastRead: state.batteryReadAt)
        sensor.delegate = self
        DirectConnect_FeatureFlags.isActiveCGM = true
        restorePendingSuspectedSessionEnd()
        startMonitor()
    }

    deinit {
        monitorTimer?.cancel()
    }

    var rawState: RawStateValue { state.rawValue }

    // MARK: - State

    var state: DirectConnect_G7State { lockedState.value }

    @discardableResult
    private func mutateState(_ changes: (inout DirectConnect_G7State) -> Void) -> DirectConnect_G7State {
        var oldValue: DirectConnect_G7State!
        let newValue = lockedState.mutate { state in
            oldValue = state
            changes(&state)
        }
        if oldValue != newValue {
            delegate.notify { delegate in
                delegate?.cgmManagerDidUpdateState(self)
                delegate?.cgmManager(self, didUpdate: self.cgmManagerStatus)
            }
            observers.forEach { $0.directConnectStateDidUpdate(newValue) }
        }
        return newValue
    }

    func addStateObserver(_ observer: DirectConnect_StateObserver, queue: DispatchQueue) {
        observers.insert(observer, queue: queue)
    }

    func removeStateObserver(_ observer: DirectConnect_StateObserver) {
        observers.removeElement(observer)
    }

    // MARK: - CGMManager

    var cgmManagerDelegate: CGMManagerDelegate? {
        get { delegate.delegate }
        set { delegate.delegate = newValue }
    }

    var delegateQueue: DispatchQueue! {
        get { delegate.queue }
        set { delegate.queue = newValue }
    }

    var shouldSyncToRemoteService: Bool { state.uploadReadings }

    var glucoseDisplay: GlucoseDisplayable? { state.latestReading }

    var cgmManagerStatus: CGMManagerStatus {
        let lifecycle = lifecycleState
        let valid = state.sensorID != nil && lifecycle != .expired && lifecycle != .failed
        return CGMManagerStatus(hasValidSensorSession: valid, lastCommunicationDate: state.latestConnect, device: device)
    }

    func fetchNewDataIfNeeded(_ completion: @escaping (CGMReadingResult) -> Void) {
        sensor.resumeScanning()
        completion(.noData)
    }

    func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier, completion: @escaping (Error?) -> Void) {
        completion(nil)
    }

    func getSoundBaseURL() -> URL? { nil }
    func getSounds() -> [Alert.Sound] { [] }

    func delete(completion: @escaping () -> Void) {
        if let sensorID = state.sensorID, let code = state.pairingCode {
            // Keep this one sensor's key and code so DirectConnect can be added back to it; the
            // code is printed only on the applicator, which is often discarded by then.
            DirectConnect_LastSensorStore.remember(
                DirectConnect_LastSensor(sensorID: sensorID, sensorType: state.sensorType, pairingCode: code, peripheralIdentifier: state.peripheralIdentifier),
                keyStore: keyStore)
            logDeviceCommunication("Deleted; remembering \(sensorID) for reconnect", type: .connection)
        } else if let sensorID = state.sensorID {
            keyStore.delete(sensor: sensorID)
        }
        monitorTimer?.cancel()
        // Fully off: a plain disconnect re-scans 2 s later, and this manager can outlive deletion.
        sensor.shutDown()
        for kind in DirectConnect_AlarmKind.allCases {
            retract(kind)
        }
        DirectConnect_FeatureFlags.isActiveCGM = false
        notifyDelegateOfDeletion(completion: completion)
    }

    var debugDescription: String {
        [
            "## DirectConnect_G7CGMManager",
            "sensorID: \(String(describing: state.sensorID))",
            "sensorType: \(state.sensorType.rawValue)",
            "activatedAt: \(String(describing: state.activatedAt))",
            "sessionLength: \(String(describing: state.knownSessionLength))",
            "latestReading: \(String(describing: state.latestReading))",
            "latestReadingTimestamp: \(String(describing: state.latestReadingTimestamp))",
            "latestConnect: \(String(describing: state.latestConnect))",
            "pairingFailure: \(String(describing: state.pairingFailure))",
            "calibration: \(state.calibration.status)",
            "hasSavedKey: \(state.sensorID.map { keyStore.key(sensor: $0, slot: 0x02) != nil } ?? false)",
        ].joined(separator: "\n")
    }

    // MARK: - Lifecycle values

    /// Lifetime for progress display. Expiry dates below stay nil until the length is known, so an
    /// estimate can never end a session early.
    var lifetime: TimeInterval { state.estimatedSessionLength - DirectConnect_SensorLifetime.gracePeriod }
    var warmupDuration: TimeInterval { state.warmupDuration }
    var sensorExpiresAt: Date? {
        guard let length = state.knownSessionLength else { return nil }
        return state.activatedAt?.addingTimeInterval(length - DirectConnect_SensorLifetime.gracePeriod)
    }
    var sensorEndsAt: Date? {
        guard let length = state.knownSessionLength else { return nil }
        return state.activatedAt?.addingTimeInterval(length)
    }
    var sensorFinishesWarmupAt: Date? { state.activatedAt?.addingTimeInterval(warmupDuration) }
    var isScanning: Bool { sensor.isScanning }
    var isConnected: Bool { sensor.isConnected }
    var lastRSSI: Int? { lockedRSSI.value }
    var hasSavedKey: Bool { state.sensorID.map { keyStore.key(sensor: $0, slot: 0x02) != nil } ?? false }

    var lifecycleState: DirectConnect_LifecycleState {
        if state.pairingCode == nil { return .notPaired }
        if state.sensorID == nil { return .searching }
        if let ends = sensorEndsAt, ends.timeIntervalSinceNow < 0 { return .expired }
        if let algorithm = state.latestReading?.algorithmState {
            if algorithm.isInWarmup { return .warmup }
            if algorithm.sensorFailed { return .failed }
            if algorithm.isSessionEnded { return .expired }
        }
        if let expires = sensorExpiresAt, expires.timeIntervalSinceNow < 0 { return .gracePeriod }
        return .ok
    }

    private var device: HKDevice? {
        HKDevice(name: state.sensorID ?? "Unknown",
                 manufacturer: "Dexcom",
                 model: state.sensorType.displayName,
                 hardwareVersion: state.extendedVersion.map { String($0.hardwareVersion) },
                 firmwareVersion: state.versionInfo?.firmwareVersion,
                 softwareVersion: "PowerPack DirectConnect",
                 localIdentifier: nil,
                 udiDeviceIdentifier: nil)
    }

    // MARK: - User actions

    /// Starts pairing a new sensor with the code from its applicator.
    /// - Parameter remembered: the sensor kept from a deleted DirectConnect, used as the previous
    ///   sensor when this manager has none.
    func configure(type: DirectConnect_SensorType, pairingCode: String, remembered: DirectConnect_LastSensor? = nil) {
        let previous: (name: String?, code: String?, identifier: String?)
        if let name = state.sensorID {
            previous = (name, state.pairingCode, state.peripheralIdentifier)
        } else if let name = state.previousSensorID {
            previous = (name, state.previousPairingCode, state.previousPeripheralIdentifier)
        } else {
            previous = (remembered?.sensorID, remembered?.pairingCode, remembered?.peripheralIdentifier)
        }
        let excluded = DirectConnect_previousSensorToExclude(name: previous.name, code: previous.code, identifier: previous.identifier, newCode: pairingCode)
        mutateState { state in
            state.previousSensorID = previous.name
            state.previousPairingCode = previous.code
            state.previousPeripheralIdentifier = previous.identifier
            state.sensorID = nil
            state.sensorType = type
            state.pairingCode = pairingCode
            state.activatedAt = nil
            state.extendedVersion = nil
            state.latestReading = nil
            state.latestReadingTimestamp = nil
            state.battery = nil
            state.batteryReadAt = nil
            state.versionInfo = nil
            state.calibration = DirectConnect_CalibrationQueue()
            state.pairingFailure = nil
            state.pairingNotice = nil
            state.recentReadings = []
            state.suspectedSessionEndAt = nil
        }
        logDeviceCommunication("Scanning for new \(type.displayName) sensor", type: .connection)
        if let excluded = excluded {
            logDeviceCommunication("Not connecting to previous sensor \(excluded.name) (different code)", type: .connection)
        }
        sensor.scanForNewSensor(type: type, pairingCode: pairingCode, excludedName: previous.name, excluded: excluded)
    }

    /// Pairs the current sensor again with a new or corrected code.
    func repair(pairingCode: String) {
        mutateState { state in
            state.pairingCode = pairingCode
            state.pairingFailure = nil
            state.pairingNotice = nil
        }
        logDeviceCommunication("Re-pairing with new code", type: .connection)
        sensor.repair(pairingCode: pairingCode)
    }

    func setUploadReadings(_ enabled: Bool) {
        mutateState { $0.uploadReadings = enabled }
    }

    /// Queues a fingerstick calibration (mg/dL). It is sent at the next sensor connection.
    func calibrate(glucose: Double, at date: Date = Date()) -> Bool {
        sensor.enqueueCalibration(glucose: glucose, date: date)
    }

    func refreshRSSI() {
        sensor.readRSSI()
    }

    /// Settings screens record the user's unit so alarm text matches what the user sees.
    static func setDisplayUnit(_ unit: HKUnit) {
        UserDefaults.standard.set(unit == .millimolesPerLiter, forKey: displayUnitKey)
    }

    private var displayUnit: HKUnit {
        UserDefaults.standard.bool(forKey: Self.displayUnitKey) ? .millimolesPerLiter : .milligramsPerDeciliter
    }

    // MARK: - Alarms

    private func apply(_ actions: [DirectConnect_AlarmAction]) {
        for action in actions {
            switch action {
            case let .issue(kind, value):
                let alert = DirectConnect_GlucoseAlarms.alert(for: kind, value: value, managerIdentifier: pluginIdentifier, unit: displayUnit)
                logDeviceCommunication("Alarm: \(kind.rawValue)", type: .receive)
                delegate.notify { $0?.issueAlert(alert) }
            case let .retract(kind):
                retract(kind)
            }
        }
    }

    private func retract(_ kind: DirectConnect_AlarmKind) {
        let identifier = Alert.Identifier(managerIdentifier: pluginIdentifier, alertIdentifier: kind.rawValue)
        delegate.notify { $0?.retractAlert(identifier: identifier) }
    }

    private func evaluateReadingAlarms(mgdl: Double, trendRate: Double?, at date: Date) {
        let settings = DirectConnect_AlarmSettings.load(from: .standard)
        var actions = [DirectConnect_AlarmAction]()
        mutateState { state in
            actions = DirectConnect_GlucoseAlarms.evaluate(reading: DirectConnect_AlarmReading(date: date, mgdl: mgdl, trendRate: trendRate),
                                                           settings: settings, state: &state.alarmState)
        }
        apply(actions)
    }

    /// Runs every minute: signal loss and sensor-lifetime warnings do not depend on a reading.
    private func evaluateTimedAlarms() {
        guard state.sensorID != nil else { return }
        let settings = DirectConnect_AlarmSettings.load(from: .standard)
        let lifecycle = lifecycleState
        let expiresAt = sensorExpiresAt
        var actions = [DirectConnect_AlarmAction]()
        mutateState { state in
            actions += DirectConnect_GlucoseAlarms.evaluateSignal(lastReading: state.latestReadingTimestamp, now: Date(), settings: settings, state: &state.alarmState)
            actions += DirectConnect_GlucoseAlarms.evaluateLifetime(expiresAt: expiresAt,
                                                                    endedOrFailed: lifecycle == .expired || lifecycle == .failed,
                                                                    now: Date(), settings: settings, state: &state.alarmState)
        }
        apply(actions)
    }

    private func startMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            self?.evaluateTimedAlarms()
            self?.runWatchdog()
            self?.sensor.expireCalibrationIfOverdue()
        }
        timer.resume()
        monitorTimer = timer
    }

    // MARK: - Keeping the sensor

    /// True when Loop has had to take the sensor back more than once in 6 hours, which means
    /// another app (in practice the Dexcom app) is still paired with it.
    var repeatedTakeover: Bool {
        DirectConnect_RecoveryPolicy.isRepeatedTakeover(history: state.takeBackHistory, now: Date())
    }

    /// Re-pairs with the stored applicator code so DirectConnect owns the sensor again.
    private func takeBack(reason: String) {
        guard let code = state.pairingCode else { return }
        let now = Date()
        let history = DirectConnect_RecoveryPolicy.recording(now, in: state.takeBackHistory)
        let repeated = DirectConnect_RecoveryPolicy.isRepeatedTakeover(history: history, now: now)
        logDeviceCommunication("Taking the sensor back (\(reason))", type: .connection)
        DirectConnect_HealthLog.shared.record(.reclaimed, at: now)
        mutateState { state in
            state.takeBackHistory = history
            state.staleStreak = 0
            state.pairingFailure = repeated
                ? NSLocalizedString("Another app keeps taking this sensor, which costs readings each time. This happens when the Dexcom app is still installed with this sensor, even if you never open it. Delete the Dexcom app (or remove the sensor in it). Loop takes the sensor back automatically.", comment: "DirectConnect repeated takeover")
                : NSLocalizedString("Another app (most likely the Dexcom app) paired with this sensor. Loop is taking it back automatically at the next sensor wake.", comment: "DirectConnect single takeover")
        }
        sensor.repair(pairingCode: code)
    }

    /// Restarts the pending Bluetooth connection when the sensor has been silent for two wakes.
    private func runWatchdog() {
        guard state.sensorID != nil, state.pairingCode != nil else { return }
        let now = Date()
        guard DirectConnect_RecoveryPolicy.watchdogShouldKick(lastConnect: state.latestConnect, lastKick: lastWatchdogKick.value, now: now) else { return }
        lastWatchdogKick.value = now
        logDeviceCommunication("No sensor connection since \(state.latestConnect.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium) } ?? "launch"); restarting the Bluetooth connection", type: .connection)
        if sensor.authenticationBlocked {
            takeBack(reason: "connections stopped after a refused key")
        } else {
            sensor.restartConnection()
        }
    }

    // MARK: - Suspected session end

    private func scheduleScanAfterSuspectedSessionEnd() {
        guard state.suspectedSessionEndAt == nil else { return }
        let start = Date()
        mutateState { $0.suspectedSessionEndAt = start }
        scheduleGraceExpiry(start: start, after: Self.suspectedSessionEndGracePeriod)
    }

    private func scheduleGraceExpiry(start: Date, after delay: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(wallDeadline: .now() + delay) { [weak self] in
            guard let self = self, self.state.suspectedSessionEndAt == start else { return }
            self.logDeviceCommunication("No sensor communication since suspected session end", type: .connection)
            self.mutateState { $0.suspectedSessionEndAt = nil }
            self.sensor.resumeScanning()
        }
    }

    private func cancelSuspectedSessionEnd() {
        guard state.suspectedSessionEndAt != nil else { return }
        mutateState { $0.suspectedSessionEndAt = nil }
    }

    private func restorePendingSuspectedSessionEnd() {
        guard let start = state.suspectedSessionEndAt else { return }
        let remaining = start.addingTimeInterval(Self.suspectedSessionEndGracePeriod).timeIntervalSinceNow
        scheduleGraceExpiry(start: start, after: max(1, remaining))
    }

    // MARK: - Helpers

    func logDeviceCommunication(_ message: String, type: DeviceLogEntryType = .send) {
        DirectConnect_Diagnostics.shared.record(message)
        cgmManagerDelegate?.deviceManager(self, logEventForDeviceIdentifier: state.sensorID, type: type, message: message, completion: nil)
    }

    private func updateDelegate(with result: CGMReadingResult) {
        delegateQueue?.async {
            self.cgmManagerDelegate?.cgmManager(self, hasNew: result)
        }
    }

    private func syncIdentifier(timestamp: UInt32) -> String {
        guard let activatedAt = state.activatedAt, let sensorID = state.sensorID else { return "invalid" }
        return "\(activatedAt.timeIntervalSince1970.hours) \(sensorID) \(timestamp)"
    }

    private func clampedQuantity(_ glucose: UInt16) -> HKQuantity {
        let value = min(max(glucose, DirectConnect_GlucoseLimits.minimum), DirectConnect_GlucoseLimits.maximum)
        return HKQuantity(unit: .milligramsPerDeciliter, doubleValue: Double(value))
    }
}

// MARK: - Sensor events

extension DirectConnect_G7CGMManager: DirectConnect_G7SensorDelegate {
    func sensorDidConnect(_ sensor: DirectConnect_G7Sensor, name: String) {
        mutateState { $0.latestConnect = Date() }
        logDeviceCommunication("Connected to \(name)", type: .connection)
    }

    func sensorDisconnected(_ sensor: DirectConnect_G7Sensor) {
        logDeviceCommunication("Disconnected", type: .connection)
    }

    func sensor(_ sensor: DirectConnect_G7Sensor, didPairWith name: String) {
        DirectConnect_LastSensorStore.forget(unless: name, keyStore: keyStore)
        if let previous = state.previousSensorID, previous != name {
            // Only the current sensor's key is kept.
            keyStore.delete(sensor: previous)
        }
        mutateState { state in
            state.sensorID = name
            state.pairingFailure = nil
            state.pairingNotice = nil
        }
        logDeviceCommunication("Paired with \(name)", type: .connection)
    }

    func sensorDidAuthenticate(_ sensor: DirectConnect_G7Sensor, peripheralIdentifier: UUID) {
        let identifier = peripheralIdentifier.uuidString
        if state.peripheralIdentifier != identifier {
            mutateState { $0.peripheralIdentifier = identifier }
        }
    }

    func sensor(_ sensor: DirectConnect_G7Sensor, didRead message: DirectConnect_G7GlucoseMessage, receivedAt: Date) {
        cancelSuspectedSessionEnd()
        logDeviceCommunication("Glucose \(message.data.dcHex)", type: .receive)

        guard message.responseStatus == 0 else {
            DirectConnect_HealthLog.shared.record(.stale, at: receivedAt)
            // A non-zero frame repeats an old cached value. Logged only: storing it would show its
            // stale algorithm state (for example "failed") as the sensor's current state.
            logDeviceCommunication("Ignored non-current glucose frame (status \(message.responseStatus), state \(message.algorithmState))", type: .receive)
            updateDelegate(with: .noData)
            evaluateTimedAlarms()
            return
        }

        if message.age >= Self.staleReadingAge {
            // The sensor only hands back an old cached reading. Seen when another app (usually the
            // Dexcom app, which reconnects in the background) has paired into the same slot since
            // Loop did, and also when a sensor fails. The frame is not stored, so its algorithm
            // state cannot mark a working sensor as failed.
            let staleSince = receivedAt.addingTimeInterval(-TimeInterval(message.age))
            let time = DateFormatter.localizedString(from: staleSince, dateStyle: .none, timeStyle: .short)
            logDeviceCommunication("Stale reading: \(Int(message.age))s old, state \(message.algorithmState)", type: .error)
            DirectConnect_HealthLog.shared.record(.stale, at: receivedAt)
            var streak = 0
            mutateState { state in
                state.staleStreak += 1
                streak = state.staleStreak
                state.pairingFailure = String(format: NSLocalizedString("The sensor is sending Loop only an old reading from %@. This happens when another app, usually the Dexcom app (even unopened, in the background), has paired with this sensor after Loop did. Delete the Dexcom app or remove the sensor from it, then tap Re-enter Pairing Code. If no other app uses this sensor, the sensor may have failed.", comment: "DirectConnect stale reading explanation (1: time)"), time)
            }
            updateDelegate(with: .noData)
            evaluateTimedAlarms()
            if DirectConnect_RecoveryPolicy.staleStreakNeedsReclaim(streak),
               DirectConnect_RecoveryPolicy.mayReclaim(history: state.takeBackHistory, now: Date()) {
                takeBack(reason: "sensor sent \(streak) cached readings in a row")
            }
            return
        }

        let activation = receivedAt.addingTimeInterval(-TimeInterval(message.messageTimestamp))
        let isNewSession = state.activatedAt.map { abs($0.timeIntervalSince(activation)) > 3600 } ?? true
        let readingDate = activation.addingTimeInterval(TimeInterval(message.glucoseTimestamp))

        guard message != state.latestReading else {
            updateDelegate(with: .noData)
            return
        }
        DirectConnect_HealthLog.shared.record(message.hasReliableGlucose && message.glucose != nil ? .reading : .withheld, at: receivedAt)

        mutateState { state in
            state.pairingFailure = nil
            state.staleStreak = 0
            if isNewSession {
                state.activatedAt = activation
                state.alarmState = DirectConnect_AlarmState()
                state.recentReadings = []
            }
            state.latestReading = message
            state.latestReadingTimestamp = readingDate
        }

        if isNewSession, let sensorID = state.sensorID {
            let event = PersistedCgmEvent(date: activation,
                                          type: .sensorStart,
                                          deviceIdentifier: sensorID,
                                          expectedLifetime: state.estimatedSessionLength,
                                          warmupPeriod: warmupDuration)
            delegate.notify { $0?.cgmManager(self, hasNew: [event]) }
        }

        if message.algorithmState.sensorFailed || message.algorithmState.isSessionEnded {
            logDeviceCommunication("Sensor reports \(message.algorithmState)", type: .receive)
            updateDelegate(with: .noData)
            evaluateTimedAlarms()
            return
        }

        if let ends = sensorEndsAt, readingDate > ends {
            logDeviceCommunication("Reading after sensor end; ignored", type: .receive)
            updateDelegate(with: .noData)
            evaluateTimedAlarms()
            return
        }

        guard let glucose = message.glucose else {
            updateDelegate(with: .noData)
            return
        }

        guard message.hasReliableGlucose else {
            updateDelegate(with: .error(DirectConnect_ReadingError.unreliable(message.algorithmState)))
            return
        }

        var stuck = false
        mutateState { stuck = $0.recordReadingAndCheckStuck(Double(glucose)) }
        guard !stuck else {
            logDeviceCommunication("Six identical readings (\(glucose)); ignored as a stalled sensor", type: .error)
            updateDelegate(with: .noData)
            return
        }

        updateDelegate(with: .newData([
            NewGlucoseSample(date: readingDate,
                             quantity: clampedQuantity(glucose),
                             condition: message.condition,
                             trend: message.trendType,
                             trendRate: message.trendRate,
                             isDisplayOnly: message.glucoseIsDisplayOnly,
                             wasUserEntered: message.glucoseIsDisplayOnly,
                             syncIdentifier: syncIdentifier(timestamp: message.glucoseTimestamp),
                             device: device)
        ]))

        evaluateReadingAlarms(mgdl: Double(glucose), trendRate: message.trend, at: readingDate)
        evaluateTimedAlarms()
    }

    func sensor(_ sensor: DirectConnect_G7Sensor, didReadBackfill backfill: [DirectConnect_G7BackfillMessage]) {
        cancelSuspectedSessionEnd()
        guard let activation = state.activatedAt else { return }
        let ends = sensorEndsAt
        let samples = backfill.compactMap { entry -> NewGlucoseSample? in
            guard let glucose = entry.glucose, entry.hasReliableGlucose else { return nil }
            let date = activation.addingTimeInterval(TimeInterval(entry.timestamp))
            if let ends = ends, date > ends { return nil }
            return NewGlucoseSample(date: date,
                                    quantity: clampedQuantity(glucose),
                                    condition: entry.condition,
                                    trend: entry.trendType,
                                    trendRate: entry.trend.map { HKQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: $0) },
                                    isDisplayOnly: entry.glucoseIsDisplayOnly,
                                    wasUserEntered: entry.glucoseIsDisplayOnly,
                                    syncIdentifier: syncIdentifier(timestamp: entry.timestamp),
                                    device: device)
        }
        logDeviceCommunication("Backfill: \(samples.count) of \(backfill.count) readings usable", type: .receive)
        if !samples.isEmpty {
            updateDelegate(with: .newData(samples))
        }
    }

    func sensor(_ sensor: DirectConnect_G7Sensor, didReceive extendedVersion: DirectConnect_G7ExtendedVersion) {
        logDeviceCommunication("Session length \(extendedVersion.sessionLength / 86400) days, warmup \(extendedVersion.warmupDuration / 60) min", type: .receive)
        mutateState { $0.extendedVersion = extendedVersion }
    }

    func sensor(_ sensor: DirectConnect_G7Sensor, didReceive battery: DirectConnect_G7BatteryStatus) {
        mutateState { state in
            state.battery = battery
            state.batteryReadAt = Date()
        }
    }

    func sensor(_ sensor: DirectConnect_G7Sensor, didReceive versionInfo: DirectConnect_G7VersionInfo) {
        logDeviceCommunication("Firmware \(versionInfo.firmwareVersion)", type: .receive)
        mutateState { $0.versionInfo = versionInfo }
    }

    func sensor(_ sensor: DirectConnect_G7Sensor, pairingDidFail failure: DirectConnect_PairingFailure) {
        logDeviceCommunication(failure.message, type: .error)
        DirectConnect_HealthLog.shared.record(.pairingFailed)
        if failure == .keyRejected, state.pairingCode != nil {
            // DirectConnect replaces the Dexcom app: a refused key means another app paired after
            // Loop, so Loop takes the sensor back instead of stopping.
            takeBack(reason: "saved key refused")
            return
        }
        mutateState { state in
            // The latest event replaces the earlier one, so a red problem and a status line never both show.
            if failure.isNotice {
                state.pairingNotice = failure.message
                state.pairingFailure = nil
            } else {
                state.pairingFailure = failure.message
                state.pairingNotice = nil
            }
        }
    }

    func sensor(_ sensor: DirectConnect_G7Sensor, calibrationDidChange queue: DirectConnect_CalibrationQueue) {
        mutateState { $0.calibration = queue }
    }

    func sensor(_ sensor: DirectConnect_G7Sensor, log message: String) {
        logDeviceCommunication(message, type: .connection)
    }

    func sensor(_ sensor: DirectConnect_G7Sensor, didReadRSSI rssi: Int) {
        lockedRSSI.value = rssi
        observers.forEach { $0.directConnectConnectionStatusDidChange() }
    }

    func sensorConnectionStatusDidUpdate(_ sensor: DirectConnect_G7Sensor) {
        observers.forEach { $0.directConnectConnectionStatusDidChange() }
    }
}

// MARK: - Supporting types

enum DirectConnect_ReadingError: LocalizedError {
    case unreliable(DirectConnect_AlgorithmState)

    var errorDescription: String? {
        NSLocalizedString("Glucose data is unavailable", comment: "DirectConnect unreliable reading error")
    }

    var failureReason: String? {
        switch self {
        case .unreliable(let state): return state.localizedDescription
        }
    }
}

extension DirectConnect_G7GlucoseMessage: GlucoseDisplayable {
    var isStateValid: Bool { hasReliableGlucose }

    var trendRate: HKQuantity? {
        trend.map { HKQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: $0) }
    }

    var isLocal: Bool { true }

    var glucoseRangeCategory: GlucoseRangeCategory? {
        guard let glucose = glucose else { return nil }
        if glucose < DirectConnect_GlucoseLimits.minimum { return .belowRange }
        if glucose > DirectConnect_GlucoseLimits.maximum { return .aboveRange }
        return nil
    }
}
