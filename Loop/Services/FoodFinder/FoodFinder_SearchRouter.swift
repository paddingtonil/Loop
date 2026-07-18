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

    /// Perform text-based food search using the configured provider.
    ///
    /// Hebrew queries are intercepted first — see `searchIsraeliDatabase`.
    func searchFoodsByText(_ query: String) async throws -> [OpenFoodFactsProduct] {
        let provider = aiService.getProviderForSearchType(.textSearch)

        // Fetch extra candidates so client-side relevance sorting has more to work with
        let fetchSize = 50

        // Hebrew goes to the Israeli national food database first, whatever the
        // configured provider is: OpenFoodFacts and USDA index English/Latin
        // names preferentially and match Hebrew terms poorly. On error or no
        // match we fall through to the configured provider below.
        if Self.containsHebrew(query) {
            if let products = await searchIsraeliDatabase(query, pageSize: fetchSize) {
                return products
            }
        }

        log.info("🔍 Routing text search '%{public}@' to provider: %{public}@", query, provider.rawValue)

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

    // MARK: - Hebrew Query Routing

    /// True if the text contains any character in the Hebrew Unicode block
    /// (U+0590–U+05FF: letters, niqqud and Hebrew punctuation).
    static func containsHebrew(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0590...0x05FF).contains($0.value) }
    }

    /// Try the Israeli database for a Hebrew query.
    /// - Returns: The products on a successful, non-empty match; `nil` when the
    ///   caller should fall back to the configured provider (error or no match).
    private func searchIsraeliDatabase(_ query: String, pageSize: Int) async -> [OpenFoodFactsProduct]? {
        log.info("🇮🇱 Hebrew query '%{public}@' — routing to Israeli food database", query)

        do {
            let products = try await IsraeliFoodDataService.shared.searchProducts(query: query, pageSize: pageSize)
            if products.isEmpty {
                log.info("ℹ️ Israeli database had no match for '%{public}@' — falling back", query)
                return nil
            }
            return products
        } catch {
            log.error("❌ Israeli database search failed: %{public}@ — falling back",
                      error.localizedDescription)
            return nil
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

    // MARK: Barcode Search Implementations
    
    
    
}
