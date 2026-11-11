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
import LoopKitUI

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

// MARK: - AI provider choice (bring your own key)

/// Which AI provider and model FoodFinder uses. The key itself lives in the Keychain (this device only).
enum AIProviderSettings {
    static let providerKey = "org.powerpack.foodfinder.provider"
    static func modelKey(_ id: AIProviderID) -> String { "org.powerpack.foodfinder.model.\(id.rawValue)" }

    static let choices: [AIProviderID] = [.anthropic, .openAI, .gemini]
    static let defaultAnthropicModel = "claude-sonnet-5-5"

    static func title(_ id: AIProviderID) -> String {
        switch id {
        case .anthropic: return "Anthropic"
        case .openAI: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .usda: return "USDA"
        }
    }

    static func selected(defaults: UserDefaults = .standard) -> AIProviderID {
        guard let raw = defaults.string(forKey: providerKey), let id = AIProviderID(rawValue: raw), choices.contains(id) else {
            return .anthropic
        }
        return id
    }

    /// The model the user chose. Anthropic has a default; OpenAI and Gemini must be chosen by the user.
    static func model(for id: AIProviderID, defaults: UserDefaults = .standard) -> String {
        let stored = (defaults.string(forKey: modelKey(id)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty { return stored }
        return id == .anthropic ? defaultAnthropicModel : ""
    }

    enum SetupError: Error, Equatable {
        case noModel(AIProviderID)
    }

    static func makeProvider(keys: APIKeyStore, defaults: UserDefaults = .standard) throws -> FoodAnalysisProvider {
        let id = selected(defaults: defaults)
        let model = model(for: id, defaults: defaults)
        guard !model.isEmpty else { throw SetupError.noModel(id) }
        switch id {
        case .anthropic: return AnthropicProvider(keys: keys, model: model)
        case .openAI: return OpenAIProvider(keys: keys, model: model)
        case .gemini: return GeminiProvider(keys: keys, model: model)
        case .usda: throw SetupError.noModel(id)
        }
    }
}

/// Settings: provider, model and key. Shown in PowerPack settings while FoodFinder is on.
struct AIProviderSection: View {
    private let keys = KeychainAPIKeyStore()
    @State private var provider = AIProviderSettings.selected()
    @State private var model = ""
    @State private var entry = ""
    @State private var isSet = false
    @State private var errorText: String?

    var body: some View {
        Section(
            header: Text(NSLocalizedString("AI provider", comment: "PowerPack AI provider section")),
            footer: Text(NSLocalizedString("Your meal photo or text is sent to the provider you choose, with your own key, and nowhere else. The key stays in the Keychain of this device. Provider charges apply to your account.", comment: "PowerPack AI provider footer"))
        ) {
            Picker(NSLocalizedString("Provider", comment: ""), selection: $provider) {
                ForEach(AIProviderSettings.choices, id: \.self) { Text(AIProviderSettings.title($0)).tag($0) }
            }
            .onChange(of: provider) { newValue in
                UserDefaults.standard.set(newValue.rawValue, forKey: AIProviderSettings.providerKey)
                load()
            }

            TextField(modelPlaceholder, text: $model)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .onChange(of: model) { newValue in
                    UserDefaults.standard.set(newValue, forKey: AIProviderSettings.modelKey(provider))
                }

            HStack {
                Text(NSLocalizedString("Key", comment: ""))
                Spacer()
                Text(isSet ? NSLocalizedString("Saved", comment: "") : NSLocalizedString("Not set", comment: ""))
                    .foregroundColor(.secondary)
            }
            SecureField(NSLocalizedString("Paste key", comment: ""), text: $entry)
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
        .onAppear(perform: load)
    }

    private var modelPlaceholder: String {
        provider == .anthropic
            ? String(format: NSLocalizedString("Model (default %@)", comment: ""), AIProviderSettings.defaultAnthropicModel)
            : NSLocalizedString("Model name (required)", comment: "")
    }

    private func load() {
        model = UserDefaults.standard.string(forKey: AIProviderSettings.modelKey(provider)) ?? ""
        isSet = keys.key(for: provider) != nil
        entry = ""
        errorText = nil
    }

    private func save() {
        do { try keys.save(entry, for: provider); entry = ""; errorText = nil; isSet = true } catch {
            errorText = NSLocalizedString("The key could not be saved.", comment: "")
        }
    }

    private func remove() {
        do { try keys.delete(provider); errorText = nil; isSet = false } catch {
            errorText = NSLocalizedString("The key could not be removed.", comment: "")
        }
    }
}

// MARK: - Carb entry: start an analysis

/// Runs one FoodFinder analysis and pre-fills the carb entry screen. Nothing is saved here: the user still
/// reviews every value and confirms through the normal Continue and bolus screens.
@MainActor
final class FoodFinderCoordinator: ObservableObject {
    enum Phase: Equatable { case idle, working, reviewing }

    /// An analysis the user is going through in one sheet: first the reference check (when published values
    /// exist), then the review. The id never changes, so moving between stages does not dismiss and re-present
    /// the sheet.
    struct AnalysisFlow: Identifiable {
        enum Stage {
            case reference(original: FoodAnalysisResult, suggestions: [ReferenceSuggestion])
            case review(FoodAnalysisResult)
        }
        let id = UUID()
        var stage: Stage
        /// Grows when a re-check replaces the result, so the review starts from the new values.
        var revision = 0
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var errorText: String?
    /// What the last analysis produced, shown under the buttons until the next one starts.
    @Published private(set) var lastResult: FoodAnalysisResult?
    @Published var flow: AnalysisFlow?
    @Published private(set) var isRechecking = false
    @Published private(set) var recheckError: String?

    private var task: Task<Void, Never>?

    func analyzePhotos(_ raw: [Data], into viewModel: CarbEntryViewModel) {
        run(into: viewModel) {
            let prepared = try await FoodPhotoPipeline().prepare(raw)
            return FoodFinderRequest(prepared: prepared)
        }
    }

    func analyzeText(_ text: String, into viewModel: CarbEntryViewModel) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        run(into: viewModel) { FoodFinderRequest(description: trimmed) }
    }

    /// A scanned or typed barcode: the published label values become a one-food analysis for the review.
    /// No AI is involved, so no key is needed. Only the digits leave the device.
    func lookUpBarcode(_ code: String) {
        guard phase == .idle else { return }
        phase = .working
        errorText = nil
        lastResult = nil

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let product = try await OpenFoodFactsSource().product(barcode: code)
                try Task.checkCancellation()
                self.flow = AnalysisFlow(stage: .review(FoodAnalysisResult.fromBarcode(product)))
                self.phase = .reviewing
            } catch {
                self.phase = .idle
                if Task.isCancelled || error is CancellationError { return }
                self.errorText = Self.message(for: error)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        flow = nil
        isRechecking = false
        recheckError = nil
        phase = .idle
    }

    /// The sheet went away (a button or a swipe). Without this, a swipe would leave the buttons disabled.
    func flowDismissed() {
        if phase == .reviewing { cancel() }
    }

    /// The user answered the reference check: apply the ticked values (possibly none) and show the review.
    func finishReference(approved: [ReferenceSuggestion]) {
        guard case .reference(let original, _)? = flow?.stage else { return }
        flow?.stage = .review(approved.isEmpty ? original : original.applying(approved))
        flow?.revision += 1
    }

    /// The user approved the review (with their edits, if any): pre-fill the carb entry.
    func approve(_ result: FoodAnalysisResult, into viewModel: CarbEntryViewModel) {
        PowerPackBridge.apply(result, to: viewModel)
        lastResult = result
        flow = nil
        recheckError = nil
        phase = .idle
    }

    /// Asks the AI to look again, treating every field the user changed as a fact (route 4). The new result
    /// comes back to the review for the user to approve; nothing is pre-filled yet.
    func recheck(base: FoodAnalysisResult, edited: FoodAnalysisResult) {
        guard !isRechecking else { return }
        isRechecking = true
        recheckError = nil

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let provider = try AIProviderSettings.makeProvider(keys: KeychainAPIKeyStore())
                var request = FoodFinderRequest(
                    jpegImages: edited.imageJPEGData.map { [$0] } ?? [],
                    correction: MealCorrection.edits(from: base.items, to: edited.items)
                )
                request.rules = Self.currentRules()
                let result = try await FoodFinderService(provider: provider).analyze(request)
                try Task.checkCancellation()
                self.flow?.stage = .review(result)
                self.flow?.revision += 1
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                self.recheckError = Self.message(for: error)
            }
            self.isRechecking = false
        }
    }

    private func run(into viewModel: CarbEntryViewModel, makeRequest: @escaping () async throws -> FoodFinderRequest) {
        guard phase == .idle else { return }
        phase = .working
        errorText = nil
        lastResult = nil

        task = Task { [weak self, weak viewModel] in
            guard let self else { return }
            do {
                let provider = try AIProviderSettings.makeProvider(keys: KeychainAPIKeyStore())
                var request = try await makeRequest()
                request.rules = Self.currentRules()
                let result = try await FoodFinderService(provider: provider).analyze(request)
                try Task.checkCancellation()

                let suggestions = await PowerPackBridge.referenceSuggestions(for: result)
                try Task.checkCancellation()

                guard viewModel != nil else { self.phase = .idle; return }
                self.flow = AnalysisFlow(stage: suggestions.isEmpty
                    ? .review(result)
                    : .reference(original: result, suggestions: suggestions))
                self.phase = .reviewing
            } catch {
                // A cancelled request can surface as URLError.cancelled, not only as CancellationError.
                if Task.isCancelled || error is CancellationError { self.phase = .idle; return }
                self.phase = .idle
                self.errorText = Self.message(for: error)
            }
        }
    }

    /// The user's confirmed rules, only while the rulebook feature is in effect.
    private static func currentRules() -> [PersonalRule] {
        guard PowerPackFlags.isActive(.foodFinderRulebook),
              let directory = RulebookStore.defaultDirectory(),
              let book = try? RulebookStore(directory: directory).load() else { return [] }
        return book.rules
    }

    /// Plain wording for the user. Provider messages are not shown: they can echo request details.
    static func message(for error: Error) -> String {
        if let setup = error as? AIProviderSettings.SetupError, case .noModel(let id) = setup {
            return String(format: NSLocalizedString("Choose a model for %@ in Settings → PowerPack.", comment: ""), AIProviderSettings.title(id))
        }
        if let provider = error as? ProviderError {
            switch provider {
            case .noAPIKey(let id):
                return String(format: NSLocalizedString("Add your %@ key in Settings → PowerPack.", comment: ""), AIProviderSettings.title(id))
            case .http(let status, let detail):
                if status == 401 || status == 403 {
                    return NSLocalizedString("The provider rejected the key. Check it in Settings → PowerPack.", comment: "")
                }
                // The provider's own text (for example "model not found" or "could not process image") is what
                // tells the user what to change. It never contains the key; it is cut short for the screen.
                let short = String(detail.prefix(140))
                return String(format: NSLocalizedString("The provider returned an error (%d): %@ Nothing was changed.", comment: ""), status, short)
            case .badResponse:
                return NSLocalizedString("The provider's answer could not be read. Nothing was changed.", comment: "")
            }
        }
        if let image = error as? ImagePreparationError {
            return String(format: NSLocalizedString("A photo could not be read, or too many photos were chosen (4 at most). [%@]", comment: ""), String(describing: image))
        }
        if let food = error as? FoodFinderError {
            // The case name only: it says which part of the answer was missing, without echoing the answer.
            let reason: String
            switch food {
            case .noJSON: reason = "no JSON in the answer (the reply may have been cut off)"
            case .malformed: reason = "the JSON did not match the format"
            case .missingField(_, let field): reason = "the answer had no value for \(field)"
            case .noItems: reason = "no food was found in the picture"
            case .implausibleItem: reason = "a value looked implausible"
            case .templateMissing: reason = "the prompt template is missing from the app"
            }
            return String(format: NSLocalizedString("The answer was not a usable meal analysis (%@). Nothing was changed. Try again or enter the meal yourself.", comment: ""), reason)
        }
        if let barcode = error as? BarcodeLookupError {
            switch barcode {
            case .invalidCode:
                return NSLocalizedString("That is not a barcode number (8 to 14 digits).", comment: "")
            case .notFound:
                return NSLocalizedString("No product with nutrition values was found for this barcode. Try a photo or a description.", comment: "")
            }
        }
        if error is URLError {
            return NSLocalizedString("The request could not be sent. Check the connection.", comment: "")
        }
        return NSLocalizedString("The analysis failed. Nothing was changed.", comment: "")
    }
}

/// Plain-language lines for the warnings the analysis carries.
enum FoodFinderWarningText {
    static func lines(for result: FoodAnalysisResult) -> [String] {
        result.warnings.map { warning in
            switch warning {
            case .estimateOnly:
                return NSLocalizedString("Menu or label text: the values are for a 100 g serving, not your plate.", comment: "")
            case .lowConfidence(let confidence):
                return String(format: NSLocalizedString("Low confidence (%d%%).", comment: ""), Int((confidence * 100).rounded()))
            case .energyMismatch(let item, _, _):
                return String(format: NSLocalizedString("%@: the calories do not match the macros.", comment: ""), item)
            case .invalidValueClamped(let item, let field):
                return String(format: NSLocalizedString("%@: %@ was invalid and set to 0.", comment: ""), item, field)
            case .servingsTotalMismatch:
                return NSLocalizedString("The serving totals do not add up.", comment: "")
            case .fiberSplitInconsistent(let item):
                return String(format: NSLocalizedString("%@: the fiber split is inconsistent, so full carbs are used.", comment: ""), item)
            }
        }
    }
}

/// A headline shown above the warnings when the analysis deserves extra care, or nil for none.
enum FoodFinderCaution {
    /// Net carbs from which a meal counts as large. A 20% error is 24 g on 120 g of carbs and 6 g on 30 g,
    /// so the portion deserves a second look. This is a starting value; Jonathan knows the right one better.
    static let largeMealCarbsGrams = 100.0

