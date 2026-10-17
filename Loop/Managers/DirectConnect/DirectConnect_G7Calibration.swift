//
//  DirectConnect_G7Calibration.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — G7 calibration command, responses, bounds record and queue.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Portions derived from xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import Foundation

// MARK: - Wire messages

/// 0x34 command: opcode, glucose (UInt16 LE), transmitter time (UInt32 LE), CRC16.
struct DirectConnect_CalibrationCommand: Equatable {
    let glucose: UInt16
    let transmitterTime: UInt32

    var data: Data {
        (Data([DirectConnect_G7Opcode.calibrate.rawValue])
            + Data.dcUInt16LEBytes(glucose)
            + Data.dcUInt32LEBytes(transmitterTime)).dcAppendingCRC()
    }
}

enum DirectConnect_CalibrationRejectionReason: Equatable {
    case unspecified
    case outsideRange
    case timestampInFuture
    case duplicate
    case earlierThanSessionStart
    case notInOrder
    case alreadyEntered
    case disabled
    case notPermitted
    case calibrationBoundsFailed
    case extremeOutlier
    case stale
    case unknown(UInt8)

    init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .unspecified
        case 1: self = .outsideRange
        case 2: self = .timestampInFuture
        case 3: self = .duplicate
        case 4: self = .earlierThanSessionStart
        case 5: self = .notInOrder
        case 6: self = .alreadyEntered
        case 7: self = .disabled
        case 8: self = .notPermitted
        case 9: self = .calibrationBoundsFailed
        case 10: self = .extremeOutlier
        case 11: self = .stale
        default: self = .unknown(rawValue)
        }
    }

    var text: String {
        switch self {
        case .unspecified: return "unspecified"
        case .outsideRange: return "outside range"
        case .timestampInFuture: return "timestamp in future"
        case .duplicate: return "duplicate"
        case .earlierThanSessionStart: return "earlier than session start"
        case .notInOrder: return "not in order"
        case .alreadyEntered: return "already entered"
        case .disabled: return "disabled"
        case .notPermitted: return "not permitted"
        case .calibrationBoundsFailed: return "calibration bounds failed"
        case .extremeOutlier: return "extreme outlier"
        case .stale: return "stale"
        case .unknown(let raw): return "unknown (\(raw))"
        }
    }

    /// The sensor already has this value; treat it as being processed rather than failed.
    var isTerminalDuplicate: Bool {
        self == .duplicate || self == .alreadyEntered
    }
}

enum DirectConnect_CalibrationAcceptanceDetail: Equatable {
    case accepted
    case error0
    case error1
    case unknown(UInt8)

    init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .accepted
        case 1: self = .error0
        case 2: self = .error1
        default: self = .unknown(rawValue)
        }
    }
}

enum DirectConnect_CalibrationCommandStatus: Equatable {
    case acceptedHigh(DirectConnect_CalibrationAcceptanceDetail)
    case acceptedLow(DirectConnect_CalibrationAcceptanceDetail)
    case rejected(DirectConnect_CalibrationRejectionReason)
    case factoryCalibrated
    case unknown(primary: UInt8, secondary: UInt8)
}

/// Immediate 4-byte 0x34 response. It only says whether the sensor took the command for
/// processing; the 0x32 bounds record is the final answer.
struct DirectConnect_CalibrationCommandResponse: Equatable {
    let primaryStatus: UInt8
    let secondaryStatus: UInt8
    let status: DirectConnect_CalibrationCommandStatus

    init?(data: Data) {
        guard data.count == 4, data.dcByte(at: 0) == DirectConnect_G7Opcode.calibrate.rawValue else { return nil }
        primaryStatus = data.dcByte(at: 2)
        secondaryStatus = data.dcByte(at: 3)
        switch primaryStatus {
        case 0: status = .acceptedHigh(DirectConnect_CalibrationAcceptanceDetail(rawValue: secondaryStatus))
        case 1: status = .acceptedLow(DirectConnect_CalibrationAcceptanceDetail(rawValue: secondaryStatus))
        case 2: status = .rejected(DirectConnect_CalibrationRejectionReason(rawValue: secondaryStatus))
        case 3: status = .factoryCalibrated
        default: status = .unknown(primary: primaryStatus, secondary: secondaryStatus)
        }
    }
}

enum DirectConnect_CalibrationProcessingState: UInt8, Equatable {
    case none = 0
    case factoryCalibrated = 1
    case inProgress = 2
    case completeHigh = 3
    case completeLow = 4
}

/// 20-byte 0x32 record describing the sensor's latest calibration.
struct DirectConnect_CalibrationBounds: Equatable {
    let sessionNumber: UInt8
    let sessionSignature: UInt32
    let glucose: UInt16
    let calibrationTime: UInt32
    let processingState: DirectConnect_CalibrationProcessingState?
    let calibrationsPermitted: Bool
    let lastProcessingUpdateTime: UInt32

