//
//  FoodFinder_SettingsView.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  FoodFinder — Settings UI for configuring AI food analysis providers.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import SwiftUI

/// Settings view for configuring AI food analysis.
/// Completely AI-agnostic — the user enters their own endpoint, key, and model.
struct AISettingsView: View {
    @Environment(\.openURL) var openURL

    /// Drives the text-search provider picker; the choice is persisted by
    /// `setProviderForSearchType`.
    @ObservedObject private var aiService = ConfigurableAIService.shared

    // Feature toggles
    @AppStorage("com.loopkit.Loop.foodSearchEnabled") private var foodSearchEnabled: Bool = false
    @AppStorage("com.loopkit.Loop.advancedDosingRecommendationsEnabled") private var advancedDosingRecommendationsEnabled: Bool = false
    @AppStorage("com.loopkit.Loop.locationTaggingEnabled") private var locationTaggingEnabled: Bool = true
    @AppStorage("com.loopkit.Loop.carbTrackingEnabled") private var carbTrackingEnabled: Bool = false
    @AppStorage("com.loopkit.Loop.analysisHistoryRetentionDays") private var retentionDays: Int = 7

    // AI configuration (non-secret settings)
    @AppStorage("com.loopkit.Loop.customAIBaseURL") private var baseURL: String = ""
    @AppStorage("com.loopkit.Loop.customAIModel") private var model: String = ""
    @AppStorage("com.loopkit.Loop.customAIEndpointPath") private var endpointPath: String = ""
    @AppStorage("com.loopkit.Loop.customAIAPIVersion") private var apiVersion: String = ""
    @AppStorage("com.loopkit.Loop.customAIOrganization") private var organizationID: String = ""

    // API keys (Keychain-backed)
    @State private var apiKey: String = ""
    @State private var usdaAPIKey: String = ""
    @State private var spoonacularAPIKey: String = ""

    // UI state
    @State private var showAPIKey: Bool = false
    @State private var showUSDAKey: Bool = false
    @State private var showSpoonacularKey: Bool = false
    @State private var isTesting: Bool = false
    @State private var testResult: TestResult?
    @State private var isTestingSpoonacular: Bool = false
    @State private var spoonacularTestResult: TestResult?
    @State private var isTestingUSDA: Bool = false
    @State private var usdaTestResult: TestResult?
    @State private var showAdvanced: Bool = false
    @State private var formatOverride: RequestFormat?
    @State private var analysisRecords: [FoodFinder_AnalysisRecord] = []
    @State private var showHistoryList: Bool = false

    private enum TestResult {
        case success
        case successWithVisionWarning(String)
        case warning(String)
        case failure(String)
    }

    var body: some View {
        Form {
            featureToggleSection
            if foodSearchEnabled {
                textSearchProviderSection
                usdaSection
                spoonacularSection
                aiConfigSection
                advancedSettingsSection
            }
            LoopInsights_SubstackPromoFooter()
            PowerPack_VersionFooter()
        }
        .navigationTitle("FoodFinder")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Load API keys from Keychain
            apiKey = FoodFinder_SecureStorage.loadAPIKey() ?? ""
            usdaAPIKey = FoodFinder_SecureStorage.loadUSDAKey() ?? ""
            spoonacularAPIKey = FoodFinder_SecureStorage.loadSpoonacularKey() ?? ""

            // Clear stale endpoint path if it matches a different format's default
            // (e.g. Google endpoint left over when user switched to OpenAI)
            if !endpointPath.isEmpty {
                let detectedFormat = RequestFormat.detect(from: baseURL)
                let isKnownDefault = RequestFormat.allCases.contains { $0.defaultEndpoint == endpointPath }
                if isKnownDefault && endpointPath != detectedFormat.defaultEndpoint {
                    endpointPath = ""
                }
            }

            // Ensure an AIProviderConfiguration exists if we have a base URL
            if !baseURL.isEmpty {
                saveConfiguration()
            }

            // Load analysis history records
            loadAnalysisRecords()
        }
    }

    private func loadAnalysisRecords() {
        FoodFinder_AnalysisHistoryStore.pruneExpired(retentionDays: retentionDays)
        analysisRecords = FoodFinder_AnalysisHistoryStore.loadRecords(retentionDays: retentionDays)
    }
}

