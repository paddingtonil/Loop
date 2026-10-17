//
//  DirectConnect_G7Messages.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — Dexcom G7-family packet parsers and request builders.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Glucose, backfill, algorithm-state and extended-version layouts adapted from
//  LoopKit G7SensorKit (MIT, © 2022 LoopKit Authors).
//  Portions derived from xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import Foundation
import LoopKit

// MARK: - Opcodes

enum DirectConnect_G7Opcode: UInt8 {
    case authRequestTx = 0x01
    case authRequest2Tx = 0x02
    case authRequestRx = 0x03
    case authChallengeTx = 0x04
    case authChallengeRx = 0x05
    case keepAlive = 0x06
    case bondRequest = 0x07
    case pairRequestRx = 0x08
    case exchangePake = 0x0A
    case certificateExchange = 0x0B
    case proofOfPossession = 0x0C
    case authStatus = 0x0D
    case batteryStatus = 0x22
    case calibrationBounds = 0x32
    case calibrate = 0x34
    case transmitterVersion = 0x4A
    case glucose = 0x4E
    case extendedVersion = 0x52
    case backfillFinished = 0x59
}

enum DirectConnect_GlucoseLimits {
    static let minimum: UInt16 = 40
    static let maximum: UInt16 = 400
}

// MARK: - Algorithm state

enum DirectConnect_AlgorithmState: RawRepresentable, Equatable, CustomStringConvertible {
    typealias RawValue = UInt8

    enum State: RawValue {
        case stopped = 1
        case warmup = 2
        case excessNoise = 3
        case firstOfTwoBGsNeeded = 4
        case secondOfTwoBGsNeeded = 5
        case ok = 6
        case needsCalibration = 7
        case calibrationError1 = 8
        case calibrationError2 = 9
        case calibrationLinearityFitFailure = 10
        case sensorFailedDuetoCountsAberration = 11
        case sensorFailedDuetoResidualAberration = 12
        case outOfCalibrationDueToOutlier = 13
        case outlierCalibrationRequest = 14
        case sessionExpired = 15
        case sessionFailedDueToUnrecoverableError = 16
        case sessionFailedDueToTransmitterError = 17
        case temporarySensorIssue = 18
        case sensorFailedDueToProgressiveSensorDecline = 19
        case sensorFailedDueToHighCountsAberration = 20
        case sensorFailedDueToLowCountsAberration = 21
        case sensorFailedDueToRestart = 22
        case expired = 24
        case sensorFailed = 25
        case sessionEnded = 26
    }

    case known(State)
    case unknown(RawValue)

    init(rawValue: RawValue) {
        if let state = State(rawValue: rawValue) {
            self = .known(state)
        } else {
            self = .unknown(rawValue)
        }
    }

    var rawValue: RawValue {
        switch self {
        case .known(let state): return state.rawValue
        case .unknown(let value): return value
        }
    }

    var sensorFailed: Bool {
        guard case .known(let state) = self else { return false }
        switch state {
        case .sensorFailed, .sensorFailedDuetoCountsAberration, .sensorFailedDuetoResidualAberration,
             .sessionFailedDueToTransmitterError, .sessionFailedDueToUnrecoverableError,
             .sensorFailedDueToProgressiveSensorDecline, .sensorFailedDueToHighCountsAberration,
             .sensorFailedDueToLowCountsAberration, .sensorFailedDueToRestart:
            return true
        default:
            return false
        }
    }

    var isSessionEnded: Bool {
        guard case .known(let state) = self else { return false }
        return state == .sessionEnded || state == .sessionExpired || state == .expired
    }

    var isInWarmup: Bool {
        self == .known(.warmup)
    }

    var hasTemporaryError: Bool {
        self == .known(.temporarySensorIssue)
    }

    var hasReliableGlucose: Bool {
        self == .known(.ok)
    }

    var description: String {
        switch self {
        case .known(let state): return String(describing: state)
        case .unknown(let value): return "unknown(\(value))"
        }
    }

    var localizedDescription: String {
        switch self {
        case .known(.ok): return NSLocalizedString("Sensor is OK", comment: "DirectConnect sensor state ok")
        case .known(.stopped): return NSLocalizedString("Sensor is stopped", comment: "DirectConnect sensor state stopped")
        case .known(.warmup): return NSLocalizedString("Sensor is warming up", comment: "DirectConnect sensor state warmup")
        // State 18 is the sensor withholding a value it does not trust; calling it "warming up" made users think the connection had dropped.
        case .known(.temporarySensorIssue): return NSLocalizedString("Temporary sensor issue. The sensor is connected but is not giving a reading right now. Readings usually return on their own.", comment: "DirectConnect sensor state temporary issue")
        case .known(.expired), .known(.sessionExpired), .known(.sessionEnded): return NSLocalizedString("Sensor session ended", comment: "DirectConnect sensor state ended")
        case _ where sensorFailed: return NSLocalizedString("Sensor failed", comment: "DirectConnect sensor state failed")
        default: return String(format: NSLocalizedString("Sensor state: %@", comment: "DirectConnect sensor state other (1: state)"), description)
        }
    }
}

