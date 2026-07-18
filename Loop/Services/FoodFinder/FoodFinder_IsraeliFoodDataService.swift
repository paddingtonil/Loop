//
//  FoodFinder_IsraeliFoodDataService.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  FoodFinder — Israeli Ministry of Health national food composition database
//  (data.gov.il CKAN datastore) client.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import Foundation
import os.log

/// Client for the Israeli Ministry of Health national food composition database,
/// published as a CKAN datastore resource on data.gov.il.
///
/// Hebrew food names are indexed natively here. OpenFoodFacts and USDA index
/// English/Latin names preferentially and match Hebrew terms poorly, so
/// `FoodSearchRouter` sends Hebrew queries here first regardless of the
/// configured provider, falling back to those sources on error or no match.
///
/// Every nutrient column in this dataset is expressed per 100 g of edible
/// portion, so products are emitted with `servingQuantity: 100` — the same
/// convention `USDAFoodDataService` uses.
class IsraeliFoodDataService {

    // MARK: - Singleton

    static let shared = IsraeliFoodDataService()

    // MARK: - Properties

    private let baseURL = "https://data.gov.il/api/3/action/datastore_search"
    private let resourceID = "c3cb0630-0650-46c1-a068-82d575c094b2"
    private let timeout: TimeInterval = 10
    private let session: URLSession
    private let log = OSLog(category: "IsraeliFoodDataService")

    /// Shown in the `brands` slot so a result's origin is obvious in the list.
    static let sourceName = "משרד הבריאות – מאגר המזון הלאומי"

    // MARK: - Initialization

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.waitsForConnectivity = true
        config.allowsCellularAccess = true
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Search the Israeli food database by name (Hebrew or English).
    /// - Parameters:
    ///   - query: Search text — matched full-text across the dataset's fields.
    ///   - pageSize: Maximum number of records to request.
    /// - Returns: Matching foods mapped to `OpenFoodFactsProduct` for UI compatibility.
    func searchProducts(query: String, pageSize: Int = 25) async throws -> [OpenFoodFactsProduct] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return []
        }

        guard var components = URLComponents(string: baseURL) else {
            throw OpenFoodFactsError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "resource_id", value: resourceID),
            URLQueryItem(name: "q", value: trimmedQuery),
            URLQueryItem(name: "limit", value: String(min(max(pageSize, 1), 100)))
        ]

        guard let url = components.url else {
            throw OpenFoodFactsError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Loop-iOS-Diabetes-App/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout

        os_log("Searching Israeli food database for: %{public}@", log: log, type: .info, trimmedQuery)

        do {
            try Task.checkCancellation()

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw OpenFoodFactsError.invalidResponse
            }

            switch httpResponse.statusCode {
            case 200:
                break
            case 429:
                throw OpenFoodFactsError.rateLimitExceeded
            default:
                os_log("Israeli DB HTTP error: %d", log: log, type: .error, httpResponse.statusCode)
                throw OpenFoodFactsError.serverError(httpResponse.statusCode)
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw OpenFoodFactsError.decodingError(
                    NSError(domain: "IsraeliFoodData", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Invalid JSON response"])
                )
            }

            // CKAN reports failures in-band with a 200 status.
            guard let success = json["success"] as? Bool, success else {
                os_log("Israeli DB reported success=false", log: log, type: .error)
                throw OpenFoodFactsError.serverError(200)
            }

            guard let result = json["result"] as? [String: Any],
                  let records = result["records"] as? [[String: Any]] else {
                throw OpenFoodFactsError.noData
            }

            try Task.checkCancellation()

            let products = records.compactMap { record -> OpenFoodFactsProduct? in
                if Task.isCancelled { return nil }
                return convertRecordToProduct(record)
            }

            os_log("Israeli DB returned %d usable products (of %d records)",
                   log: log, type: .info, products.count, records.count)

            return products

        } catch is CancellationError {
            // Expected during rapid typing — the caller replaces the task.
            return []
        } catch let urlError as URLError where urlError.code == .cancelled {
            return []
        } catch let error as OpenFoodFactsError {
            throw error
        } catch {
            os_log("Israeli DB search failed: %{public}@", log: log, type: .error, error.localizedDescription)
            throw OpenFoodFactsError.networkError(error)
        }
    }

    // MARK: - Mapping

    /// Convert one dataset record into an `OpenFoodFactsProduct`.
    ///
    /// All nutrient columns are per 100 g, which maps directly onto `Nutriments`
    /// (itself a per-100 g model), so no rescaling is needed here.
    private func convertRecordToProduct(_ record: [String: Any]) -> OpenFoodFactsProduct? {
        // Prefer the Hebrew name — it's why this source exists.
        let hebrewName = string(record["shmmitzrach"])
        let englishName = string(record["english_name"])
        guard let name = hebrewName ?? englishName else {
            return nil
        }

        // Carbohydrates drive dosing, so a record without them is unusable.
        // A legitimate zero (oil, water) is kept — only a missing value is dropped.
        guard let carbs = numeric(record["carbohydrates"]) else {
            return nil
        }

        let protein = numeric(record["protein"])
        let fat = numeric(record["total_fat"])
        let energy = numeric(record["food_energy"])
        let sugars = numeric(record["total_sugars"])
        let fiber = numeric(record["total_dietary_fiber"])

        let nutriments = Nutriments(
            carbohydrates: carbs,
            proteins: protein,
            fat: fat,
            calories: energy,
            sugars: sugars,
            fiber: fiber,
            energy: energy
        )

        // `smlmitzrach` is the dataset's food code; `_id` is the row number.
        let identifier = numeric(record["smlmitzrach"]).map { String(Int($0)) }
            ?? numeric(record["_id"]).map { String(Int($0)) }
            ?? UUID().uuidString

        // Keep the English name as a subtitle when we led with Hebrew.
        let categories: String?
        if hebrewName != nil, let englishName = englishName {
            categories = englishName
        } else {
            categories = nil
        }

        return OpenFoodFactsProduct(
            id: identifier,
            productName: name,
            brands: Self.sourceName,
            categories: categories,
            nutriments: nutriments,
            servingSize: "100g",
            servingQuantity: 100.0,
            imageURL: nil,
            imageFrontURL: nil,
            code: identifier
        )
    }

    // MARK: - Field Parsing

    /// The dataset mixes numbers, numeric strings, empty strings and nulls.
    private func numeric(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : Double(trimmed)
        default:
            return nil
        }
    }

    /// Non-empty trimmed string, or nil.
    private func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
