//
//  SiteAtlas_Coordinator.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  SiteAtlas — Central coordinator for site rotation tracking.
//  Listens for pump/pod and CGM sensor change notifications and prompts site logging.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import Foundation
import Combine

// MARK: - Notification Names

extension Notification.Name {
    static let pumpSiteDeactivated = Notification.Name("com.loopkit.Loop.pumpSiteDeactivated")
    static let cgmSensorSessionStarted = Notification.Name("com.loopkit.Loop.cgmSensorSessionStarted")
    static let siteAtlasShouldPromptLog = Notification.Name("com.loopkit.Loop.siteAtlasShouldPromptLog")
}

// MARK: - Coordinator

final class SiteAtlas_Coordinator: ObservableObject {

    static let shared = SiteAtlas_Coordinator()

    /// When true, the UI layer should present the site selection sheet.
    @Published var pendingSiteLog: Bool = false

    /// The type of site to prompt for (set before pendingSiteLog becomes true).
    @Published var promptedSiteType: SiteAtlas_SiteType = .pump

    private var cancellables = Set<AnyCancellable>()
    private let storage = SiteAtlas_Storage.shared

    private init() {
        setupNotificationListeners()
    }

    // MARK: - Public API

    /// Log a new site entry.
    func logSite(_ entry: SiteAtlas_SiteEntry) {
        storage.addEntry(entry)
        pendingSiteLog = false
    }

    /// Skip logging (dismiss prompt without saving).
    func skipLogging() {
        pendingSiteLog = false
    }

    /// Manually trigger a site log prompt (e.g., from Settings).
    /// Only sets the prompted type — the Settings screen drives its own
    /// sheet presentation; `pendingSiteLog` is reserved for auto-prompts
    /// so a manual log never leaves a stale global prompt behind.
    func promptManualLog(type: SiteAtlas_SiteType) {
        promptedSiteType = type
    }

    /// All entries from storage.
    func allEntries() -> [SiteAtlas_SiteEntry] {
        storage.loadEntries()
    }

    /// Update an existing entry (date, type, notes).
    func updateEntry(_ entry: SiteAtlas_SiteEntry) {
        storage.updateEntry(entry)
    }

    /// Delete a specific entry.
    func deleteEntry(id: UUID) {
        storage.deleteEntry(id: id)
    }

    /// Delete all entries.
    func deleteAllEntries() {
        storage.deleteAll()
    }

    /// Most recent entry for a given type.
    func mostRecent(ofType type: SiteAtlas_SiteType) -> SiteAtlas_SiteEntry? {
        storage.mostRecent(ofType: type)
    }

    // MARK: - Private

    private func setupNotificationListeners() {
        NotificationCenter.default.publisher(for: .pumpSiteDeactivated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.queueAutoPrompt(type: .pump)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .cgmSensorSessionStarted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.queueAutoPrompt(type: .sensor)
            }
            .store(in: &cancellables)
    }

    /// Pend an auto-prompt and tell the UI layer to present it when the
    /// status screen is clear. Device-change events fire mid-setup-flow
    /// (e.g. right after pod pairing), so presentation is deferred rather
    /// than shown over the device UI.
    private func queueAutoPrompt(type: SiteAtlas_SiteType) {
        guard SiteAtlas_FeatureFlags.isEnabled, SiteAtlas_FeatureFlags.autoPromptEnabled else { return }
        promptedSiteType = type
        pendingSiteLog = true
        NotificationCenter.default.post(name: .siteAtlasShouldPromptLog, object: nil)
    }
}
