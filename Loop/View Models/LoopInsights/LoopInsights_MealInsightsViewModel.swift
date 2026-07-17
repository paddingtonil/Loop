//
//  LoopInsights_MealInsightsViewModel.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  LoopInsights — Extracted ViewModel for Meal Insights view.
//  Manages meal data loading, debrief generation, and pre-meal advice state.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import Foundation
import Combine
import LoopKit
import HealthKit

@MainActor
final class LoopInsights_MealInsightsViewModel: ObservableObject {

    // MARK: - Published State

    @Published var mealEvents: [LoopInsightsMealEvent] = []
    @Published var foodPatterns: [LoopInsightsFoodResponsePattern] = []
    @Published var isLoading = true

    // Pre-Meal Advice tab
    @Published var selectedPattern: LoopInsightsFoodResponsePattern?
    @Published var aiAdvice: String?
    @Published var isLoadingAdvice = false

    // Debrief state per meal
    @Published var debriefResults: [String: LoopInsights_MealDebrief] = [:]
    @Published var debriefLoadingIDs: Set<String> = []
    @Published var debriefErrors: [String: String] = [:]

    // Swipe-to-delete state — the View binds an .alert to these.
    @Published var pendingDeleteEvent: LoopInsightsMealEvent?
    @Published var deleteError: String?

    // MARK: - Dependencies

    let coordinator: LoopInsights_Coordinator

    init(coordinator: LoopInsights_Coordinator) {
        self.coordinator = coordinator
    }

    // MARK: - Data Loading

