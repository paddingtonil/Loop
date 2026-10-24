//
//  AutoPresets_Coordinator.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  AutoPresets — Main entry point. Coordinates activity detection and preset activation.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import Combine
import Foundation
import LoopKit
import LoopKitUI
import os.log

// MARK: - DataLayer Notifications
//
// Posted when AutoPresets activates/deactivates a preset.
// DataLayer_Coordinator observes these to record events without
// direct coupling between modules.
//
// userInfo keys:
//   "activityType" — String (AutoPresetsActivityType.rawValue)
//   "presetName"   — String

extension Notification.Name {
    static let autoPresetsPresetActivated = Notification.Name("com.loopkit.Loop.autoPresetsPresetActivated")
    static let autoPresetsPresetDeactivated = Notification.Name("com.loopkit.Loop.autoPresetsPresetDeactivated")
}

// MARK: - AutoPresets Coordinator

/// Main entry point for AutoPresets feature
/// Coordinates activity detection and preset activation with minimal coupling to Loop
public class AutoPresets_Coordinator: ObservableObject {

    // MARK: - Singleton

    public static let shared = AutoPresets_Coordinator()

    // MARK: - Published Properties

    @Published public private(set) var isMonitoring: Bool = false
    @Published public private(set) var currentDetectedActivity: AutoPresetsActivityType?
    @Published public private(set) var lastError: AutoPresetsDetectionError?

    // MARK: - Private Properties

    private let log = OSLog(subsystem: "com.loopkit.Loop.AutoPresets", category: "Coordinator")
    private let fileLog = AutoPresets_Logger.shared
    private let storage = AutoPresets_Storage()
    private let activityDetectionManager = AutoPresets_ActivityDetectionManager()

    // Debounce/guard properties to prevent rapid restarts
    private var isUpdatingSettings = false
    private var pendingRestart: DispatchWorkItem?

    public weak var delegate: AutoPresets_Delegate? {
        didSet {
            // Start monitoring when delegate is set (if not already running)
            if delegate != nil && !isMonitoring {
                startIfConfigured()
            }
        }
    }

    /// User's preferred glucose display unit. Set during app boot in `LoopAppManager`
    /// from `DeviceDataManager.displayGlucosePreference`. Used by AIAdvisor and
    /// AIRecommendationView so guardrails, prompts, and override editor honor mmol/L.
    /// Declared `internal` (no `public`) — only same-module callers need access, and
    /// `LoopInsights_GlucoseUnitContext` is itself internal.
    var displayGlucosePreference: DisplayGlucosePreference?

    /// Convenience helper for unit-aware operations. Falls back to mg/dL if the
    /// preference hasn't been wired (e.g. during early boot or unit tests).
    var unitContext: LoopInsights_GlucoseUnitContext {
        if let pref = displayGlucosePreference {
            return LoopInsights_GlucoseUnitContext(displayGlucosePreference: pref)
        }
        return .fallbackMgdl
    }

    // Track which override we activated so we can deactivate the same one.
    // Saved in storage because Loop can restart while the override is active.
    private var activatedOverride: AutoPresetsActivatedOverride? {
        get { storage.activatedOverride }
        set { storage.activatedOverride = newValue }
    }

    /// Ends a restored override if no activity is confirmed within the stop interval.
    private var pendingRestoredOverrideEnd: DispatchWorkItem?

    // MARK: - Public Settings Access

    /// Current settings (read-only access)
    public var settings: AutoPresetsSettings {
        storage.settings
    }

    /// Whether the feature is enabled
    public var isEnabled: Bool {
        get { storage.settings.isEnabled }
        set {
            // Skip if no change
            guard newValue != storage.settings.isEnabled else { return }

            objectWillChange.send()
            storage.updateSettings { $0.isEnabled = newValue }
            if newValue {
                startIfConfigured()
            } else {
                stop()
            }
            logEvent(newValue ? .featureEnabled : .featureDisabled)
        }
    }

    // MARK: - Initialization

    private init() {
        activityDetectionManager.delegate = self

        // Perform migration from legacy settings if needed
        storage.migrateFromLegacyIfNeeded()

        // Note: Monitoring starts when delegate is set (see delegate didSet)
        os_log("AutoPresets_Coordinator initialized", log: log, type: .debug)
    }

    // MARK: - Public Methods

