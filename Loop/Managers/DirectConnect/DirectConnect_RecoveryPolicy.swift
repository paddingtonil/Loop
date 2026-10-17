//
//  DirectConnect_RecoveryPolicy.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — Rules for taking the sensor back from another app and restarting a stuck
//  Bluetooth connection.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import Foundation

/// Pure timing rules, kept separate from Bluetooth code so they can be unit-tested.
enum DirectConnect_RecoveryPolicy {
    /// Minimum time between automatic take-backs: one sensor wake. DirectConnect always takes the
    /// sensor back; this only prevents repeated re-pairing attempts inside a single wake window.
    static let minimumTakeBackInterval: TimeInterval = 5 * 60
    /// Two take-backs within this window means another app keeps taking the sensor.
    static let repeatWindow: TimeInterval = 6 * 3600
    /// Consecutive stale (cached) readings before Loop re-pairs.
    static let staleReadingsBeforeReclaim = 2
    /// A G7 wakes about every 5 minutes; two missed wakes plus margin means the link is stuck.
    static let watchdogSilence: TimeInterval = 11 * 60
    static let watchdogMinimumInterval: TimeInterval = 10 * 60

    static func mayReclaim(history: [Date], now: Date) -> Bool {
        guard let last = history.max() else { return true }
        return now.timeIntervalSince(last) >= minimumTakeBackInterval
    }

    static func isRepeatedTakeover(history: [Date], now: Date) -> Bool {
        history.filter { now.timeIntervalSince($0) < repeatWindow }.count >= 2
    }

    /// Adds a take-back and drops entries older than the repeat window.
    static func recording(_ date: Date, in history: [Date]) -> [Date] {
        (history + [date]).filter { date.timeIntervalSince($0) < repeatWindow }
    }

    static func staleStreakNeedsReclaim(_ streak: Int) -> Bool {
        streak >= staleReadingsBeforeReclaim
    }

    static func watchdogShouldKick(lastConnect: Date?, lastKick: Date?, now: Date) -> Bool {
        if let lastKick = lastKick, now.timeIntervalSince(lastKick) < watchdogMinimumInterval { return false }
        guard let lastConnect = lastConnect else { return true }
        return now.timeIntervalSince(lastConnect) >= watchdogSilence
    }
}