    func loadMealData() async {
        let period = LoopInsights_FeatureFlags.analysisPeriod
        let endDate = Date()
        let startDate = endDate.addingTimeInterval(-period.timeInterval)

        do {
            let carbEntries = try await coordinator.fetchCarbEntries(start: startDate, end: endDate)
            let glucoseSamples = try await coordinator.fetchGlucoseSamples(start: startDate, end: endDate)

            // Fetch dose entries and filter to boluses for meal matching
            let doseEntries = (try? await coordinator.fetchDoseEntries(start: startDate, end: endDate)) ?? []
            let bolusEntries = doseEntries.filter { $0.type == .bolus }

            // Glucose events from carb entries (used for glucose timeline matching only)
            let glucoseEvents = LoopInsights_FoodResponseAnalyzer.buildRecentMealEvents(
                carbEntries: carbEntries,
                glucoseSamples: glucoseSamples
            )
            let patterns = LoopInsights_FoodResponseAnalyzer.analyzeFoodResponses(
                carbEntries: carbEntries,
                glucoseSamples: glucoseSamples
            )

            // --- Archive-first approach ---
            // MealArchive is the single source of truth for FoodFinder meals.
            // It has the real food name, thumbnail, and nutritional data.
            // We attach glucose data to archive records by date+carbs matching,
            // then add carb-only entries (non-FoodFinder meals) separately.

            let archiveMeals = MealArchive.meals(from: startDate, to: endDate)
            var consumedGlucoseEventIndices = Set<Int>()
            var events: [LoopInsightsMealEvent] = []

            // 1. Build events from archive records, attaching glucose data when available
            for record in archiveMeals {
                let result = record.analysisResult

                // Two-stage match. The archive's `date` is captured at the
                // moment the user taps Continue, but the CarbStore entry's
                // startDate/carbs can drift if the user edits the time
                // picker or the carb slider between FoodFinder analysis and
                // Continue. The tight stage prevents wrong-meal collisions
                // when meals are close in time; the wide stage rescues meals
                // where the user nudged carbs or shifted the time within a
                // realistic window.
                func findGlucoseMatch(dateTolerance: TimeInterval, carbTolerance: Double) -> Int? {
                    glucoseEvents.indices.first { idx in
                        !consumedGlucoseEventIndices.contains(idx) &&
                        abs(glucoseEvents[idx].date.timeIntervalSince(record.date)) < dateTolerance &&
                        abs(glucoseEvents[idx].carbs - record.carbsGrams) < carbTolerance
                    }
                }
                let matchIdx = findGlucoseMatch(dateTolerance: 300, carbTolerance: 1)   // ±5 min, ±1g
                    ?? findGlucoseMatch(dateTolerance: 900, carbTolerance: 5)            // ±15 min, ±5g

                let dose = Self.matchBoluses(for: record.date, from: bolusEntries)

                if let idx = matchIdx {
                    consumedGlucoseEventIndices.insert(idx)
                    let ge = glucoseEvents[idx]
                    events.append(LoopInsightsMealEvent(
                        date: ge.date,
                        foodType: record.foodType,
                        carbs: ge.carbs,
                        preMealGlucose: ge.preMealGlucose,
                        peakGlucose: ge.peakGlucose,
                        twoHourGlucose: ge.twoHourGlucose,
                        glucoseTimeline: ge.glucoseTimeline,
                        archiveRecordID: record.id,
                        thumbnailID: record.thumbnailID,
                        totalProtein: result?.totalProtein,
                        totalFat: result?.totalFat,
                        totalFiber: result?.totalFiber,
                        totalCalories: result?.totalCalories,
                        bolusUnits: dose.total > 0 ? dose.total : nil,
                        bolusDate: dose.primaryDate,
                        automaticBolus: dose.automatic > 0 ? dose.automatic : nil,
                        manualBolus: dose.manual > 0 ? dose.manual : nil
                    ))
                } else {
                    // No glucose match yet — show archive record without glucose data
                    events.append(LoopInsightsMealEvent(
                        date: record.date,
                        foodType: record.foodType,
                        carbs: record.carbsGrams,
                        archiveRecordID: record.id,
                        thumbnailID: record.thumbnailID,
                        totalProtein: result?.totalProtein,
                        totalFat: result?.totalFat,
                        totalFiber: result?.totalFiber,
                        totalCalories: result?.totalCalories,
                        bolusUnits: dose.total > 0 ? dose.total : nil,
                        bolusDate: dose.primaryDate,
                        automaticBolus: dose.automatic > 0 ? dose.automatic : nil,
                        manualBolus: dose.manual > 0 ? dose.manual : nil
                    ))
                }
            }

            // 2. Add remaining glucose events that didn't match any archive record
            //    (these are manual carb entries without FoodFinder)
            for (idx, ge) in glucoseEvents.enumerated() where !consumedGlucoseEventIndices.contains(idx) {
                let dose = Self.matchBoluses(for: ge.date, from: bolusEntries)
                events.append(LoopInsightsMealEvent(
                    date: ge.date,
                    foodType: ge.foodType,
                    carbs: ge.carbs,
                    preMealGlucose: ge.preMealGlucose,
                    peakGlucose: ge.peakGlucose,
                    twoHourGlucose: ge.twoHourGlucose,
                    glucoseTimeline: ge.glucoseTimeline,
                    archiveRecordID: ge.archiveRecordID,
                    thumbnailID: ge.thumbnailID,
                    totalProtein: ge.totalProtein,
                    totalFat: ge.totalFat,
                    totalFiber: ge.totalFiber,
                    totalCalories: ge.totalCalories,
                    bolusUnits: dose.total > 0 ? dose.total : nil,
                    bolusDate: dose.primaryDate,
                    automaticBolus: dose.automatic > 0 ? dose.automatic : nil,
                    manualBolus: dose.manual > 0 ? dose.manual : nil
                ))
            }

            // 3. Add remaining CarbStore entries not yet represented.
            //    Catches manual carb entries that lacked sufficient glucose data
            //    for buildRecentMealEvents() but should still appear in the meal list.
            for entry in carbEntries {
                let entryDate = entry.startDate
                let entryCarbs = entry.quantity.doubleValue(for: .gram())
                guard entryCarbs > 0 else { continue }

                // Match the wider window used above so a CarbStore entry that
                // already matched an archive record via the forgiving stage
                // doesn't get re-added as a duplicate row.
                let alreadyRepresented = events.contains { event in
                    abs(event.date.timeIntervalSince(entryDate)) < 900 &&   // ±15 min
                    abs(event.carbs - entryCarbs) < 5                       // ±5 g
                }
                guard !alreadyRepresented else { continue }

                let dose = Self.matchBoluses(for: entryDate, from: bolusEntries)
                events.append(LoopInsightsMealEvent(
                    date: entryDate,
                    foodType: entry.foodType ?? "Unknown",
                    carbs: entryCarbs,
                    bolusUnits: dose.total > 0 ? dose.total : nil,
                    bolusDate: dose.primaryDate,
                    automaticBolus: dose.automatic > 0 ? dose.automatic : nil,
                    manualBolus: dose.manual > 0 ? dose.manual : nil
                ))
            }

            self.mealEvents = events.sorted { $0.date > $1.date }
            self.foodPatterns = patterns
            self.isLoading = false

            LoopInsights_FeatureFlags.log.info(
                "loadMealData: archiveMeals=\(archiveMeals.count) glucoseEvents=\(glucoseEvents.count) carbEntries=\(carbEntries.count) bolusEntries=\(bolusEntries.count) → events=\(events.count)"
            )
        } catch {
            self.isLoading = false
            LoopInsights_FeatureFlags.log.error("loadMealData failed: \(String(describing: error))")
        }
    }

