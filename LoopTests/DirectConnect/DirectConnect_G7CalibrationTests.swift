//
//  DirectConnect_G7CalibrationTests.swift
//  LoopTests
//
//  Concept & design by Taylor Patterson. Coded & tested by Claude Code in October 2026.
//  Message vectors captured and published by xDrip4iOS (GPL-3.0).
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import XCTest
@testable import Loop

final class DirectConnect_G7CalibrationTests: XCTestCase {
    private func bounds(_ hex: String) throws -> DirectConnect_CalibrationBounds {
        try XCTUnwrap(DirectConnect_CalibrationBounds(data: Data(dcHex: hex)!))
    }

    private func response(_ bytes: [UInt8]) -> DirectConnect_CalibrationCommandResponse? {
        DirectConnect_CalibrationCommandResponse(data: Data(bytes))
    }

    // MARK: - Ported from xDrip4iOS DexcomG7CalibrationTests

    func testCalibrationCommandUsesG6WireFormatWithExplicitTransmitterTime() {
        let command = DirectConnect_CalibrationCommand(glucose: 153, transmitterTime: 0x0008_840E)
        XCTAssertEqual(command.data.count, 9)
        XCTAssertEqual(command.data.prefix(7), Data([0x34, 0x99, 0x00, 0x0E, 0x84, 0x08, 0x00]))
        XCTAssertEqual(command.data.prefix(7).dcCRC16, command.data.dcUInt16LE(at: 7))
    }

    func testCapturedBoundsProgressFromInProgressToCompleteHigh() throws {
        let first = try bounds("3200017400000099000e840800020102a1840800")
        let second = try bounds("3200017400000099000e84080002010250850800")
        let third = try bounds("3200017400000099000e84080003010250850800")
        XCTAssertEqual(first.sessionNumber, 1)
        XCTAssertEqual(first.sessionSignature, 116)
        XCTAssertEqual(first.glucose, 153)
        XCTAssertEqual(first.calibrationTime, 0x0008_840E)
        XCTAssertEqual(first.processingState, .inProgress)
        XCTAssertTrue(first.calibrationsPermitted)
        XCTAssertEqual(first.lastProcessingUpdateTime, 0x0008_84A1)
        XCTAssertEqual(second.processingState, .inProgress)
        XCTAssertEqual(third.processingState, .completeHigh)
        XCTAssertTrue(third.matches(glucose: 153, transmitterTime: 0x0008_840E))
        XCTAssertFalse(third.matches(glucose: 152, transmitterTime: 0x0008_840E))
        XCTAssertFalse(third.matches(glucose: 153, transmitterTime: 0x0008_8420))
    }

    func testPreviousCalibrationBoundsDoNotMatchInFlightCalibration() throws {
        let previous = try bounds("3200015d0000006b00aaca0000030102ebcb0000")
        let inFlight = try bounds("3200015d0000006e0015df00000201024fe00000")
        XCTAssertFalse(previous.matches(glucose: 110, transmitterTime: 57109))
        XCTAssertTrue(inFlight.matches(glucose: 110, transmitterTime: 57109))
    }

    func testCalibrationCommandResponsesDecodeAcceptedRejectedAndUnknownStatuses() {
        XCTAssertEqual(response([0x34, 0, 0, 0])?.status, .acceptedHigh(.accepted))
        XCTAssertEqual(response([0x34, 0, 1, 0])?.status, .acceptedLow(.accepted))
        XCTAssertEqual(response([0x34, 0, 0, 1])?.status, .acceptedHigh(.error0))
        XCTAssertEqual(response([0x34, 0, 1, 2])?.status, .acceptedLow(.error1))
        XCTAssertEqual(response([0x34, 0, 2, 3])?.status, .rejected(.duplicate))
        XCTAssertEqual(response([0x34, 0, 2, 6])?.status, .rejected(.alreadyEntered))
        XCTAssertEqual(response([0x34, 0, 2, 8])?.status, .rejected(.notPermitted))
        XCTAssertEqual(response([0x34, 0, 3, 0])?.status, .factoryCalibrated)
        XCTAssertEqual(response([0x34, 0, 9, 7])?.status, .unknown(primary: 9, secondary: 7))
    }

