//
//  FoodFinder_SpoonacularService.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  FoodFinder — Restaurant menu lookup via the Spoonacular free-tier API.
//  When GPS confirms the user within 200 ft of a (chain) restaurant, we pull
//  that chain's menu items so the user can tap their dish and use authoritative
//  menu nutrition — skipping the pricier AI image analysis to save tokens.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import Foundation
import os.log

/// Thin client for Spoonacular's menu-items endpoints. Free tier: BYO key,
/// rate-limited daily points. Chain-focused — local/independent restaurants
/// usually return nothing, in which case the caller falls back to AI analysis.
final class FoodFinder_SpoonacularService {

    // MARK: - Singleton

    static let shared = FoodFinder_SpoonacularService()
    private init() {}

    private let base = "https://api.spoonacular.com"
    private let log = OSLog(category: "FoodFinder_Spoonacular")

    // MARK: - Configuration

    /// True when the user has saved a Spoonacular key.
    var isConfigured: Bool {
        !(FoodFinder_SecureStorage.loadSpoonacularKey() ?? "").isEmpty
    }

    // MARK: - Models

    /// A single menu item as returned by `/food/menuItems/search`.
    struct MenuItem: Identifiable, Decodable, Equatable {
        let id: Int
        let title: String
        let restaurantChain: String?
        let image: String?
    }

    private struct SearchResponse: Decodable {
        let menuItems: [MenuItem]
    }

    // MARK: - Errors

