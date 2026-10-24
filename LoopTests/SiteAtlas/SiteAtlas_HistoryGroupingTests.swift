//
//  SiteAtlas_HistoryGroupingTests.swift
//  LoopTests
//
//  Concept & design by Taylor Patterson. Coded & tested by Claude Code in October 2026.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import XCTest
@testable import Loop

final class SiteAtlas_HistoryGroupingTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func entry(_ date: Date) -> SiteAtlas_SiteEntry {
        SiteAtlas_SiteEntry(type: .pump, date: date, bodySide: .front, normalizedX: 0.5, normalizedY: 0.5)
    }

    /// The reported bug: months were ordered by their names (September,
    /// October, May) instead of by date.
    func testMonthsAreOrderedByDateNotByName() {
        let entries = [date(2026, 5, 3), date(2026, 9, 14), date(2026, 10, 2)].map(entry)

        let groups = SiteAtlas_groupByMonth(entries, newestFirst: true, calendar: calendar)

        XCTAssertEqual(groups.map(\.title), ["October 2026", "September 2026", "May 2026"])
    }

    func testOldestFirstReversesMonthsAndEntries() {
        let entries = [date(2026, 10, 2), date(2026, 5, 3), date(2026, 10, 20), date(2026, 9, 14)].map(entry)

        let groups = SiteAtlas_groupByMonth(entries, newestFirst: false, calendar: calendar)

        XCTAssertEqual(groups.map(\.title), ["May 2026", "September 2026", "October 2026"])
        XCTAssertEqual(groups.last?.entries.map(\.date), [date(2026, 10, 2), date(2026, 10, 20)])
    }

    func testEntriesWithinAMonthAreOrderedByDateAndTime() {
        let entries = [date(2026, 10, 5, 8), date(2026, 10, 5, 21, 30), date(2026, 10, 1, 23)].map(entry)

        let groups = SiteAtlas_groupByMonth(entries, newestFirst: true, calendar: calendar)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].entries.map(\.date), [date(2026, 10, 5, 21, 30), date(2026, 10, 5, 8), date(2026, 10, 1, 23)])
    }

    func testSameMonthInDifferentYearsAreSeparateGroups() {
        let entries = [date(2025, 10, 9), date(2026, 1, 4), date(2026, 10, 9)].map(entry)

        let groups = SiteAtlas_groupByMonth(entries, newestFirst: true, calendar: calendar)

        XCTAssertEqual(groups.map(\.title), ["October 2026", "January 2026", "October 2025"])
    }

    func testMonthBoundaryUsesTheCalendarTimeZone() {
        // 11:30 PM on Sep 30 in Los Angeles is already Oct 1 in UTC.
        let groups = SiteAtlas_groupByMonth([entry(date(2026, 9, 30, 23, 30))], newestFirst: true, calendar: calendar)

        XCTAssertEqual(groups.map(\.title), ["September 2026"])
    }

    func testNoEntriesGivesNoGroups() {
        XCTAssertTrue(SiteAtlas_groupByMonth([], newestFirst: true, calendar: calendar).isEmpty)
    }
}