    func testAllDocumentedRejectionReasonsRemainDistinct() {
        let expected: [DirectConnect_CalibrationRejectionReason] = [
            .unspecified, .outsideRange, .timestampInFuture, .duplicate,
            .earlierThanSessionStart, .notInOrder, .alreadyEntered, .disabled,
            .notPermitted, .calibrationBoundsFailed, .extremeOutlier, .stale,
        ]
        XCTAssertEqual((0...11).map { DirectConnect_CalibrationRejectionReason(rawValue: UInt8($0)) }, expected)
        XCTAssertEqual(DirectConnect_CalibrationRejectionReason(rawValue: 99), .unknown(99))
    }

    func testMalformedResponsesAreRejected() {
        XCTAssertNil(DirectConnect_CalibrationCommandResponse(data: Data([0x34, 0, 0])))
        XCTAssertNil(DirectConnect_CalibrationCommandResponse(data: Data([0x35, 0, 0, 0])))
        XCTAssertNil(DirectConnect_CalibrationBounds(data: Data(repeating: 0, count: 20)))
        XCTAssertNil(DirectConnect_CalibrationBounds(data: Data([0x32])))
    }

    func testClockReferenceConvertsWallClock() {
        let receivedAt = Date(timeIntervalSince1970: 1000)
        let clock = DirectConnect_ClockReference(transmitterTime: 10000, referenceDate: receivedAt)
        XCTAssertEqual(clock.transmitterTime(for: receivedAt.addingTimeInterval(-90)), 9910)
        XCTAssertEqual(clock.transmitterTime(for: receivedAt.addingTimeInterval(30)), 10030)
    }

    // MARK: - Queue behaviour

    private func clock(_ now: Date, _ time: UInt32 = 1000) -> DirectConnect_ClockReference {
        DirectConnect_ClockReference(transmitterTime: time, referenceDate: now)
    }

    func testEnqueueRejectsOutOfRangeStaleAndFuture() {
        var q = DirectConnect_CalibrationQueue()
        XCTAssertFalse(q.enqueue(glucose: 35, date: Date()))
        XCTAssertFalse(q.enqueue(glucose: 401, date: Date()))
        XCTAssertFalse(q.enqueue(glucose: 120, date: Date().addingTimeInterval(-600)))
        XCTAssertFalse(q.enqueue(glucose: 120, date: Date().addingTimeInterval(120)))
        XCTAssertTrue(q.enqueue(glucose: 120, date: Date()))
        XCTAssertEqual(q.status, .queued)
    }

    func testEnqueueRefusedWhileOneIsInProgress() {
        var q = DirectConnect_CalibrationQueue()
        XCTAssertTrue(q.enqueue(glucose: 120, date: Date()))
        XCTAssertFalse(q.enqueue(glucose: 130, date: Date()))
    }

    func testCommandUsesClockReference() {
        var q = DirectConnect_CalibrationQueue()
        let now = Date()
        XCTAssertTrue(q.enqueue(glucose: 120, date: now))
        let data = q.nextCommand(clock: clock(now.addingTimeInterval(-10)), now: now)!
        XCTAssertEqual(data[0], 0x34)
        XCTAssertEqual(data.dcUInt16LE(at: 1), 120)
        XCTAssertEqual(data.dcUInt32LE(at: 3), 1010)
        XCTAssertEqual(q.status, .sent)
    }

    func testNoCommandWithoutWorkSendsRoutineNothing() {
        var q = DirectConnect_CalibrationQueue()
        XCTAssertNil(q.nextCommand(clock: clock(Date()), now: Date()))
    }

    func testNoClockMeansNoCommand() {
        var q = DirectConnect_CalibrationQueue()
        XCTAssertTrue(q.enqueue(glucose: 120, date: Date()))
        XCTAssertNil(q.nextCommand(clock: nil, now: Date()))
        XCTAssertEqual(q.status, .queued)
    }

