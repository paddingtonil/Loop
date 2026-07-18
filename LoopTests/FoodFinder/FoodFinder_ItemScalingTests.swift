//
//  FoodFinder_ItemScalingTests.swift
//  LoopTests
//
//  Covers the per-item scaling and edit model that produces the carb total a
//  dose is calculated from, plus the Codable compatibility that protects the
//  user's stored analysis history.
//
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import XCTest
@testable import Loop

final class FoodFinder_ItemScalingTests: XCTestCase {

    // MARK: - Helpers

    /// An item the AI costed at 2× its USDA serving: 40 g carbs for the pictured
    /// portion, i.e. 20 g per USDA serving.
    private func makeItem(
        name: String = "White rice",
        servingMultiplier: Double = 2.0,
        carbs: Double = 40,
        calories: Double? = 200,
        fat: Double? = 4,
        fiber: Double? = 2,
        protein: Double? = 6
    ) -> FoodItemAnalysis {
        FoodItemAnalysis(
            name: name,
            portionEstimate: "1.5 cups",
            usdaServingSize: "1/2 cup",
            servingMultiplier: servingMultiplier,
            preparationMethod: nil,
            visualCues: nil,
            carbohydrates: carbs,
            calories: calories,
            fat: fat,
            fiber: fiber,
            protein: protein,
            assessmentNotes: nil,
            absorptionTimeHours: nil
        )
    }

    private func makeResult(_ items: [FoodItemAnalysis]) -> AIFoodAnalysisResult {
        AIFoodAnalysisResult(
            imageType: .foodPhoto,
            foodItemsDetailed: items,
            overallDescription: "Test plate",
            confidence: .high,
            numericConfidence: 0.9,
            totalFoodPortions: items.count,
            totalUsdaServings: 1,
            totalCarbohydrates: items.reduce(0) { $0 + $1.carbohydrates },
            totalProtein: nil,
            totalFat: nil,
            totalFiber: nil,
            totalCalories: nil,
            portionAssessmentMethod: nil,
            diabetesConsiderations: nil,
            visualAssessmentDetails: nil,
            notes: nil,
            originalServings: 1,
            fatProteinUnits: nil,
            netCarbsAdjustment: nil,
            insulinTimingRecommendations: nil,
            fpuDosingGuidance: nil,
            exerciseConsiderations: nil,
            absorptionTimeHours: 3,
            absorptionTimeReasoning: nil,
            mealSizeImpact: nil,
            individualizationFactors: nil,
            safetyAlerts: nil
        )
    }

    // MARK: - Baseline scaling

    func testUneditedItemReportsAIValues() {
        let item = makeItem()
        XCTAssertEqual(item.effectiveMultiplier, 2.0)
        XCTAssertEqual(item.servingScale, 1.0)
        XCTAssertEqual(item.effectiveCarbs, 40, accuracy: 0.001)
        XCTAssertFalse(item.isUserEdited)
    }

    func testServingOverrideScalesCarbsAndMacros() {
        var item = makeItem()
        // Halve the portion: 2× USDA → 1× USDA.
        item.userServingMultiplier = 1.0

        XCTAssertEqual(item.servingScale, 0.5, accuracy: 0.001)
        XCTAssertEqual(item.effectiveCarbs, 20, accuracy: 0.001)
        XCTAssertEqual(item.effectiveCalories, 100, accuracy: 0.001)
        XCTAssertEqual(item.effectiveFat, 2, accuracy: 0.001)
        XCTAssertEqual(item.effectiveProtein, 3, accuracy: 0.001)
    }

    /// A zero/missing multiplier must not divide by zero and blow the total up.
    func testZeroServingMultiplierFallsBackToOne() {
        let item = makeItem(servingMultiplier: 0)
        XCTAssertEqual(item.aiMultiplier, 1.0)
        XCTAssertEqual(item.effectiveCarbs, 40, accuracy: 0.001)
    }

    // MARK: - Editing

    func testEditingCarbsSetsTheValueTheUserTyped() {
        var item = makeItem()
        item.setEffectiveCarbs(55)

        XCTAssertEqual(item.effectiveCarbs, 55, accuracy: 0.001)
        XCTAssertTrue(item.isUserEdited)
    }

