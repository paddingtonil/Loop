//
//  DirectConnect_StateTests.swift
//  LoopTests
//
//  Concept & design by Taylor Patterson. Coded & tested by Claude Code in October 2026.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import XCTest
import UIKit
import ObjectiveC
@testable import Loop

final class DirectConnect_StateTests: XCTestCase {
    func testRawStateRoundTrip() {
        var s = DirectConnect_G7State()
        s.sensorID = "DXCMab"
        s.sensorType = .stelo
        s.pairingCode = "1234"
        s.previousSensorID = "DXCMzz"
        s.activatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        s.extendedVersion = DirectConnect_G7ExtendedVersion(data: Data(dcHex: "5200406f1400880e00010a04ff1100")!)
        s.latestReading = DirectConnect_G7GlucoseMessage(data: Data(dcHex: "4e00d507000009000001050061000601ffff0e")!)
        s.latestReadingTimestamp = Date(timeIntervalSince1970: 1_800_000_300)
        s.latestConnect = Date(timeIntervalSince1970: 1_800_000_310)
        s.uploadReadings = false
        s.battery = DirectConnect_G7BatteryStatus(data: Data(dcHex: "220020010b0106210000000001")!)
        s.batteryReadAt = Date(timeIntervalSince1970: 1_800_000_320)
        s.versionInfo = DirectConnect_G7VersionInfo(data: Data(dcHex: "4a00020301040a00000014000000010203040506")!)
        s.recentReadings = [100, 101]
        s.pairingFailure = "failure text"
        XCTAssertTrue(s.calibration.enqueue(glucose: 120, date: Date()))
        s.alarmState.lastFired["low"] = Date(timeIntervalSince1970: 1_800_000_100)
        XCTAssertEqual(DirectConnect_G7State(rawValue: s.rawValue), s)
    }

    func testPreviousSensorCodeAndIdentifierRoundTrip() {
        // Kept so a search that resumes after an app restart still leaves the previous sensor alone.
        var s = DirectConnect_G7State()
        s.previousSensorID = "DXCMSq"
        s.previousPairingCode = "1111"
        s.previousPeripheralIdentifier = "6F1D2C3B-0000-4000-8000-000000000001"
        let restored = DirectConnect_G7State(rawValue: s.rawValue)
        XCTAssertEqual(restored.previousPairingCode, "1111")
        XCTAssertEqual(restored.previousPeripheralIdentifier, "6F1D2C3B-0000-4000-8000-000000000001")
    }

    func testEmptyRawStateUsesDefaults() {
        let s = DirectConnect_G7State(rawValue: [:])
        XCTAssertNil(s.sensorID)
        XCTAssertEqual(s.sensorType, .g7)
        XCTAssertTrue(s.uploadReadings)
        XCTAssertEqual(s.calibration, DirectConnect_CalibrationQueue())
        XCTAssertTrue(s.alarmState.lastFired.isEmpty)
    }

    func testSixIdenticalReadingsRule() {
        var s = DirectConnect_G7State()
        for _ in 0..<5 { XCTAssertFalse(s.recordReadingAndCheckStuck(110)) }
        XCTAssertTrue(s.recordReadingAndCheckStuck(110))
        XCTAssertFalse(s.recordReadingAndCheckStuck(111))
        XCTAssertEqual(s.recentReadings.count, 6)
    }

    func testSessionLengthComesFromTheSensor() {
        var s = DirectConnect_G7State()
        s.sensorType = .g7
        XCTAssertNil(s.knownSessionLength)
        s.extendedVersion = DirectConnect_G7ExtendedVersion(data: Data(dcHex: "5200406f1400880e00010a04ff1100")!)
        XCTAssertEqual(s.knownSessionLength, DirectConnect_SensorLifetime.fifteenDaySession)
        XCTAssertEqual(s.warmupDuration, 3720)
        s.extendedVersion = DirectConnect_G7ExtendedVersion(data: Data(dcHex: "5200c0d70d00540600020404ff0c00")!)
        XCTAssertEqual(s.knownSessionLength, DirectConnect_SensorLifetime.tenDaySession)
        XCTAssertEqual(s.warmupDuration, 1620)
    }

    func testEstimatedLengthIsOnlyForProgressDisplay() {
        let s = DirectConnect_G7State()
        XCTAssertNil(s.knownSessionLength)
        XCTAssertEqual(s.estimatedSessionLength, DirectConnect_SensorLifetime.tenDaySession)
    }
}

// MARK: - Last sensor (reconnect after Delete CGM)

