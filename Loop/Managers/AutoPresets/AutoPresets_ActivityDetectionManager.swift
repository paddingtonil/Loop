//
//  AutoPresets_ActivityDetectionManager.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  AutoPresets — CoreMotion-based activity detection for auto-preset activation.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import CoreMotion
import Foundation
import os.log

// MARK: - Internal Delegate Protocol

/// Internal protocol for activity detection callbacks
protocol AutoPresets_ActivityDetectionDelegate: AnyObject {
    func activityDetectionDidConfirm(_ activity: AutoPresetsActivityType)
    func activityDetectionDidStop(_ activity: AutoPresetsActivityType)
    func activityDetectionDidEncounterError(_ error: AutoPresetsDetectionError)
}

// MARK: - Activity Detection Manager

/// Manages CoreMotion-based activity detection for auto-preset activation.
///
/// Detection flow (pedometer-first):
/// 1. Pedometer live updates count steps continuously
/// 2. When 20+ steps accumulate → start Continuous Activity Time timer
/// 3. Activity classifier determines type (walking vs running) for preset selection
/// 4. When timer fires → query pedometer for additional steps since threshold
/// 5. If steps still accumulating → confirm activity and notify delegate
class AutoPresets_ActivityDetectionManager {

    // MARK: - Constants

    /// Number of steps required before starting the activity timer
    private let stepThreshold = 20

    // MARK: - Properties

    private let log = OSLog(subsystem: "com.loopkit.Loop.AutoPresets", category: "ActivityDetection")
    private let fileLog = AutoPresets_Logger.shared
    private let stateQueue = DispatchQueue(label: "com.loopkit.AutoPresets.ActivityDetection.state", qos: .utility)

    weak var delegate: AutoPresets_ActivityDetectionDelegate?

    private let pedometer = CMPedometer()
    private let motionActivityManager = CMMotionActivityManager()

    // Thread-safe state variables
    private var _isMonitoring = false
    private var _currentActivity: AutoPresetsActivityType?
    private var _detectedActivityType: AutoPresetsActivityType?
    private var _stepThresholdReachedTime: Date?
    private var _pedometerStartTime: Date?
    private var _totalSteps: Int = 0
    /// Incremented on every pedometer reset to discard stale callbacks from old subscriptions
    private var _pedometerGeneration: UInt64 = 0

    private var isMonitoring: Bool {
        get { stateQueue.sync { _isMonitoring } }
        set { stateQueue.sync { _isMonitoring = newValue } }
    }

    private var currentActivity: AutoPresetsActivityType? {
        get { stateQueue.sync { _currentActivity } }
        set { stateQueue.sync { _currentActivity = newValue } }
    }

    // MARK: - Configuration

    var supportedActivities: Set<AutoPresetsActivityType> = [.walking]
    var activityStopInterval: TimeInterval = 300
    var continuousActivityTime: TimeInterval = 30
    var requireHighConfidence: Bool = false

    // Thread-safe timer references
    private var _continuousActivityTimer: Timer?
    private var _activityStopTimer: Timer?

    // MARK: - Public Properties

    var detectedActivity: AutoPresetsActivityType? {
        currentActivity
    }

    var isActivityDetected: Bool {
        currentActivity != nil
    }

    // MARK: - Initialization

    init() {
        os_log("AutoPresets_ActivityDetectionManager initialized", log: log, type: .debug)
    }

    deinit {
        os_log("AutoPresets_ActivityDetectionManager deinitializing", log: log, type: .debug)
        stopMonitoring()
        cleanupTimers()
    }

    // MARK: - Public Methods

    func startMonitoring() {
        guard !isMonitoring else {
            os_log("Activity detection already monitoring", log: log, type: .debug)
            return
        }

        // Check device capability
        guard CMPedometer.isStepCountingAvailable(), CMMotionActivityManager.isActivityAvailable() else {
            os_log("Motion detection not available on this device", log: log, type: .error)
            delegate?.activityDetectionDidEncounterError(.motionNotAvailable)
            return
        }

        // Check authorization status
        let authorizationStatus = CMMotionActivityManager.authorizationStatus()
        switch authorizationStatus {
        case .notDetermined:
            break
        case .denied, .restricted:
            os_log("Motion & Fitness permission denied or restricted", log: log, type: .error)
            delegate?.activityDetectionDidEncounterError(.permissionDenied)
            return
        case .authorized:
            break
        @unknown default:
            os_log("Unknown motion authorization status", log: log, type: .error)
            delegate?.activityDetectionDidEncounterError(.permissionDenied)
            return
        }

        isMonitoring = true
        startPedometerUpdates()
        startMotionActivityUpdates()

        os_log(
            "Started activity detection - supported: %{public}@, continuous activity time: %.0fs, stop delay: %.0fs",
            log: log,
            type: .info,
            supportedActivities.map(\.displayName).joined(separator: ", "),
            continuousActivityTime,
            activityStopInterval
        )
        fileLog.log("Started monitoring - continuousActivityTime: \(continuousActivityTime)s, stopInterval: \(activityStopInterval)s")
    }