    // MARK: - Bolus Matching

    /// Match bolus entries to a meal by timestamp proximity.
    /// Window: -5 min (pre-bolus) to +15 min (delayed bolus) of the meal date.
    /// Returns total units split by manual vs automatic, plus the primary bolus date.
    private static func matchBoluses(
        for mealDate: Date,
        from boluses: [DoseEntry]
    ) -> (total: Double, manual: Double, automatic: Double, primaryDate: Date?) {
        let windowStart = mealDate.addingTimeInterval(-5 * 60)   // 5 min before
        let windowEnd = mealDate.addingTimeInterval(15 * 60)     // 15 min after

        let matched = boluses.filter { bolus in
            bolus.startDate >= windowStart && bolus.startDate <= windowEnd
        }

        guard !matched.isEmpty else { return (0, 0, 0, nil) }

        var totalUnits: Double = 0
        var manualUnits: Double = 0
        var automaticUnits: Double = 0
        var largestUnits: Double = 0
        var primaryDate: Date?

        for bolus in matched {
            let units = bolus.deliveredUnits ?? bolus.programmedUnits
            totalUnits += units

            if bolus.automatic == true {
                automaticUnits += units
            } else {
                manualUnits += units
            }

            if units > largestUnits {
                largestUnits = units
                primaryDate = bolus.startDate
            }
        }

        return (totalUnits, manualUnits, automaticUnits, primaryDate)
    }

    // MARK: - Debrief

    /// Check debrief readiness for a meal event. Looks up the MealArchive record by date + foodType.
    func debriefReadiness(for event: LoopInsightsMealEvent) -> LoopInsights_DebriefReadiness {
        guard LoopInsights_FeatureFlags.mealDebriefEnabled else { return .featureDisabled }

        // Already loaded in this session?
        if debriefResults[event.id.uuidString] != nil { return .ready }

        // Find matching MealArchive record
        guard let record = findArchiveRecord(for: event) else { return .noSnapshot }

        return coordinator.mealDebriefService.isDebriefReady(for: record)
    }

    /// Kick off debrief generation for a meal event if needed. The result is
    /// shown in the detail sheet, which observes debriefResults/loading/errors.
    func openDebrief(for event: LoopInsightsMealEvent) {
        let eventID = event.id.uuidString

        // Already loaded or loading?
        if debriefResults[eventID] != nil || debriefLoadingIDs.contains(eventID) { return }

        guard let record = findArchiveRecord(for: event) else { return }

        let readiness = coordinator.mealDebriefService.isDebriefReady(for: record)
        guard readiness == .readyToGenerate || readiness == .ready else { return }

        // Find food pattern for this type
        let pattern = foodPatterns.first { $0.foodType == event.foodType }

        debriefLoadingIDs.insert(eventID)
        debriefErrors.removeValue(forKey: eventID)

        Task {
            do {
                let debrief = try await coordinator.mealDebriefService.generateDebrief(
                    for: record,
                    actualTimeline: event.glucoseTimeline,
                    foodPattern: pattern
                )
                self.debriefResults[eventID] = debrief
                self.debriefLoadingIDs.remove(eventID)
            } catch {
                self.debriefErrors[eventID] = error.localizedDescription
                self.debriefLoadingIDs.remove(eventID)
            }
        }
    }

    // MARK: - Pre-Meal Advice

    func requestAdvice(for pattern: LoopInsightsFoodResponsePattern) {
        selectedPattern = pattern
        isLoadingAdvice = true
        aiAdvice = nil

        let unitCtx = coordinator.unitContext
        let prompt = """
        Based on my glucose response pattern for \(pattern.foodType):
        - Average carbs: \(String(format: "%.0f", pattern.averageCarbsPerMeal))g per meal
        - Peak glucose rise: \(String(format: "%.0f", pattern.peakGlucoseRise)) mg/dL
        - Time to peak: \(String(format: "%.0f", pattern.timeToPeakMinutes)) minutes
        - 2h post-meal average: \(String(format: "%.0f", pattern.twoHourPostMealAvg)) mg/dL
        - 4h post-meal average: \(String(format: "%.0f", pattern.fourHourPostMealAvg)) mg/dL

        Give me brief, practical advice for managing this food. Include: timing of pre-bolus, \
        any carb ratio considerations, and alternative strategies. Keep it under 4 sentences.
        """

        Task {
            do {
                let response = try await LoopInsights_AIServiceAdapter.shared.sendPrompt(
                    "You are a diabetes meal advisor. Be concise and practical.\n\(unitCtx.aiPromptUnitContext())",
                    userPrompt: prompt
                )
                self.aiAdvice = response
                self.isLoadingAdvice = false
            } catch {
                self.aiAdvice = "Unable to get advice: \(error.localizedDescription)"
                self.isLoadingAdvice = false
            }
        }
    }

