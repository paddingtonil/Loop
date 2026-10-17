//
//  DirectConnect_Diagnostics.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — Log of recent sensor communication for the diagnostics screen, kept on disk
//  so it survives app restarts and rebuilds.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import Foundation

/// Keeps the most recent log lines so a user can export them when pairing or reconnecting
/// misbehaves. Lines are also written to Loop's device log; this copy exists for quick sharing.
final class DirectConnect_Diagnostics {
    static let shared = DirectConnect_Diagnostics()
    /// About 2 days of normal traffic (a handful of lines per 5-minute sensor wake).
    static let capacity = 3000

    private let lock = NSLock()
    private var lines: [String] = []
    private let writeQueue = DispatchQueue(label: "com.loopkit.Loop.DirectConnect.Diagnostics", qos: .utility)
    private let fileURL: URL?
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(fileURL: URL? = DirectConnect_Diagnostics.defaultFileURL) {
        self.fileURL = fileURL
        if let url = fileURL, let text = try? String(contentsOf: url, encoding: .utf8) {
            lines = Array(text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).suffix(Self.capacity))
        }
    }

    static var defaultFileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let directory = base.appendingPathComponent("DirectConnect", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("diagnostics.log")
    }

    func record(_ message: String, at date: Date = Date()) {
        lock.lock()
        lines.append("\(formatter.string(from: date)) \(message)")
        if lines.count > Self.capacity {
            lines.removeFirst(lines.count - Self.capacity)
        }
        let snapshot = lines
        lock.unlock()
        persist(snapshot)
    }

    var recentLines: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }

    func export(header: String) -> String {
        ([header, ""] + recentLines).joined(separator: "\n")
    }

    func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
        persist([])
    }

    private func persist(_ snapshot: [String]) {
        guard let url = fileURL else { return }
        writeQueue.async {
            // Rewriting the whole file keeps the trim simple; at capacity it is a few hundred KB.
            try? (snapshot.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