    init?(data: Data) {
        guard data.count == 20, data.dcByte(at: 0) == DirectConnect_G7Opcode.calibrationBounds.rawValue else { return nil }
        sessionNumber = data.dcByte(at: 2)
        sessionSignature = data.dcUInt32LE(at: 3)
        glucose = data.dcUInt16LE(at: 7)
        calibrationTime = data.dcUInt32LE(at: 9)
        processingState = DirectConnect_CalibrationProcessingState(rawValue: data.dcByte(at: 13))
        calibrationsPermitted = data.dcByte(at: 14) != 0
        lastProcessingUpdateTime = data.dcUInt32LE(at: 16)
    }

    /// A stale record for the previous calibration can arrive right after a new command, so
    /// both value and time must match.
    func matches(glucose expectedGlucose: Double, transmitterTime expectedTime: UInt32, tolerance: UInt32 = 2) -> Bool {
        guard glucose == UInt16(expectedGlucose.rounded()) else { return false }
        return abs(Int64(calibrationTime) - Int64(expectedTime)) <= Int64(tolerance)
    }
}

/// Anchors wall-clock time to the sensor clock using the latest glucose packet.
struct DirectConnect_ClockReference: Equatable {
    let transmitterTime: UInt32
    let referenceDate: Date

    func transmitterTime(for date: Date) -> UInt32? {
        let resolved = Double(transmitterTime) + date.timeIntervalSince(referenceDate)
        guard resolved >= 0, resolved <= Double(UInt32.max) else { return nil }
        return UInt32(resolved.rounded())
    }
}

// MARK: - Queue

enum DirectConnect_CalibrationStatus: Equatable, Codable {
    case none
    case queued
    case sent
    case processing
    case completed
    case rejected(String)
    case notPermitted
    /// The sensor took the value but never reported a final result.
    case unconfirmed

    var isInProgress: Bool {
        switch self {
        case .queued, .sent, .processing: return true
        default: return false
        }
    }

    var text: String {
        switch self {
        case .none: return NSLocalizedString("None", comment: "DirectConnect calibration status none")
        case .queued: return NSLocalizedString("Queued — sent at next sensor connection", comment: "DirectConnect calibration status queued")
        case .sent: return NSLocalizedString("Sent", comment: "DirectConnect calibration status sent")
        case .processing: return NSLocalizedString("Processing", comment: "DirectConnect calibration status processing")
        case .completed: return NSLocalizedString("Completed", comment: "DirectConnect calibration status completed")
        case .rejected(let reason): return String(format: NSLocalizedString("Rejected: %@", comment: "DirectConnect calibration rejected (1: reason)"), reason)
        case .notPermitted: return NSLocalizedString("The sensor is not accepting calibrations right now", comment: "DirectConnect calibration not permitted")
        case .unconfirmed: return NSLocalizedString("Sent. The sensor did not report whether it used the value.", comment: "DirectConnect calibration unconfirmed")
        }
    }
}

struct DirectConnect_PendingCalibration: Codable, Equatable {
    let id: UUID
    let glucose: Double
    let date: Date
}

/// Calibration lifecycle across short sensor connections. Value type so it can live inside
/// the persisted CGM manager state.
struct DirectConnect_CalibrationQueue: Codable, Equatable {
    /// Matches the established Dexcom rule: a fingerstick older than this is not sent.
    static let maxUnsentAge: TimeInterval = 300
    /// One bounds request per sensor wake (~5 min). Without a limit an unanswered calibration
    /// blocked new calibrations forever and took the only extra-command slot every wake, so
    /// battery and session reads stopped.
    static let maxBoundsRequests = 6
    /// Backstop when wakes stop calling `nextCommand` (for example the sensor is out of range):
    /// "Processing" never lasts longer than this.
    static let maxProcessingTime: TimeInterval = 30 * 60

    enum RefusalReason: Equatable {
        case outOfRange
        case waitingToSend
    }

    private(set) var pending: DirectConnect_PendingCalibration?
    private(set) var inFlight: DirectConnect_PendingCalibration?
    private(set) var awaitingBounds: DirectConnect_PendingCalibration?
    private(set) var lastCommandTime: UInt32?
    private(set) var status: DirectConnect_CalibrationStatus = .none
    /// Optional so state saved before this field existed still decodes.
    private(set) var boundsRequests: Int?
    /// When the sensor accepted the command; starts the `maxProcessingTime` clock.
    private(set) var awaitingSince: Date?
    /// The most recent calibration the sensor reported as complete, for this sensor session.
    private(set) var lastCompleted: DirectConnect_PendingCalibration?

    var hasWork: Bool { pending != nil || awaitingBounds != nil }

    /// Why a new calibration would be refused, or nil when it would be accepted.
    func refusalReason(glucose: Double, date: Date, now: Date = Date()) -> RefusalReason? {
        guard Self.isValid(glucose: glucose, date: date, now: now) else { return .outOfRange }
        // A value already delivered and being processed may be replaced; the sensor uses the newest.
        guard pending == nil, inFlight == nil else { return .waitingToSend }
        return nil
    }

