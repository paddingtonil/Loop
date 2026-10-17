//
//  DirectConnect_ConnectionHealth.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — Counts of sensor wakes received and missed, so connection reliability can be
//  measured instead of read line by line from the diagnostics log.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import Foundation

/// One thing that happened on the sensor connection.
struct DirectConnect_HealthEvent: Codable, Equatable {
    enum Kind: String, Codable {
        /// A new reading with a usable glucose value.
        case reading
        /// A new reading the sensor marked unusable (warmup, temporary sensor issue and similar).
        /// The connection worked; the sensor gave no value.
        case withheld
        /// The sensor sent only an old cached reading.
        case stale
        /// Loop re-paired to take the sensor back.
        case reclaimed
        case pairingFailed
    }

    let date: Date
    let kind: Kind
}

/// Reliability numbers for one time window. Pure, so it can be unit-tested.
struct DirectConnect_HealthSummary: Equatable {
    /// A G7 wakes about every 5 minutes.
    static let wakeInterval: TimeInterval = 5 * 60
    /// Longer than this between new readings means at least one wake was missed.
    static let gapThreshold: TimeInterval = 7.5 * 60

    let window: TimeInterval
    let freshReadings: Int
    let usableReadings: Int
    let withheldReadings: Int
    let staleReadings: Int
    let missedWakes: Int
    let gapCount: Int
    /// Longest stretch with at least one missed wake; 0 when there were none. Normal time between
    /// wakes (and since the last reading) is not a gap.
    let longestGap: TimeInterval
    /// When the longest gap ended; nil when it is still running (no reading since) or there is none.
    let longestGapEnd: Date?
    let reclaims: Int
    let pairingFailures: Int

    init(events: [DirectConnect_HealthEvent], window: TimeInterval, now: Date) {
        self.window = window
        let start = now.addingTimeInterval(-window)
        let inWindow = events.filter { $0.date >= start && $0.date <= now }
        let count = { (kind: DirectConnect_HealthEvent.Kind) in inWindow.filter { $0.kind == kind }.count }

        usableReadings = count(.reading)
        withheldReadings = count(.withheld)
        freshReadings = usableReadings + withheldReadings
        staleReadings = count(.stale)
        reclaims = count(.reclaimed)
        pairingFailures = count(.pairingFailed)

        let times = inWindow.filter { $0.kind == .reading || $0.kind == .withheld }.map(\.date).sorted()
        // Interior gaps end at a reading; the final one (last reading → now) is still open.
        // Time before the first reading in the window is not counted: Loop may not have been set up yet.
        var spans: [(length: TimeInterval, end: Date?)] = zip(times, times.dropFirst()).map { (length: $1.timeIntervalSince($0), end: Optional($1)) }
        if let last = times.last {
            spans.append((length: now.timeIntervalSince(last), end: nil))
        }
        let gaps = spans.filter { $0.length > Self.gapThreshold }
        gapCount = gaps.count
        missedWakes = gaps.reduce(0) { $0 + max(0, Int(($1.length / Self.wakeInterval).rounded()) - 1) }
        let longest = gaps.max { $0.length < $1.length }
        longestGap = longest?.length ?? 0
        longestGapEnd = longest?.end
    }

    /// Share of expected wakes that delivered a new reading, or nil with no data.
    var coverageIfKnown: Double? {
        let expected = freshReadings + missedWakes
        return expected == 0 ? nil : Double(freshReadings) / Double(expected)
    }

    var coverage: Double { coverageIfKnown ?? 0 }

    /// Plain-text block for Copy Diagnostics.
    func report(title: String, dateFormatter: DateFormatter) -> String {
        let percent = coverageIfKnown.map { String(format: "%.1f%%", $0 * 100) } ?? "no data"
        let gapText: String
        if gapCount == 0 {
            gapText = "none"
        } else {
            let end = longestGapEnd.map { "ended \(dateFormatter.string(from: $0))" } ?? "still running"
            gapText = "\(Int(longestGap / 60)) min (\(end))"
        }
        return [
            "## Connection Health — \(title)",
            "wakes received: \(freshReadings) of \(freshReadings + missedWakes) (\(percent))",
            "usable readings: \(usableReadings); withheld by sensor: \(withheldReadings); old cached: \(staleReadings)",
            "missed wakes: \(missedWakes) in \(gapCount) gap(s); longest gap: \(gapText)",
            "take-backs: \(reclaims); pairing failures: \(pairingFailures)",
        ].joined(separator: "\n")
    }
}

/// Seven days of connection events, kept on disk so the numbers survive app restarts.
final class DirectConnect_HealthLog {
    static let shared = DirectConnect_HealthLog()
    static let retention: TimeInterval = 7 * 86400
    /// About 2,000 readings a week plus other events; the cap only guards against runaway growth.
    static let capacity = 6000

    private let lock = NSLock()
    private var stored: [DirectConnect_HealthEvent] = []
    private let fileURL: URL?
    private let persistSynchronously: Bool
    private let writeQueue = DispatchQueue(label: "com.loopkit.Loop.DirectConnect.Health", qos: .utility)

    init(fileURL: URL? = DirectConnect_HealthLog.defaultFileURL, persistSynchronously: Bool = false) {
        self.fileURL = fileURL
        self.persistSynchronously = persistSynchronously
        if let url = fileURL, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([DirectConnect_HealthEvent].self, from: data) {
            stored = decoded
        }
    }

    static var defaultFileURL: URL? {
        DirectConnect_Diagnostics.defaultFileURL?.deletingLastPathComponent().appendingPathComponent("health.json")
    }

    func record(_ kind: DirectConnect_HealthEvent.Kind, at date: Date = Date()) {
        lock.lock()
        stored.append(DirectConnect_HealthEvent(date: date, kind: kind))
        stored = Self.trimmed(stored, now: Date())
        let snapshot = stored
        lock.unlock()
        persist(snapshot)
    }

    func events(now: Date = Date()) -> [DirectConnect_HealthEvent] {
        lock.lock(); defer { lock.unlock() }
        return Self.trimmed(stored, now: now)
    }

    func summary(window: TimeInterval, now: Date = Date()) -> DirectConnect_HealthSummary {
        DirectConnect_HealthSummary(events: events(now: now), window: window, now: now)
    }

    func clear() {
        lock.lock()
        stored.removeAll()
        lock.unlock()
        persist([])
    }

    private static func trimmed(_ events: [DirectConnect_HealthEvent], now: Date) -> [DirectConnect_HealthEvent] {
        Array(events.filter { now.timeIntervalSince($0.date) <= retention }.suffix(capacity))
    }

    private func persist(_ snapshot: [DirectConnect_HealthEvent]) {
        guard let url = fileURL else { return }
        let write = { try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic) }
        if persistSynchronously {
            _ = write()
        } else {
            writeQueue.async { _ = write() }
        }
    }
}
