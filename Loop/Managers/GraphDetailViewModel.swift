//
//  GraphDetailViewModel.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  GraphDetailView — Data aggregation for a specific chart timestamp.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import Combine
import Foundation
import HealthKit
import LoopKit

// MARK: - GraphDetailViewModel

final class GraphDetailViewModel: ObservableObject {
    @Published var data: GraphDetailData

    private let deviceManager: DeviceDataManager
    private var scrubThrottleTimer: Timer?
    private var lastReloadAt: Date = .distantPast
    /// Throttle window for scrub-driven reloads. 150ms gives ~6 updates/sec
    /// during continuous scrub — fast enough to feel live, slow enough to
    /// avoid flooding HealthKit/DoseStore with overlapping queries.
    private let scrubThrottleInterval: TimeInterval = 0.15

    /// Monotonic counter incremented on every reload. Each async load
    /// captures the current value when it kicks off and only commits its
    /// result if the counter is still equal at completion — late results
    /// from earlier scrub positions are dropped instead of overwriting
    /// the user's current position.
    private var loadGeneration: Int = 0

    /// Bucket size for snapping the scrub timestamp. CGM samples land every
    /// 5 minutes, so re-fetching between sample boundaries shows the same
    /// data and just causes visual churn. Round to the nearest 5-min mark
    /// and skip reloads when the rounded value hasn't changed.
    private let scrubBucketInterval: TimeInterval = 5 * 60

    /// Last bucket the popup displayed. Used to no-op `update(for:)` when
    /// the user is scrubbing within the same 5-min window.
    private var lastBucketedDate: Date?

    init(date: Date, glucoseUnit: HKUnit, deviceManager: DeviceDataManager) {
        self.deviceManager = deviceManager
        let t = date.timeIntervalSinceReferenceDate
        let bucket: TimeInterval = 5 * 60
        let initialDate = Date(timeIntervalSinceReferenceDate: (t / bucket).rounded() * bucket)
        self.data = GraphDetailData(date: initialDate, glucoseUnit: glucoseUnit)
        self.lastBucketedDate = initialDate
        loadGeneration += 1
        loadData(generation: loadGeneration, date: initialDate, unit: glucoseUnit)
    }

