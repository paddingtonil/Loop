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

    // Track which preset we activated so we can deactivate the same one
    private var activatedPresetId: UUID?

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

        // Only a FOREIGN override blocks activation. An override that matches one
        // of our activity-mapped presets is treated as ours and adopted/replaced
        // — it's typically a leftover from before an app restart (activatedPresetId
        // is in-memory only, so it resets while Loop keeps the override active).
        // Without this, a single leftover override would permanently block every
        // future activation until manually cleared.
        if let active = currentOverride(), activatedPresetId == nil {
            let managedPresetIds = Set(AutoPresetsActivityType.allCases.compactMap { settings.presetId(for: $0) })
            let activeIsManaged: Bool
            if case let .preset(activePreset) = active.context {
                activeIsManaged = managedPresetIds.contains(activePreset.id)
            } else {
                activeIsManaged = false
            }

            if !activeIsManaged {
                os_log(
                    "Foreign override active (not an AutoPresets preset), skipping activation",
                    log: log,
                    type: .info
                )
                fileLog.log("activatePreset SKIPPED — a foreign override is active (not one AutoPresets manages); leaving it untouched")
                return
            }

            fileLog.log("activatePreset — an AutoPresets-managed override is already active; adopting/replacing it")
        }

        activatedPresetId = preset.id
        delegate?.autoPresets(self, shouldActivatePreset: preset)
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
        guard let presetId = activatedPresetId,
              let preset = availablePresets().first(where: { $0.id == presetId })
        else {
            os_log(
                "No AutoPresets-activated preset to deactivate",
                log: log,
                type: .debug
            )
            activatedPresetId = nil
            return
        }

        activatedPresetId = nil
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