// MARK: - Shared trend mapping

private func dcTrendType(_ trend: Double?) -> GlucoseTrend? {
    guard let trend = trend else { return nil }
    switch trend {
    case let x where x <= -3.0: return .downDownDown
    case let x where x <= -2.0: return .downDown
    case let x where x <= -1.0: return .down
    case let x where x < 1.0: return .flat
    case let x where x < 2.0: return .up
    case let x where x < 3.0: return .upUp
    default: return .upUpUp
    }
}

private func dcCondition(_ glucose: UInt16?) -> GlucoseCondition? {
    guard let glucose = glucose else { return nil }
    if glucose < DirectConnect_GlucoseLimits.minimum { return .belowRange }
    if glucose > DirectConnect_GlucoseLimits.maximum { return .aboveRange }
    return nil
}

private func dcTrend(_ byte: UInt8) -> Double? {
    byte == 0x7F ? nil : Double(Int8(bitPattern: byte)) / 10
}

// MARK: - Glucose (0x4E response)

struct DirectConnect_G7GlucoseMessage: Equatable {
    /// 0x00 = current reading. Non-zero frames can carry a stale cached value, which must not
    /// be delivered as a new reading.
    let responseStatus: UInt8
    let glucose: UInt16?
    let predicted: UInt16?
    let glucoseIsDisplayOnly: Bool
    /// Seconds since sensor start at the time the message was sent.
    let messageTimestamp: UInt32
    /// Seconds between the reading and its transmission.
    let age: UInt16
    let sequence: UInt16
    let algorithmState: DirectConnect_AlgorithmState
    let trend: Double?
    let data: Data

    init?(data: Data) {
        //    0  1  2 3 4 5  6 7  8  9 1011 1213 14 15 1617 18
        //         TTTTTTTT SQSQ       AGAG BGBG SS TR PRPR C
        // 0x4e 00 d5070000 0900 00 01 0500 6100 06 01 ffff 0e
        guard data.count >= 19, data.dcByte(at: 0) == DirectConnect_G7Opcode.glucose.rawValue else {
            return nil
        }
        self.data = Data(data)
        responseStatus = data.dcByte(at: 1)
        messageTimestamp = data.dcUInt32LE(at: 2)
        sequence = data.dcUInt16LE(at: 6)
        age = data.dcUInt16LE(at: 10)

        let glucoseData = data.dcUInt16LE(at: 12)
        if glucoseData != 0xFFFF {
            glucose = glucoseData & 0xFFF
            glucoseIsDisplayOnly = (data.dcByte(at: 18) & 0x10) != 0
        } else {
            glucose = nil
            glucoseIsDisplayOnly = false
        }

        let predictionData = data.dcUInt16LE(at: 16)
        predicted = predictionData != 0xFFFF ? predictionData & 0xFFF : nil

        algorithmState = DirectConnect_AlgorithmState(rawValue: data.dcByte(at: 14))
        trend = dcTrend(data.dcByte(at: 15))
    }

    var glucoseTimestamp: UInt32 {
        messageTimestamp >= UInt32(age) ? messageTimestamp - UInt32(age) : 0
    }

    var hasReliableGlucose: Bool { algorithmState.hasReliableGlucose }
    var trendType: GlucoseTrend? { dcTrendType(trend) }
    var condition: GlucoseCondition? { dcCondition(glucose) }
}

// MARK: - Backfill (backfill characteristic, 9 bytes)

struct DirectConnect_G7BackfillMessage: Equatable {
    /// Seconds since sensor start.
    let timestamp: UInt32
    let glucose: UInt16?
    let glucoseIsDisplayOnly: Bool
    let algorithmState: DirectConnect_AlgorithmState
    let trend: Double?
    let data: Data

    init?(data: Data) {
        //    0 1 2  3  4 5  6  7  8
        //   TTTTTT    BGBG SS    TR
        //   45a100 00 9600 06 0f fc
        guard data.count == 9 else { return nil }
        self.data = Data(data)
        timestamp = data.dcUInt24LE(at: 0)
        let glucoseBytes = data.dcUInt16LE(at: 4)
        glucose = glucoseBytes != 0xFFFF ? glucoseBytes & 0xFFF : nil
        glucoseIsDisplayOnly = (data.dcByte(at: 7) & 0x10) != 0
        algorithmState = DirectConnect_AlgorithmState(rawValue: data.dcByte(at: 6))
        trend = dcTrend(data.dcByte(at: 8))
    }

