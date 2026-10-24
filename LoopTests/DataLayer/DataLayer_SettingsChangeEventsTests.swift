//
//  DataLayer_SettingsChangeEventsTests.swift
//  LoopTests
//
//  Concept & design by Taylor Patterson. Coded & tested by Claude Code in October 2026.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import XCTest
import HealthKit
import LoopKit
@testable import Loop

final class DataLayer_SettingsChangeEventsTests: XCTestCase {

    // MARK: - Fixtures

    private func carbRatios(_ values: [(TimeInterval, Double)]) -> CarbRatioSchedule {
        CarbRatioSchedule(unit: .gram(), dailyItems: values.map { RepeatingScheduleValue(startTime: $0.0, value: $0.1) })!
    }

    private func sensitivities(_ values: [(TimeInterval, Double)]) -> InsulinSensitivitySchedule {
        InsulinSensitivitySchedule(unit: .milligramsPerDeciliter, dailyItems: values.map { RepeatingScheduleValue(startTime: $0.0, value: $0.1) })!
    }

    private func basals(_ values: [(TimeInterval, Double)]) -> BasalRateSchedule {
        BasalRateSchedule(dailyItems: values.map { RepeatingScheduleValue(startTime: $0.0, value: $0.1) })!
    }

    private func targets(_ low: Double, _ high: Double) -> GlucoseRangeSchedule {
        GlucoseRangeSchedule(unit: .milligramsPerDeciliter, dailyItems: [RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: low, maxValue: high))])!
    }

    private var baseline: TherapySettings {
        TherapySettings(
            glucoseTargetRangeSchedule: targets(100, 110),
            correctionRangeOverrides: nil,
            overridePresets: nil,
            maximumBasalRatePerHour: 3,
            maximumBolus: 10,
            suspendThreshold: GlucoseThreshold(unit: .milligramsPerDeciliter, value: 70),
            insulinSensitivitySchedule: sensitivities([(0, 50)]),
            carbRatioSchedule: carbRatios([(0, 10)]),
            basalRateSchedule: basals([(0, 1.0)]),
            defaultRapidActingModel: nil
        )
    }

    private func override(_ context: TemporaryScheduleOverride.Context, scale: Double? = nil, id: UUID = UUID()) -> TemporaryScheduleOverride {
        TemporaryScheduleOverride(
            context: context,
            settings: TemporaryScheduleOverrideSettings(unit: .milligramsPerDeciliter, targetRange: DoubleRange(minValue: 140, maxValue: 160), insulinNeedsScaleFactor: scale),
            startDate: Date(),
            duration: .finite(3600),
            enactTrigger: .local,
            syncIdentifier: id
        )
    }

    private func settingTypes(_ events: [DataLayer_SettingsChangeEvent]) -> [String] {
        events.compactMap { $0.userInfo["settingType"] as? String }
    }

    // MARK: - Therapy settings

    func testSavingUnchangedSettingsRecordsNoEvents() {
        XCTAssertEqual(DataLayer_SettingsChangeEvents.therapySettingsEvents(old: baseline, new: baseline), [])
    }

    func testOnlyTheChangedScheduleIsRecorded() {
        var new = baseline
        new.carbRatioSchedule = carbRatios([(0, 12)])

        let events = DataLayer_SettingsChangeEvents.therapySettingsEvents(old: baseline, new: new)

        XCTAssertEqual(settingTypes(events), ["CarbRatio"])
        XCTAssertEqual(events.first?.name, DataLayer_SettingsChangeEvents.therapySettingsChanged)
        XCTAssertEqual(events.first?.userInfo["source"] as? String, "manual")
        XCTAssertEqual(events.first?.userInfo["wasAISuggested"] as? Bool, false)
    }

    func testEachChangedSettingIsRecordedOnce() {
        var new = baseline
        new.insulinSensitivitySchedule = sensitivities([(0, 45)])
        new.basalRateSchedule = basals([(0, 0.9)])
        new.glucoseTargetRangeSchedule = targets(95, 105)
        new.suspendThreshold = GlucoseThreshold(unit: .milligramsPerDeciliter, value: 75)

        let events = DataLayer_SettingsChangeEvents.therapySettingsEvents(old: baseline, new: new)

        XCTAssertEqual(Set(settingTypes(events)), ["ISF", "BasalRate", "GlucoseTarget", "SuspendThreshold"])
        XCTAssertEqual(events.count, 4)
    }

    func testTimeBlocksChangedCountsNewOrEditedBlocks() {
        let old = baseline
        var new = baseline
        // The midnight block is unchanged; two new blocks are added.
        new.basalRateSchedule = basals([(0, 1.0), (6 * 3600, 1.2), (12 * 3600, 0.8)])

        let events = DataLayer_SettingsChangeEvents.therapySettingsEvents(old: old, new: new)

        XCTAssertEqual(events.first?.userInfo["timeBlocksChanged"] as? Int, 2)
    }

    func testRemovingABlockCountsAsOneChangedBlock() {
        var old = baseline
        old.basalRateSchedule = basals([(0, 1.0), (6 * 3600, 1.2)])
        var new = baseline
        new.basalRateSchedule = basals([(0, 1.0)])

        let events = DataLayer_SettingsChangeEvents.therapySettingsEvents(old: old, new: new)

        XCTAssertEqual(settingTypes(events), ["BasalRate"])
        XCTAssertEqual(events.first?.userInfo["timeBlocksChanged"] as? Int, 1)
    }

    // MARK: - Overrides

    func testNoEventsWhenOverrideIsUnchanged() {
        let active = override(.custom)
        XCTAssertEqual(DataLayer_SettingsChangeEvents.overrideEvents(old: nil, new: nil), [])
        XCTAssertEqual(DataLayer_SettingsChangeEvents.overrideEvents(old: active, new: active), [])
    }

    func testEditingAnActiveOverrideIsNotANewActivation() {
        let id = UUID()
        let old = override(.custom, scale: 0.8, id: id)
        let edited = override(.custom, scale: 0.6, id: id)
        XCTAssertEqual(DataLayer_SettingsChangeEvents.overrideEvents(old: old, new: edited), [])
    }

    func testStartingAPresetRecordsActivation() {
        let preset = TemporaryScheduleOverridePreset(symbol: "🏃", name: "Run", settings: TemporaryScheduleOverrideSettings(unit: .milligramsPerDeciliter, targetRange: nil, insulinNeedsScaleFactor: 0.5), duration: .finite(3600))

        let events = DataLayer_SettingsChangeEvents.overrideEvents(old: nil, new: override(.preset(preset), scale: 0.5))

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].name, DataLayer_SettingsChangeEvents.overrideActivated)
        XCTAssertEqual(events[0].userInfo["overrideType"] as? String, "preset")
        XCTAssertEqual(events[0].userInfo["presetName"] as? String, "Run")
        XCTAssertEqual(events[0].userInfo["insulinNeedsScale"] as? Double, 0.5)
        XCTAssertEqual(events[0].userInfo["targetRangeLow"] as? Double, 140)
        XCTAssertEqual(events[0].userInfo["targetRangeHigh"] as? Double, 160)
    }

    func testEndingAnOverrideRecordsWhichOverrideEnded() {
        let events = DataLayer_SettingsChangeEvents.overrideEvents(old: override(.legacyWorkout), new: nil)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].name, DataLayer_SettingsChangeEvents.overrideDeactivated)
        XCTAssertEqual(events[0].userInfo["overrideType"] as? String, "workout")
        XCTAssertEqual(events[0].userInfo["presetName"] as? String, "Workout")
    }

    func testReplacingAnOverrideRecordsEndThenStart() {
        let events = DataLayer_SettingsChangeEvents.overrideEvents(old: override(.legacyWorkout), new: override(.custom))

        XCTAssertEqual(events.map(\.name), [DataLayer_SettingsChangeEvents.overrideDeactivated, DataLayer_SettingsChangeEvents.overrideActivated])
        XCTAssertEqual(events.map { $0.userInfo["overrideType"] as? String }, ["workout", "custom"])
    }

    func testAnOverrideWithoutScaleOrRangeOmitsThoseKeys() {
        let preMeal = TemporaryScheduleOverride(
            context: .preMeal,
            settings: TemporaryScheduleOverrideSettings(unit: .milligramsPerDeciliter, targetRange: nil),
            startDate: Date(),
            duration: .finite(3600),
            enactTrigger: .local,
            syncIdentifier: UUID()
        )

        let info = DataLayer_SettingsChangeEvents.overrideEvents(old: nil, new: preMeal)[0].userInfo

        XCTAssertEqual(info["overrideType"] as? String, "preMeal")
        XCTAssertNil(info["insulinNeedsScale"])
        XCTAssertNil(info["targetRangeLow"])
        XCTAssertNil(info["targetRangeHigh"])
    }

    // MARK: - Posting

    func testPostSendsEveryEventInOrder() {
        let center = NotificationCenter()
        var received: [Notification.Name] = []
        let names = [DataLayer_SettingsChangeEvents.overrideDeactivated, DataLayer_SettingsChangeEvents.overrideActivated]
        let tokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { received.append($0.name) }
        }
        defer { tokens.forEach { center.removeObserver($0) } }

        DataLayer_SettingsChangeEvents.post(
            DataLayer_SettingsChangeEvents.overrideEvents(old: override(.custom), new: override(.custom)),
            center: center
        )

        XCTAssertEqual(received, names)
    }
}
