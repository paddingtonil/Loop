//
//  FoodFinder_SearchRouter.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  FoodFinder — Routes food search queries to the appropriate data source.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import UIKit
import Foundation
import os.log

/// Service that routes different types of food searches to the appropriate configured provider
class FoodSearchRouter {
    
    // MARK: - Singleton
    
    static let shared = FoodSearchRouter()
    
    private init() {}
    
    // MARK: - Properties
    
    private let log = OSLog(category: "FoodSearchRouter")
    private let aiService = ConfigurableAIService.shared
    private let openFoodFactsService = OpenFoodFactsService() // Uses optimized configuration by default
    
    // MARK: - Text/Voice Search Routing

    /// Perform text-based food search using the configured provider
    func searchFoodsByText(_ query: String) async throws -> [OpenFoodFactsProduct] {
        let provider = aiService.getProviderForSearchType(.textSearch)

        log.info("🔍 Routing text search '%{public}@' to provider: %{public}@", query, provider.rawValue)

        // Fetch extra candidates so client-side relevance sorting has more to work with
        let fetchSize = 50

        switch provider {
        case .openFoodFacts:
            return try await openFoodFactsService.searchProducts(query: query, pageSize: fetchSize)

        case .usdaFoodData:
            do {
                return try await USDAFoodDataService.shared.searchProducts(query: query, pageSize: fetchSize)
            } catch {
                log.error("❌ USDA search failed: %{public}@ — falling back to OpenFoodFacts", error.localizedDescription)
                return try await openFoodFactsService.searchProducts(query: query, pageSize: fetchSize)
            }

        case .aiProvider:
            // AI providers are not used for text search; use USDA with OFF fallback
            log.info("ℹ️ AI provider not used for text search; using USDA with OFF fallback")
            do {
                return try await USDAFoodDataService.shared.searchProducts(query: query, pageSize: fetchSize)
            } catch {
                return try await openFoodFactsService.searchProducts(query: query, pageSize: fetchSize)
            }
        }
    }

    // MARK: - Barcode Search Routing

    /// Perform barcode-based food search using the configured provider
    func searchFoodsByBarcode(_ barcode: String) async throws -> OpenFoodFactsProduct? {
        let provider = aiService.getProviderForSearchType(.barcodeSearch)

        log.info("📱 Routing barcode search '%{public}@' to provider: %{public}@", barcode, provider.rawValue)

        switch provider {
        case .openFoodFacts:
            return try await openFoodFactsService.fetchProduct(barcode: barcode)

        case .usdaFoodData, .aiProvider:
            // These providers don't support barcode search, fall back to OpenFoodFacts
            log.info("⚠️ %{public}@ doesn't support barcode search, falling back to OpenFoodFacts", provider.rawValue)
            return try await openFoodFactsService.fetchProduct(barcode: barcode)
        }
    }

    // MARK: - AI Image Search Routing

    /// Perform AI image analysis using the configured BYO provider
    func analyzeFood(image: UIImage) async throws -> AIFoodAnalysisResult {
        log.info("🤖 Routing AI image analysis to configured BYO provider")

        guard let config = UserDefaults.standard.activeAIProviderConfiguration else {
            throw AIFoodAnalysisError.noApiKey
        }
        guard !config.apiKey.isEmpty else {
            throw AIFoodAnalysisError.noApiKey
        }

        let prompt = getAnalysisPrompt()
        return try await AIServiceManager.shared.analyzeFoodImage(
            image,
            using: config,
            query: prompt
        )
    }

    // MARK: - Voice / Generative Text Search Routing

    /// Perform AI-based food analysis from a text description (voice search).
    /// Routes through the same AI provider and prompt infrastructure as image analysis,
    /// using a placeholder image with the user's description as context.
    func analyzeFoodByDescription(_ description: String) async throws -> AIFoodAnalysisResult {
        let basePrompt = getAnalysisPrompt()
        let locationContext = FoodFinder_LocationService.shared.locationContextForPrompt()
        let voiceContext = "\(basePrompt)\(locationContext)\n\nThe user described their food verbally: \"\(description)\". There is no photo — analyze the food based solely on this text description. Provide the same detailed nutritional analysis you would for a food photo."

        log.info("🎙️ Routing voice/generative search '%{public}@' to configured BYO provider", description)

        guard let config = UserDefaults.standard.activeAIProviderConfiguration else {
            throw AIFoodAnalysisError.noApiKey
        }
        guard !config.apiKey.isEmpty else {
            throw AIFoodAnalysisError.noApiKey
        }

        return try await AIServiceManager.shared.analyzeFoodByText(
            using: config,
            query: voiceContext
        )
    }

    // MARK: - Re-evaluation With User Corrections

    /// Re-run the AI analysis after the user corrected one or more detected items.
    /// Sends the original photo (when available) together with the previous analysis
    /// and the user's edits, and asks the model to treat those edits as ground truth,
    /// re-research the nutrition data, and return a full revised analysis.
    func reevaluateFood(image: UIImage?, previous: AIFoodAnalysisResult, excludedIndices: Set<Int>) async throws -> AIFoodAnalysisResult {
        guard let config = UserDefaults.standard.activeAIProviderConfiguration else {
            throw AIFoodAnalysisError.noApiKey
        }
        guard !config.apiKey.isEmpty else {
            throw AIFoodAnalysisError.noApiKey
        }

        let prompt = getAnalysisPrompt()
            + FoodFinder_LocationService.shared.locationContextForPrompt()
            + FoodSearchRouter.correctionsContext(previous: previous, excludedIndices: excludedIndices, hasPhoto: image != nil)

        log.info("✏️ Re-evaluating analysis with user corrections (photo: %{public}@)", image != nil ? "yes" : "no")

        let revised: AIFoodAnalysisResult
        if let image = image {
            revised = try await AIServiceManager.shared.analyzeFoodImage(image, using: config, query: prompt)
        } else {
            revised = try await AIServiceManager.shared.analyzeFoodByText(using: config, query: prompt)
        }
        return FoodSearchRouter.carryOverUserEdits(into: revised, from: previous)
    }