    var hasReliableGlucose: Bool { algorithmState.hasReliableGlucose }
    var trendType: GlucoseTrend? { dcTrendType(trend) }
    var condition: GlucoseCondition? { dcCondition(glucose) }
}

// MARK: - Extended version (0x52)

struct DirectConnect_G7ExtendedVersion: Equatable {
    /// Full session length including the 12-hour grace period.
    let sessionLength: TimeInterval
    let warmupDuration: TimeInterval
    let algorithmVersion: UInt32
    let hardwareVersion: UInt8
    let maxLifetimeDays: UInt16
    let data: Data

    init?(data: Data) {
        // 10-day: 52 00 c0d70d00 5406 00020404 ff 0c00
        // 15-day: 52 00 406f1400 880e 00010a04 ff 1100
        guard data.count >= 15, data.dcByte(at: 0) == DirectConnect_G7Opcode.extendedVersion.rawValue else {
            return nil
        }
        self.data = Data(data)
        sessionLength = TimeInterval(data.dcUInt32LE(at: 2))
        warmupDuration = TimeInterval(data.dcUInt16LE(at: 6))
        algorithmVersion = data.dcUInt32LE(at: 8)
        hardwareVersion = data.dcByte(at: 12)
        maxLifetimeDays = data.dcUInt16LE(at: 13)
    }
}

// MARK: - Battery (0x22 response)

struct DirectConnect_G7BatteryStatus: Equatable {
    let status: UInt8
    let voltageA: Int
    let voltageB: Int
    let resistance: Int
    let runtime: Int
    let temperature: Int
    let data: Data

    init?(data: Data) {
        // G7-family sensors repeat the 0x22 request opcode instead of replying with 0x23.
        guard data.count >= 10, data.dcByte(at: 0) == DirectConnect_G7Opcode.batteryStatus.rawValue else {
            return nil
        }
        self.data = Data(data)
        status = data.dcByte(at: 1)
        voltageA = Int(data.dcUInt16LE(at: 2))
        voltageB = Int(data.dcUInt16LE(at: 4))
        resistance = Int(data.dcUInt16LE(at: 6))
        runtime = Int(data.dcByte(at: 8))
        temperature = Int(Int8(bitPattern: data.dcByte(at: 9)))
    }
}

// MARK: - Firmware version (0x4A response)

struct DirectConnect_G7VersionInfo: Equatable {
    let status: UInt8
    let firmwareVersion: String
    let buildVersion: UInt32
    let versionCode: UInt32
    let serialNumber: UInt64
    let data: Data

    init?(data: Data) {
        // The request is 3 bytes with the same opcode; only the 20-byte form is a response.
        guard data.count >= 20, data.dcByte(at: 0) == DirectConnect_G7Opcode.transmitterVersion.rawValue else {
            return nil
        }
        self.data = Data(data)
        status = data.dcByte(at: 1)
        firmwareVersion = (2..<6).map { String(data.dcByte(at: $0)) }.joined(separator: ".")
        buildVersion = data.dcUInt32LE(at: 6)
        versionCode = data.dcUInt32LE(at: 10)
        serialNumber = (0..<6).reduce(UInt64(0)) { $0 | UInt64(data.dcByte(at: 14 + $1)) << UInt64($1 * 8) }
    }
}

// MARK: - Authentication control messages

struct DirectConnect_AuthRequestRx {
    let tokenHash: Data
    let challenge: Data

    init?(data: Data) {
        guard data.count >= 17, data.dcByte(at: 0) == DirectConnect_G7Opcode.authRequestRx.rawValue else {
            return nil
        }
        let base = data.startIndex
        tokenHash = Data(data[(base + 1)..<(base + 9)])
        challenge = Data(data[(base + 9)..<(base + 17)])
    }
}

struct DirectConnect_AuthStatusRx {
    let authenticated: Bool
    let paired: Bool

    init?(data: Data) {
        guard data.count >= 3, data.dcByte(at: 0) == DirectConnect_G7Opcode.authChallengeRx.rawValue else {
            return nil
        }
        authenticated = data.dcByte(at: 1) == 0x01
        // 0x02 means "not paired"; other values are treated as paired, matching observed firmware.
        paired = data.dcByte(at: 2) != 0x02
    }
}

// MARK: - Requests

enum DirectConnect_G7Requests {
    static let glucose = Data([DirectConnect_G7Opcode.glucose.rawValue])
    static let extendedVersion = Data([DirectConnect_G7Opcode.extendedVersion.rawValue])
    static let calibrationBounds = Data([DirectConnect_G7Opcode.calibrationBounds.rawValue])
    static var battery: Data { Data([DirectConnect_G7Opcode.batteryStatus.rawValue]).dcAppendingCRC() }
    static var version: Data { Data([DirectConnect_G7Opcode.transmitterVersion.rawValue]).dcAppendingCRC() }
}
