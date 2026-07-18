//
//  FoodFinder_SearchViewModel.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  FoodFinder — ViewModel for food search state, AI analysis, and
//  product selection logic.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import SwiftUI
import LoopKit
import HealthKit
import Combine
import os.log
import ObjectiveC
import UIKit

// MARK: - Timeout Utilities

/// Error thrown when an operation times out
struct FoodFinder_TimeoutError: Error {
    let duration: TimeInterval

    var localizedDescription: String {
        return "Operation timed out after \(duration) seconds"
    }
}

/// Execute an async operation with a timeout
/// - Parameters:
///   - seconds: Timeout duration in seconds
///   - operation: The async operation to execute
/// - Throws: FoodFinder_TimeoutError if the operation doesn't complete within the timeout
func foodFinder_withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        // Add the main operation
        group.addTask {
            try await operation()
        }

        // Add the timeout task
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw FoodFinder_TimeoutError(duration: seconds)
        }

        // Return the first result and cancel the other task
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

// MARK: - Nutrition Result Tuple

/// The payload delivered to the host (CarbEntryView / CarbEntryViewModel)
/// when the user confirms a food selection or AI analysis.
/// The values the per-item edit sheet hands back. All are *effective* numbers —
/// the ones shown on the item row for the portion the user selected — not the
/// item's internal per-portion basis.
struct FoodFinder_ItemEdit: Equatable {
    var name: String
    var carbs: Double
    var calories: Double
    var fat: Double
    var fiber: Double
    var protein: Double
}

extension Double {
    /// Tolerant compare for user-entered nutrition values. The edit sheet
    /// round-trips through a one-decimal text field, so exact `==` against a
    /// recomputed Double would report a change the user never made.
    func isApproximately(_ other: Double, tolerance: Double = 0.05) -> Bool {
        abs(self - other) < tolerance
    }
}

struct FoodFinder_NutritionResult {
    let carbs: Double
    let foodType: String
    let absorptionTime: TimeInterval
    let absorptionTimeWasAIGenerated: Bool
    /// Optional macros for downstream features (e.g. BolusPro). nil when
    /// the source (manual carb entry, basic search) didn't carry them.
    let fat: Double?
    let protein: Double?
    /// String identifying which FoodFinder path produced the macros.
    /// Mapped to `BolusProMacrosSource` by the host. Values: `"ai"`,
    /// `"product"`, `"favorite"`. nil when no macros present.
    let macrosSource: String?
    /// Explanation shown next to the absorption-time picker. Kept in sync with
    /// `absorptionTime` so it never describes a stale plate: it's the AI's
    /// original reasoning on an untouched plate, a locally-generated note after
    /// the user edits items, or a "set manually" note after a manual override.
    /// nil for non-AI paths (barcode / text search), which carry no reasoning.
    let absorptionReasoning: String?
}

// MARK: - Search ViewModel

final class FoodFinder_SearchViewModel: ObservableObject {

    // MARK: - Callback to Host

    /// The host sets this closure so it can receive nutrition updates
    /// when the user selects a food product or AI analysis completes.
    var onNutritionApplied: ((FoodFinder_NutritionResult) -> Void)?

    /// Callback when the selected food is cleared so the host can reset its fields.
    var onFoodCleared: (() -> Void)?

    /// Callback when a generative AI search completes (triggered by natural language
    /// detected in the text field, e.g. from iOS keyboard dictation).
    var onGenerativeSearchResult: ((AIFoodAnalysisResult) -> Void)?

    // MARK: - Food Search Published Properties

    /// Current search text for food lookup
    @Published var foodSearchText: String = ""

    /// Results from food search
    @Published var foodSearchResults: [OpenFoodFactsProduct] = []

    /// Currently selected food product
    @Published var selectedFoodProduct: OpenFoodFactsProduct? = nil

    /// Pre-downloaded product thumbnail image (avoids AsyncImage rebuild issues)
    @Published var productThumbnailImage: UIImage? = nil

    /// Serving size context for selected food product
    @Published var selectedFoodServingSize: String? = nil

    /// Number of servings for the selected food product
    @Published var numberOfServings: Double = 1.0

    /// True while the user is picking an additional item to add to the current
    /// meal (after tapping "Add another item"). The next product selection or AI
    /// analysis appends to the plate instead of replacing it, then clears this.
    /// Making accumulation an explicit mode keeps a mistapped search result from
    /// silently becoming an extra item in a dose.
    @Published var isBuildingMeal: Bool = false

    /// Whether a food search is currently in progress
    @Published var isFoodSearching: Bool = false

    /// Whether the current search is an AI generative analysis (voice/dictation)
    @Published var isAISearching: Bool = false

    /// Error message from food search operations
    @Published var foodSearchError: String? = nil

    /// Whether the food search UI is visible
    @Published var showingFoodSearch: Bool = false

    /// Flag set when iOS keyboard dictation is detected via DictationAwareTextField.
    /// Causes the next search to route through AI generative search regardless of word count.
    var lastInputWasDictated: Bool = false

    /// Store the last AI analysis result for detailed UI display
    @Published var lastAIAnalysisResult: AIFoodAnalysisResult? = nil

    // Per-item exclusion and serving overrides used to live here as
    // `excludedAIItemIndices: Set<Int>` and `itemServingOverrides: [Int: Double]`.
    // Both were keyed by array index, so they aliased onto the wrong food
    // whenever the array changed underneath them — a re-analysis kept the
    // previous plate's exclusions, and deleting an item shifted every later
    // override onto its neighbour. That state now lives on `FoodItemAnalysis`
    // itself (`isExcluded` / `userServingMultiplier`), so it moves with the food
    // it describes and persists with the stored analysis.

    /// Store the captured AI image for display
    @Published var capturedAIImage: UIImage? = nil

    // MARK: - Internal / Private State

    /// Track the last barcode we searched for to prevent duplicates
    private var lastBarcodeSearched: String? = nil

    /// Flag to track if food search observers have been set up
    private var observersSetUp = false
    private var servingsObserversSetUp = false

    /// Search result cache for improved performance
    private var searchCache: [String: CachedSearchResult] = [:]

    /// Cache entry with timestamp for expiration
    private struct CachedSearchResult {
        let results: [OpenFoodFactsProduct]
        let timestamp: Date

        var isExpired: Bool {
            Date().timeIntervalSince(timestamp) > 300 // 5 minutes cache
        }
    }

    /// OpenFoodFacts service for food search
    private let openFoodFactsService = OpenFoodFactsService()

    /// AI service for provider routing
    private let aiService = ConfigurableAIService.shared

    /// Combine subscriptions
    private lazy var cancellables = Set<AnyCancellable>()

    // MARK: - Absorption Time Context
    // These are passed from the host so this ViewModel can compute
    // absorption-time adjustments without depending on CarbEntryViewModel.

    let defaultAbsorptionTimes: CarbStore.DefaultAbsorptionTimes

    /// The absorption time currently shown in the host's UI.
    /// Updated via the callback – we keep a local copy so deletion /
    /// recalculation logic can reference it.
    @Published var absorptionTime: TimeInterval

    /// Whether the absorption time was set by AI analysis
    @Published var absorptionTimeWasAIGenerated: Bool = false

    /// Set by the host view when the user manually drags the absorption-time
    /// picker after an AI/recompute write. While true, editing the plate
    /// recomputes carbs/macros but leaves the user's chosen absorption time
    /// untouched. Reset whenever a fresh analysis is applied or food is cleared.
    @Published var userDidOverrideAbsorption: Bool = false

    /// Internal flag so programmatic absorption-time writes don't flip
    /// ``absorptionTimeWasEdited`` in the host.
    internal var absorptionEditIsProgrammatic = false

    // MARK: - Associated-Object Storage for Task

