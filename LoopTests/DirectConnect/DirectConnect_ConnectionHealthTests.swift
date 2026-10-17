//
//  DirectConnect_ConnectionHealthTests.swift
//  LoopTests
//
//  Concept & design by Taylor Patterson. Coded & tested by Claude Code in October 2026.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import XCTest
@testable import Loop

final class DirectConnect_ConnectionHealthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
    private func event(_ minutesAgo: Double, _ kind: DirectConnect_HealthEvent.Kind) -> DirectConnect_HealthEvent {
        DirectConnect_HealthEvent(date: ago(minutesAgo), kind: kind)
    }

    /// One fresh reading every 5 minutes from `fromMinutesAgo` down to `toMinutesAgo`.
    private func readings(from fromMinutesAgo: Int, to toMinutesAgo: Int, kind: DirectConnect_HealthEvent.Kind = .reading) -> [DirectConnect_HealthEvent] {
        stride(from: fromMinutesAgo, through: toMinutesAgo, by: -5).map { event(Double($0), kind) }
    }

    func testEveryWakeReceivedIsFullCoverage() {
        let s = DirectConnect_HealthSummary(events: readings(from: 60, to: 0), window: 3600, now: now)
        XCTAssertEqual(s.freshReadings, 13)
        XCTAssertEqual(s.missedWakes, 0)
        XCTAssertEqual(s.coverage, 1, accuracy: 0.0001)
        XCTAssertEqual(s.gapCount, 0)
        XCTAssertEqual(s.longestGap, 0)
        XCTAssertNil(s.longestGapEnd)
    }

    func testTimeSinceLastReadingIsNotAGapUntilAWakeIsMissed() {
        let s = DirectConnect_HealthSummary(events: [event(4, .reading)], window: 3600, now: now)
        XCTAssertEqual(s.gapCount, 0)
        XCTAssertEqual(s.longestGap, 0)
    }

    func testMissedWakesAreCountedFromGaps() {
        // Readings at 60...35 and 15...0 minutes ago: the 30, 25 and 20 minute wakes are missing.
        let events = readings(from: 60, to: 35) + readings(from: 15, to: 0)
        let s = DirectConnect_HealthSummary(events: events, window: 3600, now: now)
        XCTAssertEqual(s.missedWakes, 3)
        XCTAssertEqual(s.gapCount, 1)
        XCTAssertEqual(s.longestGap, 20 * 60, accuracy: 1)
        XCTAssertEqual(s.longestGapEnd, ago(15))
        XCTAssertEqual(s.coverage, 10.0 / 13.0, accuracy: 0.0001)
    }

    func testSilenceSinceLastReadingCountsAsMissed() {
        let s = DirectConnect_HealthSummary(events: readings(from: 60, to: 20), window: 3600, now: now)
        XCTAssertEqual(s.missedWakes, 3)
        XCTAssertEqual(s.longestGap, 20 * 60, accuracy: 1)
        XCTAssertNil(s.longestGapEnd)
    }

    func testWithheldReadingsAreConnectedButNotUsable() {
        let events = readings(from: 30, to: 15) + readings(from: 10, to: 0, kind: .withheld)
        let s = DirectConnect_HealthSummary(events: events, window: 3600, now: now)
        XCTAssertEqual(s.freshReadings, 7)
        XCTAssertEqual(s.usableReadings, 4)
        XCTAssertEqual(s.withheldReadings, 3)
        XCTAssertEqual(s.missedWakes, 0)
    }

    func testOtherEventsAreCountedAndOldEventsIgnored() {
        let events = [event(200, .reclaimed), event(20, .reclaimed), event(10, .pairingFailed), event(5, .stale)] + readings(from: 30, to: 0)
        let s = DirectConnect_HealthSummary(events: events, window: 3600, now: now)
        XCTAssertEqual(s.reclaims, 1)
        XCTAssertEqual(s.pairingFailures, 1)
        XCTAssertEqual(s.staleReadings, 1)
    }

    func testNoEventsMeansNoData() {
        let s = DirectConnect_HealthSummary(events: [], window: 3600, now: now)
        XCTAssertEqual(s.freshReadings, 0)
        XCTAssertNil(s.coverageIfKnown)
    }

    func testLogTrimsToRetentionAndSurvivesReload() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dc-health-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = DirectConnect_HealthLog(fileURL: url, persistSynchronously: true)
        log.record(.reading, at: now.addingTimeInterval(-DirectConnect_HealthLog.retention - 60))
        log.record(.reading, at: ago(5))
        XCTAssertEqual(log.events(now: now).count, 1)
        let reloaded = DirectConnect_HealthLog(fileURL: url, persistSynchronously: true)
        XCTAssertEqual(reloaded.events(now: now).map(\.date), [ago(5)])
        reloaded.clear()
        XCTAssertTrue(reloaded.events(now: now).isEmpty)
    }
}
