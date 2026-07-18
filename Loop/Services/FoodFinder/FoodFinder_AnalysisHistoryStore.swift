//
//  FoodFinder_AnalysisHistoryStore.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  FoodFinder — Persistence and cleanup for AI analysis history records.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import Foundation

// MARK: - LoopInsights Notification
//
// Posted every time FoodFinder records a meal analysis. LoopInsights (or any
// future feature) can observe this to correlate meal events with BG data in
// real-time, without importing any FoodFinder view code.
//
// userInfo keys:
//   "recordID" — String, the FoodFinder_AnalysisRecord.id that was just saved.

extension Notification.Name {
    static let foodFinderMealLogged = Notification.Name("com.loopkit.Loop.foodFinderMealLogged")
    static let foodFinderMealAnalyzed = Notification.Name("com.loopkit.Loop.foodFinderMealAnalyzed")
    /// Posted when user taps "Re-use" in FoodFinder Settings. StatusTableViewController
    /// observes this to dismiss Settings and present Add Carb Entry with the record pre-filled.
    static let foodFinderReUseAnalysis = Notification.Name("com.loopkit.Loop.foodFinderReUseAnalysis")
}

// MARK: - MealDataProvider Protocol
//
// Clean query interface for LoopInsights to access FoodFinder meal history.
// FoodFinder_AnalysisHistoryStore conforms below so LoopInsights never needs
// to know about UserDefaults keys, pruning logic, or storage format.
//
// Key fields for LoopInsights tuning recommendations:
//   • originalAICarbs vs carbsGrams  → reveals systematic AI over/under-estimation
//   • aiConfidencePercent            → low-confidence meals can be weighted differently
//   • absorptionTime + foodType      → patterns in absorption accuracy by food category
//   • date                           → time-of-day and day-of-week trend analysis

protocol MealDataProvider {
    static func meals(from startDate: Date, to endDate: Date) -> [FoodFinder_AnalysisRecord]
}

enum FoodFinder_AnalysisHistoryStore {

    // MARK: - Record

    /// Append a new analysis record to the short-term analysis history (for re-entry).
    /// Does NOT archive to MealArchive — call `confirmMeal()` for that after the
    /// user commits to eating by continuing to the bolus screen.
    static func record(_ record: FoodFinder_AnalysisRecord) {
        var records = allRecords()
        // Replace existing record with the same name to avoid duplicates
        records.removeAll { $0.name == record.name }
        records.append(record)
        save(records)
        pendingRecord = record
        #if DEBUG
        print("FoodFinder: Recorded analysis history — total: \(records.count)")
        #endif

        // Notify DataLayer (separate module — uses notification decoupling)
        var mealInfo: [String: Any] = [
            "analysisType": record.analysisType.rawValue,
            "foodName": record.name,
            "carbsGrams": record.carbsGrams,
            "absorptionTimeHours": record.absorptionTime / 3600,
            "itemCount": record.analysisResult?.totalFoodPortions ?? 1
        ]
        if let v = record.originalAICarbs { mealInfo["originalAICarbs"] = v }
        if let v = record.aiConfidencePercent { mealInfo["aiConfidencePercent"] = v }
        if let v = record.analysisResult?.totalProtein { mealInfo["proteinGrams"] = v }
        if let v = record.analysisResult?.totalFat { mealInfo["fatGrams"] = v }
        if let v = record.analysisResult?.totalFiber { mealInfo["fiberGrams"] = v }
        if let v = record.analysisResult?.totalCalories { mealInfo["calories"] = v }
        if let v = record.locationName { mealInfo["locationName"] = v }
        NotificationCenter.default.post(name: .foodFinderMealAnalyzed, object: nil, userInfo: mealInfo)
    }

    /// Replace an already-recorded analysis in place, matched by `id`.
    ///
    /// Used when the user edits the plate after the analysis was first recorded
    /// — per-item value edits, exclusions, serving changes — so history, re-use
    /// and the archive reflect what they actually ate rather than the AI's first
    /// estimate.
    ///
    /// Matched on `id` rather than `name` (which is what `record(_:)` dedups on)
    /// because renaming an item changes the meal name: a name-keyed update would
    /// leave the pre-rename record behind as a duplicate. Appends if the id is
    /// gone, e.g. pruned by retention mid-edit.
    static func update(_ record: FoodFinder_AnalysisRecord) {
        var records = allRecords()
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        save(records)
        pendingRecord = record
    }