    func stopMonitoring() {
        guard isMonitoring else { return }

        isMonitoring = false
        pedometer.stopUpdates()
        motionActivityManager.stopActivityUpdates()
        cleanupTimers()

        if let activity = currentActivity {
            currentActivity = nil
            delegate?.activityDetectionDidStop(activity)
        }

        stateQueue.sync {
            _detectedActivityType = nil
            _stepThresholdReachedTime = nil
            _pedometerStartTime = nil
            _totalSteps = 0
        }

        os_log("Stopped activity detection monitoring", log: log, type: .info)
    }

    // MARK: - Pedometer (Phase 1: Step Detection)

    private func startPedometerUpdates() {
        let startDate = Date()
        let generation = stateQueue.sync { () -> UInt64 in
            _pedometerGeneration += 1
            _pedometerStartTime = startDate
            _totalSteps = 0
            _stepThresholdReachedTime = nil
            return _pedometerGeneration
        }

        fileLog.log("Pedometer started from: \(startDate)")

        pedometer.startUpdates(from: startDate) { [weak self] pedometerData, error in
            guard let self = self, self.isMonitoring else { return }

            // Discard stale callbacks from a previous pedometer subscription
            let currentGen = self.stateQueue.sync { self._pedometerGeneration }
            guard generation == currentGen else { return }

            if let error = error {
                os_log("Pedometer error: %{public}@", log: self.log, type: .error, error.localizedDescription)
                self.fileLog.log("Pedometer ERROR: \(error.localizedDescription)")
                return
            }

            guard let data = pedometerData else {
                self.fileLog.log("Pedometer callback with nil data")
                return
            }

            let steps = data.numberOfSteps.intValue
            self.fileLog.log("Pedometer update: \(steps) steps")

            DispatchQueue.main.async { [weak self] in
                self?.processPedometerUpdate(totalSteps: steps)
            }
        }
    }

    private func processPedometerUpdate(totalSteps: Int) {
        fileLog.log("Processing pedometer: \(totalSteps) steps (threshold: \(stepThreshold))")

        let (shouldStartTimer, alreadyConfirmed, stepsChanged) = stateQueue.sync { () -> (Bool, Bool, Bool) in
            let previousSteps = _totalSteps
            _totalSteps = totalSteps
            let changed = totalSteps != previousSteps

            // Already confirmed — only care if steps actually changed
            guard _currentActivity == nil else {
                return (false, true, changed)
            }

            // Check if we just crossed the step threshold
            if totalSteps >= stepThreshold && _stepThresholdReachedTime == nil {
                _stepThresholdReachedTime = Date()
                return (true, false, changed)
            }

            return (false, false, changed)
        }

        if alreadyConfirmed {
            if stepsChanged {
                startActivityStopTimer()
            }
            return
        }

        if shouldStartTimer {
            // Determine activity type from classifier, default to walking
            let activityType = stateQueue.sync { _detectedActivityType } ?? .walking

            os_log(
                "Step threshold reached (%{public}d steps) - starting continuous activity timer (%.0fs) for %{public}@",
                log: log,
                type: .info,
                totalSteps,
                continuousActivityTime,
                activityType.displayName
            )
            fileLog.log("Step threshold reached (\(totalSteps) steps) - starting \(continuousActivityTime)s timer for \(activityType.displayName)")

            startContinuousActivityTimer(for: activityType)
        }
    }

    // MARK: - Activity Classifier (determines walking vs running)