    /// The core of "a later servings step scales from the edited value rather
    /// than overwriting it". Edit at 2×, then step to 3× → 1.5× the edit.
    func testServingsStepScalesFromEditedValueNotTheAIValue() {
        var item = makeItem()
        item.setEffectiveCarbs(60)
        XCTAssertEqual(item.effectiveCarbs, 60, accuracy: 0.001)

        item.userServingMultiplier = 3.0
        XCTAssertEqual(item.effectiveCarbs, 90, accuracy: 0.001)

        item.userServingMultiplier = 1.0
        XCTAssertEqual(item.effectiveCarbs, 30, accuracy: 0.001)
    }

    /// Editing while a serving override is active must honour the number typed,
    /// not silently re-scale it.
    func testEditingAtNonDefaultServingsHonoursTypedValue() {
        var item = makeItem()
        item.userServingMultiplier = 1.0   // 20 g effective
        XCTAssertEqual(item.effectiveCarbs, 20, accuracy: 0.001)

        item.setEffectiveCarbs(35)
        XCTAssertEqual(item.effectiveCarbs, 35, accuracy: 0.001)

        // Doubling the portion doubles the edited value.
        item.userServingMultiplier = 2.0
        XCTAssertEqual(item.effectiveCarbs, 70, accuracy: 0.001)
    }

    func testEditingNameMarksItemEditedAndKeepsAIReference() {
        var item = makeItem(name: "White rice")
        item.setName("Basmati rice")

        XCTAssertEqual(item.name, "Basmati rice")
        XCTAssertEqual(item.aiReferenceName, "White rice")
        XCTAssertTrue(item.isUserEdited)
    }

    /// A second edit must not re-snapshot the baseline, or "Reset to AI" would
    /// restore the user's earlier edit instead of the AI's estimate.
    func testSecondEditDoesNotClobberTheAIBaseline() {
        var item = makeItem()
        item.setEffectiveCarbs(55)
        item.setEffectiveCarbs(70)

        XCTAssertEqual(item.aiOriginal?.carbohydrates, 40)

        item.resetToAI()
        XCTAssertEqual(item.effectiveCarbs, 40, accuracy: 0.001)
    }

    func testResetToAIRestoresValuesButKeepsPortionChoices() {
        var item = makeItem()
        item.userServingMultiplier = 1.0
        item.setName("Renamed")
        item.setEffectiveCarbs(99)

        item.resetToAI()

        XCTAssertEqual(item.name, "White rice")
        XCTAssertFalse(item.isUserEdited)
        // Portion choice survives the reset: 1× USDA of the AI's 20 g/serving.
        XCTAssertEqual(item.userServingMultiplier, 1.0)
        XCTAssertEqual(item.effectiveCarbs, 20, accuracy: 0.001)
    }

    func testResetToAIOnUneditedItemIsANoOp() {
        var item = makeItem()
        item.resetToAI()
        XCTAssertEqual(item.effectiveCarbs, 40, accuracy: 0.001)
        XCTAssertFalse(item.isUserEdited)
    }

    func testNegativeEditsAreClampedToZero() {
        var item = makeItem()
        item.setEffectiveCarbs(-10)
        XCTAssertEqual(item.effectiveCarbs, 0, accuracy: 0.001)
    }

    // MARK: - Plate totals

    func testTotalsSumIncludedItemsAndApplyPlateScale() {
        let result = makeResult([
            makeItem(name: "Rice", carbs: 40),
            makeItem(name: "Beans", carbs: 20)
        ])

        XCTAssertEqual(result.totals(plateScale: 1.0).carbs, 60, accuracy: 0.001)
        XCTAssertEqual(result.totals(plateScale: 2.0).carbs, 120, accuracy: 0.001)
    }

    func testExcludedItemsAreDroppedFromTotals() {
        var items = [makeItem(name: "Rice", carbs: 40), makeItem(name: "Beans", carbs: 20)]
        items[1].isExcluded = true
        let result = makeResult(items)

        XCTAssertEqual(result.includedItems.count, 1)
        XCTAssertEqual(result.totals(plateScale: 1.0).carbs, 40, accuracy: 0.001)
    }

    /// Exclusion state travels with the item, so removing an earlier item must
    /// not shift the exclusion onto a neighbour — the bug the index-keyed
    /// `excludedAIItemIndices` had.
    func testExclusionSurvivesRemovalOfAnEarlierItem() {
        var items = [
            makeItem(name: "Rice", carbs: 40),
            makeItem(name: "Beans", carbs: 20),
            makeItem(name: "Bread", carbs: 30)
        ]
        items[2].isExcluded = true
        var result = makeResult(items)

        result.foodItemsDetailed.remove(at: 0)

        XCTAssertEqual(result.includedItems.map(\.name), ["Beans"])
        XCTAssertEqual(result.totals(plateScale: 1.0).carbs, 20, accuracy: 0.001)
    }

