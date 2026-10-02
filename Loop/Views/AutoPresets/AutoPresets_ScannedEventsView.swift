//
//  AutoPresets_ScannedEventsView.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  Diagnostic view that lists every event returned by the most recent
//  EventKit query inside AutoPresets_CalendarManager. The whole point is
//  to answer the question "why didn't Loop see my Gym event?" by showing
//  exactly which events were returned, which calendar each came from, and
//  which (if any) keyword matched.
//
//  Reached by tapping the "Scanned N events..." result line in the
//  Calendar Triggers settings.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import SwiftUI

struct AutoPresets_ScannedEventsView: View {
    @ObservedObject private var calendarManager = AutoPresets_CalendarManager.shared

    var body: some View {
        List {
            summarySection

            if calendarManager.lastScannedEvents.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No events scanned yet")
                            .font(.body.weight(.medium))
                        Text("Tap \"Scan Calendar Now\" on the previous screen first.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                Section(header: Text("Events returned by EventKit"),
                        footer: Text("This is everything Loop's calendar query returned. Anything in your iOS Calendar app that isn't listed here is invisible to Loop — usually because of per-calendar access settings in iOS Settings → Privacy & Security → Calendars.")
                            .font(.caption)) {
                    ForEach(calendarManager.lastScannedEvents) { event in
                        eventRow(event)
                    }
                }

                // Per-calendar breakdown — quick way to spot a missing calendar.
                let byCalendar = Dictionary(grouping: calendarManager.lastScannedEvents, by: \.calendarTitle)
                    .map { (title: $0.key, count: $0.value.count) }
                    .sorted { $0.count > $1.count }
                if byCalendar.count > 1 {
                    Section(header: Text("Events per calendar")) {
                        ForEach(byCalendar, id: \.title) { entry in
                            HStack {
                                Text(entry.title)
                                Spacer()
                                Text("\(entry.count)")
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Scanned Events")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    @ViewBuilder
    private var summarySection: some View {
        Section {
            if let date = calendarManager.lastScanDate {
                HStack {
                    Text("Last scan")
                    Spacer()
                    Text(Self.timeFormatter.string(from: date))
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Events returned")
                    Spacer()
                    Text("\(calendarManager.lastScanEventCount)")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                HStack {
                    Text("Keyword matches")
                    Spacer()
                    Text("\(calendarManager.lastScanMatchCount)")
                        .foregroundColor(calendarManager.lastScanMatchCount > 0
                                         ? Color(red: 76/255, green: 175/255, blue: 80/255)
                                         : .secondary)
                        .monospacedDigit()
                }
            } else {
                Text("No scan run yet")
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Rows

    private func eventRow(_ event: AutoPresets_ScannedEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Calendar color dot
            Circle()
                .fill(Color(cgColor: event.calendarColor ?? CGColor(gray: 0.5, alpha: 1)))
                .frame(width: 10, height: 10)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.title)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                    Spacer()
                    if let kw = event.matchedKeyword {
                        Text("✓ \(kw)")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Color(red: 76/255, green: 175/255, blue: 80/255))
                    }
                }

                Text(event.calendarTitle)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(formatEventWindow(event))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Formatting

    private func formatEventWindow(_ event: AutoPresets_ScannedEvent) -> String {
        if event.isAllDay {
            return "All day — \(Self.dayFormatter.string(from: event.startDate))"
        }
        let day = Self.dayFormatter.string(from: event.startDate)
        let start = Self.timeFormatter.string(from: event.startDate)
        let end = Self.timeFormatter.string(from: event.endDate)
        return "\(day) — \(start) → \(end)"
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()
}

#if DEBUG
struct AutoPresets_ScannedEventsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            AutoPresets_ScannedEventsView()
        }
    }
}
#endif
