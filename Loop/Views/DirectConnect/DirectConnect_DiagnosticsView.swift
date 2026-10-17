//
//  DirectConnect_DiagnosticsView.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — Sensor diagnostics and log export.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import SwiftUI
import UIKit
import LoopKitUI

struct DirectConnect_DiagnosticsView: View {
    @ObservedObject var viewModel: DirectConnect_SensorStatusViewModel
    @State private var lines: [String] = []
    @State private var confirmingClear = false
    @State private var dayHealth = DirectConnect_HealthLog.shared.summary(window: 86400)
    @State private var weekHealth = DirectConnect_HealthLog.shared.summary(window: 7 * 86400)
    /// Which action last finished, shown on its button for 2 seconds so the tap is visibly confirmed.
    @State private var confirmed: ConfirmedAction?

    private enum ConfirmedAction { case copied, cleared }

    init(viewModel: DirectConnect_SensorStatusViewModel) {
        self.viewModel = viewModel
    }

    private var state: DirectConnect_G7State { viewModel.state }

    private var report: String {
        let health = [dayHealth.report(title: "last 24 hours", dateFormatter: viewModel.dateFormatter),
                      weekHealth.report(title: "last 7 days", dateFormatter: viewModel.dateFormatter)]
        return DirectConnect_Diagnostics.shared.export(header: ([viewModel.cgmManager.debugDescription] + health).joined(separator: "\n\n"))
    }

