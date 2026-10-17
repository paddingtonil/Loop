//
//  DirectConnect_G7State.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — Persisted CGM manager state.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Adapted from LoopKit G7SensorKit G7CGMManagerState (MIT, © 2022 LoopKit Authors).
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import Foundation
import LoopKit

struct DirectConnect_G7State: RawRepresentable, Equatable {
    typealias RawValue = CGMManager.RawStateValue

    var sensorID: String?
    var sensorType: DirectConnect_SensorType = .g7
    /// Kept so the sensor can be paired again (for example after a refused key) without
    /// asking for the code a second time.
    var pairingCode: String?
    /// The sensor used before the current one; skipped while scanning for a replacement.
    var previousSensorID: String?
    /// The previous sensor's code and Bluetooth identifier. A search with a different code does
    /// not connect to that sensor; the same code means it is being paired again.
    var previousPairingCode: String?
    var previousPeripheralIdentifier: String?
    var activatedAt: Date?
    var extendedVersion: DirectConnect_G7ExtendedVersion?
    var latestReading: DirectConnect_G7GlucoseMessage?
    var latestReadingTimestamp: Date?
    var latestConnect: Date?
    var uploadReadings = true
    /// Start of a grace period after a suspected session end; persisted so it survives restarts.
    var suspectedSessionEndAt: Date?
    var battery: DirectConnect_G7BatteryStatus?
    var batteryReadAt: Date?
    var versionInfo: DirectConnect_G7VersionInfo?
    var calibration = DirectConnect_CalibrationQueue()
    var alarmState = DirectConnect_AlarmState()
    var pairingFailure: String?
    /// A pairing refusal Loop retries by itself, shown as a status line. Not persisted.
    var pairingNotice: String?
    /// The last six delivered values, for the stuck-sensor rule.
    var recentReadings: [Double] = []
    /// CoreBluetooth identifier of the paired sensor, so Loop can queue a connection to it at
    /// launch without scanning.
    var peripheralIdentifier: String?
    /// When Loop re-paired to take the sensor back from another app (last 6 hours).
    var takeBackHistory: [Date] = []
    /// Consecutive cached (stale) readings received since the last live reading.
    var staleStreak = 0

    init() {}

    init(rawValue: RawValue) {
        sensorID = rawValue["sensorID"] as? String
        sensorType = (rawValue["sensorType"] as? String).flatMap(DirectConnect_SensorType.init(rawValue:)) ?? .g7
        pairingCode = rawValue["pairingCode"] as? String
        previousSensorID = rawValue["previousSensorID"] as? String
        previousPairingCode = rawValue["previousPairingCode"] as? String
        previousPeripheralIdentifier = rawValue["previousPeripheralIdentifier"] as? String
        activatedAt = rawValue["activatedAt"] as? Date
        extendedVersion = (rawValue["extendedVersion"] as? Data).flatMap(DirectConnect_G7ExtendedVersion.init(data:))
        latestReading = (rawValue["latestReading"] as? Data).flatMap(DirectConnect_G7GlucoseMessage.init(data:))
        latestReadingTimestamp = rawValue["latestReadingTimestamp"] as? Date
        latestConnect = rawValue["latestConnect"] as? Date
        uploadReadings = rawValue["uploadReadings"] as? Bool ?? true
        suspectedSessionEndAt = rawValue["suspectedSessionEndAt"] as? Date
        battery = (rawValue["battery"] as? Data).flatMap(DirectConnect_G7BatteryStatus.init(data:))
        batteryReadAt = rawValue["batteryReadAt"] as? Date
        versionInfo = (rawValue["versionInfo"] as? Data).flatMap(DirectConnect_G7VersionInfo.init(data:))
        calibration = (rawValue["calibration"] as? Data).flatMap { try? JSONDecoder().decode(DirectConnect_CalibrationQueue.self, from: $0) } ?? DirectConnect_CalibrationQueue()
        alarmState = (rawValue["alarmState"] as? Data).flatMap { try? JSONDecoder().decode(DirectConnect_AlarmState.self, from: $0) } ?? DirectConnect_AlarmState()
        pairingFailure = rawValue["pairingFailure"] as? String
        recentReadings = rawValue["recentReadings"] as? [Double] ?? []
        peripheralIdentifier = rawValue["peripheralIdentifier"] as? String
        takeBackHistory = rawValue["takeBackHistory"] as? [Date] ?? []
        staleStreak = rawValue["staleStreak"] as? Int ?? 0
    }

    var rawValue: RawValue {
        var raw: RawValue = [:]
        raw["sensorID"] = sensorID
        raw["sensorType"] = sensorType.rawValue
        raw["pairingCode"] = pairingCode
        raw["previousSensorID"] = previousSensorID
        raw["previousPairingCode"] = previousPairingCode
        raw["previousPeripheralIdentifier"] = previousPeripheralIdentifier
        raw["activatedAt"] = activatedAt
        raw["extendedVersion"] = extendedVersion?.data
        raw["latestReading"] = latestReading?.data
        raw["latestReadingTimestamp"] = latestReadingTimestamp
        raw["latestConnect"] = latestConnect
        raw["uploadReadings"] = uploadReadings
        raw["suspectedSessionEndAt"] = suspectedSessionEndAt
        raw["battery"] = battery?.data
        raw["batteryReadAt"] = batteryReadAt
        raw["versionInfo"] = versionInfo?.data
        raw["calibration"] = try? JSONEncoder().encode(calibration)
        raw["alarmState"] = try? JSONEncoder().encode(alarmState)
        raw["pairingFailure"] = pairingFailure
        raw["recentReadings"] = recentReadings
        raw["peripheralIdentifier"] = peripheralIdentifier
        raw["takeBackHistory"] = takeBackHistory
        raw["staleStreak"] = staleStreak
        return raw
    }

    // MARK: - Derived values

    /// Full session length including the 12-hour grace period, or nil until the sensor reports it.
    var knownSessionLength: TimeInterval? {
        DirectConnect_SensorLifetime.knownSessionLength(reported: extendedVersion?.sessionLength, type: sensorType)
    }

    /// Used only to draw progress before the length is known; never used to stop readings.
    var estimatedSessionLength: TimeInterval {
        knownSessionLength ?? DirectConnect_SensorLifetime.tenDaySession
    }

    var warmupDuration: TimeInterval {
        extendedVersion?.warmupDuration ?? DirectConnect_SensorLifetime.defaultWarmup
    }

    /// Records a delivered value. Returns true when the last six values are identical, which
    /// Dexcom-derived apps treat as a stalled sensor whose value must not be used.
    mutating func recordReadingAndCheckStuck(_ value: Double) -> Bool {
        recentReadings.append(value)
        if recentReadings.count > 6 {
            recentReadings.removeFirst(recentReadings.count - 6)
        }
        return recentReadings.count == 6 && Set(recentReadings).count == 1
    }
}