    /// Task for debounced search operations
    private var foodSearchTask: Task<Void, Never>? {
        get { objc_getAssociatedObject(self, &AssociatedKeys.foodSearchTask) as? Task<Void, Never> }
        set { objc_setAssociatedObject(self, &AssociatedKeys.foodSearchTask, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    private struct AssociatedKeys {
        static var foodSearchTask: UInt8 = 0
    }

    // MARK: - Init

    /// - Parameters:
    ///   - defaultAbsorptionTimes: The fast / medium / slow absorption times from the CarbStore.
    ///   - initialAbsorptionTime: Current absorption time from the host (usually `medium`).
    init(defaultAbsorptionTimes: CarbStore.DefaultAbsorptionTimes,
         initialAbsorptionTime: TimeInterval) {
        self.defaultAbsorptionTimes = defaultAbsorptionTimes
        self.absorptionTime = initialAbsorptionTime
    }

    // MARK: - Observer Setup

    /// Call once after init (typically from the hosting view's onAppear or
    /// the parent ViewModel's init).
    func setupObservers() {
        setupFoodSearchObservers()
        // onAppear can fire more than once per sheet; without this guard each
        // appearance stacked another servings/exclusion sink, so a single
        // stepper tap triggered N interleaved recomputes.
        guard !servingsObserversSetUp else { return }
        servingsObserversSetUp = true
        observeNumberOfServingsChange()
        observeAIExclusionsChange()
    }

    /// Setup food search observers
    func setupFoodSearchObservers() {
        guard !observersSetUp else {
            return
        }

        observersSetUp = true

        // Debounce search text changes
        $foodSearchText
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] searchText in
                self?.performFoodSearch(query: searchText)
            }
            .store(in: &cancellables)

        // Listen for barcode scan results with deduplication
        BarcodeScannerService.shared.$lastScanResult
            .compactMap { $0 }
            .removeDuplicates { $0.barcodeString == $1.barcodeString }
            .throttle(for: .milliseconds(800), scheduler: DispatchQueue.main, latest: false)
            .sink { [weak self] result in
                #if DEBUG
                print("🔍 ========== BARCODE RECEIVED IN VIEWMODEL ==========")
                #endif
                #if DEBUG
                print("🔍 FoodFinder_SearchViewModel received barcode from BarcodeScannerService: \(result.barcodeString)")
                #endif
                #if DEBUG
                print("🔍 Barcode confidence: \(result.confidence)")
                #endif
                #if DEBUG
                print("🔍 Calling searchFoodProductByBarcode...")
                #endif
                // Consume the scan result immediately so other subscribers
                // (e.g. from SwiftUI view recreation) don't re-process the same barcode.
                BarcodeScannerService.shared.lastScanResult = nil
                self?.searchFoodProductByBarcode(result.barcodeString)
            }
            .store(in: &cancellables)
    }

    // MARK: - Servings / AI Exclusion Observers

    private func observeNumberOfServingsChange() {
        $numberOfServings
            .receive(on: RunLoop.main)
            .dropFirst()
            .sink { [weak self] servings in
                #if DEBUG
                print("🥄 numberOfServings changed to: \(servings), recalculating nutrition...")
                #endif
                guard let self = self else { return }
                if self.lastAIAnalysisResult != nil {
                    // AI plate: the per-item recompute is the authoritative
                    // writer. Running the product-based math too sent a second,
                    // differing carbs value through onNutritionApplied on every
                    // stepper tap, racing the recompute at the host.
                    self.recomputeAIAdjustments()
                } else {
                    self.recalculateCarbsForServings(servings)
                }
            }
            .store(in: &cancellables)
    }

    /// Per-item exclusions, serving overrides and value edits all now mutate
    /// `lastAIAnalysisResult`, so observing it alone covers what the old
    /// three-way `combineLatest` did. `recomputeAIAdjustments` doesn't write
    /// back to this result, so there's no feedback loop.
    private func observeAIExclusionsChange() {
        $lastAIAnalysisResult
            .receive(on: RunLoop.main)
            .dropFirst()
            .sink { [weak self] _ in
                self?.recomputeAIAdjustments()
            }
            .store(in: &cancellables)
    }

    // MARK: - AI Adjustment Recomputation

    /// Recompute carbs and absorption time based on included AI items
    func recomputeAIAdjustments() {
        guard let ai = lastAIAnalysisResult else { return }

        // All per-item scaling (serving overrides, exclusions, user edits) lives
        // on the items themselves and is applied by `totals(plateScale:)` — the
        // same call the nutrition circles use, so the displayed macros and the
        // carbs we hand the host can no longer drift apart.
        // `numberOfServings` is the plate-level "I ate 2 of these" multiplier.
        let totals = ai.totals(plateScale: numberOfServings)
        let newCarbs = totals.carbs
        let newFat = totals.fat
        let newProtein = totals.protein
        let newFiber = totals.fiber
        let newCalories = totals.calories

        let included = ai.includedItems

        // Absorption time.
        // The AI returns ONE whole-plate absorption_time_hours (the per-item
        // field isn't in the prompt schema, so it's ~always nil). That original
        // number stops reflecting reality the moment the user edits the plate —
        // deleting a slow, fatty item used to leave absorption stuck at the
        // full-plate value. So: trust the AI's number on an unedited plate, but
        // re-derive it from the REMAINING macros once anything is excluded,
        // rescaled, or multiplied by the servings slider.
        let plateWasEdited = ai.plateWasEdited || numberOfServings != 1.0

        var newAbsorptionTime = absorptionTime
        var aiGenerated = absorptionTimeWasAIGenerated
        var absorptionReasoning = ai.absorptionTimeReasoning
        if userDidOverrideAbsorption {
            // User dialed in their own absorption time — preserve it; only the
            // macros recompute. `absorptionTime` is kept current by the host bridge.
            newAbsorptionTime = absorptionTime
            aiGenerated = false
            absorptionReasoning = NSLocalizedString(
                "Absorption time set manually.",
                comment: "FoodFinder note when the user has overridden the AI absorption time")
        } else if !plateWasEdited {
            // Untouched plate → trust the AI's exact original value and reasoning.
            if let hours = ai.absorptionTimeHours, hours > 0 {
                newAbsorptionTime = TimeInterval(hours * 3600)
                aiGenerated = true
            }
        } else {
            // Plate edited → re-derive from the remaining macros using the same
            // tuned model the deletion path uses, and refresh the reasoning text
            // so it no longer describes the original plate. No AI round-trip.
            let (hours, reasoning) = recalculateAbsorptionTime(
                carbs: newCarbs,
                protein: newProtein,
                fat: newFat,
                fiber: newFiber,
                calories: newCalories,
                remainingItems: included,
                context: NSLocalizedString(
                    "Adjusted after editing the plate",
                    comment: "FoodFinder absorption note prefix after the user edits detected items")
            )
            newAbsorptionTime = TimeInterval(hours * 3600)
            aiGenerated = true
            absorptionReasoning = reasoning
        }

        // Determine food type from the AI result (truncate to fit RowEmojiTextField maxLength)
        let maxFoodTypeLength = 25
        let foodType: String = {
            let names = included.map { $0.name }
            let raw: String
            if names.count == 1 {
                raw = names[0]
            } else if !names.isEmpty {
                raw = names.joined(separator: ", ")
            } else {
                raw = ai.overallDescription ?? "AI Analysis"
            }
            if raw.count > maxFoodTypeLength {
                return String(raw.prefix(maxFoodTypeLength - 1)) + "…"
            }
            return raw
        }()

        // Notify host
        absorptionEditIsProgrammatic = true
        absorptionTime = newAbsorptionTime
        absorptionTimeWasAIGenerated = aiGenerated

        onNutritionApplied?(FoodFinder_NutritionResult(
            carbs: newCarbs,
            foodType: foodType,
            absorptionTime: newAbsorptionTime,
            absorptionTimeWasAIGenerated: aiGenerated,
            fat: newFat > 0 ? newFat : nil,
            protein: newProtein > 0 ? newProtein : nil,
            macrosSource: (newFat > 0 || newProtein > 0) ? "ai" : nil,
            absorptionReasoning: absorptionReasoning
        ))
    }

    /// Identity for the nutrition circles' `.id(...)`, derived from the values
    /// they actually display. Keyed on the totals rather than on which knobs
    /// were touched, so a direct edit to an item's carbs or macros invalidates
    /// them the same way a servings tap does.
    var nutritionCirclesIdentity: String {
        guard let ai = lastAIAnalysisResult else { return "product-\(numberOfServings)" }
        let totals = ai.totals(plateScale: numberOfServings)
        return "\(totals.carbs)-\(totals.fat)-\(totals.protein)-\(totals.fiber)-\(totals.calories)"
    }

    /// Get the effective serving multiplier for an item (user override or AI default)
    func effectiveServings(for index: Int) -> Double {
        guard let items = lastAIAnalysisResult?.foodItemsDetailed,
              items.indices.contains(index) else { return 1.0 }
        return items[index].effectiveMultiplier
    }

    /// Adjust per-item serving multiplier by a delta (clamped to 0.25 minimum)
    func adjustItemServings(index: Int, delta: Double) {
        mutateItem(at: index) { item in
            item.userServingMultiplier = max(0.25, item.effectiveMultiplier + delta)
        }
    }

    /// Toggle an item in or out of the plate totals.
    func toggleItemExclusion(at index: Int) {
        mutateItem(at: index) { item in
            item.isExcluded = !item.excluded
        }
    }

    /// Apply an edit to one item and republish. Writing through
    /// `lastAIAnalysisResult` is what makes an edit sticky: the item row, the
    /// nutrition circles and the carb total all read from this result, and it is
    /// what gets persisted to the analysis record.
    func mutateItem(at index: Int, _ transform: (inout FoodItemAnalysis) -> Void) {
        guard var result = lastAIAnalysisResult,
              result.foodItemsDetailed.indices.contains(index) else { return }
        transform(&result.foodItemsDetailed[index])
        lastAIAnalysisResult = result
    }

    /// Apply the edit sheet's values to an item.
    ///
    /// Values arrive as *effective* numbers — what the user sees on the row and
    /// typed into the field — and the setters convert them back to the item's
    /// stored basis, so a later servings step scales from the edited value
    /// instead of discarding it.
    ///
    /// Each field is only written when it actually changed: the setters snapshot
    /// the AI's originals on first write, so touching them unconditionally would
    /// mark an untouched item as edited just for opening the sheet.
    func applyItemEdit(at index: Int, _ edit: FoodFinder_ItemEdit) {
        mutateItem(at: index) { item in
            let trimmedName = edit.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedName.isEmpty, trimmedName != item.name {
                item.setName(trimmedName)
            }
            if !edit.carbs.isApproximately(item.effectiveCarbs) {
                item.setEffectiveCarbs(edit.carbs)
            }
            if !edit.calories.isApproximately(item.effectiveCalories) {
                item.setEffectiveCalories(edit.calories)
            }
            if !edit.fat.isApproximately(item.effectiveFat) {
                item.setEffectiveFat(edit.fat)
            }
            if !edit.fiber.isApproximately(item.effectiveFiber) {
                item.setEffectiveFiber(edit.fiber)
            }
            if !edit.protein.isApproximately(item.effectiveProtein) {
                item.setEffectiveProtein(edit.protein)
            }
        }
    }

    /// Restore one item's AI values, leaving its portion choices intact.
    func resetItemToAI(at index: Int) {
        mutateItem(at: index) { $0.resetToAI() }
    }

    // MARK: - Meal Building (multi-item plate)

    /// Append items to the current plate, creating it if none exists.
    ///
    /// Setting `lastAIAnalysisResult` re-triggers the recompute observer, so the
    /// carb total, nutrition circles and food-type name all follow the enlarged
    /// plate. The synthetic product header is refreshed too so it names the whole
    /// meal, not just the food that seeded it. Clears `isBuildingMeal`.
    func appendItemsToPlate(_ newItems: [FoodItemAnalysis], description: String) {
        guard !newItems.isEmpty else { isBuildingMeal = false; return }
        var result = lastAIAnalysisResult ?? AIFoodAnalysisResult.plate(items: [], description: description)
        result.foodItemsDetailed.append(contentsOf: newItems)
        result = result.withBackfilledIDs()
        lastAIAnalysisResult = result
        refreshSyntheticPlateProduct()
        isBuildingMeal = false
    }

    /// Append a selected product to the plate as one item. Servings default to
    /// 1.0 for the new item — the plate-level `numberOfServings` multiplier
    /// belongs to the existing plate and must not scale the freshly added food.
    func appendProductToPlate(_ product: OpenFoodFactsProduct) {
        let item = FoodItemAnalysis.fromProduct(
            product,
            servings: 1.0,
            carbsOverride: nil,
            sourceLabel: sourceLabelForCurrentProduct(product)
        )
        appendItemsToPlate([item], description: product.displayName)
    }

    /// Human-readable provenance for an item built from a product.
    func sourceLabelForCurrentProduct(_ product: OpenFoodFactsProduct) -> String {
        switch product.dataSource {
        case .barcodeScan: return NSLocalizedString("Scanned", comment: "Item source label for a barcode-scanned food")
        case .textSearch: return NSLocalizedString("Searched", comment: "Item source label for a text-searched food")
        case .aiAnalysis: return NSLocalizedString("Photo", comment: "Item source label for a photo-analyzed food")
        case .manualEntry: return NSLocalizedString("Manual", comment: "Item source label for a manually entered food")
        case .unknown: return NSLocalizedString("Added", comment: "Item source label for a food of unspecified origin")
        }
    }

    /// Rebuild the synthetic `ai_` product that gates the plate card so its name
    /// and macros track the current plate. The prefix is kept so
    /// `selectFoodProduct`'s AI-state guard still recognises it as a plate.
    func refreshSyntheticPlateProduct() {
        guard let plate = lastAIAnalysisResult else { return }
        let existingID = selectedFoodProduct?.id
        let id = (existingID?.hasPrefix("ai_") == true) ? existingID! : "ai_\(UUID().uuidString.prefix(8))"
        let totals = plate.totals(plateScale: 1.0)
        let nutriments = Nutriments(
            carbohydrates: totals.carbs,
            proteins: totals.protein > 0 ? totals.protein : nil,
            fat: totals.fat > 0 ? totals.fat : nil,
            calories: totals.calories > 0 ? totals.calories : nil,
            sugars: nil,
            fiber: totals.fiber > 0 ? totals.fiber : nil
        )
        let names = plate.includedItems.map { $0.name }
        let title = names.count <= 1 ? (names.first ?? "Meal") : String(format: NSLocalizedString("Meal (%d items)", comment: "Plate header for a multi-item meal"), names.count)
        selectedFoodProduct = OpenFoodFactsProduct(
            id: id,
            productName: title,
            brands: "AI Analysis",
            categories: plate.analysisNotes ?? "Meal",
            nutriments: nutriments,
            servingSize: nil,
            servingQuantity: 100.0,
            imageURL: nil,
            imageFrontURL: nil,
            code: nil,
            dataSource: .aiAnalysis
        )
    }

    /// Restore every edited item on the plate.
    func resetAllItemsToAI() {
        guard var result = lastAIAnalysisResult else { return }
        for index in result.foodItemsDetailed.indices {
            result.foodItemsDetailed[index].resetToAI()
        }
        lastAIAnalysisResult = result
    }

    // MARK: - Voice / Generative Search

    /// Perform a generative AI food search from voice-transcribed text.
    /// Routes through the AI image analysis pipeline (same prompt) instead
    /// of the USDA text search, enabling natural-language food descriptions
    /// like "a medium bowl of spicy ramen and a side of gyoza".
    @MainActor
    func performVoiceSearch(query: String) async -> AIFoodAnalysisResult? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // User-initiated paid AI action — pass through the spend gate.
        guard await PowerPack_APIUsage.shared.gate(actionLabel: "Searching for \u{201C}\(trimmed)\u{201D}", estCostUSD: 0.01) else {
            return nil
        }

        #if DEBUG
        print("🎙️ Starting generative voice search for: '\(trimmed)'")
        #endif

        isFoodSearching = true
        isAISearching = true
        foodSearchError = nil
        foodSearchResults = []
        showingFoodSearch = true

        defer {
            isFoodSearching = false
            isAISearching = false
        }

        do {
            let result = try await foodFinder_withTimeout(seconds: 60) {
                try await FoodSearchRouter.shared.analyzeFoodByDescription(trimmed)
            }

            #if DEBUG
            print("🎙️ Voice search AI analysis completed for: '\(trimmed)' — carbs: \(result.totalCarbohydrates)g")
            #endif

            // Clear skeleton results
            foodSearchResults = []
            showingFoodSearch = false

            return result
        } catch {
            #if DEBUG
            print("🎙️ Voice search failed: \(error.localizedDescription)")
            #endif

            if error is CancellationError { return nil }

            foodSearchError = "AI analysis failed: \(error.localizedDescription). Try typing your search instead."
            foodSearchResults = []
            return nil
        }
    }

