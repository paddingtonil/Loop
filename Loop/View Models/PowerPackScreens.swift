//
//  PowerPackScreens.swift
//  Loop
//
//  Screens for FoodFinder: USDA key, personal rulebook, and approval of reference-check suggestions.
//  Nothing here changes a value without the user's tap.
//

import Foundation
import SwiftUI
import FoodFinder

// MARK: - USDA key

/// The user's own FoodData Central key, kept in the Keychain of this device only.
struct USDAKeySection: View {
    private let keys = KeychainAPIKeyStore()
    @State private var entry = ""
    @State private var isSet = false
    @State private var errorText: String?

    var body: some View {
        Section(
            header: Text(NSLocalizedString("USDA key", comment: "PowerPack USDA key section")),
            footer: Text(NSLocalizedString("A free key from api.data.gov. It stays in the Keychain of this device and is sent only to USDA. Without it the check uses Open Food Facts alone.", comment: "PowerPack USDA key footer"))
        ) {
            HStack {
                Text(NSLocalizedString("Status", comment: "PowerPack USDA key status"))
                Spacer()
                Text(isSet ? NSLocalizedString("Saved", comment: "") : NSLocalizedString("Not set", comment: ""))
                    .foregroundColor(.secondary)
            }
            SecureField(NSLocalizedString("Paste key", comment: "PowerPack USDA key field"), text: $entry)
                .textContentType(.password)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            Button(NSLocalizedString("Save key", comment: "")) { save() }
                .disabled(entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if isSet {
                Button(NSLocalizedString("Remove key", comment: ""), role: .destructive) { remove() }
            }
            if let errorText {
                Text(errorText).font(.footnote).foregroundColor(.red)
            }
        }
        .onAppear { isSet = keys.key(for: .usda) != nil }
    }

    private func save() {
        do {
            try keys.save(entry, for: .usda)
            entry = ""
            errorText = nil
            isSet = true
        } catch {
            errorText = NSLocalizedString("The key could not be saved.", comment: "")
        }
    }

    private func remove() {
        do {
            try keys.delete(.usda)
            errorText = nil
            isSet = false
        } catch {
            errorText = NSLocalizedString("The key could not be removed.", comment: "")
        }
    }
}

// MARK: - Personal rulebook

struct RulebookView: View {
    private let store: RulebookStore?
    @State private var book = Rulebook()
    @State private var errorText: String?

    init() {
        store = RulebookStore.defaultDirectory().map { RulebookStore(directory: $0) }
    }