    mutating func enqueue(glucose: Double, date: Date, now: Date = Date()) -> Bool {
        guard refusalReason(glucose: glucose, date: date, now: now) == nil else { return false }
        awaitingBounds = nil
        awaitingSince = nil
        boundsRequests = nil
        lastCommandTime = nil
        pending = DirectConnect_PendingCalibration(id: UUID(), glucose: glucose, date: date)
        status = .queued
        return true
    }

    private static func isValid(glucose: Double, date: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        // A few seconds of clock skew between entry and check are tolerated.
        return glucose >= 40 && glucose <= 400 && age >= -5 && age <= maxUnsentAge
    }

    /// Returns the next calibration-related write for this connection, if any: the 0x34
    /// command for a pending calibration, or a 0x32 bounds request while one is processing.
    mutating func nextCommand(clock: DirectConnect_ClockReference?, now: Date) -> Data? {
        if let calibration = pending, inFlight == nil {
            guard Self.isValid(glucose: calibration.glucose, date: calibration.date, now: now) else {
                pending = nil
                status = .rejected(DirectConnect_CalibrationRejectionReason.stale.text)
                return nil
            }
            guard let clock = clock, let time = clock.transmitterTime(for: calibration.date) else {
                return nil
            }
            pending = nil
            inFlight = calibration
            lastCommandTime = time
            status = .sent
            return DirectConnect_CalibrationCommand(glucose: UInt16(calibration.glucose.rounded()), transmitterTime: time).data
        }
        if awaitingBounds != nil {
            let sent = boundsRequests ?? 0
            guard sent < Self.maxBoundsRequests else {
                giveUp()
                return nil
            }
            boundsRequests = sent + 1
            return DirectConnect_G7Requests.calibrationBounds
        }
        return nil
    }

    /// Handles the 0x34 response. Returns a bounds request to send when the sensor accepted
    /// the command for processing.
    mutating func handleCommandResponse(_ data: Data, now: Date = Date()) -> Data? {
        guard let response = DirectConnect_CalibrationCommandResponse(data: data), let calibration = inFlight else {
            return nil
        }
        inFlight = nil

        switch response.status {
        case .acceptedHigh(.accepted), .acceptedLow(.accepted), .factoryCalibrated:
            awaitingBounds = calibration
            awaitingSince = now
            boundsRequests = nil
            status = .processing
            return DirectConnect_G7Requests.calibrationBounds
        case .acceptedHigh, .acceptedLow:
            status = .rejected(DirectConnect_CalibrationRejectionReason.unknown(response.secondaryStatus).text)
        case .rejected(let reason) where reason.isTerminalDuplicate:
            awaitingBounds = calibration
            awaitingSince = now
            boundsRequests = nil
            status = .processing
            return DirectConnect_G7Requests.calibrationBounds
        case .rejected(.notPermitted), .rejected(.disabled):
            status = .notPermitted
        case .rejected(let reason):
            status = .rejected(reason.text)
        case .unknown(let primary, _):
            status = .rejected(DirectConnect_CalibrationRejectionReason.unknown(primary).text)
        }
        lastCommandTime = nil
        return nil
    }

    /// Applies a 0x32 record. Returns false when it does not describe the calibration being
    /// processed, so the caller can log why the status did not move.
    @discardableResult
    mutating func handleBounds(_ data: Data) -> Bool {
        guard let bounds = DirectConnect_CalibrationBounds(data: data), let calibration = awaitingBounds else { return false }
        guard let time = lastCommandTime, bounds.matches(glucose: calibration.glucose, transmitterTime: time) else {
            return false
        }
        guard bounds.calibrationsPermitted else {
            awaitingBounds = nil
            awaitingSince = nil
            lastCommandTime = nil
            status = .notPermitted
            return true
        }
        switch bounds.processingState {
        case .some(.inProgress):
            status = .processing
        case .some(.completeHigh), .some(.completeLow):
            lastCompleted = calibration
            awaitingBounds = nil
            awaitingSince = nil
            lastCommandTime = nil
            status = .completed
        case .some(.none), .some(.factoryCalibrated), nil:
            break
        }
        return true
    }

    /// Ends "Processing" once `maxProcessingTime` has passed. Returns true if the status changed.
    mutating func expireIfOverdue(now: Date) -> Bool {
        guard awaitingBounds != nil else {
            // Processing with nothing awaited cannot finish; seen only in state saved by older builds.
            guard status == .processing else { return false }
            status = .unconfirmed
            return true
        }
        guard let since = awaitingSince else {
            // Saved by a build before this field existed: start the clock now.
            awaitingSince = now
            return false
        }
        guard now.timeIntervalSince(since) >= Self.maxProcessingTime else { return false }
        giveUp()
        return true
    }

    private mutating func giveUp() {
        awaitingBounds = nil
        awaitingSince = nil
        boundsRequests = nil
        lastCommandTime = nil
        status = .unconfirmed
    }

    /// A command whose response never arrived goes back to the queue for the next connection.
    mutating func connectionDidEnd() {
        if let calibration = inFlight {
            inFlight = nil
            pending = calibration
            lastCommandTime = nil
            status = .queued
        }
    }

    mutating func clear() {
        self = DirectConnect_CalibrationQueue()
    }
}
