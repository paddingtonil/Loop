//
//  PowerPackSettings.swift
//  Loop
//
//  Feature flags and the settings screen for the FoodFinder and BolusPro additions.
//  Every feature is off until the user turns it on.
//

import Foundation
import SwiftUI

/// The switchable PowerPack features. Stored in `UserDefaults`, off by default.
enum PowerPackFeature: String, CaseIterable, Identifiable {
    case bolusPro
    case foodFinder
    case foodFinderReferenceCheck
    case foodFinderRulebook

    var id: String { rawValue }

    /// Storage key. Used by `@AppStorage` and by `PowerPackFlags`.
    var defaultsKey: String { "org.powerpack.feature.\(rawValue)" }

    /// Features that only make sense when another one is on.
    var requires: PowerPackFeature? {
        switch self {
        case .bolusPro, .foodFinder: return nil
        case .foodFinderReferenceCheck, .foodFinderRulebook: return .foodFinder
        }
    }

    var title: String {
        switch self {
        case .bolusPro:
            return NSLocalizedString("BolusPro: fat and protein", comment: "PowerPack feature title")
        case .foodFinder:
            return NSLocalizedString("FoodFinder: meal analysis", comment: "PowerPack feature title")
        case .foodFinderReferenceCheck:
            return NSLocalizedString("FoodFinder: reference check", comment: "PowerPack feature title")
        case .foodFinderRulebook:
            return NSLocalizedString("FoodFinder: personal rulebook", comment: "PowerPack feature title")
        }
    }

    var summary: String {
        switch self {
        case .bolusPro:
            return NSLocalizedString("Adds a fat and protein field to the carb entry screen. The delayed carbohydrate entry is created only after you confirm.", comment: "PowerPack feature summary")
        case .foodFinder:
            return NSLocalizedString("Analyses a meal photo or text with your own AI key and pre-fills the carb entry screen. Nothing is saved before you confirm.", comment: "PowerPack feature summary")
        case .foodFinderReferenceCheck:
            return NSLocalizedString("Compares the analysis with Open Food Facts and USDA data. Only food names leave the device. Values change only if you approve.", comment: "PowerPack feature summary")
        case .foodFinderRulebook:
            return NSLocalizedString("Applies your own portion and naming rules to the analysis and suggests new rules from your corrections.", comment: "PowerPack feature summary")
        }
    }
}

enum PowerPackFlags {
    /// The value the user chose, ignoring dependencies.
    static func isSwitchedOn(_ feature: PowerPackFeature, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: feature.defaultsKey)
    }

    /// Whether the feature is in effect. Code outside the settings screen must call this, never
    /// `isSwitchedOn`, so that a feature whose prerequisite is off stays off.
    static func isActive(_ feature: PowerPackFeature, defaults: UserDefaults = .standard) -> Bool {
        // A feature is in effect only when it is switched on and its prerequisite (if any) is in effect too.
        guard isSwitchedOn(feature, defaults: defaults) else { return false }
        guard let prerequisite = feature.requires else { return true }
        return isActive(prerequisite, defaults: defaults)
    }
}

struct PowerPackSettingsView: View {
    @AppStorage(PowerPackFeature.bolusPro.defaultsKey) private var bolusPro = false
    @AppStorage(PowerPackFeature.foodFinder.defaultsKey) private var foodFinder = false
    @AppStorage(PowerPackFeature.foodFinderReferenceCheck.defaultsKey) private var referenceCheck = false
    @AppStorage(PowerPackFeature.foodFinderRulebook.defaultsKey) private var rulebook = false

    var body: some View {
        List {
            Section(footer: Text(NSLocalizedString("These features are optional additions. Each one is off until you turn it on. Every carb entry and bolus still needs your confirmation. Suggestions are not medical advice.", comment: "PowerPack settings footer"))) {
                toggle(.bolusPro, $bolusPro)
                toggle(.foodFinder, $foodFinder)
            }
            Section(header: Text(NSLocalizedString("FoodFinder options", comment: "PowerPack settings section"))) {
                toggle(.foodFinderReferenceCheck, $referenceCheck)
                toggle(.foodFinderRulebook, $rulebook)
                if foodFinder && rulebook {
                    NavigationLink(NSLocalizedString("Personal rulebook", comment: "")) { RulebookView() }
                }
            }
            if foodFinder && referenceCheck {
                USDAKeySection()
            }
        }
        .navigationTitle(NSLocalizedString("PowerPack", comment: "PowerPack settings title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func toggle(_ feature: PowerPackFeature, _ binding: Binding<Bool>) -> some View {
        let blocked = feature.requires.map { !PowerPackFlags.isSwitchedOn($0) } ?? false
        VStack(alignment: .leading, spacing: 4) {
            Toggle(feature.title, isOn: binding)
                .disabled(blocked)
            Text(feature.summary)
                .font(.footnote)
                .foregroundColor(.secondary)
            if blocked, let parent = feature.requires {
                Text(String(format: NSLocalizedString("Requires: %@", comment: "PowerPack prerequisite"), parent.title))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }
}

extension SettingsView {
    internal var powerPackSection: some View {
        NavigationLink(NSLocalizedString("PowerPack", comment: "PowerPack settings entry")) {
            PowerPackSettingsView()
        }
    }
}