    var body: some View {
        List {
            if store == nil {
                Section {
                    Text(NSLocalizedString("Shared storage is not available in this build, so the rulebook cannot be saved.", comment: ""))
                        .foregroundColor(.secondary)
                }
            }
            if let errorText {
                Section { Text(errorText).foregroundColor(.red) }
            }

            let suggestions = book.suggestions().filter { !book.dismissedSuggestions.contains($0.id) }
            if !suggestions.isEmpty {
                Section(
                    header: Text(NSLocalizedString("Suggestions", comment: "")),
                    footer: Text(NSLocalizedString("Learned from your corrections. A rule is used only after you accept it.", comment: ""))
                ) {
                    ForEach(suggestions) { suggestion in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(suggestion.matchKey).font(.headline)
                            Text(suggestion.defaultText).font(.footnote).foregroundColor(.secondary)
                            HStack {
                                Button(NSLocalizedString("Accept", comment: "")) {
                                    change { try $0.accept(suggestion) }
                                }
                                Spacer()
                                Button(NSLocalizedString("Dismiss", comment: ""), role: .destructive) {
                                    change { $0.dismiss(suggestion) }
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Section(header: Text(NSLocalizedString("Rules", comment: ""))) {
                if book.rules.isEmpty {
                    Text(NSLocalizedString("No rules yet.", comment: "")).foregroundColor(.secondary)
                }
                ForEach(book.rules) { rule in
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: Binding(
                            get: { rule.isEnabled },
                            set: { on in change { $0.setEnabled(on, ruleID: rule.id) } }
                        )) {
                            VStack(alignment: .leading) {
                                Text(rule.matchKey).font(.headline)
                                Text(rule.text).font(.footnote).foregroundColor(.secondary)
                            }
                        }
                        if rule.needsReview() {
                            HStack {
                                Text(NSLocalizedString("Not confirmed for a long time; not used until you confirm.", comment: ""))
                                    .font(.footnote).foregroundColor(.orange)
                                Spacer()
                                Button(NSLocalizedString("Confirm", comment: "")) {
                                    change { $0.confirm(ruleID: rule.id) }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { book.rules[$0].id }
                    change { book in ids.forEach { book.remove(ruleID: $0) } }
                }
            }
        }
        .navigationTitle(NSLocalizedString("Personal rulebook", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
    }

    private func reload() {
        guard let store else { return }
        do { book = try store.load(); errorText = nil } catch {
            errorText = NSLocalizedString("The rulebook could not be read.", comment: "")
        }
    }

    /// Applies one change through the store (read-modify-write), then shows what was saved.
    private func change(_ edit: @escaping (inout Rulebook) throws -> Void) {
        guard let store else { return }
        do { try store.update(edit); reload() } catch {
            errorText = NSLocalizedString("The change could not be saved.", comment: "")
        }
    }
}

// MARK: - Reference check: approval

/// Shows what published data says about each analysed item. Every suggestion starts unchecked.
struct ReferenceSuggestionsView: View {
    let result: FoodAnalysisResult
    let suggestions: [ReferenceSuggestion]
    /// Called with the suggestions the user ticked (possibly none).
    let onDone: ([ReferenceSuggestion]) -> Void

    @State private var approved = Set<Int>()

    /// Differences above this are shown as a warning.
    private static let warningRatio = 0.25

    var body: some View {
        List {
            Section(footer: Text(NSLocalizedString("Published values can differ from your portion or recipe. Tick an item only if you trust the published values more than the estimate.", comment: ""))) {
                ForEach(suggestions, id: \.itemIndex) { s in
                    let original = result.items[s.itemIndex]
                    Toggle(isOn: Binding(
                        get: { approved.contains(s.itemIndex) },
                        set: { on in if on { approved.insert(s.itemIndex) } else { approved.remove(s.itemIndex) } }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(original.name).font(.headline)
                            Text(String(format: NSLocalizedString("Estimate: %.0f g carbs, %.0f g protein, %.0f g fat", comment: ""),
                                        original.carbsGrams, original.proteinGrams, original.fatGrams))
                                .font(.footnote)
                            Text(String(format: NSLocalizedString("Published: %.0f g carbs, %.0f g protein, %.0f g fat", comment: ""),
                                        s.proposed.carbsGrams, s.proposed.proteinGrams, s.proposed.fatGrams))
                                .font(.footnote)
                            Text(String(format: NSLocalizedString("Source: %@ (%@)", comment: ""),
                                        String(describing: s.reference.source), s.reference.name))
                                .font(.footnote).foregroundColor(.secondary)
                            if s.carbsDifferenceRatio >= Self.warningRatio {
                                Text(String(format: NSLocalizedString("Carbs differ by %d%%.", comment: ""),
                                            Int((s.carbsDifferenceRatio * 100).rounded())))
                                    .font(.footnote).foregroundColor(.orange)
                            }
                        }
                    }
                }
            }
            Section {
                Button(NSLocalizedString("Use ticked values", comment: "")) {
                    onDone(suggestions.filter { approved.contains($0.itemIndex) })
                }
                Button(NSLocalizedString("Keep my estimate", comment: "")) { onDone([]) }
            }
        }
        .navigationTitle(NSLocalizedString("Reference check", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Bridge: reference lookup

extension PowerPackBridge {
    /// Suggestions from published data for `result`, or none when the feature is off. Only food names leave
    /// the device. A failing source is skipped, so this never blocks an analysis. The caller shows
    /// `ReferenceSuggestionsView` and passes the approved ones to `FoodAnalysisResult.applying`.
    static func referenceSuggestions(for result: FoodAnalysisResult) async -> [ReferenceSuggestion] {
        guard PowerPackFlags.isActive(.foodFinderReferenceCheck) else { return [] }
        let keys = KeychainAPIKeyStore()
        var sources: [NutritionReferenceSource] = [OpenFoodFactsSource()]
        if keys.key(for: .usda) != nil { sources.append(USDASource(keys: keys)) }
        return await NutritionReferenceLookup(sources: sources).suggestions(for: result)
    }
}
