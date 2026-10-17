//
//  DirectConnect_SensorModel.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — G7 / ONE+ / Stelo identification, lifetimes and connect decisions.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Portions derived from xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import Foundation

enum DirectConnect_SensorType: String, CaseIterable, Codable {
    case g7
    case onePlus
    case stelo

    var displayName: String {
        switch self {
        case .g7: return "Dexcom G7"
        case .onePlus: return "Dexcom ONE+"
        case .stelo: return "Dexcom Stelo"
        }
    }

    /// Advertised Bluetooth name prefix for each product family.
    var namePrefix: String {
        switch self {
        case .g7: return "DXCM"
        case .onePlus: return "DX02"
        case .stelo: return "DX01"
        }
    }

    static func from(peripheralName: String) -> DirectConnect_SensorType? {
        let upper = peripheralName.uppercased()
        return allCases.first { upper.hasPrefix($0.namePrefix) }
    }
}

enum DirectConnect_SensorLifetime {
    static let gracePeriod: TimeInterval = 12 * 3600
    static let tenDaySession: TimeInterval = 10.5 * 24 * 3600
    static let fifteenDaySession: TimeInterval = 15.5 * 24 * 3600
    static let defaultWarmup: TimeInterval = 27 * 60

    /// Full session length (lifetime + grace), or nil while it is not known. The sensor reports
    /// its length on the first connection after pairing; only the two known lengths are accepted,
    /// so an unrecognized future value is never trusted. Stelo (15-day only) and ONE+ (10-day
    /// only) are known from their type. G7 is sold in both lengths, so it stays unknown until the
    /// sensor says which it is.
    static func knownSessionLength(reported: TimeInterval?, type: DirectConnect_SensorType) -> TimeInterval? {
        if let reported = reported, reported == tenDaySession || reported == fifteenDaySession {
            return reported
        }
        switch type {
        case .stelo: return fifteenDaySession
        case .onePlus: return tenDaySession
        case .g7: return nil
        }
    }
}

enum DirectConnect_ConnectDecision: Equatable {
    /// The sensor we follow: make it the active peripheral.
    case makeActive
    /// Scanning for a new sensor and this one matches: connect and try to pair.
    case connect
    case ignore
}

/// Decides whether to connect to an advertising peripheral.
/// - Parameters:
///   - followedName: the paired sensor's name, or nil while scanning for a new one.
///   - excludedName: kept for call-site compatibility; no longer used. Each sensor has its own
///     applicator code, so an old sensor refuses a new sensor's code and is then skipped as a
///     rejected candidate. Skipping it by name blocked re-pairing the same sensor.
///   - expectedType: the sensor type the user chose in setup.
func DirectConnect_shouldConnect(peripheralName: String?, followedName: String?, excludedName: String?, expectedType: DirectConnect_SensorType?) -> DirectConnect_ConnectDecision {
    guard let name = peripheralName else { return .ignore }
    if let followedName = followedName {
        // A G7 advertises as "DXCMxx" but can later report its full name "Dexcomxx", so the
        // followed sensor is matched on its two-character suffix, as G7SensorKit does.
        let isDexcomName = DirectConnect_SensorType.from(peripheralName: name) != nil || name.hasPrefix("Dexcom")
        return isDexcomName && name.suffix(2) == followedName.suffix(2) ? .makeActive : .ignore
    }
    guard let type = DirectConnect_SensorType.from(peripheralName: name) else {
        return .ignore
    }
    if let expectedType = expectedType, expectedType != type {
        return .ignore
    }
    return .connect
}

/// Sensors that refused the code during the current search. Each is skipped for a limited
/// time, not permanently, so a sensor that refused while not ready is tried again.
struct DirectConnect_SkipList: Equatable {
    static let duration: TimeInterval = 10 * 60

    private var skippedUntil: [UUID: Date] = [:]

    /// Skips the sensor with this Bluetooth identifier for `duration` from `now`.
    mutating func skip(_ identifier: UUID, now: Date) {
        skippedUntil[identifier] = now.addingTimeInterval(Self.duration)
    }

    /// True while the sensor's skip time has not passed.
    func isSkipped(_ identifier: UUID, now: Date) -> Bool {
        skippedUntil[identifier].map { $0 > now } ?? false
    }
}

/// The sensor used before a new-sensor search, which the search does not connect to.
struct DirectConnect_ExcludedSensor: Equatable {
    let name: String
    /// Its CoreBluetooth identifier, when Loop saved one.
    let identifier: UUID?
}

/// The previous sensor to leave alone while searching with `newCode`.
/// - Returns: nil when the codes match (the user is pairing the same sensor again) or when
///   the previous sensor's name or code is unknown.
func DirectConnect_previousSensorToExclude(name: String?, code: String?, identifier: String?, newCode: String) -> DirectConnect_ExcludedSensor? {
    guard let name = name, let code = code, code != newCode else { return nil }
    return DirectConnect_ExcludedSensor(name: name, identifier: identifier.flatMap(UUID.init(uuidString:)))
}

/// Whether an advertising peripheral is the excluded previous sensor.
/// - Returns: a match on the Bluetooth identifier when it is known. Only without one is the
///   name used, because two sensors can share the last two characters of their names.
func DirectConnect_isExcluded(peripheralName: String?, identifier: UUID, excluded: DirectConnect_ExcludedSensor?) -> Bool {
    guard let excluded = excluded else { return false }
    if let excludedIdentifier = excluded.identifier {
        return identifier == excludedIdentifier
    }
    guard let name = peripheralName else { return false }
    let isDexcomName = DirectConnect_SensorType.from(peripheralName: name) != nil || name.hasPrefix("Dexcom")
    return isDexcomName && name.suffix(2) == excluded.name.suffix(2)
}
