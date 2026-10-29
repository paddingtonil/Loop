//
//  PowerPack_AIRequestOptions.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  PowerPack — Chooses the sampling and token-limit parameters each AI model accepts.
//  Newer reasoning models refuse a temperature setting, and OpenAI's refuse max_tokens. A request
//  is first sent with temperature; when the provider refuses a parameter, the model ID is saved
//  and the request is sent again without it. No model names are hard-coded, so models released
//  later work the same way. Shared by FoodFinder, LoopInsights and the model finder.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import Foundation

enum PowerPack_AIRequestFormat {
    case openAI
    case anthropic
    case gemini
}

/// Parameters a model refused in an earlier request.
struct PowerPack_ModelQuirks: Codable, Equatable {
    var omitsTemperature = false
    var usesMaxCompletionTokens = false
}

enum PowerPack_AIRequestOptions {
    /// One retry per parameter that can be changed (token limit name, temperature).
    static let maxAdaptations = 2
    /// Models that refuse temperature are the ones that think before answering, and their
    /// thinking counts against the output limit; below this the answer can be cut off.
    static let thinkingModelMinimumOutputTokens = 8192
    static let storageKey = "com.loopkit.Loop.powerPack.modelQuirks"

    // MARK: Saved quirks

    /// Returns the parameters this model refused before, or the known starting quirks for a model not seen yet.
    static func quirks(for model: String, provider: PowerPack_AIProvider? = nil, defaults: UserDefaults = .standard) -> PowerPack_ModelQuirks {
        loadAll(defaults)[key(model)] ?? knownQuirks(provider: provider, model: model)
    }

    // MARK: Known starting quirks

    /// What is known (October 2026) about each provider's models, so the first request to a
    /// known model is already correct. Rules match version numbers, not exact names, so later
    /// models in the same families are covered. A wrong guess is corrected by the retry in `send`.
    static func knownQuirks(provider: PowerPack_AIProvider?, model: String) -> PowerPack_ModelQuirks {
        let id = key(model)
        // Hosts such as OpenRouter prefix the vendor ("anthropic/claude-opus-5-5").
        let name = id.split(separator: "/").last.map(String.init) ?? id
        var quirks = PowerPack_ModelQuirks()
        // OpenAI accepts max_completion_tokens on all its chat models and refuses max_tokens on
        // reasoning models; other OpenAI-format hosts may not accept the newer name.
        quirks.usesMaxCompletionTokens = provider == .openAI
        quirks.omitsTemperature = isOpenAIReasoningModel(name) || isClaudeWithoutSampling(name) || isGemini3OrLater(name)
        return quirks
    }

    /// GPT-5 and later, and the o-series (o1, o3, o4-mini), accept only the default temperature.
    private static func isOpenAIReasoningModel(_ name: String) -> Bool {
        if let version = leadingVersion(name, after: "gpt-") { return version >= 5 }
        return name.count > 1 && name.hasPrefix("o") && name.dropFirst().first?.isNumber == true
    }

    /// Claude Opus 4.7 and later, every Claude 5 or later model, and Fable/Mythos refuse temperature.
    private static func isClaudeWithoutSampling(_ name: String) -> Bool {
        guard name.hasPrefix("claude-") else { return false }
        let parts = name.dropFirst("claude-".count).split(separator: "-").map(String.init)
        // Older IDs put the version first ("claude-3-5-sonnet-…"); those accept temperature.
        guard let family = parts.first, Int(family) == nil else { return false }
        if family == "fable" || family == "mythos" { return true }
        guard parts.count > 1, let major = Int(parts[1]) else { return false }
        if major >= 5 { return true }
        // A third part under 100 is a minor version; longer numbers are dates ("…-4-20250514").
        let minor = parts.count > 2 ? Int(parts[2]).flatMap { $0 < 100 ? $0 : nil } : nil
        return family == "opus" && major == 4 && (minor ?? 0) >= 7
    }

    /// Google recommends the default temperature for Gemini 3; lower values can degrade its reasoning.
    private static func isGemini3OrLater(_ name: String) -> Bool {
        (leadingVersion(name, after: "gemini-") ?? 0) >= 3
    }

