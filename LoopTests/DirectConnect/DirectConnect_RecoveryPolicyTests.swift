//
//  DirectConnect_RecoveryPolicyTests.swift
//  LoopTests
//
//  Concept & design by Taylor Patterson. Coded & tested by Claude Code in October 2026.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import XCTest
@testable import Loop

final class DirectConnect_RecoveryPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    func testFirstTakeBackIsAllowed() {
        XCTAssertTrue(DirectConnect_RecoveryPolicy.mayReclaim(history: [], now: now))
    }

    func testTakeBackHappensAgainAtTheNextWake() {
        XCTAssertFalse(DirectConnect_RecoveryPolicy.mayReclaim(history: [ago(2)], now: now))
        XCTAssertTrue(DirectConnect_RecoveryPolicy.mayReclaim(history: [ago(5)], now: now))
    }

    func testRepeatedTakeoverNeedsTwoWithinSixHours() {
        XCTAssertFalse(DirectConnect_RecoveryPolicy.isRepeatedTakeover(history: [ago(30)], now: now))
        XCTAssertTrue(DirectConnect_RecoveryPolicy.isRepeatedTakeover(history: [ago(300), ago(30)], now: now))
        XCTAssertFalse(DirectConnect_RecoveryPolicy.isRepeatedTakeover(history: [ago(400), ago(30)], now: now))
    }

    func testHistoryIsTrimmedToSixHours() {
        let trimmed = DirectConnect_RecoveryPolicy.recording(now, in: [ago(500), ago(100)])
        XCTAssertEqual(trimmed, [ago(100), now])
    }

    func testStaleStreakTriggersAtTwo() {
        XCTAssertFalse(DirectConnect_RecoveryPolicy.staleStreakNeedsReclaim(1))
        XCTAssertTrue(DirectConnect_RecoveryPolicy.staleStreakNeedsReclaim(2))
    }

    func testWatchdog() {
        XCTAssertFalse(DirectConnect_RecoveryPolicy.watchdogShouldKick(lastConnect: ago(5), lastKick: nil, now: now))
        XCTAssertTrue(DirectConnect_RecoveryPolicy.watchdogShouldKick(lastConnect: ago(12), lastKick: nil, now: now))
        XCTAssertFalse(DirectConnect_RecoveryPolicy.watchdogShouldKick(lastConnect: ago(30), lastKick: ago(5), now: now))
        XCTAssertTrue(DirectConnect_RecoveryPolicy.watchdogShouldKick(lastConnect: ago(30), lastKick: ago(11), now: now))
        XCTAssertTrue(DirectConnect_RecoveryPolicy.watchdogShouldKick(lastConnect: nil, lastKick: nil, now: now))
    }

    func testStateRoundTripKeepsRecoveryFields() {
        var s = DirectConnect_G7State()
        s.peripheralIdentifier = "6A1F0C1E-0000-4000-8000-000000000001"
        s.takeBackHistory = [ago(20)]
        s.staleStreak = 1
        XCTAssertEqual(DirectConnect_G7State(rawValue: s.rawValue), s)
    }
}
