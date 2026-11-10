//
//  PowerPackBridge.swift
//  Loop
//
//  Connects FoodFinder to the existing carb entry flow. It only PRE-FILLS the
//  carb entry screen; the user reviews it and confirms with the normal
//  Continue / bolus screens. Nothing here writes to CarbStore or HealthKit.
//

import BolusPro
import FoodFinder
import HealthKit

enum PowerPackBridge {
    /// Pre-fills `viewModel` from a FoodFinder analysis.
    ///
    /// - Direct carbs: net carbohydrates (fiber deduction already applied by FoodFinder).
    /// - Protein, fat and fiber go to the BolusPro section. BolusPro splits the delayed
    ///   fat/protein entry (🥩) and writes it without a HealthKit carb sample only after the
    ///   user confirms the meal, and only from 1.5 FPU.
    /// - Does nothing when editing an existing entry.
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

        let state = viewModel.bolusPro
        if prefill.proteinGrams > 0 || prefill.fatGrams > 0 {
            if !state.isOn {
                BolusProHealthWriter.requestAuthorization()
            }
            state.isOn = true
            state.proteinGrams = prefill.proteinGrams > 0 ? prefill.proteinGrams : nil
            state.fatGrams = prefill.fatGrams > 0 ? prefill.fatGrams : nil
            state.fiberGrams = prefill.fiberGrams > 0 ? prefill.fiberGrams : nil
        }
    }
}
