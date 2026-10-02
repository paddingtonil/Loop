//
//  AutoPresets_CalendarManager.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  AutoPresets — Calendar event monitoring for automatic preset activation.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import Combine
import EventKit
import Foundation
import LoopKit
import os.log

// MARK: - Calendar Trigger Model

/// A keyword-to-preset mapping for calendar event matching.
public struct AutoPresetsCalendarTrigger: Codable, Identifiable, Equatable {
    public let id: UUID
    public var keyword: String
    public var presetId: String // UUID string of TemporaryScheduleOverridePreset
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        keyword: String,
        presetId: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.keyword = keyword
        self.presetId = presetId
        self.isEnabled = isEnabled
    }
}

// MARK: - Scanned Event (diagnostic)

/// Lightweight snapshot of an event returned by the most recent EventKit
/// query. Stored on the manager so the settings UI can show users exactly
/// which events Loop saw during a scan — the key diagnostic for "why
/// didn't my Gym event match?" Independent of EKEvent so it survives
/// across the publish boundary without holding EventKit references.
public struct AutoPresets_ScannedEvent: Identifiable {
    public let id = UUID()
    public let title: String
    public let calendarTitle: String
    public let calendarColor: CGColor?
    public let startDate: Date
    public let endDate: Date
    public let isAllDay: Bool
    /// The keyword (lowercased) that matched this event's title, or `nil`
    /// if no keyword matched. Lets the diagnostic view explain *why* an
    /// event did or didn't qualify.
    public let matchedKeyword: String?
}

// MARK: - Upcoming Match

/// An upcoming calendar event that matched a trigger keyword.
public struct AutoPresetsCalendarMatch: Identifiable {
    public let id = UUID()
    public let event: EKEvent
    public let trigger: AutoPresetsCalendarTrigger
    public let activationDate: Date

    public var eventTitle: String { event.title ?? "Untitled" }
    public var eventStart: Date { event.startDate }
    public var eventEnd: Date { event.endDate }
}

// MARK: - Calendar Manager

/// Manages EventKit calendar monitoring for AutoPresets.
public final class AutoPresets_CalendarManager: NSObject, ObservableObject {

    // MARK: - Singleton

    public static let shared = AutoPresets_CalendarManager()

    // MARK: - Published State

    @Published public private(set) var authorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published public private(set) var upcomingMatches: [AutoPresetsCalendarMatch] = []
    @Published public var triggers: [AutoPresetsCalendarTrigger] = []
    @Published public var enabledCalendarIDs: Set<String> = [] // empty = all calendars

    /// Stats from the most recent `scanAndSchedule()` run. Surfaced in the
    /// settings view as a "Scanned N events — found M matches" line so the
    /// user can see that "Scan Calendar Now" did something even when zero
    /// matches were found. Nil before the first scan completes.
    @Published public private(set) var lastScanDate: Date?
    @Published public private(set) var lastScanEventCount: Int = 0
    @Published public private(set) var lastScanMatchCount: Int = 0

    /// Full per-event detail from the most recent scan — title, calendar,
    /// start/end, and which (if any) keyword matched. Powers the
    /// "View scanned events" detail screen so a user can diagnose
    /// "why didn't Loop see my Gym event?" by looking at exactly what
    /// EventKit returned. Cleared on each new scan.
    @Published public private(set) var lastScannedEvents: [AutoPresets_ScannedEvent] = []

    // MARK: - Private Properties

    private let log = OSLog(subsystem: "com.loopkit.Loop.AutoPresets", category: "Calendar")
    private let eventStore = EKEventStore()
    private let defaults = UserDefaults(suiteName: "com.loopkit.Loop.AutoPresets") ?? .standard
    private var scanTimer: Timer?
    private var activationTimers: [UUID: Timer] = [:] // trigger ID → timer
    private var deactivationTimers: [UUID: Timer] = [:] // trigger ID → timer
    private var activatedByCalendar: [String: UUID] = [:] // [trigger ID string: preset UUID]

    private static let triggersKey = "AutoPresets_CalendarTriggers"
    private static let enabledKey = "AutoPresets_CalendarEnabled"
    private static let leadTimeKey = "AutoPresets_CalendarLeadTime"
    private static let deactivateOnEndKey = "AutoPresets_CalendarDeactivateOnEnd"
    private static let enabledCalendarsKey = "AutoPresets_CalendarEnabledCalendars"
    private static let scanIntervalKey = "AutoPresets_CalendarScanIntervalMinutes"