    private func startMotionActivityUpdates() {
        let queue = OperationQueue()
        queue.name = "AutoPresetsActivityClassifierQueue"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1

        motionActivityManager.startActivityUpdates(to: queue) { [weak self] activity in
            guard let self = self, self.isMonitoring else { return }
            guard let activity = activity else { return }

            // Filter stale updates
            guard Date().timeIntervalSince(activity.startDate) < 300 else { return }

            // Check confidence
            let acceptable: Bool
            if self.requireHighConfidence {
                acceptable = activity.confidence == .high
            } else {
                acceptable = activity.confidence == .high || activity.confidence == .medium
            }
            guard acceptable else { return }

            // Determine activity type
            var type: AutoPresetsActivityType?
            if self.supportedActivities.contains(.walking), activity.walking,
               !activity.automotive, !activity.cycling
            {
                type = .walking
            } else if self.supportedActivities.contains(.running), activity.running,
                      !activity.automotive, !activity.cycling
            {
                type = .running
            }

            if let type = type {
                self.stateQueue.sync {
                    self._detectedActivityType = type
                }
            } else {
                // Non-target activity detected — may need to trigger stop
                let shouldStop = activity.confidence != .low &&
                    (activity.automotive || activity.cycling)

                if shouldStop {
                    DispatchQueue.main.async { [weak self] in
                        self?.handleNonTargetActivity()
                    }
                }
            }
        }
    }

    private func handleNonTargetActivity() {
        let shouldStartStopTimer = stateQueue.sync { () -> Bool in
            _currentActivity != nil && _activityStopTimer == nil
        }

        if shouldStartStopTimer {
            os_log("Non-target activity detected (automotive/cycling), starting stop timer", log: log, type: .debug)
            startActivityStopTimer()
        }
    }

    // MARK: - Continuous Activity Timer (Phase 2: Sustained Activity Check)

    private func startContinuousActivityTimer(for activity: AutoPresetsActivityType) {
        os_log(
            "Starting continuous activity timer with interval: %.0fs (setting value: %.0fs)",
            log: log,
            type: .debug,
            continuousActivityTime,
            continuousActivityTime
        )
        fileLog.log("Timer created with interval: \(continuousActivityTime)s")

        stateQueue.sync {
            _continuousActivityTimer?.invalidate()
            _continuousActivityTimer = nil
        }

        let timerInterval = continuousActivityTime  // Capture the value
        let timerStartTime = Date()
        let stepsAtThreshold = stateQueue.sync { _totalSteps }

        let newTimer = Timer(timeInterval: timerInterval, repeats: false) { [weak self] timer in
            timer.invalidate()
            guard let self = self else { return }

            let elapsed = Date().timeIntervalSince(timerStartTime)
            os_log(
                "Continuous activity timer fired - expected: %.0fs, actual elapsed: %.1fs",
                log: self.log,
                type: .debug,
                timerInterval,
                elapsed
            )
            self.fileLog.log("Timer FIRED - expected: \(timerInterval)s, actual elapsed: \(String(format: "%.1f", elapsed))s")

            guard self.isMonitoring else { return }

            self.confirmActivity(defaultActivity: activity, stepsAtThreshold: stepsAtThreshold)
        }

        stateQueue.sync {
            _continuousActivityTimer = newTimer
        }
        RunLoop.main.add(newTimer, forMode: .common)
    }