    func testCalibrationThatBecameStaleWhileQueuedIsDropped() {
        var q = DirectConnect_CalibrationQueue()
        let entered = Date()
        XCTAssertTrue(q.enqueue(glucose: 120, date: entered))
        XCTAssertNil(q.nextCommand(clock: clock(entered), now: entered.addingTimeInterval(400)))
        XCTAssertNil(q.pending)
        XCTAssertEqual(q.status, .rejected("stale"))
    }

    func testInterruptedCommandIsRequeued() {
        var q = DirectConnect_CalibrationQueue()
        let now = Date()
        XCTAssertTrue(q.enqueue(glucose: 120, date: now))
        _ = q.nextCommand(clock: clock(now), now: now)
        q.connectionDidEnd()
        XCTAssertEqual(q.status, .queued)
        XCTAssertNotNil(q.pending)
    }

    func testRejectedResponseShowsReason() {
        var q = DirectConnect_CalibrationQueue()
        let now = Date()
        XCTAssertTrue(q.enqueue(glucose: 120, date: now))
        _ = q.nextCommand(clock: clock(now), now: now)
        XCTAssertNil(q.handleCommandResponse(Data([0x34, 0x00, 0x02, 0x01])))
        XCTAssertEqual(q.status, .rejected("outside range"))
        XCTAssertNil(q.awaitingBounds)
    }

    func testAcceptedResponseRequestsBoundsThenCompletes() throws {
        var q = DirectConnect_CalibrationQueue()
        let now = Date()
        XCTAssertTrue(q.enqueue(glucose: 153, date: now))
        _ = q.nextCommand(clock: clock(now, 0x0008_840E), now: now)
        XCTAssertEqual(q.handleCommandResponse(Data([0x34, 0x00, 0x00, 0x00])), DirectConnect_G7Requests.calibrationBounds)
        XCTAssertEqual(q.status, .processing)
        q.handleBounds(Data(dcHex: "3200017400000099000e840800020102a1840800")!)
        XCTAssertEqual(q.status, .processing)
        q.handleBounds(Data(dcHex: "3200017400000099000e84080003010250850800")!)
        XCTAssertEqual(q.status, .completed)
        XCTAssertNil(q.awaitingBounds)
    }

    func testCompletedCalibrationIsRememberedAcrossNewEntries() throws {
        var q = DirectConnect_CalibrationQueue()
        let entered = Date()
        XCTAssertNil(q.lastCompleted)
        XCTAssertTrue(q.enqueue(glucose: 153, date: entered))
        _ = q.nextCommand(clock: clock(entered, 0x0008_840E), now: entered)
        _ = q.handleCommandResponse(Data([0x34, 0x00, 0x00, 0x00]))
        XCTAssertNil(q.lastCompleted)
        q.handleBounds(Data(dcHex: "3200017400000099000e84080003010250850800")!)
        XCTAssertEqual(q.lastCompleted?.glucose, 153)
        XCTAssertEqual(q.lastCompleted?.date, entered)
        // A new entry, or one the sensor rejects, keeps the last good one.
        XCTAssertTrue(q.enqueue(glucose: 120, date: Date()))
        _ = q.nextCommand(clock: clock(Date()), now: Date())
        _ = q.handleCommandResponse(Data([0x34, 0x00, 0x02, 0x01]))
        XCTAssertEqual(q.lastCompleted?.glucose, 153)
        let decoded = try JSONDecoder().decode(DirectConnect_CalibrationQueue.self, from: JSONEncoder().encode(q))
        XCTAssertEqual(decoded.lastCompleted, q.lastCompleted)
    }

    func testStaleBoundsForPreviousCalibrationAreIgnored() {
        var q = DirectConnect_CalibrationQueue()
        let now = Date()
        XCTAssertTrue(q.enqueue(glucose: 110, date: now))
        _ = q.nextCommand(clock: clock(now, 57109), now: now)
        _ = q.handleCommandResponse(Data([0x34, 0x00, 0x00, 0x00]))
        q.handleBounds(Data(dcHex: "3200015d0000006b00aaca0000030102ebcb0000")!)
        XCTAssertEqual(q.status, .processing)
        XCTAssertNotNil(q.awaitingBounds)
    }

