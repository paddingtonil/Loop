//
//  DirectConnect_SensorModelTests.swift
//  LoopTests
//
//  Concept & design by Taylor Patterson. Coded & tested by Claude Code in October 2026.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import XCTest
@testable import Loop

final class DirectConnect_SensorModelTests: XCTestCase {
    func testTypeFromName() {
        XCTAssertEqual(DirectConnect_SensorType.from(peripheralName: "DXCMab"), .g7)
        XCTAssertEqual(DirectConnect_SensorType.from(peripheralName: "DX02cd"), .onePlus)
        XCTAssertEqual(DirectConnect_SensorType.from(peripheralName: "DX01ef"), .stelo)
        XCTAssertNil(DirectConnect_SensorType.from(peripheralName: "Dexcom12"))
    }

    func testSessionLengthPrefersReportedValue() {
        XCTAssertEqual(DirectConnect_SensorLifetime.knownSessionLength(reported: 1339200, type: .g7), 1339200)
        XCTAssertEqual(DirectConnect_SensorLifetime.knownSessionLength(reported: 907200, type: .g7), 907200)
        XCTAssertEqual(DirectConnect_SensorLifetime.knownSessionLength(reported: 907200, type: .stelo), 907200)
    }

    func testG7LengthIsUnknownUntilTheSensorReportsIt() {
        // G7 is sold as 10-day and 15-day; Loop does not guess.
        XCTAssertNil(DirectConnect_SensorLifetime.knownSessionLength(reported: nil, type: .g7))
        XCTAssertNil(DirectConnect_SensorLifetime.knownSessionLength(reported: 12345, type: .g7))
    }

    func testSingleLengthProductsAreKnownBeforeReporting() {
        XCTAssertEqual(DirectConnect_SensorLifetime.knownSessionLength(reported: nil, type: .stelo), 1339200)
        XCTAssertEqual(DirectConnect_SensorLifetime.knownSessionLength(reported: nil, type: .onePlus), 907200)
    }

    func testFollowedSensorIsMadeActive() {
        XCTAssertEqual(DirectConnect_shouldConnect(peripheralName: "DXCMab", followedName: "DXCMab", excludedName: nil, expectedType: .g7), .makeActive)
    }

    func testFollowedSensorMatchesFullDexcomName() {
        XCTAssertEqual(DirectConnect_shouldConnect(peripheralName: "Dexcomab", followedName: "DXCMab", excludedName: nil, expectedType: .g7), .makeActive)
        XCTAssertEqual(DirectConnect_shouldConnect(peripheralName: "Otherab", followedName: "DXCMab", excludedName: nil, expectedType: .g7), .ignore)
    }

    func testScanConnectsMatchingTypeOnly() {
        XCTAssertEqual(DirectConnect_shouldConnect(peripheralName: "DXCMab", followedName: nil, excludedName: nil, expectedType: .g7), .connect)
        XCTAssertEqual(DirectConnect_shouldConnect(peripheralName: "DX01ab", followedName: nil, excludedName: nil, expectedType: .g7), .ignore)
    }

    func testScanCanPairThePreviousSensorAgain() {
        // An old sensor is filtered by refusing the new code, not by name, so the same sensor
        // can be paired again from Pair New Sensor.
        XCTAssertEqual(DirectConnect_shouldConnect(peripheralName: "DXCMold", followedName: nil, excludedName: "DXCMold", expectedType: .g7), .connect)
    }

    func testIgnoresOtherFollowedNamesAndUnnamed() {
        XCTAssertEqual(DirectConnect_shouldConnect(peripheralName: "DXCMzz", followedName: "DXCMab", excludedName: nil, expectedType: .g7), .ignore)
        XCTAssertEqual(DirectConnect_shouldConnect(peripheralName: nil, followedName: nil, excludedName: nil, expectedType: .g7), .ignore)
    }

    func testSkippedSensorMessageSaysTheSearchContinues() {
        // During a new-sensor search the old sensor refuses the new code. That is expected, so the
        // message must not tell the user the code is wrong.
        let message = DirectConnect_PairingFailure.skippedSensor("DXCMSq").message
        XCTAssertTrue(message.contains("DXCMSq"))
        XCTAssertTrue(message.contains("still searching"))
        XCTAssertFalse(message.contains("Check the 4 digits"))
    }