    /// Valid auto-scan intervals offered to the user (minutes). `0` means
    /// "no auto-scan" — the periodic Timer is disabled and the manager only
    /// scans on EKEventStoreChanged notifications + manual button taps.
    public static let scanIntervalOptions: [Int] = [0, 5, 15, 30, 60]
    public static let defaultScanIntervalMinutes = 15

    // MARK: - Initialization

    private override init() {
        super.init()
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        loadTriggers()
        loadEnabledCalendars()

        // Watch for calendar changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(calendarStoreChanged),
            name: .EKEventStoreChanged,
            object: eventStore
        )
    }

    deinit {
        stopMonitoring()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Feature Toggle

    public var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set {
            defaults.set(newValue, forKey: Self.enabledKey)
            objectWillChange.send()
            if newValue {
                startMonitoring()
            } else {
                stopMonitoring()
            }
        }
    }

    /// Minutes before event to activate preset (default 15)
    public var leadTimeMinutes: Int {
        get {
            if defaults.object(forKey: Self.leadTimeKey) == nil { return 15 }
            return defaults.integer(forKey: Self.leadTimeKey)
        }
        set {
            defaults.set(newValue, forKey: Self.leadTimeKey)
            objectWillChange.send()
            // Rescan with new lead time
            if isEnabled { scanAndSchedule() }
        }
    }

    /// Whether to deactivate preset when event ends
    public var deactivateOnEventEnd: Bool {
        get {
            // Default true if key not set
            if defaults.object(forKey: Self.deactivateOnEndKey) == nil { return true }
            return defaults.bool(forKey: Self.deactivateOnEndKey)
        }
        set {
            defaults.set(newValue, forKey: Self.deactivateOnEndKey)
            objectWillChange.send()
        }
    }

    /// How often (in minutes) the periodic background scan runs. Default 15.
    /// Set to 0 to disable the periodic scan entirely — the manager still
    /// rescans on calendar-change notifications and on manual "Scan Now"
    /// taps, so triggers remain functional.
    public var scanIntervalMinutes: Int {
        get {
            if defaults.object(forKey: Self.scanIntervalKey) == nil {
                return Self.defaultScanIntervalMinutes
            }
            return defaults.integer(forKey: Self.scanIntervalKey)
        }
        set {
            let clamped = Self.scanIntervalOptions.contains(newValue)
                ? newValue
                : Self.defaultScanIntervalMinutes
            defaults.set(clamped, forKey: Self.scanIntervalKey)
            objectWillChange.send()
            // Reschedule periodic Timer with the new interval (or stop it).
            if isEnabled { restartScanTimer() }
        }
    }

    // MARK: - Authorization

    public func requestAuthorization() {
        if #available(iOS 17.0, *) {
            eventStore.requestFullAccessToEvents { [weak self] granted, error in
                DispatchQueue.main.async {
                    self?.authorizationStatus = EKEventStore.authorizationStatus(for: .event)
                    if granted && self?.isEnabled == true {
                        self?.startMonitoring()
                    }
                }
                if let error = error {
                    os_log("Calendar authorization error: %{public}@", type: .error, error.localizedDescription)
                }
            }
        } else {
            eventStore.requestAccess(to: .event) { [weak self] granted, error in
                DispatchQueue.main.async {
                    self?.authorizationStatus = EKEventStore.authorizationStatus(for: .event)
                    if granted && self?.isEnabled == true {
                        self?.startMonitoring()
                    }
                }
                if let error = error {
                    os_log("Calendar authorization error: %{public}@", type: .error, error.localizedDescription)
                }
            }
        }
    }

    public var hasAuthorization: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17.0, *) {
            return status == .fullAccess
        }
        return status == .authorized
    }

    // MARK: - Calendar Access

    /// All calendars available on the device.
    public func availableCalendars() -> [EKCalendar] {
        eventStore.calendars(for: .event).sorted { $0.title < $1.title }
    }

    /// Whether a specific calendar is being monitored.
    public func isCalendarEnabled(_ calendar: EKCalendar) -> Bool {
        enabledCalendarIDs.isEmpty || enabledCalendarIDs.contains(calendar.calendarIdentifier)
    }

    /// Toggle a specific calendar for monitoring.
    public func toggleCalendar(_ calendar: EKCalendar) {
        objectWillChange.send()
        let id = calendar.calendarIdentifier
        if enabledCalendarIDs.isEmpty {
            // Switching from "all" to specific — add all except the toggled one
            enabledCalendarIDs = Set(availableCalendars().map(\.calendarIdentifier))
            enabledCalendarIDs.remove(id)
        } else if enabledCalendarIDs.contains(id) {
            enabledCalendarIDs.remove(id)
            // If none left, go back to "all"
            if enabledCalendarIDs.isEmpty {
                // Actually empty means all, so this is fine
            }
        } else {
            enabledCalendarIDs.insert(id)
        }
        saveEnabledCalendars()
        if isEnabled { scanAndSchedule() }
    }

    /// Reset to watching all calendars.
    public func watchAllCalendars() {
        objectWillChange.send()
        enabledCalendarIDs = []
        saveEnabledCalendars()
        if isEnabled { scanAndSchedule() }
    }

    // MARK: - Trigger Management

    public func addTrigger(_ trigger: AutoPresetsCalendarTrigger) {
        objectWillChange.send()
        triggers.append(trigger)
        saveTriggers()
        if isEnabled { scanAndSchedule() }
    }

    public func updateTrigger(_ trigger: AutoPresetsCalendarTrigger) {
        objectWillChange.send()
        guard let index = triggers.firstIndex(where: { $0.id == trigger.id }) else { return }
        triggers[index] = trigger
        saveTriggers()
        if isEnabled { scanAndSchedule() }
    }

    public func removeTrigger(_ trigger: AutoPresetsCalendarTrigger) {
        objectWillChange.send()
        triggers.removeAll { $0.id == trigger.id }
        saveTriggers()
        cancelTimers(for: trigger)
    }

    public func removeTriggers(at offsets: IndexSet) {
        let toRemove = offsets.map { triggers[$0] }
        for trigger in toRemove {
            cancelTimers(for: trigger)
        }
        objectWillChange.send()
        triggers.remove(atOffsets: offsets)
        saveTriggers()
    }

    // MARK: - Monitoring

    public func startMonitoring() {
        guard hasAuthorization else {
            os_log("Cannot start calendar monitoring — no authorization", log: log, type: .error)
            return
        }

        scanAndSchedule()
        restartScanTimer()

        os_log("Calendar monitoring started with %d triggers", log: log, type: .info, triggers.filter(\.isEnabled).count)
    }

    public func stopMonitoring() {
        scanTimer?.invalidate()
        scanTimer = nil
        for timer in activationTimers.values { timer.invalidate() }
        for timer in deactivationTimers.values { timer.invalidate() }
        activationTimers.removeAll()
        deactivationTimers.removeAll()
        upcomingMatches = []
        os_log("Calendar monitoring stopped", log: log, type: .info)
    }

    /// Force a rescan now (called from UI "Refresh" button).
    ///
    /// Why this calls `refreshSourcesIfNecessary()` first: EventKit caches
    /// calendar data locally and only re-syncs on its own schedule. Without
    /// this hint, a manual "Scan Calendar Now" tap returns stale events even
    /// after they've been deleted/updated in Google Calendar / iCloud — the
    /// scan is reading the local cache, not the cloud. `refreshSourcesIfNecessary()`
    /// asks EventKit to fetch fresh data; when that data arrives, our
    /// `EKEventStoreChanged` observer fires another scan automatically, so
    /// the UI eventually reflects the cloud state.
    public func rescan() {
        guard isEnabled else { return }
        eventStore.refreshSourcesIfNecessary()
        scanAndSchedule()
    }

    /// (Re)schedules the periodic background scan Timer using the current
    /// `scanIntervalMinutes` value. `0` disables the periodic Timer — the
    /// manager still rescans on EKEventStoreChanged + manual taps in that mode.
    private func restartScanTimer() {
        scanTimer?.invalidate()
        scanTimer = nil

        let minutes = scanIntervalMinutes
        guard minutes > 0 else {
            os_log("Periodic calendar scan disabled (scanIntervalMinutes=0)", log: log, type: .info)
            return
        }

        let seconds = TimeInterval(minutes * 60)
        scanTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            self?.scanAndSchedule()
        }
        os_log("Periodic calendar scan scheduled every %d minutes", log: log, type: .info, minutes)
    }

    // MARK: - Event Scanning

    private func scanAndSchedule() {
        guard hasAuthorization else { return }

        let now = Date()
        let lookAhead: TimeInterval = 24 * 60 * 60 // 24 hours
        let endDate = now.addingTimeInterval(lookAhead)

        // Build predicate — filter by enabled calendars if set
        let calendars: [EKCalendar]?
        if enabledCalendarIDs.isEmpty {
            calendars = nil // all calendars
        } else {
            calendars = availableCalendars().filter { enabledCalendarIDs.contains($0.calendarIdentifier) }
        }

        let predicate = eventStore.predicateForEvents(withStart: now, end: endDate, calendars: calendars)
        let events = eventStore.events(matching: predicate)

        // Cancel existing timers
        for timer in activationTimers.values { timer.invalidate() }
        activationTimers.removeAll()
        for timer in deactivationTimers.values { timer.invalidate() }
        deactivationTimers.removeAll()

        var matches: [AutoPresetsCalendarMatch] = []
        var scannedEvents: [AutoPresets_ScannedEvent] = []

        for event in events {
            // Always record the event in the diagnostic list — even if it
            // has no title or doesn't match any trigger. This is the data
            // a user needs to see to figure out why a scan didn't find
            // what they expected.
            let title = event.title ?? "(no title)"
            let titleLower = title.lowercased()
            var matchedKeyword: String?

            for trigger in triggers where trigger.isEnabled && !trigger.presetId.isEmpty {
                let keywordLower = trigger.keyword.lowercased()
                if titleLower.contains(keywordLower) {
                    matchedKeyword = keywordLower
                    break
                }
            }

            // Log every scanned event with its calendar source for offline
            // debugging via Console.app. Console will show:
            //   Calendar scan event: 'Gym' [Home] 2026-05-20 10:00 → 11:00  match=none
            os_log("Calendar scan event: '%{public}@' [%{public}@] %{public}@ %{public}@",
                   log: log, type: .debug,
                   title,
                   event.calendar.title,
                   DateFormatter.localizedString(from: event.startDate, dateStyle: .short, timeStyle: .short),
                   matchedKeyword.map { "match=\($0)" } ?? "match=none")

            scannedEvents.append(AutoPresets_ScannedEvent(
                title: title,
                calendarTitle: event.calendar.title,
                calendarColor: event.calendar.cgColor,
                startDate: event.startDate,
                endDate: event.endDate,
                isAllDay: event.isAllDay,
                matchedKeyword: matchedKeyword
            ))

            // Real match → schedule the timers (existing logic continues below).
            guard event.title != nil else { continue }

            for trigger in triggers where trigger.isEnabled && !trigger.presetId.isEmpty {
                let keywordLower = trigger.keyword.lowercased()
                if titleLower.contains(keywordLower) {
                    let leadTime = TimeInterval(leadTimeMinutes * 60)
                    let activationDate = event.startDate.addingTimeInterval(-leadTime)

                    let match = AutoPresetsCalendarMatch(
                        event: event,
                        trigger: trigger,
                        activationDate: activationDate
                    )
                    matches.append(match)

                    // Schedule activation if in the future
                    if activationDate > now {
                        let timer = Timer(fire: activationDate, interval: 0, repeats: false) { [weak self] _ in
                            self?.activatePreset(for: trigger, event: event)
                        }
                        RunLoop.main.add(timer, forMode: .common)
                        activationTimers[trigger.id] = timer

                        os_log("Scheduled preset activation for '%{public}@' at %{public}@",
                               log: log, type: .debug, title,
                               DateFormatter.localizedString(from: activationDate, dateStyle: .none, timeStyle: .short))
                    } else if event.startDate > now {
                        // Event hasn't started yet but we're within lead time — activate now
                        activatePreset(for: trigger, event: event)
                    }

                    // Schedule deactivation at event end
                    if deactivateOnEventEnd && event.endDate > now {
                        let deactivationTimer = Timer(fire: event.endDate, interval: 0, repeats: false) { [weak self] _ in
                            self?.deactivatePreset(for: trigger, event: event)
                        }
                        RunLoop.main.add(deactivationTimer, forMode: .common)
                        deactivationTimers[trigger.id] = deactivationTimer
                    }

                    break // One match per event
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.upcomingMatches = matches.sorted { $0.activationDate < $1.activationDate }
            self?.lastScanDate = Date()
            self?.lastScanEventCount = events.count
            self?.lastScanMatchCount = matches.count
            self?.lastScannedEvents = scannedEvents.sorted { $0.startDate < $1.startDate }
        }

        os_log("Calendar scan found %d matches in %d events", log: log, type: .debug, matches.count, events.count)
    }

    @objc private func calendarStoreChanged() {
        if isEnabled { scanAndSchedule() }
    }

    // MARK: - Preset Activation

    private func activatePreset(for trigger: AutoPresetsCalendarTrigger, event: EKEvent) {
        guard let presetUUID = UUID(uuidString: trigger.presetId) else { return }

        let coordinator = AutoPresets_Coordinator.shared

        // Don't override a manually-set preset
        if let currentOverride = coordinator.currentOverride(),
           activatedByCalendar[trigger.id.uuidString] == nil {
            os_log("Override already active (not from calendar), skipping", log: log, type: .info)
            return
        }

        guard let preset = coordinator.availablePresets().first(where: { $0.id == presetUUID }) else {
            os_log("Preset UUID %{public}@ not found", log: log, type: .error, trigger.presetId)
            return
        }

        activatedByCalendar[trigger.id.uuidString] = presetUUID
        coordinator.delegate?.autoPresets(coordinator, shouldActivatePreset: preset)

        let storage = AutoPresets_Storage()
        storage.addLogEntry(event: .presetActivated, activityType: nil,
                           presetName: "\(preset.name) (📅 \(event.title ?? "Event"))")

        NotificationCenter.default.post(
            name: .autoPresetsPresetActivated,
            object: nil,
            userInfo: ["activityType": "calendar", "presetName": preset.name]
        )

        os_log("Calendar activated preset '%{public}@' for event '%{public}@'",
               log: log, type: .info, preset.name, event.title ?? "")
    }

    private func deactivatePreset(for trigger: AutoPresetsCalendarTrigger, event: EKEvent) {
        guard let presetUUID = activatedByCalendar[trigger.id.uuidString] else { return }

        let coordinator = AutoPresets_Coordinator.shared
        guard let preset = coordinator.availablePresets().first(where: { $0.id == presetUUID }) else {
            activatedByCalendar.removeValue(forKey: trigger.id.uuidString)
            return
        }

        activatedByCalendar.removeValue(forKey: trigger.id.uuidString)
        coordinator.delegate?.autoPresets(coordinator, shouldDeactivatePreset: preset)

        let storage = AutoPresets_Storage()
        storage.addLogEntry(event: .presetDeactivated, activityType: nil,
                           presetName: "\(preset.name) (📅 \(event.title ?? "Event"))")

        NotificationCenter.default.post(
            name: .autoPresetsPresetDeactivated,
            object: nil,
            userInfo: ["activityType": "calendar", "presetName": preset.name]
        )

        os_log("Calendar deactivated preset '%{public}@' after event '%{public}@' ended",
               log: log, type: .info, preset.name, event.title ?? "")
    }

    // MARK: - Timer Helpers

    private func cancelTimers(for trigger: AutoPresetsCalendarTrigger) {
        activationTimers[trigger.id]?.invalidate()
        activationTimers.removeValue(forKey: trigger.id)
        deactivationTimers[trigger.id]?.invalidate()
        deactivationTimers.removeValue(forKey: trigger.id)
    }

    // MARK: - Persistence

    private func loadTriggers() {
        guard let data = defaults.data(forKey: Self.triggersKey),
              let decoded = try? JSONDecoder().decode([AutoPresetsCalendarTrigger].self, from: data)
        else {
            triggers = []
            return
        }
        triggers = decoded
    }

    private func saveTriggers() {
        if let data = try? JSONEncoder().encode(triggers) {
            defaults.set(data, forKey: Self.triggersKey)
        }
    }

    private func loadEnabledCalendars() {
        enabledCalendarIDs = Set(defaults.stringArray(forKey: Self.enabledCalendarsKey) ?? [])
    }

    private func saveEnabledCalendars() {
        defaults.set(Array(enabledCalendarIDs), forKey: Self.enabledCalendarsKey)
    }
}
