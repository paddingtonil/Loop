//
//  DataLayer_SettingsChangeEvents.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  DataLayer — Builds the therapy-settings and override events that
//  DataLayer_Coordinator records, from the settings before and after a change.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import Foundation
import HealthKit
import LoopKit

/// One DataLayer event, ready to post on NotificationCenter.
struct DataLayer_SettingsChangeEvent: Equatable {
    let name: Notification.Name
    let userInfo: [String: AnyHashable]
}

/// Pure functions that turn a before/after settings pair into DataLayer events.
///
/// Events are derived from the actual difference so a save that touches one
/// schedule records one event, and every override path (Loop screen, Siri,
/// Watch, remote command, AutoPresets) is recorded from the one place all of
/// them pass through: `LoopDataManager.mutateSettings`.
enum DataLayer_SettingsChangeEvents {

    static let therapySettingsChanged = Notification.Name("com.loopkit.Loop.therapySettingsChanged")
    static let overrideActivated = Notification.Name("com.loopkit.Loop.overrideActivated")
    static let overrideDeactivated = Notification.Name("com.loopkit.Loop.overrideDeactivated")

    // MARK: - Therapy settings

    /// Returns one event per therapy setting that differs between `old` and `new`.
    /// - Parameters:
    ///   - old: Therapy settings before the user saved.
    ///   - new: Therapy settings the user saved.
    /// - Returns: Events for the changed settings only; empty when nothing changed.
    static func therapySettingsEvents(old: TherapySettings, new: TherapySettings) -> [DataLayer_SettingsChangeEvent] {
        var changes: [(type: String, blocks: Int)] = []

        if old.carbRatioSchedule != new.carbRatioSchedule {
            changes.append(("CarbRatio", changedBlockCount(old.carbRatioSchedule?.items, new.carbRatioSchedule?.items)))
        }
        if old.insulinSensitivitySchedule != new.insulinSensitivitySchedule {
            changes.append(("ISF", changedBlockCount(old.insulinSensitivitySchedule?.items, new.insulinSensitivitySchedule?.items)))
        }
        if old.basalRateSchedule != new.basalRateSchedule {
            changes.append(("BasalRate", changedBlockCount(old.basalRateSchedule?.items, new.basalRateSchedule?.items)))
        }
        if old.glucoseTargetRangeSchedule != new.glucoseTargetRangeSchedule {
            changes.append(("GlucoseTarget", changedBlockCount(old.glucoseTargetRangeSchedule?.items, new.glucoseTargetRangeSchedule?.items)))
        }
        if old.suspendThreshold != new.suspendThreshold {
            changes.append(("SuspendThreshold", 1))
        }

        return changes.map { change in
            DataLayer_SettingsChangeEvent(name: therapySettingsChanged, userInfo: [
                "settingType": change.type,
                "timeBlocksChanged": change.blocks,
                "wasAISuggested": false,
                "source": "manual"
            ])
        }
    }

    /// Counts blocks in `new` that are not in `old`. A change that only removes
    /// blocks (or only changes the unit) still counts as one.
    private static func changedBlockCount<T: Equatable>(_ old: [RepeatingScheduleValue<T>]?, _ new: [RepeatingScheduleValue<T>]?) -> Int {
        let oldItems = old ?? []
        return max(1, (new ?? []).filter { !oldItems.contains($0) }.count)
    }

    // MARK: - Overrides

    /// Returns the events for one override slot changing from `old` to `new`.
    /// An override edited in place keeps its sync identifier and records nothing.
    /// - Parameters:
    ///   - old: The override before the change, or nil.
    ///   - new: The override after the change, or nil.
    /// - Returns: A deactivation for `old` (if any) followed by an activation for `new` (if any).
    static func overrideEvents(old: TemporaryScheduleOverride?, new: TemporaryScheduleOverride?) -> [DataLayer_SettingsChangeEvent] {
        guard old?.syncIdentifier != new?.syncIdentifier else { return [] }

        var events: [DataLayer_SettingsChangeEvent] = []
        if let old {
            let (type, name) = describe(old.context)
            events.append(DataLayer_SettingsChangeEvent(name: overrideDeactivated, userInfo: [
                "overrideType": type,
                "presetName": name
            ]))
        }
        if let new {
            let (type, name) = describe(new.context)
            var info: [String: AnyHashable] = ["overrideType": type, "presetName": name]
            // Absent keys decode as nil in DataLayer_Coordinator, matching "not set".
            info["insulinNeedsScale"] = new.settings.insulinNeedsScaleFactor
            info["targetRangeLow"] = new.settings.targetRange?.lowerBound.doubleValue(for: .milligramsPerDeciliter)
            info["targetRangeHigh"] = new.settings.targetRange?.upperBound.doubleValue(for: .milligramsPerDeciliter)
            events.append(DataLayer_SettingsChangeEvent(name: overrideActivated, userInfo: info))
        }
        return events
    }

    private static func describe(_ context: TemporaryScheduleOverride.Context) -> (type: String, name: String) {
        switch context {
        case .preMeal: return ("preMeal", "Pre-Meal")
        case .legacyWorkout: return ("workout", "Workout")
        case .preset(let preset): return ("preset", preset.name)
        case .custom: return ("custom", "Custom")
        }
    }

    // MARK: - Posting

    /// Posts `events` in order.
    /// - Parameters:
    ///   - events: Events built by this type.
    ///   - center: Injected so tests can observe without the shared center.
    static func post(_ events: [DataLayer_SettingsChangeEvent], center: NotificationCenter = .default) {
        for event in events {
            center.post(name: event.name, object: nil, userInfo: event.userInfo)
        }
    }
}