    /// Update settings with a closure
    public func updateSettings(_ update: (inout AutoPresetsSettings) -> Void) {
        // Guard against re-entrancy
        guard !isUpdatingSettings else { return }
        isUpdatingSettings = true
        defer { isUpdatingSettings = false }

        objectWillChange.send()
        storage.updateSettings(update)
        applySettingsToDetectionManager()

        // Debounce restart to prevent rapid cycling
        pendingRestart?.cancel()
        if isMonitoring {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.stop()
                self.startIfConfigured()
            }
            pendingRestart = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
        }
    }

    /// Get the preset for an activity type
    public func preset(for activity: AutoPresetsActivityType) -> TemporaryScheduleOverridePreset? {
        guard let presetId = settings.presetId(for: activity),
              let delegate = delegate
        else {
            return nil
        }

        return delegate.autoPresetsAvailablePresets(self).first { $0.id == presetId }
    }

    /// Set the preset for an activity type
    public func setPreset(_ preset: TemporaryScheduleOverridePreset?, for activity: AutoPresetsActivityType) {
        objectWillChange.send()
        storage.updateSettings { settings in
            settings.setPresetId(preset?.id, for: activity)
        }
    }

    /// Get all available presets from Loop
    public func availablePresets() -> [TemporaryScheduleOverridePreset] {
        delegate?.autoPresetsAvailablePresets(self) ?? []
    }

    /// Get the current override from Loop
    public func currentOverride() -> TemporaryScheduleOverride? {
        delegate?.autoPresetsCurrentOverride(self)
    }

    /// Create a new preset in Loop's settings (used by AI Advisor)
    public func createPreset(_ preset: TemporaryScheduleOverridePreset) {
        delegate?.autoPresets(self, shouldCreatePreset: preset)
        logEvent(.presetCreatedByAI, presetName: preset.name)
    }

    /// Start monitoring (if configured properly)
    public func startIfConfigured() {
        // Prevent starting if already monitoring
        guard !isMonitoring else {
            os_log("AutoPresets already monitoring, skipping start", log: log, type: .debug)
            return
        }

        guard delegate != nil else {
            os_log("AutoPresets delegate not set, not starting", log: log, type: .debug)
            return
        }

        guard settings.isEnabled else {
            os_log("AutoPresets not enabled, not starting", log: log, type: .debug)
            return
        }

        guard settings.hasConfiguredPresets else {
            os_log("AutoPresets has no configured presets, not starting", log: log, type: .debug)
            return
        }

        applySettingsToDetectionManager()
        activityDetectionManager.startMonitoring()
        isMonitoring = true
        restoreActivatedOverride()

        os_log(
            "AutoPresets monitoring started - activities: %{public}@, continuous activity time: %.0fs, stop: %.0fs",
            log: log,
            type: .info,
            settings.supportedActivityTypes.map(\.displayName).joined(separator: ", "),
            settings.continuousActivityTime,
            settings.stopInterval
        )
    }

    /// Stop monitoring
    public func stop() {
        pendingRestoredOverrideEnd?.cancel()
        pendingRestoredOverrideEnd = nil
        activityDetectionManager.stopMonitoring()
        isMonitoring = false
        currentDetectedActivity = nil

        os_log("AutoPresets monitoring stopped", log: log, type: .info)
    }

    /// Clear the last error
    public func clearError() {
        lastError = nil
    }

    /// Clear all activity log entries
    public func clearActivityLog() {
        objectWillChange.send()
        storage.clearActivityLog()
    }

    // MARK: - Private Methods

    private func applySettingsToDetectionManager() {
        let currentSettings = settings

        activityDetectionManager.supportedActivities = currentSettings.supportedActivityTypes
        activityDetectionManager.activityStopInterval = currentSettings.stopInterval
        activityDetectionManager.continuousActivityTime = currentSettings.continuousActivityTime
        activityDetectionManager.requireHighConfidence = currentSettings.requireHighConfidence
    }

    private func logEvent(_ event: AutoPresetsLogEvent, activity: AutoPresetsActivityType? = nil, presetName: String? = nil) {
        storage.addLogEntry(event: event, activityType: activity, presetName: presetName)
    }

    private func activatePreset(for activity: AutoPresetsActivityType) {
        fileLog.log("activatePreset: \(activity.displayName) — mapped presetId=\(settings.presetId(for: activity)?.uuidString ?? "nil"), delegate=\(delegate == nil ? "nil" : "set")")

        guard let preset = preset(for: activity) else {
            os_log(
                "No preset configured for %{public}@",
                log: log,
                type: .error,
                activity.displayName
            )
            fileLog.log("activatePreset SKIPPED — no preset resolved for \(activity.displayName) (check that \(activity.displayName) is mapped to an existing preset in AutoPresets settings)")
            return
        }

        // Only a FOREIGN override blocks activation; see AutoPresets_activationDecision.
        let managedPresetIds = Set(AutoPresetsActivityType.allCases.compactMap { settings.presetId(for: $0) })
        switch AutoPresets_activationDecision(activeOverride: currentOverride(), managedPresetIds: managedPresetIds, now: Date()) {
        case .skipForeignOverride:
            os_log(
                "Foreign override active (not an AutoPresets preset), skipping activation",
                log: log,
                type: .info
            )
            fileLog.log("activatePreset SKIPPED — a foreign override is active (not one AutoPresets manages); leaving it untouched")
            return
        case .replaceManaged:
            fileLog.log("activatePreset — an AutoPresets-managed override is already active; adopting/replacing it")
        case .apply:
            break
        }

        pendingRestoredOverrideEnd?.cancel()
        pendingRestoredOverrideEnd = nil
        delegate?.autoPresets(self, shouldActivatePreset: preset)
        // The delegate sets the override synchronously; record its identifier.
        activatedOverride = AutoPresetsActivatedOverride(
            presetId: preset.id,
            activity: activity,
            overrideSyncIdentifier: currentOverride()?.syncIdentifier
        )
        logEvent(.presetActivated, activity: activity, presetName: preset.name)
        fileLog.log("activatePreset APPLIED — '\(preset.name)' for \(activity.displayName) (delegate \(delegate == nil ? "MISSING" : "notified"))")

        // Notify DataLayer (separate module — uses notification decoupling)
        NotificationCenter.default.post(
            name: .autoPresetsPresetActivated,
            object: nil,
            userInfo: ["activityType": activity.rawValue, "presetName": preset.name]
        )

        os_log(
            "Activated preset '%{public}@' for %{public}@",
            log: log,
            type: .info,
            preset.name,
            activity.displayName
        )
    }

    private func deactivatePreset(for activity: AutoPresetsActivityType) {
        guard let record = activatedOverride,
              let preset = availablePresets().first(where: { $0.id == record.presetId })
        else {
            os_log(
                "No AutoPresets-activated preset to deactivate",
                log: log,
                type: .debug
            )
            activatedOverride = nil
            return
        }

        activatedOverride = nil
        // Leave the override alone if the user replaced it or restarted the preset by hand
        guard AutoPresets_restoreDecision(record: record, currentOverride: currentOverride(), now: Date()) == .endUnlessActivityResumes else {
            fileLog.log("deactivatePreset SKIPPED — the override AutoPresets started is no longer the active one")
            return
        }
        delegate?.autoPresets(self, shouldDeactivatePreset: preset)
        logEvent(.presetDeactivated, activity: activity, presetName: preset.name)

        // Notify DataLayer (separate module — uses notification decoupling)
        NotificationCenter.default.post(
            name: .autoPresetsPresetDeactivated,
            object: nil,
            userInfo: ["activityType": activity.rawValue, "presetName": preset.name]
        )

        os_log(
            "Deactivated preset '%{public}@' for %{public}@",
            log: log,
            type: .info,
            preset.name,
            activity.displayName
        )
    }

    /// After a restart, ends the override AutoPresets started before it unless
    /// the activity is confirmed again within the stop interval. Without this the
    /// override stays on until its own end time, because the activity that
    /// started it is not known to the new detection session and never "stops".
    private func restoreActivatedOverride() {
        switch AutoPresets_restoreDecision(record: activatedOverride, currentOverride: currentOverride(), now: Date()) {
        case .none:
            return
        case .forget:
            fileLog.log("restore — saved AutoPresets override is no longer active; forgetting it")
            activatedOverride = nil
        case .endUnlessActivityResumes:
            guard currentDetectedActivity == nil, let record = activatedOverride else { return }
            let interval = settings.stopInterval
            fileLog.log("restore — AutoPresets override still active after restart; ending it in \(interval)s unless \(record.activity.displayName) is confirmed")
            pendingRestoredOverrideEnd?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.currentDetectedActivity == nil else { return }
                self.pendingRestoredOverrideEnd = nil
                self.deactivatePreset(for: record.activity)
            }
            pendingRestoredOverrideEnd = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: workItem)
        }
    }
}

