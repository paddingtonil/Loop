//
//  DirectConnect_AlarmSettings.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — User-configurable glucose alarm settings.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import Foundation

/// Every alarm DirectConnect can raise. Raw values double as LoopKit alert identifiers and
/// as keys in `DirectConnect_AlarmState`, so they must never be renamed.
enum DirectConnect_AlarmKind: String, CaseIterable, Codable {
    case urgentLow
    case low
    case high
    case risingFast
    case fallingFast
    case signalLoss
    case sensorExpiring
    case sensorEnded
}

/// Alarm thresholds, repeat intervals and switches. Glucose values are mg/dL; rates are
/// mg/dL per minute (positive for both rising and falling); durations are minutes.
struct DirectConnect_AlarmSettings: Equatable {
    var urgentLowEnabled: Bool
    var lowEnabled: Bool
    var highEnabled: Bool
    var risingFastEnabled: Bool
    var fallingFastEnabled: Bool
    var signalLossEnabled: Bool
    var sensorExpiringEnabled: Bool
    var sensorEndedEnabled: Bool

    var urgentLowThreshold: Double
    var lowThreshold: Double
    var highThreshold: Double
    var risingRate: Double
    var fallingRate: Double
    var signalLossMinutes: Double

    var urgentLowRepeatMinutes: Double
    var lowRepeatMinutes: Double
    var highRepeatMinutes: Double

    static let urgentLowRange = 40.0...70.0
    static let lowRange = 55.0...100.0
    static let highRange = 120.0...400.0
    static let rateRange = 2.0...5.0
    static let signalLossRange = 10.0...60.0
    static let urgentLowRepeatRange = 5.0...30.0
    static let lowRepeatRange = 5.0...60.0
    static let highRepeatRange = 15.0...240.0

    // Minimum gaps keep the three glucose thresholds from overlapping, so a single reading
    // can never be "urgent low" and "high" at once.
    private static let urgentLowToLowGap = 5.0
    private static let lowToHighGap = 20.0

    static let defaults = DirectConnect_AlarmSettings(
        urgentLowEnabled: true,
        lowEnabled: true,
        highEnabled: true,
        risingFastEnabled: false,
        fallingFastEnabled: true,
        signalLossEnabled: true,
        sensorExpiringEnabled: true,
        sensorEndedEnabled: true,
        urgentLowThreshold: 55,
        lowThreshold: 70,
        highThreshold: 250,
        risingRate: 3,
        fallingRate: 3,
        signalLossMinutes: 20,
        urgentLowRepeatMinutes: 5,
        lowRepeatMinutes: 15,
        highRepeatMinutes: 60
    )

    /// Returns a copy with every value inside its allowed range and the thresholds ordered
    /// urgent low < low < high.
    func normalized() -> DirectConnect_AlarmSettings {
        var s = self
        s.urgentLowThreshold = s.urgentLowThreshold.dcClamped(to: Self.urgentLowRange)
        s.lowThreshold = s.lowThreshold.dcClamped(to: Self.lowRange)
        s.highThreshold = s.highThreshold.dcClamped(to: Self.highRange)
        s.risingRate = s.risingRate.dcClamped(to: Self.rateRange)
        s.fallingRate = s.fallingRate.dcClamped(to: Self.rateRange)
        s.signalLossMinutes = s.signalLossMinutes.dcClamped(to: Self.signalLossRange)
        s.urgentLowRepeatMinutes = s.urgentLowRepeatMinutes.dcClamped(to: Self.urgentLowRepeatRange)
        s.lowRepeatMinutes = s.lowRepeatMinutes.dcClamped(to: Self.lowRepeatRange)
        s.highRepeatMinutes = s.highRepeatMinutes.dcClamped(to: Self.highRepeatRange)

        if s.lowThreshold > s.highThreshold - Self.lowToHighGap {
            s.lowThreshold = max(Self.lowRange.lowerBound, s.highThreshold - Self.lowToHighGap)
        }
        if s.urgentLowThreshold > s.lowThreshold - Self.urgentLowToLowGap {
            s.urgentLowThreshold = max(Self.urgentLowRange.lowerBound, s.lowThreshold - Self.urgentLowToLowGap)
        }
        return s
    }

    // MARK: - Persistence

    private static let keyPrefix = "com.loopkit.Loop.directConnect.alarm."

    static func load(from defaults: UserDefaults) -> DirectConnect_AlarmSettings {
        let d = Self.defaults
        func bool(_ name: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: keyPrefix + name) as? Bool ?? fallback
        }
        func double(_ name: String, _ fallback: Double) -> Double {
            defaults.object(forKey: keyPrefix + name) as? Double ?? fallback
        }
        return DirectConnect_AlarmSettings(
            urgentLowEnabled: bool("urgentLowEnabled", d.urgentLowEnabled),
            lowEnabled: bool("lowEnabled", d.lowEnabled),
            highEnabled: bool("highEnabled", d.highEnabled),
            risingFastEnabled: bool("risingFastEnabled", d.risingFastEnabled),
            fallingFastEnabled: bool("fallingFastEnabled", d.fallingFastEnabled),
            signalLossEnabled: bool("signalLossEnabled", d.signalLossEnabled),
            sensorExpiringEnabled: bool("sensorExpiringEnabled", d.sensorExpiringEnabled),
            sensorEndedEnabled: bool("sensorEndedEnabled", d.sensorEndedEnabled),
            urgentLowThreshold: double("urgentLowThreshold", d.urgentLowThreshold),
            lowThreshold: double("lowThreshold", d.lowThreshold),
            highThreshold: double("highThreshold", d.highThreshold),
            risingRate: double("risingRate", d.risingRate),
            fallingRate: double("fallingRate", d.fallingRate),
            signalLossMinutes: double("signalLossMinutes", d.signalLossMinutes),
            urgentLowRepeatMinutes: double("urgentLowRepeatMinutes", d.urgentLowRepeatMinutes),
            lowRepeatMinutes: double("lowRepeatMinutes", d.lowRepeatMinutes),
            highRepeatMinutes: double("highRepeatMinutes", d.highRepeatMinutes)
        ).normalized()
    }

    func save(to defaults: UserDefaults) {
        let s = normalized()
        let values: [String: Any] = [
            "urgentLowEnabled": s.urgentLowEnabled,
            "lowEnabled": s.lowEnabled,
            "highEnabled": s.highEnabled,
            "risingFastEnabled": s.risingFastEnabled,
            "fallingFastEnabled": s.fallingFastEnabled,
            "signalLossEnabled": s.signalLossEnabled,
            "sensorExpiringEnabled": s.sensorExpiringEnabled,
            "sensorEndedEnabled": s.sensorEndedEnabled,
            "urgentLowThreshold": s.urgentLowThreshold,
            "lowThreshold": s.lowThreshold,
            "highThreshold": s.highThreshold,
            "risingRate": s.risingRate,
            "fallingRate": s.fallingRate,
            "signalLossMinutes": s.signalLossMinutes,
            "urgentLowRepeatMinutes": s.urgentLowRepeatMinutes,
            "lowRepeatMinutes": s.lowRepeatMinutes,
            "highRepeatMinutes": s.highRepeatMinutes,
        ]
        for (name, value) in values {
            defaults.set(value, forKey: Self.keyPrefix + name)
        }
    }
}

extension Double {
    func dcClamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
