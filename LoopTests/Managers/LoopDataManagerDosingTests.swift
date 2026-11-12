//
//  LoopDataManagerDosingTests.swift
//  LoopTests
//
//  Created by Anna Quinlan on 10/19/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import XCTest
import HealthKit
import LoopKit
@testable import LoopCore
@testable import Loop

class MockDelegate: LoopDataManagerDelegate {
    let pumpManager = MockPumpManager()
    
    var bolusUnits: Double?
    func loopDataManager(_ manager: Loop.LoopDataManager, estimateBolusDuration units: Double) -> TimeInterval? {
        self.bolusUnits = units
        return pumpManager.estimatedDuration(toBolus: units)
    }
    
    var recommendation: AutomaticDoseRecommendation?
    var error: LoopError?
    func loopDataManager(_ manager: LoopDataManager, didRecommend automaticDose: (recommendation: AutomaticDoseRecommendation, date: Date), completion: @escaping (LoopError?) -> Void) {
        self.recommendation = automaticDose.recommendation
        completion(error)
    }
    func roundBasalRate(unitsPerHour: Double) -> Double { Double(Int(unitsPerHour / 0.05)) * 0.05 }
    func roundBolusVolume(units: Double) -> Double { Double(Int(units / 0.05)) * 0.05 }
    var pumpManagerStatus: PumpManagerStatus?
    var cgmManagerStatus: CGMManagerStatus?
    var pumpStatusHighlight: DeviceStatusHighlight?
}

class LoopDataManagerDosingTests: LoopDataManagerTests {
    // MARK: Functions to load fixtures
    func loadLocalDateGlucoseEffect(_ name: String) -> [GlucoseEffect] {
        let fixture: [JSONDictionary] = loadFixture(name)
        let localDateFormatter = ISO8601DateFormatter.localTimeDate()

        return fixture.map {
            return GlucoseEffect(startDate: localDateFormatter.date(from: $0["date"] as! String)!, quantity: HKQuantity(unit: HKUnit(from: $0["unit"] as! String), doubleValue:$0["amount"] as! Double))
        }
    }