// MARK: - Activation Rules

/// What to do at monitoring start with the override AutoPresets saved as started.
enum AutoPresets_RestoreDecision: Equatable {
    /// Nothing was saved.
    case none
    /// The saved override is gone, expired or replaced; drop the record.
    case forget
    /// The saved override is still the active one; end it unless the activity resumes.
    case endUnlessActivityResumes
}

/// Compares the saved record with Loop's current override by sync identifier,
/// so an override the user started (even from the same preset) is never ended.
/// - Parameters:
///   - record: The override AutoPresets saved as started, or nil.
///   - currentOverride: Loop's current `scheduleOverride`.
///   - now: The current time; a finished override counts as gone.
/// - Returns: Whether the record still describes the active override.
func AutoPresets_restoreDecision(
    record: AutoPresetsActivatedOverride?,
    currentOverride: TemporaryScheduleOverride?,
    now: Date
) -> AutoPresets_RestoreDecision {
    guard let record else { return .none }
    guard let currentOverride,
          !currentOverride.hasFinished(relativeTo: now),
          let savedId = record.overrideSyncIdentifier,
          currentOverride.syncIdentifier == savedId
    else {
        return .forget
    }
    return .endUnlessActivityResumes
}

/// What AutoPresets may do with Loop's current override when an activity is confirmed.
enum AutoPresets_ActivationDecision: Equatable {
    /// No override is in effect; start the preset.
    case apply
    /// One of the presets AutoPresets manages is active; replace it.
    case replaceManaged
    /// An override AutoPresets does not manage is active or scheduled; leave it alone.
    case skipForeignOverride
}

