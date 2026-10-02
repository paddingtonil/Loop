//
//  LoopInsights_SignalGapHistoryView.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  LoopInsights — chronological history of CGM signal gap events.
//
//  Lets users review past gaps to correlate with real-world causes
//  ("I slept on the sensor", "I was near a strong RF source", etc.).
//  Reads from LoopInsights_BackfillDetector's persistent event store
//  (90-day rolling retention).
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import SwiftUI
import LoopKit

struct LoopInsights_SignalGapHistoryView: View {

    @ObservedObject private var detector = LoopInsights_BackfillDetector.shared

    /// Period filter — same options the dashboard analysis offers.
    @State private var periodDays: Int = 90

    private static let periodOptions: [(label: String, days: Int)] = [
        ("3 days", 3),
        ("7 days", 7),
        ("14 days", 14),
        ("30 days", 30),
        ("90 days", 90),
    ]

    var body: some View {
        let events = detector.events(within: periodDays)
        let summary = detector.buildSummary(days: periodDays)

        List {
            periodPickerSection

            if events.isEmpty {
                emptyStateSection
            } else {
                summaryHeaderSection(summary: summary)
                Section(header: Text("Events")) {
                    ForEach(events) { event in
                        eventRow(event)
                    }
                }
                noteFooterSection
            }
        }
        .navigationTitle(NSLocalizedString("Signal Gap History", comment: "LoopInsights signal gap history nav title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    private var periodPickerSection: some View {
        Section {
            Picker(selection: $periodDays, label: Text(NSLocalizedString("Lookback period", comment: "LoopInsights signal gap history lookback picker label"))) {
                ForEach(Self.periodOptions, id: \.days) { option in
                    Text(option.label).tag(option.days)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var emptyStateSection: some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title)
                    .foregroundColor(.green)
                    .padding(.top, 8)
                Text(NSLocalizedString("No signal gaps in this window", comment: "LoopInsights signal gap history empty state title"))
                    .font(.subheadline.weight(.semibold))
                Text(NSLocalizedString("Your CGM data has been arriving in real time. If you've been noticing missed readings, try a longer lookback period — older gaps may have rolled out of this window.", comment: "LoopInsights signal gap history empty state body"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
    }

    private func summaryHeaderSection(summary: LoopInsightsBackfillSummary) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundColor(.orange)
                    Text(String(
                        format: NSLocalizedString("%d gap(s) over %d days", comment: "LoopInsights signal gap history summary header"),
                        summary.totalEvents, summary.periodDays
                    ))
                    .font(.subheadline.weight(.semibold))
                }

                HStack(spacing: 12) {
                    statBlock(label: NSLocalizedString("Longest", comment: "LoopInsights signal gap history longest label"),
                              value: String(format: "%d min", summary.longestGapMinutes))
                    statBlock(label: NSLocalizedString("Average", comment: "LoopInsights signal gap history average label"),
                              value: String(format: "%.0f min", summary.averageGapMinutes))
                    statBlock(label: NSLocalizedString("Coverage", comment: "LoopInsights signal gap history coverage label"),
                              value: String(format: "%.1f%%", summary.realTimeCoveragePercent),
                              valueColor: summary.realTimeCoveragePercent >= 95 ? .green : .orange)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func eventRow(_ event: LoopInsightsBackfillEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.dayTimeFormatter.string(from: event.detectedAt))
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(String(format: NSLocalizedString("%d min", comment: "LoopInsights signal gap history row duration"),
                            event.gapDurationMinutes))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(severityColor(forMinutes: event.gapDurationMinutes))
                    .monospacedDigit()
            }
            HStack(spacing: 12) {
                Text(String(format: NSLocalizedString("%d sample(s) backfilled", comment: "LoopInsights signal gap history row sample count"),
                            event.sampleCount))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(Self.relativeFormatter.localizedString(for: event.detectedAt, relativeTo: Date()))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var noteFooterSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("About these records", comment: "LoopInsights signal gap history about section title"))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Text(NSLocalizedString("Gaps are detected when CGM samples arrive significantly delayed compared to wall-clock time. Common causes: sleeping on the sensor, distance from the phone, RF interference, or a sensor that needs replacement. Records are kept for 90 days.", comment: "LoopInsights signal gap history about section body"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Helpers

    private func statBlock(label: String, value: String, valueColor: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundColor(valueColor)
                .monospacedDigit()
        }
    }

    private func severityColor(forMinutes minutes: Int) -> Color {
        switch minutes {
        case 0..<10: return .secondary
        case 10..<30: return .orange
        default:      return .red
        }
    }

    private static let dayTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d, h:mm a"
        return f
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

#if DEBUG
struct LoopInsights_SignalGapHistoryView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            LoopInsights_SignalGapHistoryView()
        }
    }
}
#endif