    /// One headline at most: the first rule that applies, in this order (Jonathan accepted this proposal).
    /// 1. low reliability, 2. values for 100 g instead of the plate, 3. a large meal.
    /// Medium reliability gets none (the gauge shows it), and the individual warnings are listed separately.
    static func headline(for result: FoodAnalysisResult) -> String? {
        if result.confidenceLevel == .low {
            return NSLocalizedString("Low confidence: check every value before you continue.", comment: "")
        }
        if result.isEstimateOnly {
            return NSLocalizedString("Values are for 100 g, not your plate. Set the weight you ate.", comment: "")
        }
        if result.totalNetCarbsGrams >= largeMealCarbsGrams {
            return String(
                format: NSLocalizedString("Large meal (about %d g carbs): check the portion before you continue.", comment: ""),
                Int(result.totalNetCarbsGrams.rounded())
            )
        }
        return nil
    }
}

/// The FoodFinder card on the carb entry screen: camera, library, description, and the outcome.
struct FoodFinderEntrySection: View {
    @ObservedObject var viewModel: CarbEntryViewModel
    @StateObject private var coordinator = FoodFinderCoordinator()

    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var showDescription = false
    @State private var showBarcode = false
    @State private var descriptionText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString("FoodFinder", comment: "FoodFinder card title")).font(.headline)