/// Decides whether a confirmed activity may start its preset.
///
/// Decided from the override itself, not from what this coordinator remembers
/// starting: the coordinator's memory resets at app restart (so a leftover
/// managed preset must still be adoptable), and it does not see the user
/// replacing an AutoPresets preset with their own override (which must not be
/// replaced back).
/// - Parameters:
///   - activeOverride: Loop's current `scheduleOverride`.
///   - managedPresetIds: IDs of the presets mapped to activities in AutoPresets settings.
///   - now: The current time; an override that has finished no longer counts.
/// - Returns: The action `activatePreset` takes.
func AutoPresets_activationDecision(
    activeOverride: TemporaryScheduleOverride?,
    managedPresetIds: Set<UUID>,
    now: Date
) -> AutoPresets_ActivationDecision {
    guard let active = activeOverride, !active.hasFinished(relativeTo: now) else {
        return .apply
    }
    if case let .preset(activePreset) = active.context, managedPresetIds.contains(activePreset.id) {
        return .replaceManaged
    }
    return .skipForeignOverride
}

/// Whether ending `preset`'s activity should clear Loop's current override.
/// Only the same preset is cleared, so an override the user started meanwhile stays.
/// - Parameters:
///   - currentOverride: Loop's current `scheduleOverride`.
///   - preset: The preset AutoPresets started for the activity that ended.
/// - Returns: True when the current override is that preset.
func AutoPresets_shouldDeactivate(currentOverride: TemporaryScheduleOverride?, preset: TemporaryScheduleOverridePreset) -> Bool {
    guard let currentOverride, case let .preset(currentPreset) = currentOverride.context else {
        return false
    }
    return currentPreset.id == preset.id
}

// MARK: - AutoPresets_ActivityDetectionDelegate

extension AutoPresets_Coordinator: AutoPresets_ActivityDetectionDelegate {

    func activityDetectionDidConfirm(_ activity: AutoPresetsActivityType) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.currentDetectedActivity = activity
            self.activatePreset(for: activity)

            // DataLayer: activity detected
            NotificationCenter.default.post(
                name: Notification.Name("com.loopkit.Loop.autoPresetsActivityDetected"),
                object: nil,
                userInfo: [
                    "activityType": activity.rawValue
                ]
            )
        }
    }

    func activityDetectionDidStop(_ activity: AutoPresetsActivityType) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.currentDetectedActivity = nil
            self.deactivatePreset(for: activity)
        }
    }

    func activityDetectionDidEncounterError(_ error: AutoPresetsDetectionError) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.lastError = error
            os_log(
                "Activity detection error: %{public}@",
                log: self.log,
                type: .error,
                error.localizedDescription
            )
        }
    }
}
