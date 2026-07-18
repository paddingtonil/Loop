//
//  FoodFinder_AnalysisRecord.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  FoodFinder — Codable record for a single AI food analysis,
//  used by the Analysis History feature for quick re-entry.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import Foundation

struct FoodFinder_AnalysisRecord: Codable, Identifiable, Equatable {
    static func == (lhs: FoodFinder_AnalysisRecord, rhs: FoodFinder_AnalysisRecord) -> Bool {
        lhs.id == rhs.id
    }

    let id: String
    let name: String
    let carbsGrams: Double
    let foodType: String
    let absorptionTime: TimeInterval
    let analysisType: AnalysisType
    let date: Date
    let thumbnailID: String?
    let analysisResult: AIFoodAnalysisResult?

    // MARK: - LoopInsights Preparation
    //
    // These fields capture what the AI originally suggested vs what the user
    // actually entered. The delta between them is the single most valuable
    // signal for LoopInsights: it reveals systematic over/under-estimation
    // by food type, time of day, or confidence level — which directly informs
    // Carb Ratio and ISF tuning recommendations.

    /// The AI's original carb estimate before any user edits (nil for legacy records).
    let originalAICarbs: Double?

    /// The confidence percentage the AI reported (nil for legacy records).
    let aiConfidencePercent: Int?

    /// GPS latitude at time of analysis (nil if location tagging disabled or unavailable).
    let latitude: Double?

    /// GPS longitude at time of analysis (nil if location tagging disabled or unavailable).
    let longitude: Double?

    /// Reverse-geocoded venue name (e.g. "McDonald's") at time of analysis.
    let locationName: String?

    enum AnalysisType: String, Codable {
        case image
        case dictation
        case barcode
        case mfpImport
    }

    /// Returns a copy carrying the user's current plate — edited item values,
    /// exclusions and serving changes — while keeping this record's identity.
    ///
    /// `originalAICarbs`, `aiConfidencePercent` and the location fields are
    /// deliberately carried over untouched: they capture what the AI said at
    /// analysis time, and the delta against `carbsGrams` is exactly the signal
    /// LoopInsights uses to spot systematic AI over/under-estimation. Folding an
    /// edit into them would erase the evidence that the user disagreed.
    func withUpdatedPlate(
        name: String,
        carbsGrams: Double,
        foodType: String,
        absorptionTime: TimeInterval,
        analysisResult: AIFoodAnalysisResult?
    ) -> FoodFinder_AnalysisRecord {
        FoodFinder_AnalysisRecord(
            id: id,
            name: name,
            carbsGrams: carbsGrams,
            foodType: foodType,
            absorptionTime: absorptionTime,
            analysisType: analysisType,
            date: date,
            thumbnailID: thumbnailID,
            analysisResult: analysisResult,
            originalAICarbs: originalAICarbs,
            aiConfidencePercent: aiConfidencePercent,
            latitude: latitude,
            longitude: longitude,
            locationName: locationName
        )
    }

    /// Returns a copy with a new UUID (and optional updated date). Used when
    /// re-using a past analysis: dedup-by-ID would otherwise treat the new
    /// meal as already archived and silently drop it.
    func withFreshID(date: Date? = nil) -> FoodFinder_AnalysisRecord {
        FoodFinder_AnalysisRecord(
            id: UUID().uuidString,
            name: name,
            carbsGrams: carbsGrams,
            foodType: foodType,
            absorptionTime: absorptionTime,
            analysisType: analysisType,
            date: date ?? self.date,
            thumbnailID: thumbnailID,
            analysisResult: analysisResult,
            originalAICarbs: originalAICarbs,
            aiConfidencePercent: aiConfidencePercent,
            latitude: latitude,
            longitude: longitude,
            locationName: locationName
        )
    }
}