    // MARK: - Re-use from Settings

    /// Set when the user taps "Re-use" on a past analysis in FoodFinder Settings.
    /// CarbEntryViewModel picks this up on init and pre-fills the entry form.
    static var pendingReUseRecord: FoodFinder_AnalysisRecord?

    // MARK: - Meal Confirmation

    /// The most recently analyzed record, waiting for user to confirm the meal.
    static var pendingRecord: FoodFinder_AnalysisRecord?

    /// Called when the user confirms they are eating (continues to bolus).
    /// Archives the pending record to MealArchive and posts the notification.
    /// Legacy entry point — falls back to the static `pendingRecord`. New
    /// callers should pass the record explicitly via `confirmMeal(_:)` so the
    /// archive cannot silently miss when the static var is nil.
    static func confirmMeal() {
        guard let record = pendingRecord else { return }
        pendingRecord = nil
        archiveAndPostNotifications(record)
    }

    /// Archive a specific record. Use this when the caller already knows the
    /// exact record the user is committing (e.g., CarbEntryViewModel holding
    /// the FoodFinder analysis on its own state). Avoids the silent-miss
    /// failure mode of the static `pendingRecord` handoff.
    static func confirmMeal(_ record: FoodFinder_AnalysisRecord) {
        // Clear the static fallback so a stale value can't double-archive.
        pendingRecord = nil
        archiveAndPostNotifications(record)
    }

    private static func archiveAndPostNotifications(_ record: FoodFinder_AnalysisRecord) {
        MealArchive.archive(record)
        NotificationCenter.default.post(
            name: .foodFinderMealLogged,
            object: nil,
            userInfo: ["recordID": record.id]
        )
        #if DEBUG
        print("FoodFinder: Confirmed meal → archived to MealArchive: \(record.name)")
        #endif

        // Notify DataLayer for meal confirmation (piggybacks on existing .foodFinderMealLogged)
        // DataLayer_Coordinator observes .foodFinderMealLogged and reads these extra keys
        // Note: the .foodFinderMealLogged post above already happened — post a dedicated one
        var confirmInfo: [String: Any] = [
            "mealEventID": record.id,
            "finalCarbsGrams": record.carbsGrams
        ]
        if let delta = record.originalAICarbs.map({ record.carbsGrams - $0 }) {
            confirmInfo["carbDeltaFromAI"] = delta
        }
        NotificationCenter.default.post(
            name: Notification.Name("com.loopkit.Loop.foodFinderMealConfirmedForDataLayer"),
            object: nil,
            userInfo: confirmInfo
        )
    }

    // MARK: - Load (filtered by retention)

    /// Returns records that fall within the retention window.
    static func loadRecords(retentionDays: Int) -> [FoodFinder_AnalysisRecord] {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        return allRecords()
            .filter { $0.date >= cutoff }
            .sorted { $0.date > $1.date }
    }

    // MARK: - Prune Expired

    /// Remove records older than the retention window and delete orphaned thumbnails.
    static func pruneExpired(retentionDays: Int) {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        let all = allRecords()
        let (keep, expired) = all.reduce(into: ([FoodFinder_AnalysisRecord](), [FoodFinder_AnalysisRecord]())) { result, record in
            if record.date >= cutoff {
                result.0.append(record)
            } else {
                result.1.append(record)
            }
        }

        guard !expired.isEmpty else { return }
        save(keep)

        // Save the new (smaller) record set first, THEN check the
        // reference tracker — that way `isReferenced` doesn't return
        // true for the very records we just removed.
        for thumbID in Set(expired.compactMap { $0.thumbnailID }) {
            if !FoodFinder_ThumbnailReferenceTracker.isReferenced(thumbnailID: thumbID) {
                FavoriteFoodImageStore.deleteThumbnail(id: thumbID)
            }
        }

        #if DEBUG
        print("FoodFinder: Pruned \(expired.count) expired analysis records, \(keep.count) remain")
        #endif
    }

    // MARK: - Remove One

