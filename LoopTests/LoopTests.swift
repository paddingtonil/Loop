//
//  LoopTests.swift
//  LoopTests
//
//  Created by Darin Krauss on 9/18/19.
//  Copyright © 2019 LoopKit Authors. All rights reserved.
//

import HealthKit
import LoopKit
import XCTest

@testable import Loop

class LoopTests: XCTestCase {}

/// BolusPro FPU entries must be identifiable by an exact marker so that ordinary
/// meals that merely use the 🥩 emoji are never treated as virtual carbs.
class BolusProFPUMarkerTests: XCTestCase {

    private func entry(foodType: String?) -> NewCarbEntry {
        NewCarbEntry(
            quantity: HKQuantity(unit: .gram(), doubleValue: 22),
            startDate: Date(),
            foodType: foodType,
            absorptionTime: .hours(3)
        )
    }

    func testSecondaryEntryCarriesExactMarker() {
        let state = BolusProEntryState(
            enabled: true,
            macros: BolusProMacroInputs(fatGrams: 40, proteinGrams: 30),
            sliderCoverage: 1.0,
            macrosSource: .manual,
            autoDetected: false
        )
        let secondary = BolusPro_FPUCalculator.makeSecondaryEntry(primaryStartDate: Date(), state: state, coverageFactorPercent: 50)
        XCTAssertNotNil(secondary)
        XCTAssertEqual(secondary?.foodType, BolusPro_FeatureFlags.fpuEntryMarker)
        XCTAssertTrue(secondary?.isBolusProFPU == true)
    }

    func testMarkerIsRecognized() {
        XCTAssertTrue(entry(foodType: BolusPro_FeatureFlags.fpuEntryMarker).isBolusProFPU)
    }

    func testPlainEmojiMealIsNotFPU() {
        XCTAssertFalse(entry(foodType: "🥩").isBolusProFPU)
        XCTAssertFalse(entry(foodType: "🥩 steak").isBolusProFPU)
    }

    func testNilAndOtherFoodTypesAreNotFPU() {
        XCTAssertFalse(entry(foodType: nil).isBolusProFPU)
        XCTAssertFalse(entry(foodType: "🍞").isBolusProFPU)
    }
}

extension XCTestCase {
    
    func waitOnMain(timeout: TimeInterval = 1.0, file: StaticString = #file, function: String = #function, line: UInt = #line) {
        let exp = expectation(description: function)
        var fulfilled = false
        DispatchQueue.main.async {
            fulfilled = true
            exp.fulfill()
        }
        wait(for: [exp], timeout: timeout)
        XCTAssertTrue(fulfilled, "Failed to wait on main in \(function)", file: file, line: line)
    }

}