    func testPlateWasEditedDetectsEachKindOfChange() {
        XCTAssertFalse(makeResult([makeItem()]).plateWasEdited)

        var excluded = makeItem(); excluded.isExcluded = true
        XCTAssertTrue(makeResult([excluded]).plateWasEdited)

        var rescaled = makeItem(); rescaled.userServingMultiplier = 1.0
        XCTAssertTrue(makeResult([rescaled]).plateWasEdited)

        var edited = makeItem(); edited.setEffectiveCarbs(1)
        XCTAssertTrue(makeResult([edited]).plateWasEdited)
    }

    func testHasUserEditsTracksTheBulkResetAffordance() {
        var items = [makeItem(name: "Rice"), makeItem(name: "Beans")]
        XCTAssertFalse(makeResult(items).hasUserEdits)

        items[1].setEffectiveCarbs(5)
        XCTAssertTrue(makeResult(items).hasUserEdits)
    }

    /// The denormalised plate totals are what the archived record hands
    /// LoopInsights, so they must not keep reporting the AI's original plate
    /// after an edit or an exclusion.
    func testRefreshedTotalsFollowEditsAndExclusions() {
        var items = [makeItem(name: "Rice", carbs: 40), makeItem(name: "Beans", carbs: 20)]
        items[0].setEffectiveCarbs(10)
        items[1].isExcluded = true

        let refreshed = makeResult(items).withRefreshedTotals()

        XCTAssertEqual(refreshed.totalCarbohydrates, 10, accuracy: 0.001)
    }

    /// Totals describe one plate — the servings stepper is applied separately to
    /// produce the number actually dosed on, and must not be baked in here.
    func testRefreshedTotalsIgnoreThePlateServingsStepper() {
        let result = makeResult([makeItem(carbs: 40)]).withRefreshedTotals()
        XCTAssertEqual(result.totalCarbohydrates, 40, accuracy: 0.001)
        XCTAssertEqual(result.totals(plateScale: 3.0).carbs, 120, accuracy: 0.001)
    }

    // MARK: - Identity

    func testWithBackfilledIDsAssignsMissingIDsAndPreservesExisting() {
        let existing = UUID()
        var items = [makeItem(name: "Rice"), makeItem(name: "Beans")]
        items[0].itemID = existing

        let result = makeResult(items).withBackfilledIDs()

        XCTAssertEqual(result.foodItemsDetailed[0].itemID, existing)
        XCTAssertNotNil(result.foodItemsDetailed[1].itemID)
        XCTAssertNotEqual(result.foodItemsDetailed[0].itemID, result.foodItemsDetailed[1].itemID)
    }

    // MARK: - Mixed plate: building from products

    /// servingQuantity = 100 makes `carbsPerServing` the per-100g value verbatim,
    /// so the arithmetic below is easy to read.
    private func makeProduct(
        name: String = "Granola bar",
        carbs: Double = 22,
        protein: Double? = 4,
        fat: Double? = 6,
        source: FoodDataSource = .barcodeScan
    ) -> OpenFoodFactsProduct {
        OpenFoodFactsProduct(
            id: "code_\(name)",
            productName: name,
            brands: nil,
            categories: nil,
            nutriments: Nutriments(carbohydrates: carbs, proteins: protein, fat: fat),
            servingSize: "1 bar",
            servingQuantity: 100,
            imageURL: nil,
            imageFrontURL: nil,
            code: "code_\(name)",
            dataSource: source
        )
    }

    func testProductBecomesAnItemAtOneServing() {
        let item = FoodItemAnalysis.fromProduct(makeProduct(carbs: 22), servings: 1.0, carbsOverride: nil, sourceLabel: "Scanned")
        XCTAssertEqual(item.effectiveCarbs, 22, accuracy: 0.001)
        XCTAssertEqual(item.sourceLabel, "Scanned")
        XCTAssertNotNil(item.itemID)
    }

    func testProductServingsAreBakedIntoTheItem() {
        let item = FoodItemAnalysis.fromProduct(makeProduct(carbs: 22, protein: 4, fat: 6), servings: 2.0, carbsOverride: nil, sourceLabel: nil)
        XCTAssertEqual(item.effectiveCarbs, 44, accuracy: 0.001)
        XCTAssertEqual(item.effectiveProtein, 8, accuracy: 0.001)
        XCTAssertEqual(item.effectiveFat, 12, accuracy: 0.001)
    }

