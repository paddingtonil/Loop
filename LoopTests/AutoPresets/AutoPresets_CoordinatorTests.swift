//
//  AutoPresets_CoordinatorTests.swift
//  LoopTests
//
//  Concept & design by Taylor Patterson. Coded & tested by Claude Code in October 2026.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import XCTest
import HealthKit
import LoopKit
@testable import Loop

final class AutoPresets_CoordinatorTests: XCTestCase {

    // MARK: - Fixtures

    private let now = Date()

    private func preset(_ name: String) -> TemporaryScheduleOverridePreset {
        TemporaryScheduleOverridePreset(
            symbol: "🚶",
            name: name,
            settings: TemporaryScheduleOverrideSettings(unit: .milligramsPerDeciliter, targetRange: DoubleRange(minValue: 140, maxValue: 160), insulinNeedsScaleFactor: 0.7),
            duration: .finite(3600)
        )
    }

    private func override(_ context: TemporaryScheduleOverride.Context, startedAgo: TimeInterval = 600, duration: TimeInterval = 3600) -> TemporaryScheduleOverride {
        TemporaryScheduleOverride(
            context: context,
            settings: TemporaryScheduleOverrideSettings(unit: .milligramsPerDeciliter, targetRange: DoubleRange(minValue: 140, maxValue: 160)),
            startDate: now.addingTimeInterval(-startedAgo),
            duration: .finite(duration),
            enactTrigger: .local,
            syncIdentifier: UUID()
        )
    }

    // MARK: - Activation: when AutoPresets may change the active override

    func testActivatesWhenNoOverrideIsActive() {
        XCTAssertEqual(
            AutoPresets_activationDecision(activeOverride: nil, managedPresetIds: [UUID()], now: now),
            .apply
        )
    }

    func testDoesNotReplaceACustomOverrideTheUserStarted() {
        XCTAssertEqual(
            AutoPresets_activationDecision(activeOverride: override(.custom), managedPresetIds: [UUID()], now: now),
            .skipForeignOverride
        )
    }

    func testDoesNotReplaceAPresetThatAutoPresetsDoesNotManage() {
        let usersPreset = preset("Sick Day")
        XCTAssertEqual(
            AutoPresets_activationDecision(activeOverride: override(.preset(usersPreset)), managedPresetIds: [UUID()], now: now),
            .skipForeignOverride
        )
    }

    func testDoesNotReplaceTheLegacyWorkoutOverride() {
        XCTAssertEqual(
            AutoPresets_activationDecision(activeOverride: override(.legacyWorkout), managedPresetIds: [UUID()], now: now),
            .skipForeignOverride
        )
    }

    /// The inputs a running coordinator sees after it started Walking and the
    /// user then started their own override: the user's override must stay.
    /// Before this test, a coordinator that had activated a preset skipped
    /// the foreign-override check and replaced the user's override.
    func testManualOverrideStartedAfterAnAutoPresetIsNotReplaced() {
        let walking = preset("Walking")
        XCTAssertEqual(
            AutoPresets_activationDecision(activeOverride: override(.custom), managedPresetIds: [walking.id], now: now),
            .skipForeignOverride
        )
    }

    func testReplacesAManagedPresetLeftActiveFromBeforeARestart() {
        let walking = preset("Walking")
        XCTAssertEqual(
            AutoPresets_activationDecision(activeOverride: override(.preset(walking)), managedPresetIds: [walking.id], now: now),
            .replaceManaged
        )
    }

    func testAnExpiredForeignOverrideDoesNotBlockActivation() {
        let expired = override(.custom, startedAgo: 7200, duration: 3600)
        XCTAssertEqual(
            AutoPresets_activationDecision(activeOverride: expired, managedPresetIds: [UUID()], now: now),
            .apply
        )
    }

    func testAForeignOverrideScheduledToStartLaterBlocksActivation() {
        let future = override(.custom, startedAgo: -1800)
        XCTAssertEqual(
            AutoPresets_activationDecision(activeOverride: future, managedPresetIds: [UUID()], now: now),
            .skipForeignOverride
        )
    }

    // MARK: - Deactivation: only the preset AutoPresets started is cleared

    func testDeactivatesTheMatchingPreset() {
        let walking = preset("Walking")
        XCTAssertTrue(AutoPresets_shouldDeactivate(currentOverride: override(.preset(walking)), preset: walking))
    }

    func testDoesNotClearADifferentPreset() {
        XCTAssertFalse(AutoPresets_shouldDeactivate(currentOverride: override(.preset(preset("Sick Day"))), preset: preset("Walking")))
    }

    func testDoesNotClearACustomOverride() {
        XCTAssertFalse(AutoPresets_shouldDeactivate(currentOverride: override(.custom), preset: preset("Walking")))
    }

    func testNothingToClearWhenNoOverrideIsActive() {
        XCTAssertFalse(AutoPresets_shouldDeactivate(currentOverride: nil, preset: preset("Walking")))
    }

    // MARK: - Restart: the override AutoPresets started is remembered

    private func record(for override: TemporaryScheduleOverride, preset: TemporaryScheduleOverridePreset) -> AutoPresetsActivatedOverride {
        AutoPresetsActivatedOverride(presetId: preset.id, activity: .walking, overrideSyncIdentifier: override.syncIdentifier)
    }

