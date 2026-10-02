//
//  SiteAtlas_FeatureFlags.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  SiteAtlas — Feature toggle and configuration flags.
//  All SiteAtlas enable/disable logic lives here.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import Foundation

// MARK: - Feature Toggle

/// Central on/off switch for the entire SiteAtlas feature.
/// Loop host files check `SiteAtlas_FeatureFlags.isEnabled` to gate UI insertion.
enum SiteAtlas_FeatureFlags {
    /// Master toggle — persisted in UserDefaults.
    /// Controls whether SiteAtlas appears in Settings.
    /// Defaults to false; user must manually enable.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.siteAtlasEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.siteAtlasEnabled) }
    }

    /// Auto-prompt toggle — persisted in UserDefaults.
    /// When on, the site logging sheet pops up after a pod/pump or CGM sensor change.
    /// Defaults to false; user must manually enable.
    static var autoPromptEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.siteAtlasAutoPromptEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.siteAtlasAutoPromptEnabled) }
    }
}

// MARK: - UserDefaults Keys

extension SiteAtlas_FeatureFlags {
    enum Keys {
        static let siteAtlasEnabled = "com.loopkit.Loop.siteAtlasEnabled"
        static let siteAtlasAutoPromptEnabled = "com.loopkit.Loop.siteAtlasAutoPromptEnabled"
    }
}