            if coordinator.phase == .working {
                HStack {
                    ProgressView()
                    Text(NSLocalizedString("Analysing…", comment: "")).foregroundColor(.secondary)
                    Spacer()
                    Button(NSLocalizedString("Cancel", comment: "")) { coordinator.cancel() }
                }
            } else {
                // Four buttons do not fit one row on a narrow phone, so two rows of two.
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        inputButton("Photo", "camera") { showCamera = true }
                        inputButton("Library", "photo.on.rectangle") { showLibrary = true }
                    }
                    HStack(spacing: 8) {
                        inputButton("Describe", "text.cursor") { showDescription = true }
                        inputButton("Barcode", "barcode.viewfinder") { showBarcode = true }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(coordinator.phase != .idle)
            }

            if let errorText = coordinator.errorText {
                Text(errorText).font(.footnote).foregroundColor(.red)
            }

            if let result = coordinator.lastResult {
                resultSummary(result)
            }

            Text(String(format: NSLocalizedString("The photo or text is sent to %@ with your own key. A barcode lookup sends only the number to Open Food Facts. Nothing is saved until you continue and confirm. Not medical advice.", comment: ""),
                        AIProviderSettings.title(AIProviderSettings.selected())))
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        // Text wraps inside the screen width instead of stretching the scroll view.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(CardBackground())
        .padding(.horizontal)
        .sheet(isPresented: $showCamera) {
            FoodCameraView(
                onImage: { data in showCamera = false; coordinator.analyzePhotos([data], into: viewModel) },
                onCancel: { showCamera = false }
            )
        }
        .sheet(isPresented: $showLibrary) {
            FoodLibraryPicker(limit: 4) { images in
                showLibrary = false
                if !images.isEmpty { coordinator.analyzePhotos(images, into: viewModel) }
            }
        }
        .sheet(isPresented: $showDescription) { descriptionSheet }
        .sheet(isPresented: $showBarcode) {
            FoodBarcodeSheet(
                onCode: { code in showBarcode = false; coordinator.lookUpBarcode(code) },
                onCancel: { showBarcode = false }
            )
        }
        .sheet(item: $coordinator.flow, onDismiss: { coordinator.flowDismissed() }) { flow in
            NavigationView {
                switch flow.stage {
                case .reference(let original, let suggestions):
                    ReferenceSuggestionsView(result: original, suggestions: suggestions) { approved in
                        coordinator.finishReference(approved: approved)
                    }
                case .review(let result):
                    FoodAnalysisReviewView(
                        result: result,
                        notes: reviewNotes(for: result),
                        providerName: AIProviderSettings.title(AIProviderSettings.selected()),
                        isRechecking: coordinator.isRechecking,
                        recheckError: coordinator.recheckError,
                        onApprove: { coordinator.approve($0, into: viewModel) },
                        onRecheck: { coordinator.recheck(base: $0, edited: $1) },
                        onCancel: { coordinator.cancel() }
                    )
                    .id(flow.revision)
                }
            }
            .navigationViewStyle(.stack)
            .interactiveDismissDisabled(coordinator.isRechecking)
        }
    }

    /// The caution headline (if any) and the warning lines, shown on the review screen.
    private func reviewNotes(for result: FoodAnalysisResult) -> [String] {
        (FoodFinderCaution.headline(for: result).map { [$0] } ?? []) + FoodFinderWarningText.lines(for: result)
    }

    private func inputButton(_ title: String, _ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(NSLocalizedString(title, comment: ""), systemImage: systemImage).frame(maxWidth: .infinity)
        }
    }

    private func resultSummary(_ result: FoodAnalysisResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.mealTitle).font(.subheadline.weight(.semibold))
            Text(NSLocalizedString("The carb entry screen was pre-filled. Check every value before you continue.", comment: ""))
                .font(.footnote)
            if let headline = FoodFinderCaution.headline(for: result) {
                Text(headline).font(.footnote.weight(.semibold)).foregroundColor(.orange)
            }
            ForEach(FoodFinderWarningText.lines(for: result), id: \.self) { line in
                Text(line).font(.footnote).foregroundColor(.orange)
            }
        }
    }

    private var descriptionSheet: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                Text(NSLocalizedString("Describe the meal, with portions if you can.", comment: ""))
                    .font(.footnote).foregroundColor(.secondary)
                TextEditor(text: $descriptionText)
                    .frame(minHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4)))
                Spacer()
            }
            .padding()
            .navigationTitle(NSLocalizedString("Describe meal", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(NSLocalizedString("Cancel", comment: "")) { showDescription = false }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(NSLocalizedString("Analyse", comment: "")) {
                        showDescription = false
                        coordinator.analyzeText(descriptionText, into: viewModel)
                    }
                    .disabled(descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
