//
//  DirectConnect_GlucoseAlarmsTests.swift
//  LoopTests
//
//  Concept & design by Taylor Patterson. Coded & tested by Claude Code in October 2026.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import XCTest
import HealthKit
import LoopKit
@testable import Loop

final class DirectConnect_GlucoseAlarmsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func r(_ min: Double, _ mgdl: Double, rate: Double? = nil) -> DirectConnect_AlarmReading {
        DirectConnect_AlarmReading(date: t0.addingTimeInterval(min * 60), mgdl: mgdl, trendRate: rate)
    }

    private func kinds(_ a: [DirectConnect_AlarmAction]) -> [String] {
        a.map {
            switch $0 {
            case let .issue(k, _): return "+\(k.rawValue)"
            case let .retract(k): return "-\(k.rawValue)"
            }
        }
    }

    private func eval(_ reading: DirectConnect_AlarmReading, _ state: inout DirectConnect_AlarmState, _ settings: DirectConnect_AlarmSettings = .defaults) -> [String] {
        kinds(DirectConnect_GlucoseAlarms.evaluate(reading: reading, settings: settings, state: &state))
    }

    func testInRangeDoesNothing() {
        var s = DirectConnect_AlarmState()
        XCTAssertEqual(eval(r(0, 120), &s), [])
    }

    func testLowIssuesOnce() {
        var s = DirectConnect_AlarmState()
        XCTAssertEqual(eval(r(0, 68), &s), ["+low"])
        XCTAssertEqual(eval(r(5, 66), &s), [])
    }

    func testLowRepeatsOnlyAfterInterval() {
        var s = DirectConnect_AlarmState()
        _ = eval(r(0, 68), &s)
        XCTAssertEqual(eval(r(10, 69), &s), [])
        XCTAssertEqual(eval(r(15, 69), &s), ["+low"])
    }

    func testLowRetractsWhenBackInRange() {
        var s = DirectConnect_AlarmState()
        _ = eval(r(0, 68), &s)
        XCTAssertEqual(eval(r(5, 75), &s), ["-low"])
        XCTAssertTrue(s.lastFired.isEmpty)
    }

    func testUrgentLowReplacesLow() {
        var s = DirectConnect_AlarmState()
        _ = eval(r(0, 68), &s)
        XCTAssertEqual(Set(eval(r(5, 54), &s)), ["+urgentLow", "-low"])
    }

    func testUrgentLowRepeatsEveryFiveMinutes() {
        var s = DirectConnect_AlarmState()
        _ = eval(r(0, 50), &s)
        XCTAssertEqual(eval(r(5, 50), &s), ["+urgentLow"])
    }

    func testHigh() {
        var s = DirectConnect_AlarmState()
        XCTAssertEqual(eval(r(0, 260), &s), ["+high"])
        XCTAssertEqual(eval(r(30, 270), &s), [])
        XCTAssertEqual(eval(r(60, 270), &s), ["+high"])
    }

    func testDisabledAlarmNeverIssuesAndRetractsIfActive() {
        var settings = DirectConnect_AlarmSettings.defaults
        var s = DirectConnect_AlarmState()
        XCTAssertEqual(eval(r(0, 300), &s, settings), ["+high"])
        settings.highEnabled = false
        XCTAssertEqual(eval(r(5, 300), &s, settings), ["-high"])
        XCTAssertEqual(eval(r(10, 300), &s, settings), [])
    }

    func testUserThresholdIsUsed() {
        var settings = DirectConnect_AlarmSettings.defaults
        settings.lowThreshold = 80
        var s = DirectConnect_AlarmState()
        XCTAssertEqual(eval(r(0, 78), &s, settings), ["+low"])
    }

    func testFallingFastOncePerEpisode() {
        var s = DirectConnect_AlarmState()
        XCTAssertEqual(eval(r(0, 150, rate: -3.5), &s), ["+fallingFast"])
        XCTAssertEqual(eval(r(5, 130, rate: -3.5), &s), [])
        XCTAssertEqual(eval(r(10, 125, rate: -1), &s), ["-fallingFast"])
        XCTAssertEqual(eval(r(15, 110, rate: -3.2), &s), ["+fallingFast"])
    }

    func testRisingFastOffByDefaultAndWorksWhenEnabled() {
        var s = DirectConnect_AlarmState()
        XCTAssertEqual(eval(r(0, 150, rate: 4), &s), [])
        var settings = DirectConnect_AlarmSettings.defaults
        settings.risingFastEnabled = true
        XCTAssertEqual(eval(r(5, 170, rate: 4), &s, settings), ["+risingFast"])
    }

    func testMissingTrendDoesNotTriggerRateAlarms() {
        var s = DirectConnect_AlarmState()
        XCTAssertEqual(eval(r(0, 150, rate: nil), &s), [])
    }

    func testSignalLossOncePerGap() {
        var s = DirectConnect_AlarmState()
        func sig(_ last: Double, _ now: Double) -> [String] {
            kinds(DirectConnect_GlucoseAlarms.evaluateSignal(lastReading: t0.addingTimeInterval(last * 60), now: t0.addingTimeInterval(now * 60), settings: .defaults, state: &s))
        }
        XCTAssertEqual(sig(0, 19), [])
        XCTAssertEqual(sig(0, 21), ["+signalLoss"])
        XCTAssertEqual(sig(0, 40), [])
        XCTAssertEqual(sig(41, 41), ["-signalLoss"])
    }

    func testNoSignalAlarmBeforeFirstReading() {
        var s = DirectConnect_AlarmState()
        XCTAssertEqual(kinds(DirectConnect_GlucoseAlarms.evaluateSignal(lastReading: nil, now: t0, settings: .defaults, state: &s)), [])
    }

    func testSensorExpiringFiresAt24hAnd2h() {
        var s = DirectConnect_AlarmState()
        let exp = t0.addingTimeInterval(30 * 3600)
        func life(_ hours: Double) -> [String] {
            kinds(DirectConnect_GlucoseAlarms.evaluateLifetime(expiresAt: exp, endedOrFailed: false, now: t0.addingTimeInterval(hours * 3600), settings: .defaults, state: &s))
        }
        XCTAssertEqual(life(0), [])
        XCTAssertEqual(life(7), ["+sensorExpiring"])
        XCTAssertEqual(life(8), [])
        XCTAssertEqual(life(28.5), ["+sensorExpiring"])
        XCTAssertEqual(life(29), [])
    }

    func testNewSensorReArmsExpiringWarnings() {
        var s = DirectConnect_AlarmState()
        let now = t0
        _ = DirectConnect_GlucoseAlarms.evaluateLifetime(expiresAt: now.addingTimeInterval(3600), endedOrFailed: false, now: now, settings: .defaults, state: &s)
        XCTAssertEqual(kinds(DirectConnect_GlucoseAlarms.evaluateLifetime(expiresAt: now.addingTimeInterval(10 * 86400), endedOrFailed: false, now: now, settings: .defaults, state: &s)), ["-sensorExpiring"])
        XCTAssertTrue(s.lastFired.isEmpty)
    }

    func testSensorEndedIssuesOnceAndRetracts() {
        var s = DirectConnect_AlarmState()
        func life(_ ended: Bool) -> [String] {
            kinds(DirectConnect_GlucoseAlarms.evaluateLifetime(expiresAt: nil, endedOrFailed: ended, now: t0, settings: .defaults, state: &s))
        }
        XCTAssertEqual(life(true), ["+sensorEnded"])
        XCTAssertEqual(life(true), [])
        XCTAssertEqual(life(false), ["-sensorEnded"])
    }

    func testAlertBuildsWithInterruptionLevelsFromSpec() {
        let urgent = DirectConnect_GlucoseAlarms.alert(for: .urgentLow, value: 50, managerIdentifier: "M", unit: .milligramsPerDeciliter)
        XCTAssertEqual(urgent.interruptionLevel, .critical)
        XCTAssertEqual(urgent.identifier, Alert.Identifier(managerIdentifier: "M", alertIdentifier: "urgentLow"))
        XCTAssertTrue(urgent.backgroundContent.body.contains("50"))
        XCTAssertEqual(DirectConnect_GlucoseAlarms.alert(for: .low, value: 65, managerIdentifier: "M", unit: .milligramsPerDeciliter).interruptionLevel, .timeSensitive)
        XCTAssertEqual(DirectConnect_GlucoseAlarms.alert(for: .risingFast, value: 200, managerIdentifier: "M", unit: .milligramsPerDeciliter).interruptionLevel, .active)
        XCTAssertEqual(DirectConnect_GlucoseAlarms.alert(for: .sensorExpiring, value: nil, managerIdentifier: "M", unit: .milligramsPerDeciliter).interruptionLevel, .active)
    }

    func testAlertFormatsMmol() {
        let a = DirectConnect_GlucoseAlarms.alert(for: .low, value: 63, managerIdentifier: "M", unit: .millimolesPerLiter)
        XCTAssertTrue(a.backgroundContent.body.contains("3.5"))
    }

    func testEachIssueClearsTheEarlierAlertOfTheSameAlarm() {
        // Loop's AlertStore marks only the latest alert with an identifier as retracted. On
        // 2026-10-18 Urgent Low repeated at 2:11 and 2:21 AM; the low ended and only the 2:21 alert
        // was retracted, so Loop re-showed "Glucose is 45 mg/dL" at every launch.
        XCTAssertEqual(DirectConnect_GlucoseAlarms.steps(for: [.issue(.urgentLow, value: 45)]),
                       [.retractAlert(.urgentLow), .issueAlert(.urgentLow, value: 45), .playSound(.urgentLow)])
        XCTAssertEqual(DirectConnect_GlucoseAlarms.steps(for: [.retract(.urgentLow)]),
                       [.retractAlert(.urgentLow), .stopSound(.urgentLow)])
    }

    func testStateCodableRoundTrip() throws {
        var s = DirectConnect_AlarmState()
        _ = eval(r(0, 68), &s)
        XCTAssertEqual(try JSONDecoder().decode(DirectConnect_AlarmState.self, from: JSONEncoder().encode(s)), s)
    }
}