    // MARK: - Helpers

    /// Find the MealArchive record that matches this meal event.
    /// Uses archiveRecordID if available, otherwise falls back to date + carb proximity.
    private func findArchiveRecord(for event: LoopInsightsMealEvent) -> FoodFinder_AnalysisRecord? {
        if let recordID = event.archiveRecordID {
            return MealArchive.loadAll().first { $0.id == recordID }
        }
        let windowStart = event.date.addingTimeInterval(-300) // 5 min tolerance
        let windowEnd = event.date.addingTimeInterval(300)
        let candidates = MealArchive.meals(from: windowStart, to: windowEnd)
        return candidates.first { abs($0.carbsGrams - event.carbs) < 1 }
            ?? candidates.first // Fall back to closest match
    }

    // MARK: - Delete

    /// Permanently delete a meal everywhere it touches our data:
    /// - Loop's CarbStore (so the algorithm forgets the carbs)
    /// - The matched BolusPro secondary entry, if any (foodType "🥩" within
    ///   +30 to +120 min of the primary)
    /// - MealArchive (FoodFinder long-term record + thumbnail)
    /// - FoodFinder short-term analysis history (re-use dropdown source)
    /// - Prediction snapshot
    /// - Cached debrief
    ///
    /// The view binds an `.alert` to `pendingDeleteEvent`; the user
    /// confirms there and we call this method.
    func deleteMeal(_ event: LoopInsightsMealEvent) async {
        // Carb entries to delete: the primary that matches the event, plus
        // any BolusPro secondary entry that was generated alongside it.
        do {
            // Fetch a window wide enough to also catch the BolusPro
            // secondary (typically +60 min).
            let windowStart = event.date.addingTimeInterval(-15 * 60)
            let windowEnd = event.date.addingTimeInterval(150 * 60)
            let carbEntries = try await coordinator.fetchCarbEntries(start: windowStart, end: windowEnd)

            // Primary: closest match on date + carbs.
            let primary = carbEntries.first { entry in
                abs(entry.startDate.timeIntervalSince(event.date)) < 900 &&    // ±15 min
                abs(entry.quantity.doubleValue(for: .gram()) - event.carbs) < 5 // ±5 g
            }

            // BolusPro secondary: foodType emoji "🥩", later than the primary
            // by ~30-120 min, smaller carbs. Tolerate either the new-style
            // emoji-only foodType or older formats.
            let secondary = carbEntries.first { entry in
                guard let foodType = entry.foodType, foodType.contains("🥩") else { return false }
                let offset = entry.startDate.timeIntervalSince(event.date)
                return offset >= 30 * 60 && offset <= 120 * 60
            }

            for entry in [primary, secondary].compactMap({ $0 }) {
                _ = try await coordinator.deleteCarbEntry(entry)
            }
        } catch {
            // Don't bail out — still remove our own metadata so the row
            // disappears from the list. Surface the error to the user via
            // the alert state.
            deleteError = "Couldn't remove the carb entry from Loop. The meal's analysis data was still removed."
        }

        // Remove the FoodFinder/LoopInsights side records.
        if let archiveRecord = findArchiveRecord(for: event) {
            MealArchive.remove(id: archiveRecord.id)
            FoodFinder_AnalysisHistoryStore.remove(id: archiveRecord.id)
            LoopInsights_PredictionSnapshotStore.remove(forMealID: archiveRecord.id)
            LoopInsights_MealDebriefCache.remove(forMealID: archiveRecord.id)
        } else if let recordID = event.archiveRecordID {
            // findArchiveRecord didn't match but the event remembers an ID
            // — clean up by ID directly.
            MealArchive.remove(id: recordID)
            FoodFinder_AnalysisHistoryStore.remove(id: recordID)
            LoopInsights_PredictionSnapshotStore.remove(forMealID: recordID)
            LoopInsights_MealDebriefCache.remove(forMealID: recordID)
        } else {
            // Event came from a CarbStore entry that never made it to
            // MealArchive. Best-effort cleanup by date + carbs.
            MealArchive.removeMatching(date: event.date, carbs: event.carbs)
        }

        // Drop any in-memory debrief state for this event.
        let eventKey = event.id.uuidString
        debriefResults.removeValue(forKey: eventKey)
        debriefLoadingIDs.remove(eventKey)
        debriefErrors.removeValue(forKey: eventKey)

        // Refresh the list so the row disappears.
        await loadMealData()
    }
}