    /// Remove a single short-term history record by ID. Reference-counts
    /// the thumbnail — only deletes the file when no other record (this
    /// store, MealArchive) or favorite still points at the same
    /// thumbnailID. No-op if not found. Used by Meal Insights'
    /// swipe-to-delete so the deleted meal can't reappear from the
    /// re-use dropdown.
    @discardableResult
    static func remove(id: String) -> Bool {
        var records = allRecords()
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return false }
        let thumbID = records[idx].thumbnailID
        records.remove(at: idx)
        save(records)
        if let thumbID, !FoodFinder_ThumbnailReferenceTracker.isReferenced(thumbnailID: thumbID) {
            FavoriteFoodImageStore.deleteThumbnail(id: thumbID)
        }
        return true
    }

    // MARK: - Clear All

    /// Remove all analysis history records. Reference-counts thumbnails —
    /// only deletes a thumbnail file when no MealArchive record or favorite
    /// still references it. Otherwise surviving rows in Meal Insights or
    /// the Favorites list would render with broken images.
    static func clearAll() {
        let records = allRecords()
        let thumbIDs = Set(records.compactMap { $0.thumbnailID })
        save([])
        for thumbID in thumbIDs {
            if !FoodFinder_ThumbnailReferenceTracker.isReferenced(thumbnailID: thumbID) {
                FavoriteFoodImageStore.deleteThumbnail(id: thumbID)
            }
        }
        #if DEBUG
        print("FoodFinder: Cleared all \(records.count) analysis history records")
        #endif
    }

    // MARK: - Private Helpers

    private static let key = FoodFinder_FeatureFlags.Keys.analysisHistory

    /// All short-term history records (unfiltered). Internal access so
    /// `MealArchive` and ref-counted thumbnail deletion can consult it.
    static func allRecords() -> [FoodFinder_AnalysisRecord] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([FoodFinder_AnalysisRecord].self, from: data)) ?? []
    }

    private static func save(_ records: [FoodFinder_AnalysisRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - Thumbnail Reference Tracker
//
// FoodFinder thumbnails are shared by `thumbnailID` across multiple records
// (e.g., re-used analyses, duplicates from cross-source dedup, favorites
// derived from the same photo). Deleting a single record must NOT delete
// the underlying thumbnail file if other records or favorites still need
// it — otherwise the surviving rows would render with broken images.
//
// Callers consult this tracker after they've removed their record from
// their own store. If `isReferenced` returns false, the thumbnail file
// can be safely deleted.

enum FoodFinder_ThumbnailReferenceTracker {
    /// True if any FoodFinder short-term history record, any MealArchive
    /// record, or any favorite-food mapping still references the given
    /// thumbnail ID.
    static func isReferenced(thumbnailID: String) -> Bool {
        if FoodFinder_AnalysisHistoryStore.allRecords().contains(where: { $0.thumbnailID == thumbnailID }) {
            return true
        }
        if MealArchive.loadAll().contains(where: { $0.thumbnailID == thumbnailID }) {
            return true
        }
        if UserDefaults.standard.favoriteFoodImageIDs.values.contains(thumbnailID) {
            return true
        }
        return false
    }
}

// MARK: - MealDataProvider Conformance
//
// Gives LoopInsights a clean way to query meal history by date range
// without knowing anything about FoodFinder's storage internals.

extension FoodFinder_AnalysisHistoryStore: MealDataProvider {
    static func meals(from startDate: Date, to endDate: Date) -> [FoodFinder_AnalysisRecord] {
        allRecords()
            .filter { $0.date >= startDate && $0.date <= endDate }
            .sorted { $0.date > $1.date }
    }
}

// MARK: - Long-Term Meal Archive
//
// Permanent archive of all meal analysis records for LoopInsights data mining.
// Unlike the 7-day analysis history (UserDefaults), this archive persists
// indefinitely as a JSON file on disk. Used for:
//   • Long-term AI carb estimation accuracy tracking
//   • Nutritional glucose response correlation (high-fat vs low-fat, etc.)
//   • Food pattern trend analysis across months
//   • Data mining for personalized meal insights

enum MealArchive {

    private static let filename = "FoodFinder_MealArchive.json"

    private static var archiveURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("LoopInsights")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(filename)
    }

    /// Remove a single record by ID. Reference-counts the thumbnail — only
    /// deletes the file when no other record (this store, the FoodFinder
    /// short-term history) or favorite still points at the same
    /// thumbnailID. Returns true if a record was removed.
    @discardableResult
    static func remove(id: String) -> Bool {
        var existing = loadAll()
        guard let idx = existing.firstIndex(where: { $0.id == id }) else { return false }
        let thumbID = existing[idx].thumbnailID
        existing.remove(at: idx)
        saveAll(existing)
        if let thumbID, !FoodFinder_ThumbnailReferenceTracker.isReferenced(thumbnailID: thumbID) {
            FavoriteFoodImageStore.deleteThumbnail(id: thumbID)
        }
        return true
    }

    /// Remove a record matching the given date (±2 min) and carbs (±1 g).
    /// Used when we have a meal event without a stored archive UUID (e.g.,
    /// a manual carb entry that ended up in MealArchive via dedup priority).
    @discardableResult
    static func removeMatching(date: Date, carbs: Double) -> Bool {
        let existing = loadAll()
        guard let match = existing.first(where: {
            abs($0.date.timeIntervalSince(date)) < 120 && abs($0.carbsGrams - carbs) < 1
        }) else { return false }
        return remove(id: match.id)
    }

    /// Archive a single record (append to the JSON file on disk).
    /// Deduplicates by ID and by date+foodType proximity to avoid storing the same meal twice.
    static func archive(_ record: FoodFinder_AnalysisRecord) {
        var existing = loadAll()
        // Skip if exact ID match
        guard !existing.contains(where: { $0.id == record.id }) else { return }
        // Skip if another record with same foodType exists within 5 minutes
        let isDuplicate = existing.contains { other in
            abs(other.date.timeIntervalSince(record.date)) < 300 &&
            other.foodType == record.foodType
        }
        guard !isDuplicate else { return }
        existing.append(record)
        saveAll(existing)
    }

    /// Load all archived records within a date range.
    static func meals(from startDate: Date, to endDate: Date) -> [FoodFinder_AnalysisRecord] {
        loadAll()
            .filter { $0.date >= startDate && $0.date <= endDate }
            .sorted { $0.date > $1.date }
    }

    /// Load the complete archive (all time), deduplicating in two passes:
    /// 1. Same-source dedup: date ±5min + carbs ±1g (collapses write-side duplicates).
    /// 2. Cross-source priority dedup: date ±2h + carbs ±5g across different sources.
    ///    Keeps the highest-priority source per the data primacy order:
    ///    Loop > FoodFinder (image/dictation/barcode) > External (mfpImport).
    static func loadAll() -> [FoodFinder_AnalysisRecord] {
        guard FileManager.default.fileExists(atPath: archiveURL.path) else { return [] }
        guard let data = try? Data(contentsOf: archiveURL) else { return [] }
        let raw = (try? JSONDecoder().decode([FoodFinder_AnalysisRecord].self, from: data)) ?? []

        // Pass 1: same-source dedup (tight window)
        var seen: [(date: Date, carbs: Double)] = []
        let pass1 = raw.filter { record in
            let isDup = seen.contains { existing in
                abs(existing.date.timeIntervalSince(record.date)) < 300 &&
                abs(existing.carbs - record.carbsGrams) < 1
            }
            guard !isDup else { return false }
            seen.append((record.date, record.carbsGrams))
            return true
        }

        // Pass 2: cross-source priority dedup (wider window)
        // When entries from different sources overlap (±2h, ±5g carbs),
        // keep the higher-priority source only.
        var result: [FoodFinder_AnalysisRecord] = []
        for record in pass1 {
            let dominated = result.contains { existing in
                existing.analysisType != record.analysisType &&
                abs(existing.date.timeIntervalSince(record.date)) < 7200 &&
                abs(existing.carbsGrams - record.carbsGrams) < 5 &&
                sourcePriority(existing.analysisType) >= sourcePriority(record.analysisType)
            }
            guard !dominated else { continue }

            // Also remove any existing lower-priority entry this record supersedes
            result.removeAll { existing in
                existing.analysisType != record.analysisType &&
                abs(existing.date.timeIntervalSince(record.date)) < 7200 &&
                abs(existing.carbsGrams - record.carbsGrams) < 5 &&
                sourcePriority(existing.analysisType) < sourcePriority(record.analysisType)
            }
            result.append(record)
        }

        return result
    }

    /// Data primacy: Loop > FoodFinder (image/dictation/barcode) > External (mfpImport).
    private static func sourcePriority(_ type: FoodFinder_AnalysisRecord.AnalysisType) -> Int {
        switch type {
        case .image:      return 3
        case .dictation:  return 2
        case .barcode:    return 1
        case .mfpImport:  return 0
        }
    }

    /// Total archived meal count.
    static var count: Int { loadAll().count }

    private static func saveAll(_ records: [FoodFinder_AnalysisRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: archiveURL, options: .atomic)
    }
}