    // MARK: - Natural Language Detection

    /// Heuristic to detect natural language food descriptions (likely from iOS keyboard dictation).
    /// Short keyword queries like "apple" or "chicken soup" go to USDA; longer descriptive
    /// phrases like "a medium bowl of spicy ramen and a side of gyoza" go to AI.
    private func isNaturalLanguageQuery(_ query: String) -> Bool {
        let words = query.split(separator: " ").filter { !$0.isEmpty }
        guard words.count >= 4 else { return false }

        let lowered = query.lowercased()

        // Explicit natural language indicators (common in dictated speech)
        let indicators = [
            "i'm eating", "i ate", "i had", "i'm having", "i just had", "i just ate",
            "a bowl of", "a plate of", "a cup of", "a glass of", "a piece of", "a slice of",
            "a medium", "a large", "a small", "with a side", "and a side", "and a",
            "for lunch", "for dinner", "for breakfast", "some "
        ]
        for indicator in indicators {
            if lowered.contains(indicator) { return true }
        }

        // 5+ words without explicit indicators is still likely a descriptive phrase
        return words.count >= 5
    }

    // MARK: - Food Search Methods

    /// Perform food search with given query
    /// - Parameter query: Search term for food lookup
    func performFoodSearch(query: String) {

        // Cancel previous search
        foodSearchTask?.cancel()

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Clear results if query is empty
        guard !trimmedQuery.isEmpty else {
            foodSearchResults = []
            foodSearchError = nil
            showingFoodSearch = false
            return
        }

        #if DEBUG
        print("🔍 Starting search for: '\(trimmedQuery)'")
        #endif

        // Detect dictation (via DictationAwareTextField flag) or natural language input and route to AI
        let wasDictated = lastInputWasDictated
        if wasDictated {
            lastInputWasDictated = false  // Reset flag immediately
        }

        if wasDictated || isNaturalLanguageQuery(trimmedQuery) {
            #if DEBUG
            print("🎙️ \(wasDictated ? "Dictation detected" : "Natural language detected") — routing to AI generative search for: '\(trimmedQuery)'")
            #endif
            // Cancel any in-flight search so only the latest query runs.
            foodSearchTask?.cancel()
            foodSearchTask = Task { [weak self] in
                guard let self = self else { return }
                // Wait for dictation to settle — if more text arrives, this task
                // gets cancelled and a new one starts with the updated query.
                if wasDictated {
                    do {
                        try await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
                    } catch {
                        return // Cancelled — newer dictation text superseded this
                    }
                }
                if let result = await self.performVoiceSearch(query: trimmedQuery) {
                    await MainActor.run {
                        self.onGenerativeSearchResult?(result)
                    }
                }
            }
            return
        }

        // Show search UI, clear previous results and error
        showingFoodSearch = true
        foodSearchResults = []  // Clear previous results to show searching state
        foodSearchError = nil
        isFoodSearching = true

        // Perform new search immediately but ensure minimum search time for UX
        foodSearchTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                await self.searchFoodProducts(query: trimmedQuery)
            } catch {
                #if DEBUG
                print("🔍 Food search error: \(error)")
                #endif
                await MainActor.run {
                    self.foodSearchError = error.localizedDescription
                    self.isFoodSearching = false
                }
            }
        }
    }

    /// Search for food products using OpenFoodFacts API
    /// - Parameter query: Search query string
    @MainActor
    private func searchFoodProducts(query: String) async {
        #if DEBUG
        print("🔍 searchFoodProducts starting for: '\(query)'")
        #endif
        foodSearchError = nil

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Check cache first for instant results
        if let cachedResult = searchCache[trimmedQuery], !cachedResult.isExpired {
            #if DEBUG
            print("🔍 Using cached results for: '\(trimmedQuery)'")
            #endif
            foodSearchResults = cachedResult.results
            isFoodSearching = false
            return
        }

        // Show skeleton loading state immediately
        foodSearchResults = createSkeletonResults()

        do {
            #if DEBUG
            print("🔍 Performing text search with configured provider...")
            #endif
            let rawProducts = try await performTextSearch(query: query)

            // Sort results by relevance and return the top 15 most relevant
            let products = Array(sortByRelevance(rawProducts, query: trimmedQuery).prefix(15))

            // Cache the sorted results for future use
            searchCache[trimmedQuery] = CachedSearchResult(results: products, timestamp: Date())
            #if DEBUG
            print("🔍 Cached results for: '\(trimmedQuery)' (\(products.count) items)")
            #endif

            // Periodically clean up expired cache entries
            if searchCache.count > 20 {
                cleanupExpiredCache()
            }

            foodSearchResults = products

            #if DEBUG
            print("🔍 Search completed! Found \(products.count) products")
            #endif

            os_log("Food search for '%{public}@' returned %d results",
                   log: OSLog(category: "FoodSearch"),
                   type: .info,
                   query,
                   products.count)

        } catch {
            #if DEBUG
            print("🔍 Search failed with error: \(error)")
            #endif

            // Don't show cancellation errors to the user - they're expected during rapid typing
            if error is CancellationError {
                #if DEBUG
                print("🔍 Search was cancelled (expected behavior)")
                #endif
                // Clear any previous error when cancelled
                foodSearchError = nil
                isFoodSearching = false
                return
            }

            // Check for URLError cancellation as well
            if let urlError = error as? URLError, urlError.code == .cancelled {
                #if DEBUG
                print("🔍 URLSession request was cancelled (expected behavior)")
                #endif
                // Clear any previous error when cancelled
                foodSearchError = nil
                isFoodSearching = false
                return
            }

            // Check for OpenFoodFactsError wrapping a URLError cancellation
            if let openFoodFactsError = error as? OpenFoodFactsError,
               case .networkError(let underlyingError) = openFoodFactsError,
               let urlError = underlyingError as? URLError,
               urlError.code == .cancelled {
                #if DEBUG
                print("🔍 OpenFoodFacts wrapped URLSession request was cancelled (expected behavior)")
                #endif
                // Clear any previous error when cancelled
                foodSearchError = nil
                isFoodSearching = false
                return
            }

            foodSearchError = error.localizedDescription
            foodSearchResults = []

            os_log("Food search failed: %{public}@",
                   log: OSLog(category: "FoodSearch"),
                   type: .error,
                   error.localizedDescription)
        }

        // Always set isFoodSearching to false at the end
        isFoodSearching = false
        #if DEBUG
        print("🔍 searchFoodProducts finished, isFoodSearching = false")
        #endif
    }

    // MARK: - Barcode Search

    /// Search for a specific product by barcode
    /// - Parameter barcode: Product barcode

    func searchFoodProductByBarcode(_ barcode: String) {
        #if DEBUG
        print("🔍 ========== BARCODE SEARCH STARTED ==========")
        #endif
        #if DEBUG
        print("🔍 searchFoodProductByBarcode called with barcode: \(barcode)")
        #endif
        #if DEBUG
        print("🔍 Current thread: \(Thread.isMainThread ? "MAIN" : "BACKGROUND")")
        #endif
        #if DEBUG
        print("🔍 lastBarcodeSearched: \(lastBarcodeSearched ?? "nil")")
        #endif

        // Prevent duplicate searches for the same barcode
        if let lastBarcode = lastBarcodeSearched, lastBarcode == barcode {
            #if DEBUG
            print("🔍 ⚠️ Ignoring duplicate barcode search for: \(barcode)")
            #endif
            return
        }

        // Always cancel any existing task to prevent stalling
        if let existingTask = foodSearchTask, !existingTask.isCancelled {
            #if DEBUG
            print("🔍 Cancelling existing search task")
            #endif
            existingTask.cancel()
        }

        lastBarcodeSearched = barcode

        foodSearchTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                #if DEBUG
                print("🔍 Starting barcode lookup task for: \(barcode)")
                #endif

                // Add timeout wrapper to prevent infinite stalling
                try await foodFinder_withTimeout(seconds: 45) {
                    await self.lookupProductByBarcode(barcode)
                }

                // Clear the last barcode after successful completion
                await MainActor.run {
                    self.lastBarcodeSearched = nil
                }
            } catch {
                #if DEBUG
                print("🔍 Barcode search error: \(error)")
                #endif

                await MainActor.run {
                    // If it's a timeout, create fallback product
                    if error is FoodFinder_TimeoutError {
                        #if DEBUG
                        print("🔍 Barcode search timed out, creating fallback product")
                        #endif
                        self.createManualEntryPlaceholder(for: barcode)
                        self.lastBarcodeSearched = nil
                        return
                    }

                    self.foodSearchError = error.localizedDescription
                    self.isFoodSearching = false

                    // Clear the last barcode after error
                    self.lastBarcodeSearched = nil
                }
            }
        }
    }

    /// Look up a product by barcode
    /// - Parameter barcode: Product barcode
    @MainActor
    private func lookupProductByBarcode(_ barcode: String) async {
        #if DEBUG
        print("🔍 lookupProductByBarcode starting for: \(barcode)")
        #endif

        // Clear previous results to show searching state
        foodSearchResults = []
        isFoodSearching = true
        foodSearchError = nil

        defer {
            #if DEBUG
            print("🔍 lookupProductByBarcode finished, setting isFoodSearching = false")
            #endif
            isFoodSearching = false
        }

        do {
            #if DEBUG
            print("🔍 Calling performBarcodeSearch for: \(barcode)")
            #endif
            if let product = try await performBarcodeSearch(barcode: barcode) {
                // Add to search results and select it
                if !foodSearchResults.contains(product) {
                    foodSearchResults.insert(product, at: 0)
                }
                selectFoodProduct(product)

                os_log("Barcode lookup successful for %{public}@: %{public}@",
                       log: OSLog(category: "FoodSearch"),
                       type: .info,
                       barcode,
                       product.displayName)

                // DataLayer: barcode scan found
                NotificationCenter.default.post(
                    name: Notification.Name("com.loopkit.Loop.foodFinderBarcodeScanned"),
                    object: nil,
                    userInfo: [
                        "barcode": barcode,
                        "productName": product.displayName,
                        "carbsGrams": product.nutriments.carbohydrates as Any,
                        "source": "openfoodfacts",
                        "found": true
                    ]
                )
            } else {
                #if DEBUG
                print("🔍 No product found, creating manual entry placeholder")
                #endif
                createManualEntryPlaceholder(for: barcode)

                // DataLayer: barcode scan not found
                NotificationCenter.default.post(
                    name: Notification.Name("com.loopkit.Loop.foodFinderBarcodeScanned"),
                    object: nil,
                    userInfo: [
                        "barcode": barcode,
                        "source": "openfoodfacts",
                        "found": false
                    ]
                )
            }

        } catch {
            // Don't show cancellation errors to the user - just return without doing anything
            if error is CancellationError {
                #if DEBUG
                print("🔍 Barcode lookup was cancelled (expected behavior)")
                #endif
                foodSearchError = nil
                return
            }

            if let urlError = error as? URLError, urlError.code == .cancelled {
                #if DEBUG
                print("🔍 Barcode lookup URLSession request was cancelled (expected behavior)")
                #endif
                foodSearchError = nil
                return
            }

            // Check for OpenFoodFactsError wrapping a URLError cancellation
            if let openFoodFactsError = error as? OpenFoodFactsError,
               case .networkError(let underlyingError) = openFoodFactsError,
               let urlError = underlyingError as? URLError,
               urlError.code == .cancelled {
                #if DEBUG
                print("🔍 Barcode lookup OpenFoodFacts wrapped URLSession request was cancelled (expected behavior)")
                #endif
                foodSearchError = nil
                return
            }

            // For any other error (network issues, product not found, etc.), create manual entry placeholder
            #if DEBUG
            print("🔍 Barcode lookup failed with error: \(error), creating manual entry placeholder")
            #endif
            createManualEntryPlaceholder(for: barcode)

            os_log("Barcode lookup failed for %{public}@: %{public}@, created manual entry placeholder",
                   log: OSLog(category: "FoodSearch"),
                   type: .info,
                   barcode,
                   error.localizedDescription)
        }
    }

    /// Create a manual entry placeholder when network requests fail
    /// - Parameter barcode: The scanned barcode
    private func createManualEntryPlaceholder(for barcode: String) {
        #if DEBUG
        print("🔍 ========== CREATING MANUAL ENTRY PLACEHOLDER ==========")
        #endif
        #if DEBUG
        print("🔍 Creating manual entry placeholder for barcode: \(barcode)")
        #endif
        #if DEBUG
        print("🔍 Current thread: \(Thread.isMainThread ? "MAIN" : "BACKGROUND")")
        #endif
        #if DEBUG
        print("🔍 ⚠️ WARNING: This is NOT real product data - requires manual entry")
        #endif

        // Create a placeholder product that requires manual nutrition entry
        let fallbackProduct = OpenFoodFactsProduct(
            id: "fallback_\(barcode)",
            productName: "Product \(barcode)",
            brands: "Database Unavailable",
            categories: "⚠️ NUTRITION DATA UNAVAILABLE - ENTER MANUALLY",
            nutriments: Nutriments(
                carbohydrates: 0.0,  // Force user to enter real values
                proteins: 0.0,
                fat: 0.0,
                calories: 0.0,
                sugars: nil,
                fiber: nil
            ),
            servingSize: "Enter serving size",
            servingQuantity: 100.0,
            imageURL: nil,
            imageFrontURL: nil,
            code: barcode,
            dataSource: .barcodeScan
        )

        // Add to search results and select it
        if !foodSearchResults.contains(fallbackProduct) {
            foodSearchResults.insert(fallbackProduct, at: 0)
        }

        selectFoodProduct(fallbackProduct)

        // Store the selected food information for UI display
        selectedFoodServingSize = fallbackProduct.servingSize
        numberOfServings = 1.0

        // Clear any error since we successfully created a fallback
        foodSearchError = nil

        #if DEBUG
        print("🔍 ✅ Manual entry placeholder created for barcode: \(barcode)")
        #endif
        #if DEBUG
        print("🔍 foodSearchResults.count: \(foodSearchResults.count)")
        #endif
        #if DEBUG
        print("🔍 selectedFoodProduct: \(selectedFoodProduct?.displayName ?? "nil")")
        #endif
        #if DEBUG
        print("🔍 ========== MANUAL ENTRY PLACEHOLDER COMPLETE ==========")
        #endif
    }

    // MARK: - Select Food Product

    /// Select a food product and populate carb entry fields
    /// - Parameter product: The selected food product
    func selectFoodProduct(_ product: OpenFoodFactsProduct) {
        // Meal-building mode: append this product to the plate instead of
        // replacing the current food. Synthetic `ai_` plate products are the
        // plate re-selecting itself and must fall through to the normal path.
        if isBuildingMeal, !product.id.hasPrefix("ai_") {
            appendProductToPlate(product)
            foodSearchText = ""
            foodSearchResults = []
            foodSearchError = nil
            showingFoodSearch = false
            foodSearchTask?.cancel()
            return
        }

        #if DEBUG
        print("🔄 ========== SELECTING FOOD PRODUCT ==========")
        #endif
        #if DEBUG
        print("🔄 Product: \(product.displayName)")
        #endif
        #if DEBUG
        print("🔄 Product ID: \(product.id)")
        #endif
        #if DEBUG
        print("🔄 Data source: \(product.dataSource)")
        #endif
        #if DEBUG
        print("🔄 Current absorptionTime BEFORE selecting: \(absorptionTime)")
        #endif

        selectedFoodProduct = product
        downloadProductThumbnail(for: product)

        // Populate food type (truncate to 20 chars to fit RowEmojiTextField maxLength)
        let maxFoodTypeLength = 25
        let foodType: String
        if product.displayName.count > maxFoodTypeLength {
            let truncatedName = String(product.displayName.prefix(maxFoodTypeLength - 1)) + "…"
            foodType = truncatedName
        } else {
            foodType = product.displayName
        }

        // Store serving size context for display
        selectedFoodServingSize = product.servingSizeDisplay

        // Start with 1 serving (user can adjust)
        numberOfServings = 1.0

        // Calculate carbs - but only for real products with valid data
        let carbsQuantity: Double?
        if product.id.hasPrefix("fallback_") {
            // This is a fallback product - don't auto-populate any nutrition data
            carbsQuantity = nil  // Force user to enter manually
            #if DEBUG
            print("🔍 ⚠️ Fallback product selected - carbs must be entered manually")
            #endif
        } else if let carbsPerServing = product.carbsPerServing {
            carbsQuantity = carbsPerServing * numberOfServings
        } else if product.nutriments.carbohydrates > 0 {
            // Use carbs per 100g as base, user can adjust
            carbsQuantity = product.nutriments.carbohydrates * numberOfServings
        } else {
            // No carb data available
            carbsQuantity = nil
        }

        #if DEBUG
        print("🔄 Current absorptionTime AFTER all processing: \(absorptionTime)")
        #endif
        #if DEBUG
        print("🔄 ========== FOOD PRODUCT SELECTION COMPLETE ==========")
        #endif

        // Clear search UI but keep selected product
        foodSearchText = ""
        foodSearchResults = []
        foodSearchError = nil
        showingFoodSearch = false
        foodSearchTask?.cancel()

        // Clear AI-specific state when selecting a non-AI product
        // This ensures AI results don't persist when switching to text/barcode search
        if !product.id.hasPrefix("ai_") {
            lastAIAnalysisResult = nil
            capturedAIImage = nil
            absorptionTimeWasAIGenerated = false  // Clear AI absorption time flag for non-AI products
            os_log("🔄 Cleared AI analysis state when selecting non-AI product: %{public}@",
                   log: OSLog(category: "FoodSearch"),
                   type: .info,
                   product.id)
        }

        os_log("Selected food product: %{public}@ with %{public}g carbs per %{public}@ for %{public}.1f servings",
               log: OSLog(category: "FoodSearch"),
               type: .info,
               product.displayName,
               carbsQuantity ?? 0,
               selectedFoodServingSize ?? "serving",
               numberOfServings)

        // Notify the host about the selection. Macros from product nutriments
        // (when available) drive BolusPro auto-populate.
        let productFat = (product.nutriments.fat ?? 0) * numberOfServings
        let productProtein = (product.nutriments.proteins ?? 0) * numberOfServings
        onNutritionApplied?(FoodFinder_NutritionResult(
            carbs: carbsQuantity ?? 0,
            foodType: foodType,
            absorptionTime: absorptionTime,
            absorptionTimeWasAIGenerated: absorptionTimeWasAIGenerated,
            fat: productFat > 0 ? productFat : nil,
            protein: productProtein > 0 ? productProtein : nil,
            macrosSource: (productFat > 0 || productProtein > 0) ? "product" : nil,
            absorptionReasoning: nil
        ))
    }

    // MARK: - Product Thumbnail Download

    /// Eagerly download the product thumbnail so the view can use a cached UIImage
    /// instead of AsyncImage (which restarts on every SwiftUI view rebuild).
    private func downloadProductThumbnail(for product: OpenFoodFactsProduct) {
        productThumbnailImage = nil
        // Prefer image_thumb_url (~100px) which is the smallest OFF provides
        let urlString = product.imageThumbURL ?? product.imageFrontSmallURL ?? product.imageFrontURL ?? product.imageURL
        guard let urlString, !urlString.isEmpty else { return }
        guard let url = URL(string: urlString) else { return }
        Task {
            let image = await ImageDownloader.fetchThumbnail(from: url, maxDimension: 120)
            await MainActor.run {
                // Only set if this product is still selected
                if self.selectedFoodProduct?.id == product.id {
                    self.productThumbnailImage = image
                }
            }
        }
    }

    // MARK: - Recalculate Carbs for Servings

    /// Recalculate carbohydrates based on number of servings
    /// - Parameter servings: Number of servings
    private func recalculateCarbsForServings(_ servings: Double) {
        guard let selectedFood = selectedFoodProduct else {
            #if DEBUG
            print("🥄 recalculateCarbsForServings: No selected food product")
            #endif
            return
        }

        #if DEBUG
        print("🥄 recalculateCarbsForServings: servings=\(servings), selectedFood=\(selectedFood.displayName)")
        #endif

        // Calculate carbs based on servings - prefer per serving, fallback to per 100g
        let newCarbsQuantity: Double
        if let carbsPerServing = selectedFood.carbsPerServing {
            newCarbsQuantity = carbsPerServing * servings
            #if DEBUG
            print("🥄 Using carbsPerServing: \(carbsPerServing) * \(servings) = \(newCarbsQuantity)")
            #endif
        } else {
            newCarbsQuantity = selectedFood.nutriments.carbohydrates * servings
            #if DEBUG
            print("🥄 Using nutriments.carbohydrates: \(selectedFood.nutriments.carbohydrates) * \(servings) = \(newCarbsQuantity)")
            #endif
        }

        #if DEBUG
        print("🥄 Final carbsQuantity set to: \(newCarbsQuantity)")
        #endif

        // Determine food type from the selected product
        let maxFoodTypeLength = 25
        let foodType: String
        if selectedFood.displayName.count > maxFoodTypeLength {
            foodType = String(selectedFood.displayName.prefix(maxFoodTypeLength - 1)) + "…"
        } else {
            foodType = selectedFood.displayName
        }

        // Notify host of the updated carbs (with optional macros from selected food).
        let foodFat: Double = (selectedFood.fatPerServing ?? selectedFood.nutriments.fat ?? 0) * servings
        let foodProtein: Double = (selectedFood.proteinPerServing ?? selectedFood.nutriments.proteins ?? 0) * servings
        onNutritionApplied?(FoodFinder_NutritionResult(
            carbs: newCarbsQuantity,
            foodType: foodType,
            absorptionTime: absorptionTime,
            absorptionTimeWasAIGenerated: absorptionTimeWasAIGenerated,
            fat: foodFat > 0 ? foodFat : nil,
            protein: foodProtein > 0 ? foodProtein : nil,
            macrosSource: (foodFat > 0 || foodProtein > 0) ? "favorite" : nil,
            absorptionReasoning: nil
        ))

        os_log("Recalculated carbs for %{public}.1f servings: %{public}g",
               log: OSLog(category: "FoodSearch"),
               type: .info,
               servings,
               newCarbsQuantity)
    }

    // MARK: - Skeleton Loading

    /// Create skeleton loading results for immediate feedback
    private func createSkeletonResults() -> [OpenFoodFactsProduct] {
        return (0..<3).map { index in
            var product = OpenFoodFactsProduct(
                id: "skeleton_\(index)",
                productName: "Loading...",
                brands: "Loading...",
                categories: nil,
                nutriments: Nutriments.empty(),
                servingSize: nil,
                servingQuantity: nil,
                imageURL: nil,
                imageFrontURL: nil,
                code: nil,
                dataSource: .unknown,
                isSkeleton: false
            )
            product.isSkeleton = true  // Set skeleton flag
            return product
        }
    }

    // MARK: - Clear / Toggle Helpers

    /// Clear food search state
    func clearFoodSearch() {
        foodSearchText = ""
        foodSearchResults = []
        selectedFoodProduct = nil
        productThumbnailImage = nil
        selectedFoodServingSize = nil
        foodSearchError = nil
        showingFoodSearch = false
        foodSearchTask?.cancel()
        lastBarcodeSearched = nil  // Allow re-scanning the same barcode
    }

    /// Clean up expired cache entries
    private func cleanupExpiredCache() {
        let expiredKeys = searchCache.compactMap { key, value in
            value.isExpired ? key : nil
        }

        for key in expiredKeys {
            searchCache.removeValue(forKey: key)
        }

        if !expiredKeys.isEmpty {
            #if DEBUG
            print("🔍 Cleaned up \(expiredKeys.count) expired cache entries")
            #endif
        }
    }

    /// Clear search cache manually
    func clearSearchCache() {
        searchCache.removeAll()
        #if DEBUG
        print("🔍 Search cache cleared")
        #endif
    }

    /// Toggle food search visibility
    func toggleFoodSearch() {
        showingFoodSearch.toggle()

        if !showingFoodSearch {
            clearFoodSearch()
        }
    }

    /// Clear selected food product and its context
    func clearSelectedFood() {
        selectedFoodProduct = nil
        productThumbnailImage = nil
        selectedFoodServingSize = nil
        numberOfServings = 1.0
        lastAIAnalysisResult = nil
        capturedAIImage = nil
        absorptionTimeWasAIGenerated = false  // Clear AI absorption time flag
        lastBarcodeSearched = nil  // Allow re-scanning the same barcode

        os_log("Cleared selected food product",
               log: OSLog(category: "FoodSearch"),
               type: .info)

        // Notify host that food was cleared
        onFoodCleared?()
    }

    // MARK: - Relevance Sorting

    /// Sort search results so the most obvious/generic match for the query appears first.
    /// E.g. searching "banana" should show "Banana, raw" before "Yogurt Bnine BANANA".
    private func sortByRelevance(_ products: [OpenFoodFactsProduct], query: String) -> [OpenFoodFactsProduct] {
        let q = query.lowercased()

        return products.sorted { a, b in
            relevanceScore(for: a, query: q) > relevanceScore(for: b, query: q)
        }
    }

    // Categories that indicate whole/fresh foods — these should rank high for generic queries
    private static let wholeFoodCategories: Set<String> = [
        "fruits", "vegetables", "fresh", "raw", "legumes", "nuts", "seeds",
        "meats", "poultry", "fish", "seafood", "eggs", "dairy", "milk",
        "cereals", "grains", "rice", "bread", "pasta", "cheese", "yogurt",
        "plant-based-foods", "fresh-foods", "fruits-and-vegetables",
        "tropical-fruits", "berries", "citrus", "en:fruits",
        "en:vegetables", "en:fresh-foods", "en:bananas", "en:apples",
        "en:berries", "en:tropical-fruits", "en:citrus-fruits",
        "en:nuts", "en:legumes", "en:cereals-and-potatoes",
        "en:meats", "en:fishes", "en:eggs", "en:cheeses",
        "en:breads", "en:rice", "en:pastas"
    ]

    // Categories that indicate highly processed/flavored products — penalize for generic queries
    private static let processedCategories: Set<String> = [
        "snacks", "bars", "chips", "cookies", "biscuits", "candy",
        "beverages", "sodas", "juices", "smoothies", "desserts",
        "supplements", "meal-replacements", "sweet-snacks",
        "breakfast-cereals", "sauces", "condiments", "spreads",
        "en:snacks", "en:sweet-snacks", "en:bars", "en:chips",
        "en:biscuits", "en:beverages", "en:desserts",
        "en:breakfast-cereals", "en:sauces-and-condiments",
        "en:meal-replacements", "en:dietary-supplements"
    ]

    private func relevanceScore(for product: OpenFoodFactsProduct, query: String) -> Int {
        let name = product.displayName.lowercased()
        let nameWords = name.split(separator: " ")
            .map { String($0).trimmingCharacters(in: .punctuationCharacters) }
        let queryWords = query.split(separator: " ").map { String($0) }
        let isSingleWordQuery = queryWords.count == 1
        var score = 0

        // --- Tier 1: Name purity (is the product name essentially the query?) ---
        // These are mutually exclusive — take the highest tier hit

        let strippedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let isExact = strippedName == query
        let isPlural = strippedName == query + "s" || strippedName + "s" == query
            || strippedName == query + "es" || strippedName + "es" == query

        if isExact {
            // "banana" == "banana" — perfect
            score += 20000
        } else if isPlural {
            // "bananas" for query "banana" — essentially perfect
            score += 19000
        } else if nameWords.count <= 2 && (name.hasPrefix(query + ",") || name.hasPrefix(query + " ")) {
            // "banana, raw" or "banana fresh" — 1–2 words, query-first
            score += 16000
        } else if nameWords.count <= 2 && nameWords.first.map({ $0 == query || $0 == query + "s" || $0 + "s" == query }) == true {
            // "loose banana" or "organic bananas" — 2 words, query is there
            score += 14000
        } else if name.hasPrefix(query + " ") || name.hasPrefix(query + ",") {
            // "banana chips", "banana chocolate cake" — query-first but more words
            let extraWords = nameWords.count - queryWords.count
            score += 10000 - (extraWords * 500)
        } else if let first = nameWords.first, first.hasPrefix(query) {
            // First word starts with query: "bananas foster"
            score += 8000
        } else if nameWords.contains(query) || nameWords.contains(query + "s") {
            // Query appears as a word somewhere: "dried bananas"
            score += 6000
        } else if name.contains(query) {
            // Query is a substring: "strawberry-banana"
            score += 2000
        }

        // --- Tier 2: Name simplicity (generic foods have short, simple names) ---
        let wordCount = nameWords.count
        if wordCount == 1 { score += 2000 }
        else if wordCount == 2 { score += 1500 }
        else if wordCount <= 3 { score += 800 }
        else { score -= wordCount * 100 }

        // --- Tier 3: Category-based scoring (crucial for generic queries) ---
        if isSingleWordQuery {
            let cats = (product.categories ?? "").lowercased()
            let catTokens = cats.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

            var hasWholeFood = false
            var hasProcessed = false

            for cat in catTokens {
                if Self.wholeFoodCategories.contains(where: { cat.contains($0) }) {
                    hasWholeFood = true
                }
                if Self.processedCategories.contains(where: { cat.contains($0) }) {
                    hasProcessed = true
                }
            }

            if hasWholeFood && !hasProcessed { score += 4000 }
            else if hasWholeFood { score += 1500 }
            if hasProcessed && !hasWholeFood { score -= 3000 }

            // Penalize branded products for generic single-word queries
            if let brands = product.brands, !brands.isEmpty {
                let brandLower = brands.lowercased()
                if !brandLower.contains(query) {
                    score -= 800
                }
            }

            // Penalize names where the query is clearly a flavoring, not the main food
            // e.g. "Yogurt Banana", "Chocolate Banana Cake"
            if let firstWord = nameWords.first, firstWord != query
                && !firstWord.hasPrefix(query) && !(firstWord + "s" == query) {
                score -= 2000
            }
        }

        // --- Tier 4: Nutritional completeness ---
        if product.nutriments.carbohydrates > 0 { score += 300 }

        return score
    }

    // MARK: - Provider Routing Methods

    /// Perform text search using configured provider
    private func performTextSearch(query: String) async throws -> [OpenFoodFactsProduct] {
        // Centralize text search routing and fallbacks in FoodSearchRouter
        return try await FoodSearchRouter.shared.searchFoodsByText(query)
    }

    /// Perform barcode search using configured provider
    private func performBarcodeSearch(barcode: String) async throws -> OpenFoodFactsProduct? {
        let provider = aiService.getProviderForSearchType(.barcodeSearch)


        switch provider {
        case .openFoodFacts:
            if let product = try await openFoodFactsService.fetchProduct(barcode: barcode) {
                // Create a new product with the correct dataSource
                return OpenFoodFactsProduct(
                    id: product.id,
                    productName: product.productName,
                    brands: product.brands,
                    categories: product.categories,
                    nutriments: product.nutriments,
                    servingSize: product.servingSize,
                    servingQuantity: product.servingQuantity,
                    imageURL: product.imageURL,
                    imageFrontURL: product.imageFrontURL,
                    imageFrontSmallURL: product.imageFrontSmallURL,
                    code: product.code,
                    dataSource: .barcodeScan
                )
            }
            return nil

        case .usdaFoodData, .aiProvider:
            // These providers don't support barcode search, fall back to OpenFoodFacts
            if let product = try await openFoodFactsService.fetchProduct(barcode: barcode) {
                return OpenFoodFactsProduct(
                    id: product.id,
                    productName: product.productName,
                    brands: product.brands,
                    categories: product.categories,
                    nutriments: product.nutriments,
                    servingSize: product.servingSize,
                    servingQuantity: product.servingQuantity,
                    imageURL: product.imageURL,
                    imageFrontURL: product.imageFrontURL,
                    imageFrontSmallURL: product.imageFrontSmallURL,
                    code: product.code,
                    dataSource: .barcodeScan
                )
            }
            return nil
        }
    }

    // MARK: - Food Item Management

    /// Hard-remove an item from the plate (distinct from soft exclusion, which
    /// keeps the row visible with its carbs struck through). Used to undo a
    /// mistakenly added item on a mixed plate.
    ///
    /// Setting `lastAIAnalysisResult` fires the recompute observer, which
    /// re-derives the carb total, macros, absorption time and food-type name
    /// from the survivors through the one shared code path — so this no longer
    /// hand-rolls those totals (the old version summed raw carbs and ignored
    /// per-item exclusions and edits). Because state lives on the items, removal
    /// can't misalign a neighbour's override the way index keys did.
    func deleteFoodItem(at index: Int) {
        guard var currentResult = lastAIAnalysisResult,
              currentResult.foodItemsDetailed.indices.contains(index) else {
            return
        }
        currentResult.foodItemsDetailed.remove(at: index)

        // Removing the last item leaves no meal — clear the whole selection so
        // the screen returns to the empty state rather than showing an empty
        // plate with a stale carb total.
        if currentResult.foodItemsDetailed.isEmpty {
            clearSelectedFood()
            return
        }

        lastAIAnalysisResult = currentResult.withRefreshedTotals()
        refreshSyntheticPlateProduct()
    }

    /// Ensures we have an absorption time even if the AI response omitted it.
    func ensureAbsorptionTimeForInitialResult(_ result: inout AIFoodAnalysisResult) {
        if let hours = result.absorptionTimeHours, hours > 0 { return }

        let carbs = result.totalCarbohydrates
        let protein = result.totalProtein ?? result.foodItemsDetailed.compactMap { $0.protein }.reduce(0, +)
        let fat = result.totalFat ?? result.foodItemsDetailed.compactMap { $0.fat }.reduce(0, +)
        let fiber = result.totalFiber ?? result.foodItemsDetailed.compactMap { $0.fiber }.reduce(0, +)
        let calories = result.totalCalories ?? result.foodItemsDetailed.compactMap { $0.calories }.reduce(0, +)

        let (hours, reasoning) = recalculateAbsorptionTime(
            carbs: carbs,
            protein: protein,
            fat: fat,
            fiber: fiber,
            calories: calories,
            remainingItems: result.foodItemsDetailed,
            context: "Estimated from meal composition"
        )

        let defaultHours = defaultAbsorptionTimes.medium / 3600
        if abs(hours - defaultHours) < 0.75 {
            return
        }

        result.absorptionTimeHours = hours
        result.absorptionTimeReasoning = reasoning
    }

    // MARK: - Absorption Time Recalculation

    /// Recalculates absorption time based on remaining meal composition.
    ///
    /// Uses conservative adjustments anchored to Loop's 3-hour default.
    /// Fat/protein slow gastric emptying slightly but don't dramatically extend
    /// carb absorption — they primarily create a secondary glucose rise that
    /// Loop's prediction algorithm handles separately. Most mixed meals should
    /// land between 3–4 hours; only exceptionally heavy meals warrant 4.5–5.
    private func recalculateAbsorptionTime(
        carbs: Double,
        protein: Double,
        fat: Double,
        fiber: Double,
        calories: Double,
        remainingItems: [FoodItemAnalysis],
        context: String
    ) -> (hours: Double, reasoning: String) {

        // Baseline: 3 hours is Loop's well-tested default for most meals.
        // Only low-carb snacks get a shorter baseline.
        let baselineHours: Double = carbs <= 15 ? 2.5 : 3.0

        // Fat/Protein Units — conservative adjustments.
        // Fat and protein slow gastric emptying modestly, but the bulk of
        // their glucose effect is a secondary rise hours later that Loop
        // models separately. We only nudge absorption time slightly.
        let fpuValue = (fat + protein) / 10.0
        let fpuAdjustment: Double
        let fpuDescription: String

        if fpuValue < 2.0 {
            fpuAdjustment = 0.0
            fpuDescription = "Low FPU (\(String(format: "%.1f", fpuValue))) — no meaningful extension"
        } else if fpuValue < 4.0 {
            fpuAdjustment = 0.5
            fpuDescription = "Medium FPU (\(String(format: "%.1f", fpuValue))) — slight gastric emptying delay"
        } else {
            fpuAdjustment = 1.5
            fpuDescription = "High FPU (\(String(format: "%.1f", fpuValue))) — significant gastric emptying delay (pizza/nachos pattern)"
        }

        // Fiber — modest effect on absorption speed.
        // High fiber flattens the glucose curve (more gradual rise) but
        // doesn't dramatically extend total absorption duration.
        let fiberAdjustment: Double
        let fiberDescription: String

        if fiber > 8.0 {
            fiberAdjustment = 0.5
            fiberDescription = "High fiber (\(String(format: "%.1f", fiber))g) — slows gastric emptying modestly"
        } else if fiber > 5.0 {
            fiberAdjustment = 0.25
            fiberDescription = "Moderate fiber (\(String(format: "%.1f", fiber))g) — slight slowing effect"
        } else {
            fiberAdjustment = 0.0
            fiberDescription = "Low fiber (\(String(format: "%.1f", fiber))g) — no meaningful impact"
        }

        // Meal size — minor effect on gastric emptying.
        // Very large meals slow stomach emptying, but the effect is modest
        // compared to what the old model assumed.
        let mealSizeAdjustment: Double
        let mealSizeDescription: String

        if calories > 800 {
            mealSizeAdjustment = 0.5
            mealSizeDescription = "Large meal (\(String(format: "%.0f", calories)) cal) — slightly slower gastric emptying"
        } else if calories > 400 {
            mealSizeAdjustment = 0.25
            mealSizeDescription = "Medium meal (\(String(format: "%.0f", calories)) cal) — minimal impact"
        } else {
            mealSizeAdjustment = 0.0
            mealSizeDescription = "Small meal (\(String(format: "%.0f", calories)) cal) — no impact"
        }

        // Total: capped at 2–6 hours (extended from 5h to accommodate high-fat meals like pizza)
        let totalHours = min(max(baselineHours + fpuAdjustment + fiberAdjustment + mealSizeAdjustment, 2.0), 6.0)

        // Generate detailed reasoning
        let reasoning = "\(context): " +
                       "BASELINE: \(String(format: "%.1f", baselineHours)) hours for \(String(format: "%.1f", carbs))g carbs. " +
                       "FPU IMPACT: \(fpuDescription) (+\(String(format: "%.1f", fpuAdjustment)) hr). " +
                       "FIBER EFFECT: \(fiberDescription) (+\(String(format: "%.1f", fiberAdjustment)) hr). " +
                       "MEAL SIZE: \(mealSizeDescription) (+\(String(format: "%.1f", mealSizeAdjustment)) hr). " +
                       "TOTAL: \(String(format: "%.1f", totalHours)) hours."

        return (totalHours, reasoning)
    }
}
