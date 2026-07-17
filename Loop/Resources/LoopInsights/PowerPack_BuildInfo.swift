//
//  PowerPack_BuildInfo.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  PowerPack-specific version + build metadata. Surfaced in the small
//  version footer at the bottom of LoopInsights dashboard and FoodFinder
//  Settings so users can report exactly which release of PowerPack
//  they're running.
//
//  Auto-stamped values: `commitShortSHA`, `buildDate`.
//  Stamped by Scripts/install_features.sh Phase 4c at install time,
//  pulling the actual Loop submodule short SHA + install date. The
//  defaults committed in this file represent a "developer build" — that's
//  what Option A users (direct clone + Xcode) see, and it correctly
//  distinguishes their build from an installer-stamped one.
//
//  Manually-maintained value: `version`. Bumped in
//  install_features.sh's FEATURE_VERSION constant at meaningful release
//  points (new features shipping, major bug fixes, etc.).
//
//  Version → commit mapping is preserved on the LoopPowerPack/Loop repo
//  via the commit log + tags. When a user reports "I'm on PowerPack v0.1.0
//  (8bd0a85)", you can `git -C Loop checkout 8bd0a85` to reproduce their
//  exact state.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import Foundation
import SwiftUI

enum PowerPack_BuildInfo {
    /// Semver string. Manually bumped in install_features.sh at release
    /// points. The committed default here is what Option A clone-and-build
    /// users see; the installer overwrites this with FEATURE_VERSION from
    /// install_features.sh at Phase 4c.
    static let version = "0.3.11"

    /// Loop submodule short SHA at install time. `"dev"` for Option A
    /// developer builds (direct clone + Xcode); a real 7-char short SHA
    /// for Option B users (installer overlay onto stock Loop).
    static let commitShortSHA = "e3761d31"

    /// Install date in YYYY-MM-DD UTC. Empty for developer builds.
    static let buildDate = "2026-07-17"

    /// User-facing display string for the footer card. Two formats:
    ///   "PowerPack v0.1.0 (8bd0a85)" — installer build
    ///   "PowerPack v0.1.0-dev"        — developer build (Option A)
    static var displayString: String {
        if commitShortSHA == "dev" || commitShortSHA.isEmpty {
            return "PowerPack v\(version)-dev"
        }
        return "PowerPack v\(version) (\(commitShortSHA))"
    }
}

// MARK: - Reusable footer view

/// Drop-in version footer for any feature's settings screen. Renders a
/// small grey "PowerPack v0.1.0 (8bd0a85)" line as the last Section of
/// a Form/List. Every PowerPack feature should include this at the
/// bottom of its settings view so a user can read the version off any
/// PowerPack surface — current features (FoodFinder, LoopInsights,
/// AutoPresets, BolusPro, SiteAtlas) and any future ones.
///
/// Usage:
///     Form {
///         featureToggleSection
///         // ... other sections ...
///         LoopInsights_SubstackPromoFooter()   // optional
///         PowerPack_VersionFooter()            // always last
///     }
struct PowerPack_VersionFooter: View {
    @ObservedObject private var checker = PowerPack_UpdateChecker.shared
    @Environment(\.openURL) private var openURL
    @State private var checking = false
    @State private var showUpToDate = false

    var body: some View {
        Section {
            VStack(spacing: 6) {
                Text(PowerPack_BuildInfo.displayString)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Button {
                    checking = true
                    Task {
                        let hasUpdate = await checker.refresh(force: true)
                        checking = false
                        // If behind, the update-available alert below fires.
                        // If current, confirm here so the tap always gives feedback.
                        if !hasUpdate { showUpToDate = true }
                    }
                } label: {
                    if checking {
                        ProgressView()
                    } else {
                        Text("Check for updates").font(.caption2)
                    }
                }
                .disabled(checking)
                .alert("You're up to date", isPresented: $showUpToDate) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("PowerPack \(PowerPack_BuildInfo.version) is the latest version.")
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            // Daily-throttled auto-check whenever any PowerPack surface appears.
            .task { await checker.refresh() }
            .alert("PowerPack update available",
                   isPresented: Binding(
                       get: { checker.availableUpdate != nil },
                       set: { if !$0 { checker.dismissCurrent() } }
                   ),
                   presenting: checker.availableUpdate) { info in
                Button("How to update") { openURL(info.url); checker.dismissCurrent() }
                Button("Later", role: .cancel) { checker.dismissCurrent() }
            } message: { info in
                Text(Self.updateMessage(for: info))
            }
        }
    }

    private static func updateMessage(for info: PowerPack_UpdateChecker.UpdateInfo) -> String {
        var msg = "PowerPack \(info.latest) is available (you're on \(PowerPack_BuildInfo.version)). Reinstall at your convenience to get the latest fixes."
        if let notes = info.notes, !notes.isEmpty {
            msg += "\n\nWhat's new: \(notes)"
        }
        return msg
    }
}
