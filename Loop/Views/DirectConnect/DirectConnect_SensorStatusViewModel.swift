//
//  DirectConnect_SensorStatusViewModel.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — Observable sensor status for the settings screen.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Adapted from LoopKit G7SensorKitUI G7SettingsViewModel (MIT, © 2022 LoopKit Authors).
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import Foundation
import HealthKit
import LoopKit
import LoopKitUI
import SwiftUI

final class DirectConnect_SensorStatusViewModel: ObservableObject {
    @Published private(set) var state: DirectConnect_G7State
    @Published private(set) var scanning = false
    @Published private(set) var connected = false
    @Published private(set) var rssi: Int?
    @Published private(set) var hasSavedKey = false

    let cgmManager: DirectConnect_G7CGMManager
    let displayGlucosePreference: DisplayGlucosePreference

    let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    init(cgmManager: DirectConnect_G7CGMManager, displayGlucosePreference: DisplayGlucosePreference) {
        self.cgmManager = cgmManager
        self.displayGlucosePreference = displayGlucosePreference
        state = cgmManager.state
        refreshConnection()
        cgmManager.addStateObserver(self, queue: .main)
        cgmManager.refreshRSSI()
    }

    deinit {
        cgmManager.removeStateObserver(self)
    }

    private func refreshConnection() {
        let manager = cgmManager
        DispatchQueue.global(qos: .userInitiated).async {
            let scanning = manager.isScanning
            let connected = manager.isConnected
            let rssi = manager.lastRSSI
            let hasKey = manager.hasSavedKey
            DispatchQueue.main.async {
                self.scanning = scanning
                self.connected = connected
                self.rssi = rssi
                self.hasSavedKey = hasKey
            }
        }
    }

    // MARK: - Display values

    var lifecycleState: DirectConnect_LifecycleState { cgmManager.lifecycleState }

    var statusText: String {
        switch lifecycleState {
        case .notPaired: return NSLocalizedString("Not paired", comment: "DirectConnect status not paired")
        case .searching: return NSLocalizedString("Searching for sensor…", comment: "DirectConnect status searching")
        case .warmup: return NSLocalizedString("Sensor warming up", comment: "DirectConnect status warmup")
        case .ok: return NSLocalizedString("Sensor active", comment: "DirectConnect status ok")
        case .failed: return NSLocalizedString("Sensor failed", comment: "DirectConnect status failed")
        case .gracePeriod: return NSLocalizedString("Grace period — replace sensor", comment: "DirectConnect status grace")
        case .expired: return NSLocalizedString("Sensor expired", comment: "DirectConnect status expired")
        }
    }

    /// Fraction of the session elapsed, for the progress bar.
    var progress: Double {
        guard let start = state.activatedAt else { return 0 }
        if lifecycleState == .warmup {
            return min(1, max(0, Date().timeIntervalSince(start) / max(1, cgmManager.warmupDuration)))
        }
        return min(1, max(0, Date().timeIntervalSince(start) / max(1, cgmManager.lifetime)))
    }

    /// Time left before the sensor expires, then before the grace period ends; nil before the
    /// session length is known and after the sensor has ended.
    var daysLeftText: String? {
        let now = Date()
        if let expires = cgmManager.sensorExpiresAt, expires > now {
            return Self.remainingText(expires.timeIntervalSince(now), suffix: NSLocalizedString("left", comment: "DirectConnect time left suffix"))
        }
        if let ends = cgmManager.sensorEndsAt, ends > now {
            return Self.remainingText(ends.timeIntervalSince(now), suffix: NSLocalizedString("of grace period left", comment: "DirectConnect grace left suffix"))
        }
        return nil
    }

    /// Whole days while a day or more remains, so the number counts down once a day; hours below that.
    private static func remainingText(_ interval: TimeInterval, suffix: String) -> String {
        if interval >= 86400 {
            let days = Int(interval / 86400)
            let unit = days == 1 ? NSLocalizedString("day", comment: "DirectConnect one day") : NSLocalizedString("days", comment: "DirectConnect days")
            return "\(days) \(unit) \(suffix)"
        }
        let hours = max(1, Int((interval / 3600).rounded(.up)))
        let unit = hours == 1 ? NSLocalizedString("hour", comment: "DirectConnect one hour") : NSLocalizedString("hours", comment: "DirectConnect hours")
        return "\(hours) \(unit) \(suffix)"
    }

