//
//  DirectConnect_FeatureFlags.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — Feature toggle flags.
//  All DirectConnect enable/disable logic lives here.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import Foundation

// MARK: - Feature Toggle

/// Central on/off switch for DirectConnect (PowerPack Exclusive).
/// Loop host files check `DirectConnect_FeatureFlags.isEnabled` to list the CGM option.
enum DirectConnect_FeatureFlags {
    /// Master toggle — persisted in UserDefaults. Defaults to false.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.enabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.enabled) }
    }

    /// Set by DirectConnect_G7CGMManager while it is Loop's CGM, so Settings can refuse to
    /// turn the feature off underneath an active glucose source.
    static var isActiveCGM: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.activeCGM) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.activeCGM) }
    }
}

// MARK: - UserDefaults Keys

extension DirectConnect_FeatureFlags {
    enum Keys {
        static let enabled = "com.loopkit.Loop.directConnectFeatureEnabled"
        static let activeCGM = "com.loopkit.Loop.directConnect.isActiveCGM"
    }
}