    // MARK: - Skipping sensors during a new-sensor search

    private let oldID = UUID(uuidString: "6F1D2C3B-0000-4000-8000-000000000001")!
    private let newID = UUID(uuidString: "6F1D2C3B-0000-4000-8000-000000000002")!

    func testSkippedSensorIsTriedAgainAfterTenMinutes() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var list = DirectConnect_SkipList()
        list.skip(oldID, now: start)
        XCTAssertTrue(list.isSkipped(oldID, now: start.addingTimeInterval(9 * 60)))
        XCTAssertFalse(list.isSkipped(oldID, now: start.addingTimeInterval(10 * 60 + 1)))
        XCTAssertFalse(list.isSkipped(newID, now: start))
    }

    func testPreviousSensorIsLeftAloneOnlyWhenTheCodeDiffers() {
        let excluded = DirectConnect_previousSensorToExclude(name: "DXCMSq", code: "1111", identifier: oldID.uuidString, newCode: "7553")
        XCTAssertEqual(excluded, DirectConnect_ExcludedSensor(name: "DXCMSq", identifier: oldID))
        // The same code means the user is pairing the same sensor again.
        XCTAssertNil(DirectConnect_previousSensorToExclude(name: "DXCMSq", code: "7553", identifier: oldID.uuidString, newCode: "7553"))
        // Without the old code Loop cannot tell, so nothing is excluded.
        XCTAssertNil(DirectConnect_previousSensorToExclude(name: "DXCMSq", code: nil, identifier: oldID.uuidString, newCode: "7553"))
        XCTAssertNil(DirectConnect_previousSensorToExclude(name: nil, code: "1111", identifier: nil, newCode: "7553"))
    }

    func testExclusionUsesTheBluetoothIDWhenKnown() {
        let excluded = DirectConnect_ExcludedSensor(name: "DXCMSq", identifier: oldID)
        XCTAssertTrue(DirectConnect_isExcluded(peripheralName: "DexcomSq", identifier: oldID, excluded: excluded))
        // A new sensor whose name ends in the same two characters is still paired.
        XCTAssertFalse(DirectConnect_isExcluded(peripheralName: "DXCMSq", identifier: newID, excluded: excluded))
        XCTAssertFalse(DirectConnect_isExcluded(peripheralName: "DXCMSq", identifier: oldID, excluded: nil))
    }

    func testExclusionFallsBackToTheNameWithoutAnID() {
        let excluded = DirectConnect_ExcludedSensor(name: "DXCMSq", identifier: nil)
        XCTAssertTrue(DirectConnect_isExcluded(peripheralName: "DXCMSq", identifier: newID, excluded: excluded))
        XCTAssertTrue(DirectConnect_isExcluded(peripheralName: "DexcomSq", identifier: newID, excluded: excluded))
        XCTAssertFalse(DirectConnect_isExcluded(peripheralName: "DXCMcw", identifier: newID, excluded: excluded))
        XCTAssertFalse(DirectConnect_isExcluded(peripheralName: nil, identifier: newID, excluded: excluded))
    }

    // MARK: - Pairing messages

    func testRefusalsThatAreNotTheUsersFaultAreNotices() {
        XCTAssertTrue(DirectConnect_PairingFailure.pakeRefused("DXCMcw").isNotice)
        XCTAssertTrue(DirectConnect_PairingFailure.certificateRefused("DXCMcw").isNotice)
        XCTAssertFalse(DirectConnect_PairingFailure.wrongCode("DXCMcw").isNotice)
        XCTAssertFalse(DirectConnect_PairingFailure.skippedSensor("DXCMSq").isNotice)
    }

    func testCertificateRefusalMessageSaysTheCodeWasAccepted() {
        let message = DirectConnect_PairingFailure.certificateRefused("DXCMcw").message
        XCTAssertTrue(message.contains("DXCMcw"))
        XCTAssertTrue(message.contains("accepted the code"))
        XCTAssertFalse(message.contains("Check the 4 digits"))
        XCTAssertFalse(DirectConnect_PairingFailure.pakeRefused("DXCMcw").message.contains("Check the 4 digits"))
    }
}