    /// "gpt-4.1-mini" after "gpt-" → 4.1; nil when no number follows the prefix.
    private static func leadingVersion(_ name: String, after prefix: String) -> Double? {
        guard name.hasPrefix(prefix) else { return nil }
        let digits = name.dropFirst(prefix.count).prefix { $0.isNumber || $0 == "." }
        return Double(digits)
    }

    /// Saves the parameters this model refused, so later requests leave them out on the first try.
    static func save(_ quirks: PowerPack_ModelQuirks, for model: String, defaults: UserDefaults = .standard) {
        var all = loadAll(defaults)
        all[key(model)] = quirks
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private static func key(_ model: String) -> String {
        model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func loadAll(_ defaults: UserDefaults) -> [String: PowerPack_ModelQuirks] {
        guard let data = defaults.data(forKey: storageKey),
              let all = try? JSONDecoder().decode([String: PowerPack_ModelQuirks].self, from: data) else { return [:] }
        return all
    }

    // MARK: Adapting to an error

    /// Returns new quirks when the error response says the model refused temperature or
    /// max_tokens, or nil when the error has another cause (and resending would not help).
    static func adapted(_ quirks: PowerPack_ModelQuirks, format: PowerPack_AIRequestFormat, status: Int, body: Data) -> PowerPack_ModelQuirks? {
        guard status == 400 || status == 422 else { return nil }
        var next = quirks
        switch PowerPack_ModelFinder.failureReason(status: status, body: body) {
        case .needsMaxCompletionTokens where format == .openAI:
            // Either name can be the refused one: a host that refuses the newer name gets max_tokens back.
            next.usesMaxCompletionTokens.toggle()
        case .rejectsTemperature where !quirks.omitsTemperature:
            next.omitsTemperature = true
        default:
            return nil
        }
        return next
    }

    // MARK: Request parameters

    /// The token-limit and sampling fields to merge into a request body. For Gemini they are
    /// nested in `generationConfig`; topP/topK are left out together with temperature.
    static func parameters(format: PowerPack_AIRequestFormat, quirks: PowerPack_ModelQuirks, temperature: Double, maxTokens: Int) -> [String: Any] {
        switch format {
        case .openAI:
            var params: [String: Any] = [quirks.usesMaxCompletionTokens ? "max_completion_tokens" : "max_tokens": maxTokens]
            if !quirks.omitsTemperature { params["temperature"] = temperature }
            return params
        case .anthropic:
            // Anthropic requires max_tokens on every request.
            var params: [String: Any] = ["max_tokens": maxTokens]
            if !quirks.omitsTemperature { params["temperature"] = temperature }
            return params
        case .gemini:
            var config: [String: Any] = ["maxOutputTokens": maxTokens]
            if !quirks.omitsTemperature {
                config["temperature"] = temperature
                config["topP"] = 0.95
                config["topK"] = 8
            }
            return ["generationConfig": config]
        }
    }

    /// The output limit to send: raised to the thinking-model minimum for models that refused temperature.
    static func outputTokens(_ requested: Int, quirks: PowerPack_ModelQuirks) -> Int {
        quirks.omitsTemperature ? max(requested, thinkingModelMinimumOutputTokens) : requested
    }

    // MARK: Reading Claude responses

    /// The answer text of a Claude response. Models that think put thinking blocks before the
    /// text block, so the first content block is not always the answer.
    static func anthropicText(from json: [String: Any]) -> String? {
        guard let blocks = json["content"] as? [[String: Any]] else { return nil }
        let texts = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
        return texts.isEmpty ? nil : texts.joined()
    }

    // MARK: Sending

    /// Builds and sends a request with the model's saved quirks. When the provider refuses
    /// temperature or max_tokens, saves the new quirks and sends the request again.
    static func send(model: String,
                     provider: PowerPack_AIProvider? = nil,
                     format: PowerPack_AIRequestFormat,
                     defaults: UserDefaults = .standard,
                     build: (PowerPack_ModelQuirks) throws -> URLRequest,
                     execute: (URLRequest) async throws -> (Data, URLResponse)) async throws -> (Data, URLResponse) {
        var current = quirks(for: model, provider: provider, defaults: defaults)
        var adaptations = 0
        while true {
            let (data, response) = try await execute(try build(current))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard adaptations < maxAdaptations,
                  let next = adapted(current, format: format, status: status, body: data) else {
                return (data, response)
            }
            current = next
            adaptations += 1
            save(current, for: model, defaults: defaults)
        }
    }
}