final class DirectConnect_LastSensorTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "DirectConnect_LastSensorTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    private func sensor(_ id: String, code: String = "1234") -> DirectConnect_LastSensor {
        DirectConnect_LastSensor(sensorID: id, sensorType: .g7, pairingCode: code, peripheralIdentifier: "6A1F0C1E-0000-4000-8000-000000000001")
    }

    func testRememberedSensorRoundTrips() {
        let keys = DirectConnect_MemoryKeyStore()
        DirectConnect_LastSensorStore.remember(sensor("DXCMSq"), keyStore: keys, defaults: defaults)
        XCTAssertEqual(DirectConnect_LastSensorStore.load(defaults: defaults), sensor("DXCMSq"))
    }

    func testOnlyOneSensorIsRememberedAndTheOlderKeyIsErased() {
        let keys = DirectConnect_MemoryKeyStore()
        let key = Data(repeating: 1, count: 16)
        keys.save(key, sensor: "DXCMaa", slot: 2)
        keys.save(key, sensor: "DXCMbb", slot: 2)
        DirectConnect_LastSensorStore.remember(sensor("DXCMaa"), keyStore: keys, defaults: defaults)
        DirectConnect_LastSensorStore.remember(sensor("DXCMbb"), keyStore: keys, defaults: defaults)
        XCTAssertEqual(DirectConnect_LastSensorStore.load(defaults: defaults)?.sensorID, "DXCMbb")
        XCTAssertNil(keys.key(sensor: "DXCMaa", slot: 2))
        XCTAssertEqual(keys.key(sensor: "DXCMbb", slot: 2), key)
    }

    func testPairingADifferentSensorForgetsTheRememberedOne() {
        let keys = DirectConnect_MemoryKeyStore()
        keys.save(Data(repeating: 1, count: 16), sensor: "DXCMaa", slot: 2)
        DirectConnect_LastSensorStore.remember(sensor("DXCMaa"), keyStore: keys, defaults: defaults)
        DirectConnect_LastSensorStore.forget(unless: "DXCMzz", keyStore: keys, defaults: defaults)
        XCTAssertNil(DirectConnect_LastSensorStore.load(defaults: defaults))
        XCTAssertNil(keys.key(sensor: "DXCMaa", slot: 2))
    }

    func testReconnectingTheSameSensorKeepsItsKey() {
        let keys = DirectConnect_MemoryKeyStore()
        let key = Data(repeating: 1, count: 16)
        keys.save(key, sensor: "DXCMaa", slot: 2)
        DirectConnect_LastSensorStore.remember(sensor("DXCMaa"), keyStore: keys, defaults: defaults)
        DirectConnect_LastSensorStore.forget(unless: "DXCMaa", keyStore: keys, defaults: defaults)
        XCTAssertNil(DirectConnect_LastSensorStore.load(defaults: defaults))
        XCTAssertEqual(keys.key(sensor: "DXCMaa", slot: 2), key)
    }

    func testReconnectStateFollowsTheRememberedSensor() {
        let state = sensor("DXCMSq", code: "4821").reconnectState
        XCTAssertEqual(state.sensorID, "DXCMSq")
        XCTAssertEqual(state.sensorType, .g7)
        XCTAssertEqual(state.pairingCode, "4821")
        XCTAssertEqual(state.peripheralIdentifier, "6A1F0C1E-0000-4000-8000-000000000001")
    }
}

final class DirectConnect_PickerStyleTests: XCTestCase {
    /// The purple, centered Add CGM entry relies on two private UIAlertAction keys. If an iOS
    /// release drops one, the entry silently falls back to plain; this test says which.
    func testAlertActionStillHasTheKeysThePurpleEntryUses() {
        var count: UInt32 = 0
        guard let list = class_copyIvarList(UIAlertAction.self, &count) else { return XCTFail("no ivars") }
        defer { free(list) }
        let names = Set((0..<Int(count)).compactMap { ivar_getName(list[$0]).map { String(cString: $0) } })
        XCTAssertTrue(names.contains("_titleTextColor"), "titleTextColor key missing on this iOS")
        XCTAssertTrue(names.contains("_titleTextAlignment"), "titleTextAlignment key missing on this iOS")
    }
}

final class DirectConnect_HeartbeatTextTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()
    private let locale = Locale(identifier: "en_US")
    private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testTodayUsesShortTime() {
        XCTAssertEqual(DirectConnect_HeartbeatText.when(date(10, 13, 33), now: date(10, 14, 0), calendar: calendar, locale: locale), "today @ 1:33p")
        XCTAssertEqual(DirectConnect_HeartbeatText.when(date(10, 9, 5), now: date(10, 14, 0), calendar: calendar, locale: locale), "today @ 9:05a")
    }

    func testYesterdayAndOlder() {
        XCTAssertEqual(DirectConnect_HeartbeatText.when(date(9, 22, 0), now: date(10, 8, 0), calendar: calendar, locale: locale), "yesterday @ 10:00p")
        XCTAssertEqual(DirectConnect_HeartbeatText.when(date(7, 22, 0), now: date(10, 8, 0), calendar: calendar, locale: locale), "Oct 7 @ 10:00p")
    }

    func testNoContactYet() {
        XCTAssertEqual(DirectConnect_HeartbeatText.when(nil, now: date(10, 8, 0), calendar: calendar, locale: locale), "none yet")
    }
}

final class DirectConnect_RemainingTextTests: XCTestCase {
    private func text(_ seconds: TimeInterval) -> String {
        DirectConnect_SensorStatusViewModel.remainingText(seconds, suffix: "left")
    }

    func testWholeDaysAtOrAboveOneDay() {
        XCTAssertEqual(text(86400), "1 day left")
        XCTAssertEqual(text(86400 * 2.9), "2 days left")
    }

    // Rounding hours up overstated the time left (11 h 26 min showed as "12 hours").
    func testHoursAndMinutesBelowOneDay() {
        XCTAssertEqual(text(11 * 3600 + 26 * 60), "11 h 26 min left")
        XCTAssertEqual(text(11 * 3600 + 26 * 60 + 59), "11 h 26 min left")
    }

    func testDropsZeroParts() {
        XCTAssertEqual(text(5 * 3600), "5 h left")
        XCTAssertEqual(text(45 * 60), "45 min left")
    }

    func testUnderOneMinuteShowsOneMinute() {
        XCTAssertEqual(text(20), "1 min left")
    }
}