    /// Decide whether to confirm sustained activity by taking the MAX of two
    /// independent step sources, because each one under-reports (never
    /// over-reports) in a different situation and a single source isn't
    /// reliable on its own:
    ///
    /// - **Live stream** (`_totalSteps` from `startUpdates`, minus the count at
    ///   threshold): accurate and real-time while the app is awake, but stalls
    ///   while the app is suspended (screen off, phone in a pocket — exactly
    ///   when the user is really walking). On resume it catches up in a batch.
    ///
    /// - **Historical query** (`queryPedometerData` over the recent window):
    ///   reads the motion coprocessor's recorded history so it survives
    ///   suspension, but the coprocessor commits step data with a lag, so the
    ///   most-recent ~15-30s are under-counted (device logs showed a real 21-step
    ///   walk returning only 2-13 from the query over a 10s window).
    ///
    /// Earlier attempts each broke one case: a wall-clock "last live step within
    /// 60s" recency check rejected every suspended walk; a pure historical query
    /// rejected short foreground walks due to the commit lag. Taking the max
    /// reliably confirms continuous walking in both foreground and pocket, at the
    /// cost of possibly confirming a walk that just ended right as a long-delayed
    /// timer fires — which self-corrects via the no-steps stop timer.
    private func confirmActivity(defaultActivity: AutoPresetsActivityType, stepsAtThreshold: Int) {
        let windowEnd = Date()
        let windowStart = windowEnd.addingTimeInterval(-continuousActivityTime)
        let activityType = stateQueue.sync { _detectedActivityType } ?? defaultActivity

        // Live stream: steps accumulated since the threshold was crossed. If the
        // pedometer restarted mid-timer, stepsAtThreshold is stale/inflated, so
        // treat the whole current count as additional.
        let currentLiveSteps = stateQueue.sync { _totalSteps }
        let liveAdditional = currentLiveSteps >= stepsAtThreshold
            ? currentLiveSteps - stepsAtThreshold
            : currentLiveSteps

        pedometer.queryPedometerData(from: windowStart, to: windowEnd) { [weak self] data, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard self.isMonitoring else { return }

                if let error = error {
                    self.fileLog.log("Confirmation query ERROR: \(error.localizedDescription) — falling back to live count \(liveAdditional)")
                }

                let queriedSteps = data?.numberOfSteps.intValue ?? 0
                let effectiveSteps = max(liveAdditional, queriedSteps)

                // Sustained-walking floor: ~30 steps/min over the window, min 15.
                // Normal walking is 100+/min; 30/min stays lenient for stop-and-go.
                let requiredSteps = max(15, Int(self.continuousActivityTime / 60.0 * 30.0))
                let confirmed = effectiveSteps >= requiredSteps

                self.fileLog.log("Confirmation [last \(String(format: "%.0f", self.continuousActivityTime))s]: live=\(liveAdditional) query=\(queriedSteps) → effective=\(effectiveSteps) (need >= \(requiredSteps)) → \(confirmed ? "CONFIRM" : "REJECT")")

                if confirmed {
                    os_log(
                        "%{public}@ confirmed - %{public}d steps (live %{public}d / query %{public}d) in last %.0fs",
                        log: self.log,
                        type: .info,
                        activityType.displayName,
                        effectiveSteps,
                        liveAdditional,
                        queriedSteps,
                        self.continuousActivityTime
                    )
                    self.fileLog.log("CONFIRMED \(activityType.displayName) - \(effectiveSteps) steps in last \(String(format: "%.0f", self.continuousActivityTime))s")

                    self.stateQueue.sync {
                        self._currentActivity = activityType
                        self._continuousActivityTimer = nil
                    }
                    self.delegate?.activityDetectionDidConfirm(activityType)
                    self.startActivityStopTimer()
                } else {
                    os_log(
                        "%{public}@ confirmation failed - %{public}d steps (need >= %{public}d)",
                        log: self.log,
                        type: .debug,
                        activityType.displayName,
                        effectiveSteps,
                        requiredSteps
                    )
                    self.fileLog.log("REJECTED \(activityType.displayName) - only \(effectiveSteps) steps in last \(String(format: "%.0f", self.continuousActivityTime))s (need >= \(requiredSteps))")

                    self.stateQueue.sync {
                        self._stepThresholdReachedTime = nil
                        self._continuousActivityTimer = nil
                    }
                    self.resetPedometer()
                }
            }
        }
    }

    // MARK: - Stop Detection

    private func startActivityStopTimer() {
        stateQueue.sync {
            _activityStopTimer?.invalidate()
            _activityStopTimer = nil
        }

        let newTimer = Timer(timeInterval: activityStopInterval, repeats: false) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            guard self.isMonitoring else {
                timer.invalidate()
                return
            }

            let activityToStop = self.stateQueue.sync { () -> AutoPresetsActivityType? in
                let activity = self._currentActivity
                self._currentActivity = nil
                self._stepThresholdReachedTime = nil
                self._activityStopTimer = nil
                return activity
            }

            if let activity = activityToStop {
                self.delegate?.activityDetectionDidStop(activity)
                os_log(
                    "%{public}@ stopped after %.0fs of inactivity",
                    log: self.log,
                    type: .info,
                    activity.displayName,
                    self.activityStopInterval
                )
                self.fileLog.log("DEACTIVATED \(activity.displayName) after \(self.activityStopInterval)s of no steps")
            }

            self.resetPedometer()

            timer.invalidate()
        }

        stateQueue.sync {
            _activityStopTimer = newTimer
        }
        RunLoop.main.add(newTimer, forMode: .common)
    }

    // MARK: - Helpers

    private func cleanupTimers() {
        stateQueue.sync {
            _continuousActivityTimer?.invalidate()
            _continuousActivityTimer = nil
            _activityStopTimer?.invalidate()
            _activityStopTimer = nil
        }
    }

    private func resetPedometer() {
        pedometer.stopUpdates()

        stateQueue.sync {
            _totalSteps = 0
            _stepThresholdReachedTime = nil
            _pedometerStartTime = nil
        }

        // Restart pedometer for next detection cycle
        if isMonitoring {
            startPedometerUpdates()
        }
    }
}
