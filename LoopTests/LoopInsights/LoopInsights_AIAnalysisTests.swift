//
//  LoopInsights_AIAnalysisTests.swift
//  LoopTests
//
//  Concept & design by Taylor Patterson. Coded & tested by Claude Code in February 2026.
//  Copyright (c) 2025-2026 LoopKit Authors. All rights reserved.
//

import XCTest
@testable import Loop

final class LoopInsights_AIAnalysisTests: XCTestCase {

    private var analysis: LoopInsights_AIAnalysis!

    override func setUp() {
        super.setUp()
        analysis = LoopInsights_AIAnalysis()
    }

    // MARK: - Fixtures

    /// Minimal but valid aggregated stats. Meal/correction counts are kept high enough
    /// that the data-availability confidence cap doesn't kick in and complicate assertions,
    /// and hourlyAverages is left empty so the citation-verification check is a no-op.
    private func makeStats(period: LoopInsightsAnalysisPeriod = .fourteenDays) -> LoopInsightsAggregatedStats {
        LoopInsightsAggregatedStats(
            period: period,
            glucoseStats: .init(
                averageGlucose: 140, standardDeviation: 30, coefficientOfVariation: 25,
                timeInRange: 75, timeInTightRange: 60, tightRangeUpperBound: 140,
                timeVeryHigh: 3, timeHigh: 10, timeLow: 2, timeVeryLow: 0,
                gmi: 6.8, sampleCount: 4000, hourlyAverages: [:]
            ),
            insulinStats: .init(
                totalDailyDose: 40, basalPercentage: 50, bolusPercentage: 50,
                hourlyBasalAverages: [:], correctionBolusCount: 10, negativeBasalStats: nil,
                dailyBreakdown: [], tddMin: 35, tddMax: 45, tddVariabilityCV: 10,
                tddWeekOverWeekChange: nil
            ),
            carbStats: .init(
                averageDailyCarbs: 150, mealCount: 20, averageCarbsPerMeal: 40,
                hourlyMealFrequency: [:]
            ),
            biometricStats: nil,
            generatedAt: Date()
        )
    }

    private func timeBlockJSON(start: Int, end: Int, current: Double, proposed: Double) -> String {
        """
        {"start_seconds": \(start), "end_seconds": \(end), "current_value": \(current), "proposed_value": \(proposed)}
        """
    }

    private func responseJSON(
        timeBlocksJSON: String,
        reasoning: String = "Test reasoning citing a data pattern.",
        plainSummary: String? = nil
    ) -> String {
        let plainSummaryLine = plainSummary.map { "\"plain_summary\": \"\($0)\"," } ?? ""
        return """
        {
            "suggestions": [
                {
                    "time_blocks": [\(timeBlocksJSON)],
                    \(plainSummaryLine)
                    "reasoning": "\(reasoning)",
                    "confidence": "medium"
                }
            ],
            "overall_assessment": "Test assessment.",
            "next_recommended_focus": null,
            "past_suggestion_evaluations": {}
        }
        """
    }

    // MARK: - No-op suggestion filtering (Problem #1)

    /// A suggestion whose only time block proposes the exact current value (a "0% change"
    /// recommendation, like the "29.00 → 29.00 (+0%)" case reported in the app) must be
    /// dropped entirely — it isn't a recommendation at all.
    func testSuggestionWithSingleNoOpBlockIsDropped() throws {
        let json = responseJSON(timeBlocksJSON: timeBlockJSON(start: 0, end: 21600, current: 29, proposed: 29))

        let result = try analysis.parseResponse(
            rawResponse: json, settingType: .insulinSensitivity, period: .fourteenDays, stats: makeStats()
        )

        XCTAssertTrue(result.suggestions.isEmpty, "A suggestion with no actual value change must not be surfaced")
    }

    /// A multi-block suggestion where some blocks genuinely change and others echo the
    /// current value (matching the screenshot: 3 blocks, all +0%) must drop only the
    /// no-op blocks and keep the real ones — not nuke the whole suggestion if any block
    /// is real, and not keep any block that recommends nothing.
    func testSuggestionWithMixedNoOpAndRealBlocksKeepsOnlyRealBlocks() throws {
        let blocks = [
            timeBlockJSON(start: 0, end: 21600, current: 29, proposed: 29),       // no-op
            timeBlockJSON(start: 21600, end: 43200, current: 33, proposed: 30),   // real change
            timeBlockJSON(start: 43200, end: 64800, current: 36, proposed: 36),   // no-op
        ].joined(separator: ", ")
        let json = responseJSON(timeBlocksJSON: blocks)

        let result = try analysis.parseResponse(
            rawResponse: json, settingType: .insulinSensitivity, period: .fourteenDays, stats: makeStats()
        )

        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.timeBlocks.count, 1)
        XCTAssertEqual(result.suggestions.first?.timeBlocks.first?.proposedValue, 30)
    }

    /// A suggestion where every block is a genuine change must pass through unaffected.
    func testSuggestionWithRealChangeIsKept() throws {
        let json = responseJSON(timeBlocksJSON: timeBlockJSON(start: 0, end: 21600, current: 29, proposed: 26))

        let result = try analysis.parseResponse(
            rawResponse: json, settingType: .insulinSensitivity, period: .fourteenDays, stats: makeStats()
        )

        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.timeBlocks.first?.proposedValue, 26)
    }

    // MARK: - Plain summary parsing

    /// The conversational headline ("plain_summary") must survive parsing into the
    /// suggestion model so the UI can show it above the collapsed full reasoning.
    func testPlainSummaryIsParsed() throws {
        let json = responseJSON(
            timeBlocksJSON: timeBlockJSON(start: 0, end: 21600, current: 29, proposed: 26),
            plainSummary: "I think you need more insulin here, so I recommend changing your ISF from 29 to 26."
        )

        let result = try analysis.parseResponse(
            rawResponse: json, settingType: .insulinSensitivity, period: .fourteenDays, stats: makeStats()
        )

        XCTAssertEqual(
            result.suggestions.first?.plainSummary,
            "I think you need more insulin here, so I recommend changing your ISF from 29 to 26."
        )
    }

    /// A response without plain_summary (or an older stored record) must still parse,
    /// with the field nil so the UI falls back to showing only the detailed reasoning.
    func testMissingPlainSummaryParsesAsNil() throws {
        let json = responseJSON(timeBlocksJSON: timeBlockJSON(start: 0, end: 21600, current: 29, proposed: 26))

        let result = try analysis.parseResponse(
            rawResponse: json, settingType: .insulinSensitivity, period: .fourteenDays, stats: makeStats()
        )

        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertNil(result.suggestions.first?.plainSummary)
    }

    /// Basal rate rounds to a finer increment (0.05 U/hr) than ISF's whole numbers — verify
    /// the no-op check compares at the setting's own rounding increment, not raw doubles.
    func testNoOpDetectionRespectsSettingRoundingIncrement() throws {
        // 0.85 proposed rounds to 0.85 (0.05 increment), identical to current — no-op.
        let json = responseJSON(timeBlocksJSON: timeBlockJSON(start: 0, end: 21600, current: 0.85, proposed: 0.851))

        let result = try analysis.parseResponse(
            rawResponse: json, settingType: .basalRate, period: .fourteenDays, stats: makeStats()
        )

        XCTAssertTrue(result.suggestions.isEmpty, "A change smaller than the display increment must be treated as no-op")
    }
}
