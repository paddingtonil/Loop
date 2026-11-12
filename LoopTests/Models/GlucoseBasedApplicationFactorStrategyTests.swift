//
//  GlucoseBasedApplicationFactorStrategyTests.swift
//  LoopTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
import HealthKit
import LoopKit
@testable import LoopCore
@testable import Loop

class GlucoseBasedApplicationFactorStrategyTests: XCTestCase {

    // Correction range lower bound 95 mg/dL => the sliding scale starts at 95 + 10 = 105 mg/dL
    // and ends at 200 mg/dL.
    private let correctionRangeSchedule = GlucoseRangeSchedule(
        unit: .milligramsPerDeciliter,
        dailyItems: [.init(startTime: 0, value: DoubleRange(minValue: 95, maxValue: 105))]
    )!

    private let strategy = GlucoseBasedApplicationFactorStrategy()

    private func factor(atMgDl glucose: Double) -> Double {
        strategy.calculateDosingFactor(
            for: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: glucose),
            correctionRangeSchedule: correctionRangeSchedule,
            settings: LoopSettings()
        )
    }

    func testBoundsAre40And80Percent() {
        XCTAssertEqual(GlucoseBasedApplicationFactorStrategy.minPartialApplicationFactor, 0.40, accuracy: 1e-9)
        XCTAssertEqual(GlucoseBasedApplicationFactorStrategy.maxPartialApplicationFactor, 0.80, accuracy: 1e-9)
    }

    func testMinimumFactorNearCorrectionRange() {
        XCTAssertEqual(factor(atMgDl: 100), 0.40, accuracy: 1e-9)
        XCTAssertEqual(factor(atMgDl: 105), 0.40, accuracy: 1e-9)
    }

    func testFactorScalesLinearly() {
        // Midpoint of 105...200 mg/dL
        XCTAssertEqual(factor(atMgDl: 152.5), 0.60, accuracy: 1e-9)
    }

    func testMaximumFactorAtAndAboveMaxGlucose() {
        XCTAssertEqual(factor(atMgDl: 200), 0.80, accuracy: 1e-9)
        XCTAssertEqual(factor(atMgDl: 300), 0.80, accuracy: 1e-9)
    }
}