    func testNothingToRestoreWithoutARecord() {
        XCTAssertEqual(AutoPresets_restoreDecision(record: nil, currentOverride: override(.custom), now: now), .none)
    }

    /// The reported problem: after a restart the coordinator forgot the
    /// preset it started, so ending the walk never cleared it.
    func testOverrideStartedBeforeARestartIsEndedUnlessTheActivityResumes() {
        let walking = preset("Walking")
        let active = override(.preset(walking))
        XCTAssertEqual(
            AutoPresets_restoreDecision(record: record(for: active, preset: walking), currentOverride: active, now: now),
            .endUnlessActivityResumes
        )
    }

    func testRecordIsForgottenWhenTheUserReplacedTheOverride() {
        let walking = preset("Walking")
        let started = override(.preset(walking))
        XCTAssertEqual(
            AutoPresets_restoreDecision(record: record(for: started, preset: walking), currentOverride: override(.custom), now: now),
            .forget
        )
    }

    /// The same preset started again by hand gets a new sync identifier, so
    /// AutoPresets does not end an override the user started.
    func testRecordIsForgottenWhenTheUserRestartedTheSamePresetByHand() {
        let walking = preset("Walking")
        let started = override(.preset(walking))
        let restartedByUser = override(.preset(walking))
        XCTAssertEqual(
            AutoPresets_restoreDecision(record: record(for: started, preset: walking), currentOverride: restartedByUser, now: now),
            .forget
        )
    }

    func testRecordIsForgottenWhenTheOverrideEndedOrExpired() {
        let walking = preset("Walking")
        let expired = override(.preset(walking), startedAgo: 7200, duration: 3600)
        let r = record(for: expired, preset: walking)
        XCTAssertEqual(AutoPresets_restoreDecision(record: r, currentOverride: nil, now: now), .forget)
        XCTAssertEqual(AutoPresets_restoreDecision(record: r, currentOverride: expired, now: now), .forget)
    }

    func testActivatedOverrideIsSavedAcrossRestarts() throws {
        let suite = "AutoPresets_CoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = AutoPresetsActivatedOverride(presetId: UUID(), activity: .running, overrideSyncIdentifier: UUID())

        AutoPresets_Storage(defaults: defaults).activatedOverride = saved

        XCTAssertEqual(AutoPresets_Storage(defaults: defaults).activatedOverride, saved)

        AutoPresets_Storage(defaults: defaults).activatedOverride = nil
        XCTAssertNil(AutoPresets_Storage(defaults: defaults).activatedOverride)
    }

    // MARK: - Settings: activity → preset mapping

    func testPresetIdRoundTrip() {
        var settings = AutoPresetsSettings()
        let id = UUID()

        settings.setPresetId(id, for: .running)
        XCTAssertEqual(settings.presetId(for: .running), id)
        XCTAssertNil(settings.presetId(for: .walking))

        settings.setPresetId(nil, for: .running)
        XCTAssertNil(settings.presetId(for: .running))
    }

    func testHasConfiguredPresetsCountsOnlyMonitoredActivities() {
        var settings = AutoPresetsSettings(supportedActivityTypes: [.walking])
        settings.setPresetId(UUID(), for: .running)
        XCTAssertFalse(settings.hasConfiguredPresets, "A preset for an activity that is not monitored must not start monitoring")

        settings.setPresetId(UUID(), for: .walking)
        XCTAssertTrue(settings.hasConfiguredPresets)
    }

    func testAMalformedPresetIdIsTreatedAsNotConfigured() {
        let settings = AutoPresetsSettings(activityPresets: [AutoPresetsActivityType.walking.rawValue: "not-a-uuid"])
        XCTAssertNil(settings.presetId(for: .walking))
    }

    // MARK: - Settings: saved-data compatibility

    func testDecodesLegacyContinuousActivityWindowKey() throws {
        let json = #"{"isEnabled": true, "continuousActivityWindow": 90}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AutoPresetsSettings.self, from: json)
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.continuousActivityTime, 90)
    }

    func testNewKeyWinsOverLegacyKey() throws {
        let json = #"{"continuousActivityTime": 45, "continuousActivityWindow": 90}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AutoPresetsSettings.self, from: json)
        XCTAssertEqual(settings.continuousActivityTime, 45)
    }

    func testMissingKeysFallBackToSafeDefaults() throws {
        let settings = try JSONDecoder().decode(AutoPresetsSettings.self, from: "{}".data(using: .utf8)!)
        XCTAssertFalse(settings.isEnabled, "AutoPresets must stay off unless the user turned it on")
        XCTAssertEqual(settings.supportedActivityTypes, [.walking])
        XCTAssertEqual(settings.stopInterval, 300)
        XCTAssertEqual(settings.continuousActivityTime, 30)
        XCTAssertTrue(settings.activityPresets.isEmpty)
    }

    func testEncodeDecodeRoundTrip() throws {
        var settings = AutoPresetsSettings(isEnabled: true, supportedActivityTypes: [.walking, .running], stopInterval: 600, continuousActivityTime: 60, requireHighConfidence: true)
        settings.setPresetId(UUID(), for: .running)

        let decoded = try JSONDecoder().decode(AutoPresetsSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }
}