    func loadPredictedGlucoseFixture(_ name: String) -> [PredictedGlucoseValue] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let url = bundle.url(forResource: name, withExtension: "json")!
        return try! decoder.decode([PredictedGlucoseValue].self, from: try! Data(contentsOf: url))
    }

    // MARK: Tests
    func testForecastFromLiveCaptureInputData() {

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let url = bundle.url(forResource: "live_capture_input", withExtension: "json")!
        let predictionInput = try! decoder.decode(LoopPredictionInput.self, from: try! Data(contentsOf: url))

        // Therapy settings in the "live capture" input only have one value, so we can fake some schedules
        // from the first entry of each therapy setting's history.
        let basalRateSchedule = BasalRateSchedule(dailyItems: [
            RepeatingScheduleValue(startTime: 0, value: predictionInput.settings.basal.first!.value)
        ])
        let insulinSensitivitySchedule = InsulinSensitivitySchedule(
            unit: .milligramsPerDeciliter,
            dailyItems: [
                RepeatingScheduleValue(startTime: 0, value: predictionInput.settings.sensitivity.first!.value.doubleValue(for: .milligramsPerDeciliter))
            ],
            timeZone: .utcTimeZone
        )!
        let carbRatioSchedule = CarbRatioSchedule(
            unit: .gram(),
            dailyItems: [
                RepeatingScheduleValue(startTime: 0.0, value: predictionInput.settings.carbRatio.first!.value)
            ],
            timeZone: .utcTimeZone
        )!

        let settings = LoopSettings(
            dosingEnabled: false,
            glucoseTargetRangeSchedule: glucoseTargetRangeSchedule,
            insulinSensitivitySchedule: insulinSensitivitySchedule,
            basalRateSchedule: basalRateSchedule,
            carbRatioSchedule: carbRatioSchedule,
            maximumBasalRatePerHour: 10,
            maximumBolus: 5,
            suspendThreshold: predictionInput.settings.suspendThreshold,
            automaticDosingStrategy: .automaticBolus
        )

        let glucoseStore = MockGlucoseStore()
        glucoseStore.storedGlucose = predictionInput.glucoseHistory

        let currentDate = glucoseStore.latestGlucose!.startDate
        now = currentDate

        let doseStore = MockDoseStore()
        doseStore.basalProfile = basalRateSchedule
        doseStore.basalProfileApplyingOverrideHistory = doseStore.basalProfile
        doseStore.sensitivitySchedule = insulinSensitivitySchedule
        doseStore.doseHistory = predictionInput.doses
        doseStore.lastAddedPumpData = predictionInput.doses.last!.startDate
        let carbStore = MockCarbStore()
        carbStore.insulinSensitivityScheduleApplyingOverrideHistory = insulinSensitivitySchedule
        carbStore.carbRatioSchedule = carbRatioSchedule
        carbStore.carbRatioScheduleApplyingOverrideHistory = carbRatioSchedule
        carbStore.carbHistory = predictionInput.carbEntries


        dosingDecisionStore = MockDosingDecisionStore()
        automaticDosingStatus = AutomaticDosingStatus(automaticDosingEnabled: true, isAutomaticDosingAllowed: true)
        loopDataManager = LoopDataManager(
            lastLoopCompleted: currentDate,
            basalDeliveryState: .active(currentDate),
            settings: settings,
            overrideHistory: TemporaryScheduleOverrideHistory(),
            analyticsServicesManager: AnalyticsServicesManager(),
            localCacheDuration: .days(1),
            doseStore: doseStore,
            glucoseStore: glucoseStore,
            carbStore: carbStore,
            dosingDecisionStore: dosingDecisionStore,
            latestStoredSettingsProvider: MockLatestStoredSettingsProvider(),
            now: { currentDate },
            pumpInsulinType: .novolog,
            automaticDosingStatus: automaticDosingStatus,
            trustedTimeOffset: { 0 }
        )

        let expectedPredictedGlucose = loadPredictedGlucoseFixture("live_capture_predicted_glucose")

        let updateGroup = DispatchGroup()
        updateGroup.enter()
        var predictedGlucose: [PredictedGlucoseValue]?
        var recommendedBasal: TempBasalRecommendation?
        self.loopDataManager.getLoopState { _, state in
            predictedGlucose = state.predictedGlucoseIncludingPendingInsulin
            recommendedBasal = state.recommendedAutomaticDose?.recommendation.basalAdjustment
            updateGroup.leave()
        }
        // We need to wait until the task completes to get outputs
        updateGroup.wait()

        XCTAssertNotNil(predictedGlucose)

        XCTAssertEqual(expectedPredictedGlucose.count, predictedGlucose!.count)

        for (expected, calculated) in zip(expectedPredictedGlucose, predictedGlucose!) {
            XCTAssertEqual(expected.startDate, calculated.startDate)
            XCTAssertEqual(expected.quantity.doubleValue(for: .milligramsPerDeciliter), calculated.quantity.doubleValue(for: .milligramsPerDeciliter), accuracy: defaultAccuracy)
        }
    }


    func testFlatAndStable() {
        setUp(for: .flatAndStable)
        let predictedGlucoseOutput = loadLocalDateGlucoseEffect("flat_and_stable_predicted_glucose")

        let updateGroup = DispatchGroup()
        updateGroup.enter()
        var predictedGlucose: [PredictedGlucoseValue]?
        var recommendedDose: AutomaticDoseRecommendation?
        self.loopDataManager.getLoopState { _, state in
            predictedGlucose = state.predictedGlucose
            recommendedDose = state.recommendedAutomaticDose?.recommendation
            updateGroup.leave()
        }
        // We need to wait until the task completes to get outputs
        updateGroup.wait()

        XCTAssertNotNil(predictedGlucose)
        XCTAssertEqual(predictedGlucoseOutput.count, predictedGlucose!.count)
        
        for (expected, calculated) in zip(predictedGlucoseOutput, predictedGlucose!) {
            XCTAssertEqual(expected.startDate, calculated.startDate)
            XCTAssertEqual(expected.quantity.doubleValue(for: .milligramsPerDeciliter), calculated.quantity.doubleValue(for: .milligramsPerDeciliter), accuracy: defaultAccuracy)
        }
        
        let recommendedTempBasal = recommendedDose?.basalAdjustment

        XCTAssertEqual(1.40, recommendedTempBasal!.unitsPerHour, accuracy: defaultAccuracy)
    }
    
    func testHighAndStable() {
        setUp(for: .highAndStable)
        let predictedGlucoseOutput = loadLocalDateGlucoseEffect("high_and_stable_predicted_glucose")

        let updateGroup = DispatchGroup()
        updateGroup.enter()
        var predictedGlucose: [PredictedGlucoseValue]?
        var recommendedBasal: TempBasalRecommendation?
        self.loopDataManager.getLoopState { _, state in
            predictedGlucose = state.predictedGlucose
            recommendedBasal = state.recommendedAutomaticDose?.recommendation.basalAdjustment
            updateGroup.leave()
        }
        // We need to wait until the task completes to get outputs
        updateGroup.wait()

        XCTAssertNotNil(predictedGlucose)
        XCTAssertEqual(predictedGlucoseOutput.count, predictedGlucose!.count)
        
        for (expected, calculated) in zip(predictedGlucoseOutput, predictedGlucose!) {
            XCTAssertEqual(expected.startDate, calculated.startDate)
            XCTAssertEqual(expected.quantity.doubleValue(for: .milligramsPerDeciliter), calculated.quantity.doubleValue(for: .milligramsPerDeciliter), accuracy: defaultAccuracy)
        }

        XCTAssertEqual(4.63, recommendedBasal!.unitsPerHour, accuracy: defaultAccuracy)
    }
    
    func testHighAndFalling() {
        setUp(for: .highAndFalling)
        let predictedGlucoseOutput = loadLocalDateGlucoseEffect("high_and_falling_predicted_glucose")

        let updateGroup = DispatchGroup()
        updateGroup.enter()
        var predictedGlucose: [PredictedGlucoseValue]?
        var recommendedTempBasal: TempBasalRecommendation?
        self.loopDataManager.getLoopState { _, state in
            predictedGlucose = state.predictedGlucose
            recommendedTempBasal = state.recommendedAutomaticDose?.recommendation.basalAdjustment
            updateGroup.leave()
        }
        // We need to wait until the task completes to get outputs
        updateGroup.wait()

        XCTAssertNotNil(predictedGlucose)
        XCTAssertEqual(predictedGlucoseOutput.count, predictedGlucose!.count)
        
        for (expected, calculated) in zip(predictedGlucoseOutput, predictedGlucose!) {
            XCTAssertEqual(expected.startDate, calculated.startDate)
            XCTAssertEqual(expected.quantity.doubleValue(for: .milligramsPerDeciliter), calculated.quantity.doubleValue(for: .milligramsPerDeciliter), accuracy: defaultAccuracy)
        }

        XCTAssertEqual(0, recommendedTempBasal!.unitsPerHour, accuracy: defaultAccuracy)
    }
    
    func testHighAndRisingWithCOB() {
        setUp(for: .highAndRisingWithCOB)
        let predictedGlucoseOutput = loadLocalDateGlucoseEffect("high_and_rising_with_cob_predicted_glucose")

        let updateGroup = DispatchGroup()
        updateGroup.enter()
        var predictedGlucose: [PredictedGlucoseValue]?
        var recommendedBolus: ManualBolusRecommendation?
        self.loopDataManager.getLoopState { _, state in
            predictedGlucose = state.predictedGlucose
            recommendedBolus = try? state.recommendBolus(consideringPotentialCarbEntry: nil, replacingCarbEntry: nil, considerPositiveVelocityAndRC: true)
            updateGroup.leave()
        }
        // We need to wait until the task completes to get outputs
        updateGroup.wait()

        XCTAssertNotNil(predictedGlucose)
        XCTAssertEqual(predictedGlucoseOutput.count, predictedGlucose!.count)
        
        for (expected, calculated) in zip(predictedGlucoseOutput, predictedGlucose!) {
            XCTAssertEqual(expected.startDate, calculated.startDate)
            XCTAssertEqual(expected.quantity.doubleValue(for: .milligramsPerDeciliter), calculated.quantity.doubleValue(for: .milligramsPerDeciliter), accuracy: defaultAccuracy)
        }

        XCTAssertEqual(1.6, recommendedBolus!.amount, accuracy: defaultAccuracy)
    }
    
    func testLowAndFallingWithCOB() {
        setUp(for: .lowAndFallingWithCOB)
        let predictedGlucoseOutput = loadLocalDateGlucoseEffect("low_and_falling_predicted_glucose")

        let updateGroup = DispatchGroup()
        updateGroup.enter()
        var predictedGlucose: [PredictedGlucoseValue]?
        var recommendedTempBasal: TempBasalRecommendation?
        self.loopDataManager.getLoopState { _, state in
            predictedGlucose = state.predictedGlucose
            recommendedTempBasal = state.recommendedAutomaticDose?.recommendation.basalAdjustment
            updateGroup.leave()
        }
        // We need to wait until the task completes to get outputs
        updateGroup.wait()

        XCTAssertNotNil(predictedGlucose)
        XCTAssertEqual(predictedGlucoseOutput.count, predictedGlucose!.count)
        
        for (expected, calculated) in zip(predictedGlucoseOutput, predictedGlucose!) {
            XCTAssertEqual(expected.startDate, calculated.startDate)
            XCTAssertEqual(expected.quantity.doubleValue(for: .milligramsPerDeciliter), calculated.quantity.doubleValue(for: .milligramsPerDeciliter), accuracy: defaultAccuracy)
        }

        XCTAssertEqual(0, recommendedTempBasal!.unitsPerHour, accuracy: defaultAccuracy)
    }
    
    func testLowWithLowTreatment() {
        setUp(for: .lowWithLowTreatment)
        let predictedGlucoseOutput = loadLocalDateGlucoseEffect("low_with_low_treatment_predicted_glucose")

        let updateGroup = DispatchGroup()
        updateGroup.enter()
        var predictedGlucose: [PredictedGlucoseValue]?
        var recommendedTempBasal: TempBasalRecommendation?
        self.loopDataManager.getLoopState { _, state in
            predictedGlucose = state.predictedGlucose
            recommendedTempBasal = state.recommendedAutomaticDose?.recommendation.basalAdjustment
            updateGroup.leave()
        }
        // We need to wait until the task completes to get outputs
        updateGroup.wait()

        XCTAssertNotNil(predictedGlucose)
        XCTAssertEqual(predictedGlucoseOutput.count, predictedGlucose!.count)
        
        for (expected, calculated) in zip(predictedGlucoseOutput, predictedGlucose!) {
            XCTAssertEqual(expected.startDate, calculated.startDate)
            XCTAssertEqual(expected.quantity.doubleValue(for: .milligramsPerDeciliter), calculated.quantity.doubleValue(for: .milligramsPerDeciliter), accuracy: defaultAccuracy)
        }

        XCTAssertEqual(0, recommendedTempBasal!.unitsPerHour, accuracy: defaultAccuracy)
    }

    func waitOnDataQueue(timeout: TimeInterval = 10.0) {
        let e = expectation(description: "dataQueue")
        loopDataManager.getLoopState { _, _ in
            e.fulfill()
        }
        wait(for: [e], timeout: timeout)
    }
    
    func testValidateMaxTempBasalDoesntCancelTempBasalIfHigher() {
        let dose = DoseEntry(type: .tempBasal, startDate: Date(), endDate: nil, value: 3.0, unit: .unitsPerHour, deliveredUnits: nil, description: nil, syncIdentifier: nil, scheduledBasalRate: nil)
        setUp(for: .highAndStable, basalDeliveryState: .tempBasal(dose))
        // This wait is working around the issue presented by LoopDataManager.init().  It cancels the temp basal if
        // `isClosedLoop` is false (which it is from `setUp` above). When that happens, it races with
        // `maxTempBasalSavePreflight` below.  This ensures only one happens at a time.
        waitOnDataQueue()
        let delegate = MockDelegate()
        loopDataManager.delegate = delegate
        var error: Error?
        let exp = expectation(description: #function)
        XCTAssertNil(delegate.recommendation)
        loopDataManager.maxTempBasalSavePreflight(unitsPerHour: 5.0) {
            error = $0
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10.0)
        XCTAssertNil(error)
        XCTAssertNil(delegate.recommendation)
        XCTAssertTrue(dosingDecisionStore.dosingDecisions.isEmpty)
    }
    
    func testValidateMaxTempBasalCancelsTempBasalIfLower() {
        let dose = DoseEntry(type: .tempBasal, startDate: Date(), endDate: nil, value: 5.0, unit: .unitsPerHour, deliveredUnits: nil, description: nil, syncIdentifier: nil, scheduledBasalRate: nil)
        setUp(for: .highAndStable, basalDeliveryState: .tempBasal(dose))
        // This wait is working around the issue presented by LoopDataManager.init().  It cancels the temp basal if
        // `isClosedLoop` is false (which it is from `setUp` above). When that happens, it races with
        // `maxTempBasalSavePreflight` below.  This ensures only one happens at a time.
        waitOnDataQueue()
        let delegate = MockDelegate()
        loopDataManager.delegate = delegate
        var error: Error?
        let exp = expectation(description: #function)
        XCTAssertNil(delegate.recommendation)
        loopDataManager.maxTempBasalSavePreflight(unitsPerHour: 3.0) {
            error = $0
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10.0)
        XCTAssertNil(error)
        XCTAssertEqual(delegate.recommendation, AutomaticDoseRecommendation(basalAdjustment: .cancel))
        XCTAssertEqual(dosingDecisionStore.dosingDecisions.count, 1)
        XCTAssertEqual(dosingDecisionStore.dosingDecisions[0].reason, "maximumBasalRateChanged")
        XCTAssertEqual(dosingDecisionStore.dosingDecisions[0].automaticDoseRecommendation, AutomaticDoseRecommendation(basalAdjustment: .cancel))
    }
    
    func testChangingMaxBasalUpdatesLoopData() {
        setUp(for: .highAndStable)
        waitOnDataQueue()
        var loopDataUpdated = false
        let exp = expectation(description: #function)
        let observer = NotificationCenter.default.addObserver(forName: .LoopDataUpdated, object: nil, queue: nil) { _ in
            loopDataUpdated = true
            exp.fulfill()
        }
        XCTAssertFalse(loopDataUpdated)
        loopDataManager.mutateSettings { $0.maximumBasalRatePerHour = 2.0 }
        wait(for: [exp], timeout: 10.0)
        XCTAssertTrue(loopDataUpdated)
        NotificationCenter.default.removeObserver(observer)
    }

    func testOpenLoopCancelsTempBasal() {
        let dose = DoseEntry(type: .tempBasal, startDate: Date(), value: 1.0, unit: .unitsPerHour)
        setUp(for: .highAndStable, basalDeliveryState: .tempBasal(dose))
        waitOnDataQueue()
        let delegate = MockDelegate()
        loopDataManager.delegate = delegate
        let exp = expectation(description: #function)
        let observer = NotificationCenter.default.addObserver(forName: .LoopDataUpdated, object: nil, queue: nil) { _ in
            exp.fulfill()
        }
        automaticDosingStatus.automaticDosingEnabled = false
        wait(for: [exp], timeout: 10.0)
        let expectedAutomaticDoseRecommendation = AutomaticDoseRecommendation(basalAdjustment: .cancel)
        XCTAssertEqual(delegate.recommendation, expectedAutomaticDoseRecommendation)
        XCTAssertEqual(dosingDecisionStore.dosingDecisions.count, 1)
        XCTAssertEqual(dosingDecisionStore.dosingDecisions[0].reason, "automaticDosingDisabled")
        XCTAssertEqual(dosingDecisionStore.dosingDecisions[0].automaticDoseRecommendation, expectedAutomaticDoseRecommendation)
        NotificationCenter.default.removeObserver(observer)
    }

    func testReceivedUnreliableCGMReadingCancelsTempBasal() {
        let dose = DoseEntry(type: .tempBasal, startDate: Date(), value: 5.0, unit: .unitsPerHour)
        setUp(for: .highAndStable, basalDeliveryState: .tempBasal(dose))
        waitOnDataQueue()
        let delegate = MockDelegate()
        loopDataManager.delegate = delegate
        let exp = expectation(description: #function)
        let observer = NotificationCenter.default.addObserver(forName: .LoopDataUpdated, object: nil, queue: nil) { _ in
            exp.fulfill()
        }
        loopDataManager.receivedUnreliableCGMReading()
        wait(for: [exp], timeout: 10.0)
        let expectedAutomaticDoseRecommendation = AutomaticDoseRecommendation(basalAdjustment: .cancel)
        XCTAssertEqual(delegate.recommendation, expectedAutomaticDoseRecommendation)
        XCTAssertEqual(dosingDecisionStore.dosingDecisions.count, 1)
        XCTAssertEqual(dosingDecisionStore.dosingDecisions[0].reason, "unreliableCGMData")
        XCTAssertEqual(dosingDecisionStore.dosingDecisions[0].automaticDoseRecommendation, expectedAutomaticDoseRecommendation)
        NotificationCenter.default.removeObserver(observer)
    }

    func testLoopEnactsTempBasalWithoutManualBolusRecommendation() {
        setUp(for: .highAndStable)
        waitOnDataQueue()
        let delegate = MockDelegate()
        loopDataManager.delegate = delegate
        let exp = expectation(description: #function)
        let observer = NotificationCenter.default.addObserver(forName: .LoopCompleted, object: nil, queue: nil) { _ in
            exp.fulfill()
        }
        loopDataManager.loop()
        wait(for: [exp], timeout: 10.0)
        let expectedAutomaticDoseRecommendation = AutomaticDoseRecommendation(basalAdjustment: TempBasalRecommendation(unitsPerHour: 4.55, duration: .minutes(30)))
        XCTAssertEqual(delegate.recommendation, expectedAutomaticDoseRecommendation)
        XCTAssertEqual(dosingDecisionStore.dosingDecisions.count, 1)
        if dosingDecisionStore.dosingDecisions.count == 1 {
            XCTAssertEqual(dosingDecisionStore.dosingDecisions[0].reason, "loop")
            XCTAssertEqual(dosingDecisionStore.dosingDecisions[0].automaticDoseRecommendation, expectedAutomaticDoseRecommendation)
            XCTAssertNil(dosingDecisionStore.dosingDecisions[0].manualBolusRecommendation)
            XCTAssertNil(dosingDecisionStore.dosingDecisions[0].manualBolusRequested)
        }
        NotificationCenter.default.removeObserver(observer)
    }

    func testLoopRecommendsTempBasalWithoutEnactingIfOpenLoop() {
        setUp(for: .highAndStable)
        automaticDosingStatus.automaticDosingEnabled = false
        waitOnDataQueue()
        let delegate = MockDelegate()
        loopDataManager.delegate = delegate
        let exp = expectation(description: #function)
        let observer = NotificationCenter.default.addObserver(forName: .LoopCompleted, object: nil, queue: nil) { _ in
            exp.fulfill()
        }
        loopDataManager.loop()
        wait(for: [exp], timeout: 10.0)
        let expectedAutomaticDoseRecommendation = AutomaticDoseRecommendation(basalAdjustment: TempBasalRecommendation(unitsPerHour: 4.55, duration: .minutes(30)))
        XCTAssertNil(delegate.recommendation)
        XCTAssertEqual(dosingDecisionStore.dosingDecisions.count, 1)
        XCTAssertEqual(dosingDecisionStore.dosingDecisions[0].reason, "loop")
        XCTAssertEqual(dosingDecisionStore.dosingDecisions[0].automaticDoseRecommendation, expectedAutomaticDoseRecommendation)
        XCTAssertNil(dosingDecisionStore.dosingDecisions[0].manualBolusRecommendation)
        XCTAssertNil(dosingDecisionStore.dosingDecisions[0].manualBolusRequested)
        NotificationCenter.default.removeObserver(observer)
    }

    func testLoopGetStateRecommendsManualBolus() {
        setUp(for: .highAndStable)
        let exp = expectation(description: #function)
        var recommendedBolus: ManualBolusRecommendation?
        loopDataManager.getLoopState { (_, loopState) in
            recommendedBolus = try? loopState.recommendBolus(consideringPotentialCarbEntry: nil, replacingCarbEntry: nil, considerPositiveVelocityAndRC: true)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 100000.0)
        XCTAssertEqual(recommendedBolus!.amount, 1.82, accuracy: 0.01)
    }

    func testLoopGetStateRecommendsManualBolusWithMomentum() {
        setUp(for: .highAndRisingWithCOB)
        let exp = expectation(description: #function)
        var recommendedBolus: ManualBolusRecommendation?
        loopDataManager.getLoopState { (_, loopState) in
            recommendedBolus = try? loopState.recommendBolus(consideringPotentialCarbEntry: nil, replacingCarbEntry: nil, considerPositiveVelocityAndRC: true)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10.0)
        XCTAssertEqual(recommendedBolus!.amount, 1.62, accuracy: 0.01)
    }

    func testLoopGetStateRecommendsManualBolusWithoutMomentum() {
        setUp(for: .highAndRisingWithCOB)
        let exp = expectation(description: #function)
        var recommendedBolus: ManualBolusRecommendation?
        loopDataManager.getLoopState { (_, loopState) in
            recommendedBolus = try? loopState.recommendBolus(consideringPotentialCarbEntry: nil, replacingCarbEntry: nil, considerPositiveVelocityAndRC: false)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10.0)
        XCTAssertEqual(recommendedBolus!.amount, 1.52, accuracy: 0.01)
    }

    func testIsClosedLoopAvoidsTriggeringTempBasalCancelOnCreation() {
        let settings = LoopSettings(
            dosingEnabled: false,
            glucoseTargetRangeSchedule: glucoseTargetRangeSchedule,
            maximumBasalRatePerHour: 5,
            maximumBolus: 10,
            suspendThreshold: suspendThreshold
        )

        let doseStore = MockDoseStore()
        let glucoseStore = MockGlucoseStore(for: .flatAndStable)
        let carbStore = MockCarbStore()

        let currentDate = Date()

        dosingDecisionStore = MockDosingDecisionStore()
        automaticDosingStatus = AutomaticDosingStatus(automaticDosingEnabled: false, isAutomaticDosingAllowed: true)
        let existingTempBasal = DoseEntry(
            type: .tempBasal,
            startDate: currentDate.addingTimeInterval(-.minutes(2)),
            endDate: currentDate.addingTimeInterval(.minutes(28)),
            value: 1.0,
            unit: .unitsPerHour,
            deliveredUnits: nil,
            description: "Mock Temp Basal",
            syncIdentifier: "asdf",
            scheduledBasalRate: nil,
            insulinType: .novolog,
            automatic: true,
            manuallyEntered: false,
            isMutable: true)
        loopDataManager = LoopDataManager(
            lastLoopCompleted: currentDate.addingTimeInterval(-.minutes(5)),
            basalDeliveryState: .tempBasal(existingTempBasal),
            settings: settings,
            overrideHistory: TemporaryScheduleOverrideHistory(),
            analyticsServicesManager: AnalyticsServicesManager(),
            localCacheDuration: .days(1),
            doseStore: doseStore,
            glucoseStore: glucoseStore,
            carbStore: carbStore,
            dosingDecisionStore: dosingDecisionStore,
            latestStoredSettingsProvider: MockLatestStoredSettingsProvider(),
            now: { currentDate },
            pumpInsulinType: .novolog,
            automaticDosingStatus: automaticDosingStatus,
            trustedTimeOffset: { 0 }
        )
        let mockDelegate = MockDelegate()
        loopDataManager.delegate = mockDelegate

        // Dose enacting happens asynchronously, as does receiving isClosedLoop signals
        waitOnMain(timeout: 5)
        XCTAssertNil(mockDelegate.recommendation)
    }

    func testAutoBolusMaxIOBClamping() {
        /// `maxBolus` is set to clamp the automatic dose
        /// Autobolus without clamping: 0.65 U. Clamped recommendation: 0.2 U.
        setUp(for: .highAndRisingWithCOB, maxBolus: 5, dosingStrategy: .automaticBolus)

        // This sets up dose rounding
        let delegate = MockDelegate()
        loopDataManager.delegate = delegate

        let updateGroup = DispatchGroup()
        updateGroup.enter()

        var insulinOnBoard: InsulinValue?
        var recommendedBolus: Double?
        self.loopDataManager.getLoopState { _, state in
            insulinOnBoard = state.insulinOnBoard
            recommendedBolus = state.recommendedAutomaticDose?.recommendation.bolusUnits
            updateGroup.leave()
        }
        updateGroup.wait()

        XCTAssertEqual(recommendedBolus!, 0.5, accuracy: 0.01)
        XCTAssertEqual(insulinOnBoard?.value, 9.5)

        /// Set the `maximumBolus` to 10U so there's no clamping
        updateGroup.enter()
        self.loopDataManager.mutateSettings { settings in settings.maximumBolus = 10 }
        self.loopDataManager.getLoopState { _, state in
            insulinOnBoard = state.insulinOnBoard
            recommendedBolus = state.recommendedAutomaticDose?.recommendation.bolusUnits
            updateGroup.leave()
        }
        updateGroup.wait()

        XCTAssertEqual(recommendedBolus!, 0.65, accuracy: 0.01)
        XCTAssertEqual(insulinOnBoard?.value, 9.5)
    }

    func testTempBasalMaxIOBClamping() {
        /// `maximumBolus` is set to 5U to clamp max IOB at 10U
        /// Without clamping: 4.25 U/hr. Clamped recommendation: 2.0 U/hr.
        setUp(for: .highAndRisingWithCOB, maxBolus: 5)

        // This sets up dose rounding
        let delegate = MockDelegate()
        loopDataManager.delegate = delegate

        let updateGroup = DispatchGroup()
        updateGroup.enter()

        var insulinOnBoard: InsulinValue?
        var recommendedBasal: TempBasalRecommendation?
        self.loopDataManager.getLoopState { _, state in
            insulinOnBoard = state.insulinOnBoard
            recommendedBasal = state.recommendedAutomaticDose?.recommendation.basalAdjustment
            updateGroup.leave()
        }
        updateGroup.wait()

        XCTAssertEqual(recommendedBasal!.unitsPerHour, 2.0, accuracy: 0.01)
        XCTAssertEqual(insulinOnBoard?.value, 9.5)

        /// Set the `maximumBolus` to 10U so there's no clamping
        updateGroup.enter()
        self.loopDataManager.mutateSettings { settings in settings.maximumBolus = 10 }
        self.loopDataManager.getLoopState { _, state in
            insulinOnBoard = state.insulinOnBoard
            recommendedBasal = state.recommendedAutomaticDose?.recommendation.basalAdjustment
            updateGroup.leave()
        }
        updateGroup.wait()

        XCTAssertEqual(recommendedBasal!.unitsPerHour, 4.25, accuracy: 0.01)
        XCTAssertEqual(insulinOnBoard?.value, 9.5)
    }


    // MARK: - Negative IOB clamp

    /// A cumulative glucose effect timeline that ramps linearly from 0 at `start` to `total` mg/dL after `rampDuration`,
    /// then stays flat. It begins 30 minutes before `start`, so the value at "now" is exactly 0.
    private func rampingEffect(from start: Date, total: Double, rampDuration: TimeInterval) -> [GlucoseEffect] {
        return stride(from: -TimeInterval(minutes: 30), through: TimeInterval(hours: 6), by: TimeInterval(minutes: 5)).map { offset in
            let fraction = min(max(offset, 0) / rampDuration, 1)
            return GlucoseEffect(
                startDate: start.addingTimeInterval(offset),
                quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: total * fraction)
            )
        }
    }

    /// Recommended manual bolus for a 30 g meal, given an IOB and the glucose effect that IOB implies.
    ///
    /// - Parameters:
    ///   - iob: IOB reported by the dose store. Negative IOB implies a rising insulin effect.
    ///   - insulinEffectTotal: Total insulin glucose effect over 4 hours, in mg/dL. Positive for negative IOB.
    ///   - clampEnabled: State of the Negative IOB Clamp experiment.
    private func manualBolusFor30gMeal(iob: Double, insulinEffectTotal: Double, clampEnabled: Bool) -> Double {
        UserDefaults.standard.negativeIOBClampEnabled = clampEnabled

        // 30 g at a 10 g/U carb ratio and 45 mg/dL/U sensitivity raises glucose by 135 mg/dL over 3 hours
        setUp(for: .flatAndStable) { doseStore, carbStore in
            doseStore.insulinOnBoardOverride = iob
            doseStore.glucoseEffectsOverride = self.rampingEffect(from: self.currentScenarioDate, total: insulinEffectTotal, rampDuration: .hours(4))
            carbStore.glucoseEffectsOverride = self.rampingEffect(from: self.currentScenarioDate, total: 135, rampDuration: .hours(3))
        }

        let carbEntry = NewCarbEntry(
            quantity: HKQuantity(unit: .gram(), doubleValue: 30),
            startDate: now.addingTimeInterval(.minutes(1)),
            foodType: nil,
            absorptionTime: .hours(3)
        )

        let exp = expectation(description: #function)
        var recommendedBolus: ManualBolusRecommendation?
        loopDataManager.getLoopState { (_, loopState) in
            recommendedBolus = try? loopState.recommendBolus(consideringPotentialCarbEntry: carbEntry, replacingCarbEntry: nil, considerPositiveVelocityAndRC: true)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10.0)

        return recommendedBolus!.amount
    }

    private var currentScenarioDate: Date {
        DosingTestScenario.flatAndStable.currentDate
    }

    func testNegativeIOBWithoutClampIncreasesMealBolus() {
        let noInsulinOnBoard = manualBolusFor30gMeal(iob: 0, insulinEffectTotal: 0, clampEnabled: false)
        // -1 U of IOB at 45 mg/dL/U is a predicted rise of about 45-50 mg/dL
        let negativeInsulinOnBoard = manualBolusFor30gMeal(iob: -1.0, insulinEffectTotal: 50, clampEnabled: false)

        XCTAssertGreaterThan(noInsulinOnBoard, 1.0, "A 30 g meal should produce a meaningful bolus")
        XCTAssertGreaterThan(negativeInsulinOnBoard, noInsulinOnBoard + 0.5, "Without the clamp, negative IOB should add insulin to the recommendation")
    }

    func testNegativeIOBClampMakesMealBolusMatchZeroIOB() {
        let noInsulinOnBoard = manualBolusFor30gMeal(iob: 0, insulinEffectTotal: 0, clampEnabled: true)

        for (iob, effect) in [(-0.44, 22.0), (-1.0, 50.0), (-3.0, 150.0)] {
            let clamped = manualBolusFor30gMeal(iob: iob, insulinEffectTotal: effect, clampEnabled: true)
            XCTAssertEqual(clamped, noInsulinOnBoard, accuracy: 0.01, "With the clamp on, \(iob) U of IOB should be treated as 0")
        }
    }

    func testNegativeIOBClampDoesNotChangePositiveIOB() {
        // +1 U of IOB lowers the forecast by about 50 mg/dL
        let clampOff = manualBolusFor30gMeal(iob: 1.0, insulinEffectTotal: -50, clampEnabled: false)
        let clampOn = manualBolusFor30gMeal(iob: 1.0, insulinEffectTotal: -50, clampEnabled: true)

        XCTAssertEqual(clampOn, clampOff, accuracy: 0.001)
    }

    func testNegativeIOBInputRowControlsForecastClamp() {
        UserDefaults.standard.negativeIOBClampEnabled = true
        setUp(for: .flatAndStable) { doseStore, _ in
            doseStore.insulinOnBoardOverride = -1.0
            doseStore.glucoseEffectsOverride = self.rampingEffect(from: self.currentScenarioDate, total: 50, rampDuration: .hours(4))
        }

        let exp = expectation(description: #function)
        var withClamp: [GlucoseValue]?
        var withoutClampRow: [GlucoseValue]?
        loopDataManager.getLoopState { (_, loopState) in
            withClamp = try? loopState.predictGlucose(using: .all)
            withoutClampRow = try? loopState.predictGlucose(using: PredictionInputEffect.all.subtracting(.negativeIOB))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10.0)

        let unit = HKUnit.milligramsPerDeciliter
        let clampedEnd = withClamp!.last!.quantity.doubleValue(for: unit)
        let unclampedEnd = withoutClampRow!.last!.quantity.doubleValue(for: unit)

        // Unticking the Negative IOB row restores the rise caused by the negative insulin effect
        XCTAssertEqual(unclampedEnd - clampedEnd, 50, accuracy: 1.0)
    }

}