    enum SpoonacularError: LocalizedError {
        case notConfigured
        case invalidURL
        case quotaExceeded
        case server(Int)
        case decoding(Error)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "No Spoonacular API key configured."
            case .invalidURL: return "Could not build the Spoonacular request URL."
            case .quotaExceeded: return "Spoonacular daily free-tier quota reached."
            case .server(let code): return "Spoonacular returned an error (status \(code))."
            case .decoding(let e): return "Could not read the Spoonacular response: \(e.localizedDescription)"
            }
        }
    }

    // MARK: - Validation

    /// Verifies the saved key with a cheap `/food/menuItems/search` request so
    /// the user learns a bad key in Settings, not while standing in a restaurant.
    /// Succeeds even when zero items match (auth is what we're checking); throws
    /// `SpoonacularError` — notably `.server(401)` for a rejected key — otherwise.
    func validateSavedKey() async throws {
        _ = try await performSearch(query: "test", rankVenue: "test", number: 1)
    }

    // MARK: - Menu Search

    /// Searches Spoonacular for menu items matching `restaurant`. Returns items
    /// whose `restaurantChain` plausibly matches the venue first, then any
    /// remaining matches. Empty array means "no menu found — fall back to AI".
    func searchMenuItems(restaurant: String, number: Int = 30) async throws -> [MenuItem] {
        try await performSearch(query: restaurant, rankVenue: restaurant, number: number)
    }

    /// Searches for a specific dish the user typed at a given restaurant. The
    /// query combines both ("Chipotle Chicken Burrito") so Spoonacular narrows to
    /// that chain's matching item; results are ranked so the restaurant's own
    /// items surface first. Empty array means "no match — offer AI fallback".
    func searchMenuItems(restaurant: String, item: String, number: Int = 25) async throws -> [MenuItem] {
        let trimmedItem = item.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = trimmedItem.isEmpty ? restaurant : "\(restaurant) \(trimmedItem)"
        return try await performSearch(query: query, rankVenue: restaurant, number: number)
    }

    /// Runs a `/food/menuItems/search` request and ranks results by chain match.
    private func performSearch(query: String, rankVenue: String, number: Int) async throws -> [MenuItem] {
        guard let key = FoodFinder_SecureStorage.loadSpoonacularKey(), !key.isEmpty else {
            throw SpoonacularError.notConfigured
        }
        var components = URLComponents(string: "\(base)/food/menuItems/search")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "number", value: String(number)),
            URLQueryItem(name: "apiKey", value: key)
        ]
        guard let url = components?.url else { throw SpoonacularError.invalidURL }

        let items = try await get(url, as: SearchResponse.self).menuItems
        return rankByChainMatch(items, venue: rankVenue)
    }

    /// Fetches full nutrition for a menu item and converts it into the same
    /// `AIFoodAnalysisResult` the camera/text flows use to populate carb entry.
    func fetchNutrition(itemId: Int, fallbackName: String) async throws -> AIFoodAnalysisResult {
        guard let key = FoodFinder_SecureStorage.loadSpoonacularKey(), !key.isEmpty else {
            throw SpoonacularError.notConfigured
        }
        guard let url = URL(string: "\(base)/food/menuItems/\(itemId)?apiKey=\(key)") else {
            throw SpoonacularError.invalidURL
        }

        // Decode loosely — Spoonacular's nutrient list is the stable part.
        let detail = try await get(url, as: MenuItemDetail.self)
        return Self.makeResult(from: detail, fallbackName: fallbackName)
    }

    // MARK: - Networking

    private func get<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200...299: break
            case 402, 429: throw SpoonacularError.quotaExceeded
            default: throw SpoonacularError.server(http.statusCode)
            }
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            os_log("Decode failed: %{public}@", log: log, type: .error, error.localizedDescription)
            throw SpoonacularError.decoding(error)
        }
    }

    // MARK: - Ranking

    /// Prefer items whose chain shares a meaningful word with the venue name so
    /// "Chipotle Mexican Grill" surfaces ahead of unrelated query matches.
    private func rankByChainMatch(_ items: [MenuItem], venue: String) -> [MenuItem] {
        let venueWords = significantWords(venue)
        func score(_ item: MenuItem) -> Int {
            guard let chain = item.restaurantChain else { return 0 }
            let chainWords = significantWords(chain)
            return venueWords.intersection(chainWords).isEmpty ? 0 : 1
        }
        return items.sorted { score($0) > score($1) }
    }

    private func significantWords(_ s: String) -> Set<String> {
        let stop: Set<String> = ["the", "and", "shop", "restaurant", "grill", "cafe", "bar", "kitchen", "co", "inc"]
        return Set(
            s.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 && !stop.contains($0) }
        )
    }

    // MARK: - Detail decoding + mapping

    private struct MenuItemDetail: Decodable {
        let id: Int
        let title: String
        let restaurantChain: String?
        let nutrition: Nutrition?
        let servings: Servings?

        struct Nutrition: Decodable {
            let nutrients: [Nutrient]
        }
        struct Nutrient: Decodable {
            let name: String
            let amount: Double
            let unit: String?
        }
        struct Servings: Decodable {
            let number: Double?
        }
    }

    private static func amount(_ detail: MenuItemDetail, _ name: String) -> Double? {
        detail.nutrition?.nutrients.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.amount
    }

    /// Builds a single-item `AIFoodAnalysisResult` from a menu item's nutrients.
    /// Carbs are the per-item totals from the menu (serving multiplier 1.0), so
    /// they populate carb entry directly — no scaling.
    private static func makeResult(from detail: MenuItemDetail, fallbackName: String) -> AIFoodAnalysisResult {
        let name = detail.title.isEmpty ? fallbackName : detail.title
        let carbs = amount(detail, "Carbohydrates") ?? 0
        let protein = amount(detail, "Protein")
        let fat = amount(detail, "Fat")
        let fiber = amount(detail, "Fiber")
        let calories = amount(detail, "Calories")

        let titled = detail.restaurantChain.map { "\(name) – \($0)" } ?? name

        let item = FoodItemAnalysis(
            name: titled,
            portionEstimate: "1 menu serving",
            usdaServingSize: nil,
            servingMultiplier: 1.0,
            preparationMethod: nil,
            visualCues: nil,
            carbohydrates: carbs,
            calories: calories,
            fat: fat,
            fiber: fiber,
            protein: protein,
            assessmentNotes: "Spoonacular menu lookup",
            absorptionTimeHours: nil
        )

        let chainNote = detail.restaurantChain.map { "📍 Menu nutrition from \($0) via Spoonacular. " } ?? ""

        return AIFoodAnalysisResult(
            imageType: .menuItem,
            foodItemsDetailed: [item],
            overallDescription: titled,
            confidence: .high,
            numericConfidence: nil,
            totalFoodPortions: 1,
            totalUsdaServings: 1.0,
            totalCarbohydrates: carbs,
            totalProtein: protein,
            totalFat: fat,
            totalFiber: fiber,
            totalCalories: calories,
            portionAssessmentMethod: "Restaurant menu lookup",
            diabetesConsiderations: chainNote.isEmpty ? nil : chainNote,
            visualAssessmentDetails: nil,
            notes: nil,
            originalServings: 1.0,
            fatProteinUnits: nil,
            netCarbsAdjustment: nil,
            insulinTimingRecommendations: nil,
            fpuDosingGuidance: nil,
            exerciseConsiderations: nil,
            absorptionTimeHours: nil,
            absorptionTimeReasoning: nil,
            mealSizeImpact: nil,
            individualizationFactors: nil,
            safetyAlerts: nil
        )
    }
}