    func testCarbsOverrideWinsOverComputedValue() {
        let item = FoodItemAnalysis.fromProduct(makeProduct(carbs: 22), servings: 2.0, carbsOverride: 30, sourceLabel: nil)
        XCTAssertEqual(item.effectiveCarbs, 30, accuracy: 0.001)
    }

    func testPlateFactoryDerivesTotalsAndAssignsIDs() {
        let plate = AIFoodAnalysisResult.plate(
            items: [makeItem(name: "Rice", carbs: 40), makeItem(name: "Beans", carbs: 20)],
            description: "Combo"
        )
        XCTAssertEqual(plate.totalCarbohydrates, 60, accuracy: 0.001)
        XCTAssertTrue(plate.foodItemsDetailed.allSatisfy { $0.itemID != nil })
    }

    /// The heart of the mixed plate: items from different sources sum into one
    /// carb total, and each keeps its own per-item editing.
    func testMixedSourceItemsSumIntoOneTotal() {
        let photoItem = makeItem(name: "Grilled chicken", carbs: 5)   // servingMultiplier 2 → effective 5
        let barcodeItem = FoodItemAnalysis.fromProduct(makeProduct(name: "Bun", carbs: 26), servings: 1.0, carbsOverride: nil, sourceLabel: "Scanned")
        let searchItem = FoodItemAnalysis.fromProduct(makeProduct(name: "Apple", carbs: 15, source: .textSearch), servings: 1.0, carbsOverride: nil, sourceLabel: "Searched")

        var plate = AIFoodAnalysisResult.plate(items: [photoItem, barcodeItem, searchItem], description: "Meal")
        XCTAssertEqual(plate.totals(plateScale: 1.0).carbs, 46, accuracy: 0.001)

        // Editing one item leaves the others untouched.
        plate.foodItemsDetailed[1].setEffectiveCarbs(30)
        XCTAssertEqual(plate.totals(plateScale: 1.0).carbs, 50, accuracy: 0.001)

        // Excluding an item drops exactly its contribution.
        plate.foodItemsDetailed[2].isExcluded = true
        XCTAssertEqual(plate.totals(plateScale: 1.0).carbs, 35, accuracy: 0.001)
    }

    // MARK: - Codable compatibility
    //
    // Both the analysis history and the permanent MealArchive decode with
    // `(try? decode(...)) ?? []` and then re-save. A decode failure would not
    // surface as an error — it would silently erase every stored meal. These
    // guard that the fields added for editing stay backward compatible.

    func testLegacyItemJSONWithoutNewFieldsStillDecodes() throws {
        let legacy = """
        {
          "name": "White rice",
          "portionEstimate": "1.5 cups",
          "usdaServingSize": "1/2 cup",
          "servingMultiplier": 2.0,
          "carbohydrates": 40,
          "calories": 200,
          "fat": 4,
          "fiber": 2,
          "protein": 6
        }
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(FoodItemAnalysis.self, from: legacy)

        XCTAssertEqual(item.name, "White rice")
        XCTAssertEqual(item.carbohydrates, 40)
        XCTAssertNil(item.itemID)
        XCTAssertNil(item.userServingMultiplier)
        XCTAssertNil(item.isExcluded)
        XCTAssertNil(item.aiOriginal)
        // Legacy items must behave exactly as before the edit feature existed.
        XCTAssertFalse(item.excluded)
        XCTAssertFalse(item.isUserEdited)
        XCTAssertEqual(item.effectiveCarbs, 40, accuracy: 0.001)
    }

    func testEditedItemSurvivesAnEncodeDecodeRoundTrip() throws {
        var item = makeItem()
        item.itemID = UUID()
        item.userServingMultiplier = 1.5
        item.isExcluded = true
        item.setName("Renamed")
        item.setEffectiveCarbs(33)

        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(FoodItemAnalysis.self, from: data)

        XCTAssertEqual(decoded, item)
        XCTAssertEqual(decoded.name, "Renamed")
        XCTAssertEqual(decoded.effectiveCarbs, 33, accuracy: 0.001)
        XCTAssertTrue(decoded.isUserEdited)
        XCTAssertTrue(decoded.excluded)
        XCTAssertEqual(decoded.aiOriginal?.name, "White rice")
        XCTAssertEqual(decoded.aiOriginal?.carbohydrates, 40)
    }
}