    /// Update to a new date and reload all data.
    ///
    /// Uses a **leading-edge throttle**: the first scrub call (or any call
    /// after a quiet period ≥ `scrubThrottleInterval`) fires immediately so
    /// the popup updates live as the user drags. Subsequent calls inside
    /// the window are coalesced into a single trailing reload that fires
    /// once the throttle window closes — guarantees the popup always
    /// settles on the user's final position even if they stop mid-window.
    ///
    /// This replaces the previous pure-debounce behavior, which suppressed
    /// every reload until the user lifted their finger.
    func update(for date: Date) {
        // Snap to the nearest 5-min mark — CGM samples land on this cadence
        // so any finer resolution just re-fetches the same data and creates
        // visual churn.
        let bucketed = bucketed(date: date)

        // If the user is still inside the same 5-min window as the last
        // displayed bucket, do nothing — same data, same timestamp.
        if let last = lastBucketedDate, last == bucketed { return }
        lastBucketedDate = bucketed

        // Update the displayed timestamp immediately so the user sees the
        // popup jump to the new bucket as soon as they cross the boundary.
        data.date = bucketed

        let now = Date()
        let elapsed = now.timeIntervalSince(lastReloadAt)

        if elapsed >= scrubThrottleInterval {
            // Leading edge — outside the throttle window, fire now.
            scrubThrottleTimer?.invalidate()
            scrubThrottleTimer = nil
            lastReloadAt = now
            reloadAtCurrentDate()
        } else {
            // Inside the window — coalesce into a trailing reload at the
            // window's end so the user lands on accurate data even if
            // they stop scrubbing right now.
            scrubThrottleTimer?.invalidate()
            let delay = scrubThrottleInterval - elapsed
            scrubThrottleTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.lastReloadAt = Date()
                self.reloadAtCurrentDate()
            }
        }
    }

    /// Round a date to the nearest `scrubBucketInterval` boundary.
    private func bucketed(date: Date) -> Date {
        let t = date.timeIntervalSinceReferenceDate
        let snapped = (t / scrubBucketInterval).rounded() * scrubBucketInterval
        return Date(timeIntervalSinceReferenceDate: snapped)
    }

    /// Re-fetch every series for `data.date` without wiping the existing
    /// values first. Wiping caused the popup to collapse to "just the
    /// date" between reloads and re-expand as each async loader returned,
    /// producing a visible flash on every scrub tick. Now the previous
    /// values stay on screen, each loader overwrites its own field with
    /// the new value (or nil if no nearby sample), and stale results from
    /// prior scrub positions are dropped via the generation counter.
    ///
    /// All loaders write into a single `pendingData` accumulator and the
    /// commit to the @Published `data` happens once per reload, so SwiftUI
    /// re-renders the popup a single time per scrub tick rather than 8.
    private func reloadAtCurrentDate() {
        loadGeneration += 1
        let gen = loadGeneration
        let currentDate = data.date
        let unit = data.glucoseUnit
        loadData(generation: gen, date: currentDate, unit: unit)
    }

    // MARK: - Data Loading

    /// State accumulated across the 8 per-series loaders for a single reload.
    /// Initialised from the currently-displayed values so that fields whose
    /// loader hasn't completed yet keep showing their last value instead of
    /// briefly blanking. Each loader sets its own field unconditionally —
    /// to a value if a nearby sample is found, or nil if not — so values
    /// don't linger after the user scrubs past the data that produced them.
    private struct PendingLoad {
        var data: GraphDetailData
        var remaining: Int
    }
    private var pending: PendingLoad?

    private func loadData(generation gen: Int, date: Date, unit: HKUnit) {
        // Seed from current values so unfinished loaders show stale-but-near
        // values instead of blanks. Each loader will overwrite its own field.
        var seed = data
        seed.date = date
        seed.glucoseUnit = unit
        pending = PendingLoad(data: seed, remaining: 8)

        loadGlucose(generation: gen, date: date, unit: unit)
        loadIOB(generation: gen, date: date)
        loadCOB(generation: gen, date: date)
        loadBolus(generation: gen, date: date)
        loadBasalRate(generation: gen, date: date)
        loadOverride(generation: gen, date: date)
        loadAutoPreset(generation: gen, date: date)
        loadHeartRate(generation: gen, date: date)
    }

    /// Commit one loader's result into the pending accumulator. When all 8
    /// loaders for this generation have reported, publish the full snapshot
    /// to `data` in a single SwiftUI update. Stale generations are dropped.
    private func commit(generation gen: Int, _ mutate: @escaping (inout GraphDetailData) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard gen == self.loadGeneration, var pending = self.pending else { return }
            mutate(&pending.data)
            pending.remaining -= 1
            if pending.remaining <= 0 {
                self.data = pending.data
                self.pending = nil
            } else {
                self.pending = pending
            }
        }
    }

    private func loadGlucose(generation gen: Int, date: Date, unit: HKUnit) {
        let window: TimeInterval = 5 * 60 // ±5 minutes
        let start = date.addingTimeInterval(-window)
        let end = date.addingTimeInterval(window)

        deviceManager.glucoseStore.getGlucoseSamples(start: start, end: end) { [weak self] result in
            guard let self = self else { return }
            var value: Double? = nil
            if case .success(let samples) = result {
                let closest = samples.min(by: {
                    abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date))
                })
                if let sample = closest {
                    value = sample.quantity.doubleValue(for: unit)
                }
            }
            self.commit(generation: gen) { $0.glucoseValue = value }
        }
    }

    private func loadIOB(generation gen: Int, date: Date) {
        let start = date.addingTimeInterval(-5 * 60)
        let end = date.addingTimeInterval(5 * 60)

        deviceManager.doseStore.getInsulinOnBoardValues(start: start, end: end, basalDosingEnd: nil) { [weak self] result in
            guard let self = self else { return }
            var value: Double? = nil
            if case .success(let values) = result {
                let closest = values.min(by: {
                    abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date))
                })
                value = closest?.value
            }
            self.commit(generation: gen) { $0.insulinOnBoard = value }
        }
    }

    private func loadCOB(generation gen: Int, date: Date) {
        // COB only meaningful for the live present — historical COB would
        // require replaying counteraction effects, which is more work than
        // this popup justifies. Return the current value only when the
        // scrubbed time is within the recent window.
        guard abs(date.timeIntervalSinceNow) < 10 * 60 else {
            self.commit(generation: gen) { $0.carbsOnBoard = nil }
            return
        }
        deviceManager.loopManager.getLoopState { [weak self] (_, state) in
            guard let self = self else { return }
            let value = state.carbsOnBoard?.quantity.doubleValue(for: .gram())
            self.commit(generation: gen) { $0.carbsOnBoard = value }
        }
    }

    private func loadBolus(generation gen: Int, date: Date) {
        let window: TimeInterval = 15 * 60
        let start = date.addingTimeInterval(-window)
        let end = date.addingTimeInterval(window)

        deviceManager.doseStore.getNormalizedDoseEntries(start: start, end: end) { [weak self] result in
            guard let self = self else { return }
            var value: (units: Double, date: Date)? = nil
            if case .success(let entries) = result {
                let boluses = entries.filter { $0.type == .bolus }
                let closest = boluses.min(by: {
                    abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date))
                })
                if let bolus = closest {
                    let units = bolus.deliveredUnits ?? bolus.programmedUnits
                    if units > 0 {
                        value = (units: units, date: bolus.startDate)
                    }
                }
            }
            self.commit(generation: gen) { $0.recentBolus = value }
        }
    }

    private func loadBasalRate(generation gen: Int, date: Date) {
        let rate = deviceManager.loopManager.settings.basalRateSchedule?.value(at: date)
        commit(generation: gen) { $0.basalRate = rate }
    }

    /// The override actually in effect at `date`, from Loop's override history.
    /// Unlike `settings.scheduleOverride` (current override only) or the
    /// AutoPresets activity log (misses manual cancels, natural expiry, and
    /// deactivations across app restarts), the history records every
    /// override's true start and actual end, so past scrub times resolve
    /// correctly. Loop prunes this history to roughly ±10 hours, so scrubs
    /// older than that show no override rather than a stale one.
    private func overrideActive(at date: Date) -> TemporaryScheduleOverride? {
        return deviceManager.loopManager.overrideHistory.getEvents()
            .first { $0.actualEnd != .deleted && $0.startDate <= date && date < $0.actualEndDate }
    }

    private func loadOverride(generation gen: Int, date: Date) {
        var name: String? = nil
        if let override = overrideActive(at: date) {
            switch override.context {
            case .preset(let preset):
                name = "\(preset.symbol) \(preset.name)"
            case .legacyWorkout:
                name = "🏃 Workout"
            case .preMeal:
                name = "🍽 Pre-Meal"
            case .custom:
                name = "⚙️ Custom Override"
            }
        }
        commit(generation: gen) { $0.activePreset = name }
    }

    private func loadAutoPreset(generation gen: Int, date: Date) {
        var name: String? = nil
        defer { commit(generation: gen) { $0.activeAutoPreset = name } }

        guard let override = overrideActive(at: date),
              case .preset(let preset) = override.context else { return }

        // Only label the row when the active preset is one AutoPresets manages
        // (i.e. mapped to an activity type in AutoPresets settings).
        guard let defaults = UserDefaults(suiteName: "com.loopkit.Loop.AutoPresets"),
              let settingsData = defaults.data(forKey: "settings") else { return }

        struct MinimalSettings: Decodable {
            let activityPresets: [String: String]?
        }

        guard let settings = try? JSONDecoder().decode(MinimalSettings.self, from: settingsData),
              let managedIds = settings.activityPresets?.values.compactMap({ UUID(uuidString: $0) }),
              managedIds.contains(preset.id) else { return }

        name = preset.name
    }

    private func loadHeartRate(generation gen: Int, date: Date) {
        guard HKHealthStore.isHealthDataAvailable() else {
            commit(generation: gen) { $0.heartRate = nil }
            return
        }

        let healthStore = HKHealthStore()
        let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let window: TimeInterval = 5 * 60
        let start = date.addingTimeInterval(-window)
        let end = date.addingTimeInterval(window)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        let query = HKSampleQuery(
            sampleType: heartRateType,
            predicate: predicate,
            limit: 10,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        ) { [weak self] _, samples, _ in
            guard let self = self else { return }
            var bpm: Double? = nil
            if let samples = samples as? [HKQuantitySample] {
                let closest = samples.min(by: {
                    abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date))
                })
                if let hr = closest {
                    bpm = hr.quantity.doubleValue(for: HKUnit(from: "count/min"))
                }
            }
            self.commit(generation: gen) { $0.heartRate = bpm }
        }
        healthStore.execute(query)
    }
}
