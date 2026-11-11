//
//  PowerPackBridge.swift
//  Loop
//
//  Connects FoodFinder and BolusPro to Loop's existing carb entry flow.
//
//  Division of work:
//   - Loop (CarbStore) writes the carbohydrates, as before.
//   - FoodFinder finds the nutrition of the meal and writes calories, fat, protein and fiber to Apple Health.
//   - BolusPro only converts fat/protein to a delayed carb entry and its absorption time; it writes nothing.
//
//  The bridge PRE-FILLS the carb entry screen. The user confirms through the normal Continue / bolus screens,
//  and only then is anything written (see `mealSaved`).
//

import BolusPro
import FoodFinder
import HealthKit
import LoopKit
import os.log

enum PowerPackBridge {
    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "Loop", category: "PowerPackBridge")

    /// A FoodFinder analysis waiting for the user's confirmation.
    struct FoodFinderMeal {
        let id: String
        let nutrition: MealNutrition
        let imageJPEG: Data?
    }

    // MARK: - Pre-fill

    /// Pre-fills `viewModel` from a FoodFinder analysis and remembers the meal for `mealSaved`.
    /// Does nothing when editing an existing entry.
    @MainActor
    static func apply(_ result: FoodAnalysisResult, to viewModel: CarbEntryViewModel) {
        guard viewModel.originalCarbEntry == nil else { return }

        let prefill = MealPrefill(
            result,
            absorptionRangeHours: (viewModel.minAbsorptionTime / 3600)...(viewModel.maxAbsorptionTime / 3600)
        )

        if prefill.carbsGrams > 0 {
            viewModel.carbsQuantity = HKQuantity(unit: .gram(), doubleValue: prefill.carbsGrams)
                .doubleValue(for: viewModel.preferredCarbUnit)
        }

        if let hours = prefill.absorptionHours {
            viewModel.absorptionTime = hours * 3600
        }

        if !prefill.title.isEmpty {
            viewModel.foodType = prefill.title
            viewModel.usesCustomFoodType = true
        }

        // BolusPro only needs fat and protein to compute the delayed carbs.
        if prefill.proteinGrams > 0 || prefill.fatGrams > 0 {
            let state = viewModel.bolusPro
            state.isOn = true
            state.proteinGrams = prefill.proteinGrams > 0 ? prefill.proteinGrams : nil
            state.fatGrams = prefill.fatGrams > 0 ? prefill.fatGrams : nil
        }

        FoodFinderHealthWriter.requestAuthorization()
        viewModel.foodFinderMeal = FoodFinderMeal(
            id: UUID().uuidString,
            nutrition: MealNutrition(result),
            imageJPEG: result.imageJPEGData
        )
    }

    /// The meal to record after confirmation: fat and protein are the values on the screen when BolusPro is on
    /// (an empty field counts as 0), otherwise the analysed values. Calories follow the change.
    static func confirmedMeal(_ meal: FoodFinderMeal?, bolusPro: BolusProEntryState) -> FoodFinderMeal? {
        guard let meal else { return nil }
        guard bolusPro.isOn else { return meal }
        return FoodFinderMeal(
            id: meal.id,
            nutrition: meal.nutrition.updating(fatGrams: bolusPro.fatGrams ?? 0, proteinGrams: bolusPro.proteinGrams ?? 0),
            imageJPEG: meal.imageJPEG
        )
    }

    // MARK: - Delayed fat/protein (🥩) entry belongs to its meal

    private static let fpuLinksKey = "PowerPackFPULinks"
    private static let maxFPULinks = 500

    /// Remembers which delayed entry belongs to which meal, so deleting the meal removes both.
    static func linkFPUEntry(primary: StoredCarbEntry, fpu: StoredCarbEntry) {
        guard let primaryID = primary.syncIdentifier, let fpuID = fpu.syncIdentifier else { return }
        var links = fpuLinks().filter { $0["primary"] != primaryID }
        links.append(["primary": primaryID, "fpu": fpuID])
        UserDefaults.standard.set(Array(links.suffix(maxFPULinks)), forKey: fpuLinksKey)
    }

    /// Sync identifier of the delayed entry that belongs to `entry`, if it has one.
    static func linkedFPUSyncIdentifier(for entry: StoredCarbEntry) -> String? {
        guard let id = entry.syncIdentifier else { return nil }
        return fpuLinks().first { $0["primary"] == id }?["fpu"]
    }

    /// Forgets the link of a meal, or of a delayed entry that was removed on its own.
    static func forgetFPULink(for entry: StoredCarbEntry) {
        guard let id = entry.syncIdentifier else { return }
        UserDefaults.standard.set(fpuLinks().filter { $0["primary"] != id && $0["fpu"] != id }, forKey: fpuLinksKey)
    }

    private static func fpuLinks() -> [[String: String]] {
        UserDefaults.standard.array(forKey: fpuLinksKey) as? [[String: String]] ?? []
    }

    // MARK: - After the user's confirmation

    /// Called once the user confirmed and the carb entry was saved. Records the meal for LoopInsights
    /// (App Group) and writes calories and nutrients to Apple Health, linking both to the carb entry so
    /// they can be removed together if the entry is deleted.
    static func mealSaved(_ meal: FoodFinderMeal, carbEntry: StoredCarbEntry) {
        let store = SharedContainer.directory().map { SharedMealStore(directory: $0) }

        var record = SharedMealRecord(id: meal.id, timestamp: carbEntry.startDate, nutrition: meal.nutrition)
        record.carbEntrySyncIdentifier = carbEntry.syncIdentifier
        do {
            try store?.upsert(record, imageJPEG: meal.imageJPEG)
        } catch {
            os_log("Could not record the meal in the App Group: %{public}@", log: log, type: .error, String(describing: error))
        }

        FoodFinderHealthWriter.save(
            meal.nutrition,
            mealID: meal.id,
            date: carbEntry.startDate,
            foodType: meal.nutrition.title
        ) { result in
            switch result {
            case .success(let uuids):
                guard !uuids.isEmpty else { return }
                do {
                    try store?.update(id: meal.id) { $0.healthSampleUUIDs = uuids.map(\.uuidString) }
                } catch {
                    os_log("Could not link Health samples to the meal: %{public}@", log: log, type: .error, String(describing: error))
                }
            case .failure(let error):
                os_log("Could not write nutrition to Apple Health: %{public}@", log: log, type: .error, String(describing: error))
            }
        }
    }

    /// Called after Loop deleted a carb entry: removes the Health samples written for that meal, then the
    /// shared record. If Health refuses, the record is kept so the removal can be retried.
    static func carbEntryDeleted(_ entry: StoredCarbEntry) {
        // A delayed entry removed on its own leaves its meal untouched; only the link goes.
        if BolusProFPU.isFPUEntry(foodType: entry.foodType) { forgetFPULink(for: entry) }
        guard let syncIdentifier = entry.syncIdentifier,
              let directory = SharedContainer.directory() else { return }
        let store = SharedMealStore(directory: directory)
        guard let record = try? store.record(carbEntrySyncIdentifier: syncIdentifier) else { return }

        let uuids = (record.healthSampleUUIDs ?? []).compactMap(UUID.init(uuidString:))
        FoodFinderHealthWriter.delete(sampleUUIDs: uuids) { error in
            if let error {
                os_log("Could not remove Health samples of a deleted meal: %{public}@", log: log, type: .error, String(describing: error))
                return
            }
            try? store.remove(id: record.id)
        }
    }
}