    var glucoseText: String {
        guard let reading = state.latestReading, reading.responseStatus == 0, let glucose = reading.glucose else { return "–" }
        let quantity = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: Double(glucose))
        return displayGlucosePreference.formatter.string(from: quantity) ?? "–"
    }

    /// Words plus the rate, e.g. "Flat → (+0.1 mg/dL/min)". A bare arrow in a settings row reads
    /// as a navigation hint, so the direction is spelled out.
    var trendText: String {
        guard let reading = state.latestReading, reading.responseStatus == 0,
              let trend = reading.trendType, let rate = reading.trend else { return "–" }
        let words: String
        switch trend {
        case .upUpUp: words = NSLocalizedString("Rising very fast", comment: "DirectConnect trend upUpUp")
        case .upUp: words = NSLocalizedString("Rising fast", comment: "DirectConnect trend upUp")
        case .up: words = NSLocalizedString("Rising", comment: "DirectConnect trend up")
        case .flat: words = NSLocalizedString("Flat", comment: "DirectConnect trend flat")
        case .down: words = NSLocalizedString("Falling", comment: "DirectConnect trend down")
        case .downDown: words = NSLocalizedString("Falling fast", comment: "DirectConnect trend downDown")
        case .downDownDown: words = NSLocalizedString("Falling very fast", comment: "DirectConnect trend downDownDown")
        }
        let rateText: String
        if displayGlucosePreference.unit == .millimolesPerLiter {
            rateText = String(format: "%+.2f mmol/L/min", rate / 18.0182)
        } else {
            rateText = String(format: "%+.1f mg/dL/min", rate)
        }
        return "\(words) \(trend.symbol) (\(rateText))"
    }

    var batteryText: String? {
        guard let battery = state.battery else { return nil }
        // G7-family thresholds published by xDrip4iOS: below 215 low, below 250 fair.
        let level: String
        switch battery.voltageB {
        case 0: level = NSLocalizedString("Unknown", comment: "DirectConnect battery unknown")
        case ..<215: level = NSLocalizedString("Low", comment: "DirectConnect battery low")
        case ..<250: level = NSLocalizedString("Fair", comment: "DirectConnect battery fair")
        default: level = NSLocalizedString("Good", comment: "DirectConnect battery good")
        }
        return "\(level) (\(battery.voltageB))"
    }

    var sessionLengthText: String {
        guard let length = state.knownSessionLength else {
            return NSLocalizedString("Detecting…", comment: "DirectConnect session length not yet reported")
        }
        let product = length == DirectConnect_SensorLifetime.fifteenDaySession
            ? NSLocalizedString("15-day sensor", comment: "DirectConnect 15-day product")
            : NSLocalizedString("10-day sensor", comment: "DirectConnect 10-day product")
        let source = state.extendedVersion != nil
            ? NSLocalizedString("reported by sensor", comment: "DirectConnect session length source sensor")
            : NSLocalizedString("by sensor type", comment: "DirectConnect session length source type")
        return "\(product), +12 h grace (\(source))"
    }

    // MARK: - Actions

    func setUploadReadings(_ enabled: Bool) { cgmManager.setUploadReadings(enabled) }
    func repair(code: String) { cgmManager.repair(pairingCode: code) }

    func addNewSensor(type: DirectConnect_SensorType, code: String) {
        cgmManager.configure(type: type, pairingCode: code)
    }
}

extension DirectConnect_SensorStatusViewModel: DirectConnect_StateObserver {
    func directConnectStateDidUpdate(_ state: DirectConnect_G7State) {
        self.state = state
        refreshConnection()
    }

    func directConnectConnectionStatusDidChange() {
        refreshConnection()
    }
}