    /// Builds the prompt addendum describing the previous analysis and the user's corrections.
    /// Only the fields the user actually changed are marked authoritative; every other number is
    /// labelled as a stale AI estimate that must be recomputed from the corrected description/weight.
    static func correctionsContext(previous: AIFoodAnalysisResult, excludedIndices: Set<Int>, hasPhoto: Bool) -> String {
        func num(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "unknown" }

        var lines: [String] = []
        for (index, item) in previous.foodItemsDetailed.enumerated() {
            if excludedIndices.contains(index) {
                lines.append("\(index + 1). \"\(item.name)\" — REMOVED by the user (not eaten). Leave it out of the revised analysis.")
                continue
            }
            let fields = Set(item.editedFields ?? [])
            var corrections: [String] = []
            if fields.contains("name") { corrections.append("name = \"\(item.name)\"") }
            if fields.contains("description"), let d = item.userDescription, !d.isEmpty { corrections.append("description = \"\(d)\"") }
            if fields.contains("portion") { corrections.append("portion = \"\(item.portionEstimate)\"") }
            if fields.contains("weight"), let g = item.weightGrams { corrections.append("weight = \(num(g)) g") }
            if fields.contains("carbs") { corrections.append("carbs = \(num(item.carbohydrates)) g") }
            if fields.contains("calories") { corrections.append("calories = \(num(item.calories))") }
            if fields.contains("fat") { corrections.append("fat = \(num(item.fat)) g") }
            if fields.contains("fiber") { corrections.append("fiber = \(num(item.fiber)) g") }
            if fields.contains("protein") { corrections.append("protein = \(num(item.protein)) g") }

            var line = "\(index + 1). \"\(item.name)\""
            if corrections.isEmpty {
                line += " — no user changes. Previous AI estimate: portion \(item.portionEstimate); carbs \(num(item.carbohydrates)) g, calories \(num(item.calories)), fat \(num(item.fat)) g, fiber \(num(item.fiber)) g, protein \(num(item.protein)) g."
            } else {
                line += "\n   USER CORRECTIONS (authoritative, do not override): " + corrections.joined(separator: "; ")
                let nutritionPinned = !fields.isDisjoint(with: ["carbs", "calories", "fat", "fiber", "protein"])
                line += "\n   Previous AI estimate (STALE for anything the corrections affect — recompute, do not copy): portion \(item.portionEstimate); carbs \(num(item.carbohydrates)) g, calories \(num(item.calories)), fat \(num(item.fat)) g, fiber \(num(item.fiber)) g, protein \(num(item.protein)) g."
                if !nutritionPinned {
                    line += "\n   The user did NOT set nutrition values for this item: derive ALL of its nutrition afresh from the corrected food."
                }
            }
            lines.append(line)
        }

        let source = hasPhoto ? "the photo" : "the item list below (no photo is available)"
        return """


        THE USER HAS REVIEWED YOUR PREVIOUS ANALYSIS AND CORRECTED IT.
        Re-evaluate the whole meal using \(source) together with the user's corrections below.
        Rules:
        - Fields listed under USER CORRECTIONS are facts supplied by the user and override what you see in the photo. If the user's description contradicts the photo (e.g. the user says the rice is cauliflower rice), trust the user.
        - Every field that is NOT listed under USER CORRECTIONS must be recomputed from the corrected food, description, portion and weight. Never reuse a previous number just because it appeared before: a changed ingredient or weight must change the nutrition (e.g. cauliflower rice has far fewer carbs than white rice).
        - If the user gave a weight in grams, compute nutrition for exactly that weight using per-100 g values for that food (e.g. USDA FoodData Central).
        - Items marked REMOVED are not eaten. Items with no user changes may still be adjusted if the corrections make them inconsistent.
        - Return the complete analysis in the same JSON format as before, with revised totals, confidence, and absorption time. In your notes, say briefly what changed because of the user's corrections.

        Previous analysis and user corrections:
        \(lines.joined(separator: "\n"))
        """
    }

    /// The revised analysis comes back without the user-only fields; restore them by item name.
    static func carryOverUserEdits(into revised: AIFoodAnalysisResult, from previous: AIFoodAnalysisResult) -> AIFoodAnalysisResult {
        var result = revised
        let edited = previous.foodItemsDetailed.filter { $0.userEdited == true }
        for (i, item) in result.foodItemsDetailed.enumerated() {
            let key = item.name.trimmingCharacters(in: .whitespaces).lowercased()
            if let match = edited.first(where: { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == key }) {
                result.foodItemsDetailed[i].weightGrams = match.weightGrams
                result.foodItemsDetailed[i].userDescription = match.userDescription
                result.foodItemsDetailed[i].userEdited = true
                result.foodItemsDetailed[i].editedFields = match.editedFields
            }
        }
        return result
    }

    // MARK: Barcode Search Implementations
    
    
    
}
