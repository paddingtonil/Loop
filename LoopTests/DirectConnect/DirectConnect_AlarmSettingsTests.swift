//
//  DirectConnect_AlarmSettingsTests.swift
//  LoopTests
//
//  Concept & design by Taylor Patterson. Coded & tested by Claude Code in October 2026.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import XCTest
@testable import Loop

final class DirectConnect_AlarmSettingsTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "DirectConnect_AlarmSettingsTests")
        defaults.removePersistentDomain(forName: "DirectConnect_AlarmSettingsTests")
    }

    func testDefaultsMatchSpec() {
        let s = DirectConnect_AlarmSettings.defaults
        XCTAssertEqual(s.urgentLowThreshold, 55); XCTAssertTrue(s.urgentLowEnabled); XCTAssertEqual(s.urgentLowRepeatMinutes, 5)
        XCTAssertEqual(s.lowThreshold, 70); XCTAssertTrue(s.lowEnabled); XCTAssertEqual(s.lowRepeatMinutes, 15)
        XCTAssertEqual(s.highThreshold, 250); XCTAssertTrue(s.highEnabled); XCTAssertEqual(s.highRepeatMinutes, 60)
        XCTAssertEqual(s.risingRate, 3); XCTAssertFalse(s.risingFastEnabled)
        XCTAssertEqual(s.fallingRate, 3); XCTAssertTrue(s.fallingFastEnabled)
        XCTAssertEqual(s.signalLossMinutes, 20); XCTAssertTrue(s.signalLossEnabled)
        XCTAssertTrue(s.sensorExpiringEnabled); XCTAssertTrue(s.sensorEndedEnabled)
    }

    func testLoadReturnsDefaultsWhenNothingSaved() {
        XCTAssertEqual(DirectConnect_AlarmSettings.load(from: defaults), .defaults)
    }

    func testSaveLoadRoundTrip() {
        var s = DirectConnect_AlarmSettings.defaults
        s.lowThreshold = 80; s.highEnabled = false; s.risingRate = 2.5
        s.save(to: defaults)
        XCTAssertEqual(DirectConnect_AlarmSettings.load(from: defaults), s)
    }

    func testValuesAreClampedToRanges() {
        var s = DirectConnect_AlarmSettings.defaults
        s.urgentLowThreshold = 10; s.highThreshold = 900; s.risingRate = 9; s.signalLossMinutes = 1
        let n = s.normalized()
        XCTAssertEqual(n.urgentLowThreshold, 40); XCTAssertEqual(n.highThreshold, 400)
        XCTAssertEqual(n.risingRate, 5); XCTAssertEqual(n.signalLossMinutes, 10)
    }

    func testThresholdOrderingIsEnforced() {
        var s = DirectConnect_AlarmSettings.defaults
        s.urgentLowThreshold = 65; s.lowThreshold = 60
        let n = s.normalized()
        XCTAssertLessThan(n.urgentLowThreshold, n.lowThreshold)
        XCTAssertLessThan(n.lowThreshold, n.highThreshold)
    }
}