    func testNotPermittedBounds() {
        var q = DirectConnect_CalibrationQueue()
        let now = Date()
        XCTAssertTrue(q.enqueue(glucose: 153, date: now))
        _ = q.nextCommand(clock: clock(now, 0x0008_840E), now: now)
        _ = q.handleCommandResponse(Data([0x34, 0x00, 0x00, 0x00]))
        // Same record with "calibrations permitted" (byte 14) cleared.
        q.handleBounds(Data(dcHex: "3200017400000099000e840800020002a1840800")!)
        XCTAssertEqual(q.status, .notPermitted)
    }

    private func processingQueue(glucose: Double = 185, time: UInt32 = 5000) -> DirectConnect_CalibrationQueue {
        var q = DirectConnect_CalibrationQueue()
        let now = Date()
        XCTAssertTrue(q.enqueue(glucose: glucose, date: now))
        _ = q.nextCommand(clock: clock(now, time), now: now)
        _ = q.handleCommandResponse(Data([0x34, 0x00, 0x00, 0x00]))
        XCTAssertEqual(q.status, .processing)
        return q
    }

    func testNewCalibrationReplacesOneStillProcessing() {
        var q = processingQueue()
        XCTAssertTrue(q.enqueue(glucose: 65, date: Date()))
        XCTAssertEqual(q.status, .queued)
        XCTAssertNil(q.awaitingBounds)
        XCTAssertEqual(q.pending?.glucose, 65)
    }

    func testUnansweredBoundsRequestsStopAfterLimit() {
        var q = processingQueue()
        for _ in 0..<DirectConnect_CalibrationQueue.maxBoundsRequests {
            XCTAssertEqual(q.nextCommand(clock: clock(Date()), now: Date()), DirectConnect_G7Requests.calibrationBounds)
        }
        XCTAssertNil(q.nextCommand(clock: clock(Date()), now: Date()))
        XCTAssertNil(q.awaitingBounds)
        XCTAssertEqual(q.status, .unconfirmed)
        XCTAssertFalse(q.status.isInProgress)
        XCTAssertTrue(q.enqueue(glucose: 65, date: Date()))
    }

    func testProcessingGivesUpAfterTimeLimitEvenWithoutSensorWakes() {
        var q = processingQueue()
        let start = q.awaitingSince!
        XCTAssertFalse(q.expireIfOverdue(now: start.addingTimeInterval(DirectConnect_CalibrationQueue.maxProcessingTime - 1)))
        XCTAssertEqual(q.status, .processing)
        XCTAssertTrue(q.expireIfOverdue(now: start.addingTimeInterval(DirectConnect_CalibrationQueue.maxProcessingTime)))
        XCTAssertEqual(q.status, .unconfirmed)
        XCTAssertNil(q.awaitingBounds)
        XCTAssertFalse(q.expireIfOverdue(now: Date()))
    }

    func testBoundsReportWhetherTheyMatchedTheCalibration() {
        var q = processingQueue(glucose: 110, time: 57109)
        XCTAssertFalse(q.handleBounds(Data(dcHex: "3200015d0000006b00aaca0000030102ebcb0000")!))
        XCTAssertTrue(q.handleBounds(Data(dcHex: "3200015d0000006e0015df00000201024fe00000")!))
    }

    func testRefusalReasonSeparatesRangeFromBusy() {
        var q = DirectConnect_CalibrationQueue()
        XCTAssertEqual(q.refusalReason(glucose: 30, date: Date()), .outOfRange)
        XCTAssertNil(q.refusalReason(glucose: 120, date: Date()))
        XCTAssertTrue(q.enqueue(glucose: 120, date: Date()))
        XCTAssertEqual(q.refusalReason(glucose: 130, date: Date()), .waitingToSend)
    }

    func testCodableRoundTrip() throws {
        var q = DirectConnect_CalibrationQueue()
        XCTAssertTrue(q.enqueue(glucose: 120, date: Date()))
        let decoded = try JSONDecoder().decode(DirectConnect_CalibrationQueue.self, from: JSONEncoder().encode(q))
        XCTAssertEqual(decoded, q)
    }
}