    var body: some View {
        List {
            Section(header: Text(NSLocalizedString("Sensor", comment: "DirectConnect diagnostics sensor section"))) {
                LabeledValueView(label: NSLocalizedString("Name", comment: "DirectConnect diag name"), value: state.sensorID ?? "–")
                LabeledValueView(label: NSLocalizedString("Type", comment: "DirectConnect diag type"), value: state.sensorType.displayName)
                LabeledValueView(label: NSLocalizedString("Firmware", comment: "DirectConnect diag firmware"), value: state.versionInfo?.firmwareVersion ?? "–")
                LabeledValueView(label: NSLocalizedString("Build", comment: "DirectConnect diag build"), value: state.versionInfo.map { String($0.buildVersion) } ?? "–")
                LabeledValueView(label: NSLocalizedString("Session Length", comment: "DirectConnect diag session"), value: viewModel.sessionLengthText)
                LabeledValueView(label: NSLocalizedString("Algorithm State", comment: "DirectConnect diag algorithm"), value: state.latestReading?.algorithmState.description ?? "–")
            }

            Section(header: Text(NSLocalizedString("Connection Health", comment: "DirectConnect diagnostics health section")),
                    footer: Text(NSLocalizedString("A G7 sends a reading about every 5 minutes. Received counts readings that arrived. Withheld by sensor means the connection worked but the sensor gave no value (for example warmup or a temporary sensor issue). Missed wakes are 5-minute slots with nothing received.", comment: "DirectConnect diagnostics health footer"))) {
                healthRow(NSLocalizedString("Last 24 Hours", comment: "DirectConnect health 24h"), dayHealth)
                healthRow(NSLocalizedString("Last 7 Days", comment: "DirectConnect health 7d"), weekHealth)
            }

            Section(header: Text(NSLocalizedString("Connection", comment: "DirectConnect diagnostics connection section"))) {
                LabeledValueView(label: NSLocalizedString("Saved Pairing Key", comment: "DirectConnect diag key"), value: viewModel.hasSavedKey ? NSLocalizedString("Yes", comment: "yes") : NSLocalizedString("No", comment: "no"))
                LabeledValueView(label: NSLocalizedString("Reconnects Stopped", comment: "DirectConnect diag blocked"), value: viewModel.cgmManager.sensor.authenticationBlocked ? NSLocalizedString("Yes — key rejected", comment: "DirectConnect blocked yes") : NSLocalizedString("No", comment: "no"))
                LabeledValueView(label: NSLocalizedString("Signal Strength", comment: "DirectConnect diag rssi"), value: viewModel.rssi.map { "\($0) dBm" } ?? "–")
                LabeledDateView(label: NSLocalizedString("Last Connect", comment: "DirectConnect diag last connect"), date: state.latestConnect, dateFormatter: viewModel.dateFormatter)
                LabeledDateView(label: NSLocalizedString("Last Reading", comment: "DirectConnect diag last reading"), date: state.latestReadingTimestamp, dateFormatter: viewModel.dateFormatter)
                LabeledValueView(label: NSLocalizedString("Last Packet", comment: "DirectConnect diag last packet"), value: state.latestReading?.data.dcHex ?? "–")
            }

            Section {
                if #available(iOS 16.0, *) {
                    ShareLink(item: report) {
                        Label(NSLocalizedString("Share Diagnostics", comment: "DirectConnect share diagnostics"), systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    UIPasteboard.general.string = report
                    confirm(.copied)
                } label: {
                    if confirmed == .copied {
                        Label(NSLocalizedString("Copied", comment: "DirectConnect diagnostics copied"), systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Label(NSLocalizedString("Copy Diagnostics", comment: "DirectConnect copy diagnostics"), systemImage: "doc.on.doc")
                    }
                }
                Button(role: .destructive) {
                    confirmingClear = true
                } label: {
                    if confirmed == .cleared {
                        Label(NSLocalizedString("Logs Cleared", comment: "DirectConnect logs cleared"), systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Label(NSLocalizedString("Clear Logs", comment: "DirectConnect clear logs"), systemImage: "trash")
                    }
                }
                .disabled(lines.isEmpty && confirmed != .cleared)
                .confirmationDialog(NSLocalizedString("Clear the DirectConnect log?", comment: "DirectConnect clear logs confirm title"),
                                    isPresented: $confirmingClear, titleVisibility: .visible) {
                    Button(NSLocalizedString("Clear Logs", comment: "DirectConnect clear logs confirm"), role: .destructive) {
                        DirectConnect_Diagnostics.shared.clear()
                        DirectConnect_HealthLog.shared.clear()
                        lines = []
                        refreshHealth()
                        confirm(.cleared)
                    }
                } message: {
                    Text(NSLocalizedString("This deletes the log lines and Connection Health counts shown here and in Copy Diagnostics. The pairing key and sensor settings are not changed.", comment: "DirectConnect clear logs confirm message"))
                }
            }

            Section(header: Text(NSLocalizedString("Recent Log", comment: "DirectConnect recent log section"))) {
                if lines.isEmpty {
                    Text(NSLocalizedString("No log entries yet.", comment: "DirectConnect empty log")).foregroundColor(.secondary)
                }
                ForEach(lines.reversed().prefix(200), id: \.self) { line in
                    Text(line).font(.system(.caption2, design: .monospaced))
                }
            }
        }
        .insetGroupedListStyle()
        .navigationTitle(NSLocalizedString("Diagnostics", comment: "DirectConnect diagnostics title"))
        .onAppear {
            viewModel.cgmManager.refreshRSSI()
            lines = DirectConnect_Diagnostics.shared.recentLines
            refreshHealth()
        }
    }

    private func refreshHealth() {
        dayHealth = DirectConnect_HealthLog.shared.summary(window: 86400)
        weekHealth = DirectConnect_HealthLog.shared.summary(window: 7 * 86400)
    }

    private func healthRow(_ title: String, _ summary: DirectConnect_HealthSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let coverage = summary.coverageIfKnown {
                    Text(String(format: "%.1f%%", coverage * 100))
                        .font(.headline.monospacedDigit())
                        .foregroundColor(coverage >= 0.98 ? .green : coverage >= 0.9 ? .orange : .red)
                } else {
                    Text(NSLocalizedString("No data yet", comment: "DirectConnect health no data")).foregroundColor(.secondary)
                }
            }
            if summary.coverageIfKnown != nil {
                Group {
                    Text(String(format: NSLocalizedString("Received %d of %d wakes · %d missed in %d gap(s)", comment: "DirectConnect health received (1: received, 2: expected, 3: missed, 4: gaps)"),
                                summary.freshReadings, summary.freshReadings + summary.missedWakes, summary.missedWakes, summary.gapCount))
                    Text(String(format: NSLocalizedString("Usable %d · withheld by sensor %d · old cached %d", comment: "DirectConnect health kinds (1: usable, 2: withheld, 3: stale)"),
                                summary.usableReadings, summary.withheldReadings, summary.staleReadings))
                    Text(longestGapText(summary))
                    Text(String(format: NSLocalizedString("Take-backs %d · pairing failures %d", comment: "DirectConnect health recovery (1: take-backs, 2: failures)"),
                                summary.reclaims, summary.pairingFailures))
                }
                // One line each: these are short counts, and wrapped halves were hard to read.
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func longestGapText(_ summary: DirectConnect_HealthSummary) -> String {
        guard summary.gapCount > 0 else {
            return NSLocalizedString("No gaps", comment: "DirectConnect health no gaps")
        }
        let minutes = Int(summary.longestGap / 60)
        guard let end = summary.longestGapEnd else {
            return String(format: NSLocalizedString("Longest gap %d min (no reading since)", comment: "DirectConnect health gap open (1: minutes)"), minutes)
        }
        return String(format: NSLocalizedString("Longest gap %d min, ended %@", comment: "DirectConnect health gap (1: minutes, 2: time)"), minutes, viewModel.dateFormatter.string(from: end))
    }

    private func confirm(_ action: ConfirmedAction) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation { confirmed = action }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if confirmed == action { withAnimation { confirmed = nil } }
        }
    }
}