// MARK: - Sections

extension AISettingsView {

    // MARK: Text Search Provider

    /// Database providers usable for text/voice search. The AI provider is
    /// excluded — it has no food index of its own and the router just falls
    /// through to these two anyway.
    private var textSearchProviders: [SearchProvider] {
        aiService.getAvailableProvidersForSearchType(.textSearch)
            .filter { !$0.requiresAPIKey }
    }

    private var textSearchProviderSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass.circle.fill")
                        .foregroundColor(Color(red: 107/255, green: 47/255, blue: 160/255))
                    Text("TEXT SEARCH SOURCE")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                        .lineLimit(1)
                        .layoutPriority(1)
                }

                Picker("Search database", selection: Binding(
                    get: { aiService.textSearchProvider },
                    set: { aiService.setProviderForSearchType($0, searchType: .textSearch) }
                )) {
                    ForEach(textSearchProviders, id: \.self) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }

                Text("Which database text and voice searches use. Your choice is saved between launches.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Hebrew searches always use the Israeli Ministry of Health national food database first, regardless of this setting, and fall back here if it has no match.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: Feature Toggle

    private var featureToggleSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "fork.knife.circle.fill")
                        .foregroundColor(Color(red: 107/255, green: 47/255, blue: 160/255))
                    Text("FOODFINDER")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                Toggle("Enable FoodFinder", isOn: $foodSearchEnabled)
                Text("Enable this to show FoodFinder in the carb entry screen. Requires Internet connection. When disabled, the feature is hidden but settings are preserved.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if foodSearchEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "cross.fill")
                                .foregroundColor(.red)
                            Text("MEDICAL DISCLAIMER")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)
                                .lineLimit(1)
                        }
                        Text("AI nutritional estimates are approximations only. Verify information before dosing; this is not medical advice.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Divider()
                    HStack {
                        Text("Analysis History")
                        Picker("", selection: $retentionDays) {
                            Text("Last 24 hours").tag(1)
                            Text("Last 7 days").tag(7)
                            Text("Last 14 days").tag(14)
                            Text("Last 30 days").tag(30)
                        }
                        .pickerStyle(.menu)
                    }
                    Text("How long to keep AI-analyzed foods available for quick re-entry.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    analysisHistoryList
                    Divider()
                    Toggle("Advanced Dosing Insights", isOn: $advancedDosingRecommendationsEnabled)
                    Text("Enable advanced dosing advice including Fat/Protein Units (FPUs) calculations. Prolongs analysis.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Divider()
                    Toggle("Location Tagging", isOn: $locationTaggingEnabled)
                    Text("Tag meals with where you ate. Helps the AI identify restaurant menu items for more accurate carb estimates. Location data stays on your device.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Divider()
                    Toggle("Carb Tracking", isOn: $carbTrackingEnabled)
                    Text("Track daily carb totals with weekly comparisons and historical trends. Shows a summary card when logging carbs.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if carbTrackingEnabled {
                        NavigationLink {
                            FoodFinder_CarbTrackingDashboard()
                                .navigationTitle("Carb Tracking")
                                .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            HStack {
                                Image(systemName: "chart.bar.fill")
                                    .foregroundColor(Color(red: 107/255, green: 47/255, blue: 160/255))
                                Text("View Carb Dashboard")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Analysis History List

    @ViewBuilder
    private var analysisHistoryList: some View {
        if !analysisRecords.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                // Tap to expand/collapse
                Button(action: { withAnimation { showHistoryList.toggle() } }) {
                    HStack {
                        Text("Recent Analyses (\(analysisRecords.count))")
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: showHistoryList ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if showHistoryList {
                    // Scrollable compact list with thumbnails
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(analysisRecords) { record in
                                HStack(spacing: 8) {
                                    if let thumbID = record.thumbnailID,
                                       let uiImage = FavoriteFoodImageStore.loadThumbnail(id: thumbID) {
                                        Image(uiImage: uiImage)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: 32, height: 32)
                                            .clipShape(RoundedRectangle(cornerRadius: 5))
                                    } else {
                                        Image(systemName: "fork.knife.circle.fill")
                                            .font(.system(size: 20))
                                            .foregroundColor(Color(red: 107/255, green: 47/255, blue: 160/255))
                                            .frame(width: 32, height: 32)
                                    }

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(record.name)
                                            .font(.subheadline)
                                            .lineLimit(1)
                                        Text("\(Int(record.carbsGrams))g carbs")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    Button(action: {
                                        FoodFinder_AnalysisHistoryStore.pendingReUseRecord = record
                                        NotificationCenter.default.post(name: .foodFinderReUseAnalysis, object: nil)
                                    }) {
                                        Text("Re-use")
                                            .font(.caption)
                                            .fontWeight(.medium)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(Color(red: 107/255, green: 47/255, blue: 160/255))
                                            .foregroundColor(.white)
                                            .cornerRadius(8)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }

                HStack {
                    Spacer()
                    Button(action: {
                        FoodFinder_AnalysisHistoryStore.clearAll()
                        analysisRecords = []
                        showHistoryList = false
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.caption)
                            Text("Clear All")
                                .font(.caption)
                        }
                        .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: AI Configuration

    private var aiConfigSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundColor(Color(red: 107/255, green: 47/255, blue: 160/255))
                    Text("AI CONFIGURATION")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                }
                Text("Enter your preferred AI API connection details for any AI service that supports vision-capable chat completions.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // API key signup links
                VStack(alignment: .leading, spacing: 6) {
                    Text("OR, get an API key from one of these popular providers:").font(.caption).foregroundColor(.secondary)
                    HStack(spacing: 12) {
                        apiKeyLink("OpenAI  ", url: "https://platform.openai.com/api-keys", color: .green)
                        apiKeyLink("Anthropic  ", url: "https://console.anthropic.com/settings/keys", color: .orange)
                        apiKeyLink("Gemini  ", url: "https://aistudio.google.com/apikey", color: .blue)
                        apiKeyLink("Grok  ", url: "https://console.x.ai", color: .red)
                    }
                }

                // Base URL
                VStack(alignment: .leading, spacing: 4) {
                    Text("Base URL").font(.caption).foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        TextField("", text: $baseURL)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .overlay(alignment: .leading) {
                                if baseURL.isEmpty {
                                    Text("e.g. https://api.example.com/v1")
                                        .foregroundColor(.secondary)
                                        .padding(.leading, 4)
                                        .allowsHitTesting(false)
                                }
                            }
                            .foregroundColor(.primary)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .onChange(of: baseURL) { _ in
                                // Reset endpoint path and format override so auto-detection
                                // drives the correct defaults for the new URL.
                                endpointPath = ""
                                formatOverride = nil
                                testResult = nil
                                saveConfiguration()
                            }
                        if !baseURL.isEmpty {
                            Button(action: { baseURL = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // API Key
                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key").font(.caption).foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        Group {
                            if showAPIKey {
                                TextField("Enter your API key", text: $apiKey)
                            } else {
                                SecureField("Enter your API key", text: $apiKey)
                            }
                        }
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .onChange(of: apiKey) { newValue in
                            saveAPIKey(newValue)
                            testResult = nil
                        }
                        Button(action: { showAPIKey.toggle() }) {
                            Image(systemName: showAPIKey ? "eye.slash" : "eye")
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                        if !apiKey.isEmpty {
                            Button(action: { apiKey = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !apiKey.isEmpty {
                        Text("Stored securely in Keychain")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                }

                // Model
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model").font(.caption).foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        TextField("e.g. gpt-4o, claude-sonnet-4-20250514, gemini-2.0-flash", text: $model)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .onChange(of: model) { _ in
                                testResult = nil
                                saveConfiguration()
                            }
                        if !model.isEmpty {
                            Button(action: { model = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Test Connection
                HStack(spacing: 12) {
                    Button(action: testConnection) {
                        HStack(spacing: 6) {
                            if isTesting {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Image(systemName: "checkmark.seal")
                            }
                            Text("Test Connection")
                        }
                        .foregroundColor(Color(red: 107/255, green: 47/255, blue: 160/255))
                    }
                    .buttonStyle(.plain)
                    .disabled(isTesting || apiKey.isEmpty || baseURL.isEmpty)
                    .opacity((isTesting || apiKey.isEmpty || baseURL.isEmpty) ? 0.5 : 1.0)

                    if let result = testResult {
                        switch result {
                        case .success:
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                Text("Connected").font(.caption).foregroundColor(.green)
                            }
                        case .successWithVisionWarning(let message):
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                    Text("Connected").font(.caption).foregroundColor(.green)
                                }
                                HStack(alignment: .top, spacing: 4) {
                                    Image(systemName: "eye.trianglebadge.exclamationmark").foregroundColor(.orange)
                                    Text(message).font(.caption).foregroundColor(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        case .warning(let message):
                            HStack(alignment: .top, spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                                Text(message).font(.caption).foregroundColor(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        case .failure(let message):
                            HStack(alignment: .top, spacing: 4) {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                                Text(message).font(.caption).foregroundColor(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: USDA Database

    private var usdaSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "leaf").foregroundColor(.green)
                    Text("USDA DATABASE (TEXT SEARCH)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                }

                HStack(spacing: 8) {
                    Group {
                        if showUSDAKey {
                            TextField("Enter your USDA API key (optional)", text: $usdaAPIKey)
                        } else {
                            SecureField("Enter your USDA API key (optional)", text: $usdaAPIKey)
                        }
                    }
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .onChange(of: usdaAPIKey) { newValue in
                        saveUSDAKey(newValue)
                        usdaTestResult = nil
                    }
                    Button(action: { showUSDAKey.toggle() }) {
                        Image(systemName: showUSDAKey ? "eye.slash" : "eye").foregroundColor(.green)
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 12) {
                    Button(action: testUSDAKey) {
                        HStack(spacing: 6) {
                            if isTestingUSDA {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Image(systemName: "checkmark.seal")
                            }
                            Text("Test Connection")
                        }
                        .foregroundColor(.green)
                    }
                    .buttonStyle(.plain)
                    .disabled(isTestingUSDA || usdaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity((isTestingUSDA || usdaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ? 0.5 : 1.0)

                    if let result = usdaTestResult {
                        switch result {
                        case .success:
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                Text("Key works").font(.caption).foregroundColor(.green)
                            }
                        case .warning(let message):
                            HStack(alignment: .top, spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                                Text(message).font(.caption).foregroundColor(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        case .failure(let message):
                            HStack(alignment: .top, spacing: 4) {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                                Text(message).font(.caption).foregroundColor(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        case .successWithVisionWarning:
                            EmptyView()
                        }
                    }
                }
                Button(action: { if let url = URL(string: "https://fdc.nal.usda.gov/api-guide") { openURL(url) } }) {
                    HStack { Image(systemName: "info.circle"); Text("How to get a key") }
                        .foregroundColor(.green)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 2) {
                    Text("How to obtain a USDA API key:")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text("1. Open the USDA FoodData Central API Guide. 2. Sign in or create an account. 3. Request a new API key. 4. Copy and paste it here. The key activates immediately.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Why add a key?")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text("Without your own key, searches use a public DEMO_KEY that is heavily rate-limited and often returns 429 errors. Adding your free personal key avoids this.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: Spoonacular Restaurant Menus

    private var spoonacularSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "fork.knife").foregroundColor(.purple)
                    Text("RESTAURANT MENUS (SAVES AI TOKENS)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                }

                HStack(spacing: 8) {
                    Group {
                        if showSpoonacularKey {
                            TextField("Enter your Spoonacular API key (optional)", text: $spoonacularAPIKey)
                        } else {
                            SecureField("Enter your Spoonacular API key (optional)", text: $spoonacularAPIKey)
                        }
                    }
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .onChange(of: spoonacularAPIKey) { newValue in
                        saveSpoonacularKey(newValue)
                        spoonacularTestResult = nil
                    }
                    Button(action: { showSpoonacularKey.toggle() }) {
                        Image(systemName: showSpoonacularKey ? "eye.slash" : "eye").foregroundColor(.purple)
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 12) {
                    Button(action: testSpoonacularKey) {
                        HStack(spacing: 6) {
                            if isTestingSpoonacular {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Image(systemName: "checkmark.seal")
                            }
                            Text("Test Connection")
                        }
                        .foregroundColor(.purple)
                    }
                    .buttonStyle(.plain)
                    .disabled(isTestingSpoonacular || spoonacularAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity((isTestingSpoonacular || spoonacularAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ? 0.5 : 1.0)

                    if let result = spoonacularTestResult {
                        switch result {
                        case .success:
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                Text("Key works").font(.caption).foregroundColor(.green)
                            }
                        case .warning(let message):
                            HStack(alignment: .top, spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                                Text(message).font(.caption).foregroundColor(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        case .failure(let message):
                            HStack(alignment: .top, spacing: 4) {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                                Text(message).font(.caption).foregroundColor(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        case .successWithVisionWarning:
                            EmptyView()
                        }
                    }
                }
                Button(action: { if let url = URL(string: "https://spoonacular.com/food-api/console#Dashboard") { openURL(url) } }) {
                    HStack { Image(systemName: "info.circle"); Text("Get a free key") }
                        .foregroundColor(.purple)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 2) {
                    Text("How to obtain a free Spoonacular API key:")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text("1. Open spoonacular.com/food-api and create a free account. 2. Open your dashboard and copy your API key. 3. Paste it here. The free tier is plenty for personal use.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("What this does:")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text("When your phone confirms you're within 200 ft of a restaurant, FoodFinder shows that restaurant's menu so you can tap your item and use its real nutrition — skipping the AI photo analysis and saving tokens. Menu data is chain-focused, so local spots still fall back to AI.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: Advanced Settings

    private var advancedSettingsSection: some View {
        Section {
            DisclosureGroup("Advanced API Settings", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 12) {
                    PowerPack_APIUsageControls()

                    Divider()

                    Text("This section is for self-hosted, Azure, or non-standard API endpoints. Most users can ignore these.")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    // Endpoint path
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Endpoint Path").font(.caption).foregroundColor(.secondary)
                        TextField("e.g. /chat/completions", text: $endpointPath)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .onChange(of: endpointPath) { _ in saveConfiguration() }
                        Text("Leave blank to use the default for your chosen format.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    // API Version
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Version").font(.caption).foregroundColor(.secondary)
                        TextField("e.g. 2024-06-01 (Azure only)", text: $apiVersion)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .onChange(of: apiVersion) { _ in saveConfiguration() }
                    }

                    // Organization ID
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Organization ID").font(.caption).foregroundColor(.secondary)
                        TextField("e.g. org-... (OpenAI, Azure)", text: $organizationID)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .onChange(of: organizationID) { _ in saveConfiguration() }
                    }

                    // Request Format override
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Request Format Override").font(.caption).foregroundColor(.secondary)
                        Picker("Format", selection: Binding(
                            get: { formatOverride ?? .openAICompatible },
                            set: { formatOverride = $0; saveConfiguration() }
                        )) {
                            ForEach(RequestFormat.allCases, id: \.self) { format in
                                Text(format.displayName).tag(format)
                            }
                        }
                        .pickerStyle(.segmented)
                        HStack(spacing: 4) {
                            Text("Auto-detected:")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(resolvedFormat.displayName)
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                            if formatOverride != nil {
                                Button("Reset") { formatOverride = nil; saveConfiguration() }
                                    .font(.caption2)
                            }
                        }
                        Text("Most providers use Chat Completions. Only change this if auto-detection is wrong.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    if !endpointPreview.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Full endpoint URL:")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(endpointPreview)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

}

// MARK: - Helpers

extension AISettingsView {

    private func apiKeyLink(_ name: String, url: String, color: Color) -> some View {
        Button(action: { if let u = URL(string: url) { openURL(u) } }) {
            Text(name)
                .font(.caption)
                .foregroundColor(color)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Actions

extension AISettingsView {

    /// The effective request format: user override if set, otherwise auto-detected from base URL.
    private var resolvedFormat: RequestFormat {
        formatOverride ?? RequestFormat.detect(from: baseURL)
    }

    private func saveAPIKey(_ key: String) {
        if key.isEmpty {
            try? FoodFinder_SecureStorage.deleteAPIKey()
        } else {
            try? FoodFinder_SecureStorage.saveAPIKey(key)
        }
        saveConfiguration()
    }

    private func saveUSDAKey(_ key: String) {
        if key.isEmpty {
            try? FoodFinder_SecureStorage.deleteUSDAKey()
        } else {
            try? FoodFinder_SecureStorage.saveUSDAKey(key)
        }
    }

    private func saveSpoonacularKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? FoodFinder_SecureStorage.deleteSpoonacularKey()
        } else {
            try? FoodFinder_SecureStorage.saveSpoonacularKey(trimmed)
        }
    }

    /// Saves the current settings as an AIProviderConfiguration and sets it as active.
    private func saveConfiguration() {
        let config = AIProviderConfiguration(
            name: "AI Provider",
            baseURL: baseURL,
            model: model,
            endpointPath: endpointPath.isEmpty ? nil : endpointPath,
            requestFormat: resolvedFormat,
            apiVersion: apiVersion.isEmpty ? nil : apiVersion,
            organizationID: organizationID.isEmpty ? nil : organizationID
        )

        // Always maintain a single configuration — replace or create
        var configs = UserDefaults.standard.aiProviderConfigurations

        if let index = configs.firstIndex(where: { _ in true }) {
            // Replace the first (only) config, keeping its ID for stability
            let existingID = configs[index].id
            var updated = config
            updated.id = existingID
            configs[index] = updated
            UserDefaults.standard.aiProviderConfigurations = configs
            UserDefaults.standard.activeAIProviderConfigurationId = existingID
        } else {
            configs.append(config)
            UserDefaults.standard.aiProviderConfigurations = configs
            UserDefaults.standard.activeAIProviderConfigurationId = config.id
        }
    }

    /// Validates the Spoonacular key against a cheap request so a bad paste is
    /// caught here rather than at a restaurant. Distinguishes a rejected key
    /// (401) from a hit quota (402/429), which are otherwise both non-200.
    private func testSpoonacularKey() {
        let trimmed = spoonacularAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Persist the current field value so the service tests exactly this key.
        saveSpoonacularKey(trimmed)
        isTestingSpoonacular = true
        spoonacularTestResult = nil

        Task {
            var result: TestResult
            do {
                try await FoodFinder_SpoonacularService.shared.validateSavedKey()
                result = .success
            } catch FoodFinder_SpoonacularService.SpoonacularError.quotaExceeded {
                result = .warning("Key is valid, but its daily free quota is used up. It'll work again tomorrow.")
            } catch let FoodFinder_SpoonacularService.SpoonacularError.server(code) where code == 401 {
                result = .failure("Spoonacular rejected this key. Double-check you pasted it exactly, with no missing or extra characters.")
            } catch {
                result = .failure("Couldn't reach Spoonacular: \(error.localizedDescription)")
            }
            await MainActor.run {
                isTestingSpoonacular = false
                spoonacularTestResult = result
            }
        }
    }

    /// Validates the USDA key against a cheap search so a bad paste is caught
    /// here rather than mid-search. USDA rejects a bad key with 403 and
    /// rate-limits with 429, which we surface as distinct messages.
    private func testUSDAKey() {
        let trimmed = usdaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Persist the current field value so the service tests exactly this key.
        saveUSDAKey(trimmed)
        isTestingUSDA = true
        usdaTestResult = nil

        Task {
            var result: TestResult
            do {
                try await USDAFoodDataService.shared.validateSavedKey()
                result = .success
            } catch OpenFoodFactsError.rateLimitExceeded {
                result = .warning("Key is valid, but it's rate-limited right now. Try again in a bit.")
            } catch OpenFoodFactsError.serverError(let code) where code == 403 {
                result = .failure("USDA rejected this key. Double-check you pasted it exactly, with no missing or extra characters.")
            } catch {
                result = .failure("Couldn't reach USDA: \(error.localizedDescription)")
            }
            await MainActor.run {
                isTestingUSDA = false
                usdaTestResult = result
            }
        }
    }

    private func testConnection() {
        guard !baseURL.isEmpty, !apiKey.isEmpty else { return }

        isTesting = true
        testResult = nil

        let config = AIProviderConfiguration(
            name: "AI Provider",
            baseURL: baseURL,
            model: model,
            endpointPath: endpointPath.isEmpty ? nil : endpointPath,
            requestFormat: resolvedFormat,
            apiVersion: apiVersion.isEmpty ? nil : apiVersion,
            organizationID: organizationID.isEmpty ? nil : organizationID,
            apiKey: apiKey
        )

        Task {
            let result = await AIServiceManager.shared.testConnection(to: config)
            await MainActor.run {
                isTesting = false
                if result.success {
                    // 402/429 are "connected with caveats" — show as warning
                    if let code = result.statusCode, (code == 402 || code == 429) {
                        testResult = .warning(result.message)
                    } else if result.supportsVision == false {
                        testResult = .successWithVisionWarning("Connected — but this model may not support image analysis. FoodFinder requires a vision-capable model.")
                    } else {
                        testResult = .success
                    }
                } else {
                    testResult = .failure(result.message)
                }
            }
        }
    }

    private var endpointPreview: String {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return "" }
        let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = endpointPath.isEmpty ? resolvedFormat.defaultEndpoint : endpointPath
        let resolvedPath = path.replacingOccurrences(of: "{MODEL}", with: model.isEmpty ? "<model>" : model)
        return "\(trimmed)\(resolvedPath)"
    }
}

// MARK: - Preview

#if DEBUG
struct AISettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            AISettingsView()
        }
    }
}
#endif

// MARK: - Version Footer
//
// The FoodFinder-specific versionFooterSection that used to live here was
// replaced by `PowerPack_VersionFooter()` — a reusable widget shared by
// every PowerPack feature's settings view. Single source of truth, drops
// into any Form/List, ensures new features pick up the same version
// surface without per-file duplication.

// MARK: - PowerPack Version Helper
//
// The old fileprivate FoodFinder_PowerPackVersion enum that mirrored
// Loop's CFBundleVersion lived here. Replaced with the shared
// PowerPack_BuildInfo helper in Loop/Resources/LoopInsights/, which
// renders the same footer text but with PowerPack's own semver + the
// Loop submodule commit short SHA so user-reported versions can be
// mapped back to specific commits.
