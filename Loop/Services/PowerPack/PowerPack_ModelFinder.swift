//
//  PowerPack_ModelFinder.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  PowerPack — Finds the current models from OpenAI, Claude, Gemini and Grok that accept the
//  requests PowerPack's AI features send (image input for FoodFinder), by listing the provider's
//  models and sending each a tiny test request. Temperature and the token-limit name are adapted
//  per model by PowerPack_AIRequestOptions, so refusing either does not make a model incompatible.
//  Shared by FoodFinder, LoopInsights and AutoPresets.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import Foundation
import UIKit

// MARK: - Providers

enum PowerPack_AIProvider: String, CaseIterable, Codable, Identifiable {
    case openAI
    case claude
    case gemini
    case grok

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .grok: return "Grok"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .claude: return "https://api.anthropic.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .grok: return "https://api.x.ai/v1"
        }
    }

    var apiKeyPageURL: URL {
        switch self {
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")!
        case .claude: return URL(string: "https://console.anthropic.com/settings/keys")!
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")!
        case .grok: return URL(string: "https://console.x.ai")!
        }
    }

    /// The request body format this provider's chat endpoint uses.
    var requestFormat: PowerPack_AIRequestFormat {
        switch self {
        case .openAI, .grok: return .openAI
        case .claude: return .anthropic
        case .gemini: return .gemini
        }
    }

    /// Google search for this provider's current models (that accept photos, for FoodFinder).
    /// Needs no API key, so it works before the user has one.
    func searchURL(purpose: PowerPack_ModelPurpose) -> URL {
        let vision = purpose == .vision ? " that support image input" : ""
        let query = "list current \(displayName) API model IDs\(vision) \(Calendar.current.component(.year, from: Date()))"
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url!
    }

    static func detect(baseURL: String) -> PowerPack_AIProvider? {
        guard let host = URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.host?.lowercased() else { return nil }
        if host == "api.openai.com" { return .openAI }
        if host.hasSuffix("anthropic.com") { return .claude }
        if host.hasSuffix("generativelanguage.googleapis.com") { return .gemini }
        if host.hasSuffix("x.ai") { return .grok }
        return nil
    }
}

/// What the calling feature sends: plain text with a system prompt (LoopInsights, AutoPresets)
/// or a photo plus text (FoodFinder).
enum PowerPack_ModelPurpose: String, Codable {
    case text
    case vision
}

// MARK: - Results

struct PowerPack_ModelInfo: Codable, Equatable {
    let id: String
    let displayName: String?
    let created: Date?
}

enum PowerPack_FailureReason: Codable, Equatable {
    case rejectsTemperature
    case needsMaxCompletionTokens
    case noImageInput
    case keyRejected
    case notAvailableToKey
    case rateLimited
    case network(String)
    case other(String)

    var text: String {
        switch self {
        case .rejectsTemperature: return NSLocalizedString("Does not accept a temperature setting", comment: "Model finder: temperature rejected")
        case .needsMaxCompletionTokens: return NSLocalizedString("Requires a newer request format (max_completion_tokens)", comment: "Model finder: max_completion_tokens")
        case .noImageInput: return NSLocalizedString("Cannot read photos", comment: "Model finder: no vision")
        case .keyRejected: return NSLocalizedString("API key not accepted", comment: "Model finder: 401")
        case .notAvailableToKey: return NSLocalizedString("Not available to this API key", comment: "Model finder: 403/404")
        case .rateLimited: return NSLocalizedString("Rate limited — try again later", comment: "Model finder: 429")
        case .network(let detail): return String(format: NSLocalizedString("Network error: %@", comment: "Model finder: network (1: detail)"), detail)
        case .other(let message): return message
        }
    }
}

enum PowerPack_CheckOutcome: Codable, Equatable {
    case compatible
    case failed(PowerPack_FailureReason)
}

struct PowerPack_ModelCheck: Codable, Equatable, Identifiable {
    let model: PowerPack_ModelInfo
    let outcome: PowerPack_CheckOutcome
    var id: String { model.id }
    var isCompatible: Bool { outcome == .compatible }
}

struct PowerPack_ModelFinderCache: Codable, Equatable {
    let date: Date
    let results: [PowerPack_ModelCheck]
}

enum PowerPack_ModelFinderError: LocalizedError, Equatable {
    case missingKey
    case keyRejected(PowerPack_AIProvider)
    case listFailed(String)
    case network(String)
    case noCandidates

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return NSLocalizedString("Enter your API key first.", comment: "Model finder: no key")
        case .keyRejected(let provider):
            return String(format: NSLocalizedString("%@ did not accept this API key. Make sure the key in the API Key field is a %@ key.", comment: "Model finder: wrong key (1, 2: provider)"), provider.displayName, provider.displayName)
        case .listFailed(let detail):
            return String(format: NSLocalizedString("Could not get the model list: %@", comment: "Model finder: list failed (1: detail)"), detail)
        case .network(let detail):
            return String(format: NSLocalizedString("Network error: %@", comment: "Model finder: network (1: detail)"), detail)
        case .noCandidates:
            return NSLocalizedString("The provider returned no chat models for this key.", comment: "Model finder: empty list")
        }
    }
}

// MARK: - Finder

enum PowerPack_ModelFinder {
    /// Most test requests per check. Testing walks from newest to oldest.
    static let maxModelsToTest = 24
    /// Testing stops early once this many compatible models are found.
    static let targetCompatible = 3
    /// Parallel test requests, kept low to stay under free-tier rate limits.
    static let parallelTests = 3
    static let cacheLifetime: TimeInterval = 24 * 3600

    // Values used in the test request. Temperature is sent first, as in PowerPack's real requests;
    // a model that refuses it is tested again without it and remembered (PowerPack_AIRequestOptions).
    static let testTemperature = 0.2
    static let testMaxTokens = 64

    // MARK: Running a check

    /// Lists the provider's models, tests the newest candidates, and returns results in
    /// newest-first order. `progress` receives (completed, total, model ID) on the main queue.
    static func run(provider: PowerPack_AIProvider,
                    purpose: PowerPack_ModelPurpose,
                    apiKey: String,
                    session: URLSession = .shared,
                    progress: @escaping (Int, Int, String) -> Void) async throws -> [PowerPack_ModelCheck] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw PowerPack_ModelFinderError.missingKey }

        let all = try await listModels(provider: provider, apiKey: key, session: session)
        let candidates = candidates(from: all, provider: provider, limit: maxModelsToTest)
        guard !candidates.isEmpty else { throw PowerPack_ModelFinderError.noCandidates }
        var tested = [PowerPack_ModelInfo]()

        let image = purpose == .vision ? testImageBase64() : nil
        var outcomes = [String: PowerPack_CheckOutcome]()
        var completed = 0

        // Small batches instead of an unbounded task group, so a free-tier key is not rate limited.
        for batchStart in stride(from: 0, to: candidates.count, by: parallelTests) {
            let compatibleSoFar = outcomes.values.filter { $0 == .compatible }.count
            guard shouldContinue(tested: tested.count, compatible: compatibleSoFar) else { break }
            let batch = candidates[batchStart..<min(batchStart + parallelTests, candidates.count)]
            tested.append(contentsOf: batch)
            await withTaskGroup(of: (String, PowerPack_CheckOutcome).self) { group in
                for model in batch {
                    group.addTask {
                        (model.id, await check(model: model.id, provider: provider, purpose: purpose, apiKey: key, imageBase64: image, session: session))
                    }
                }
                for await (id, outcome) in group {
                    outcomes[id] = outcome
                    completed += 1
                    let done = completed
                    await MainActor.run { progress(done, candidates.count, id) }
                }
            }
        }

        let results = tested.map { PowerPack_ModelCheck(model: $0, outcome: outcomes[$0.id] ?? .failed(.other("Not tested"))) }
        saveCache(results, provider: provider, purpose: purpose)
        return results
    }

    /// Keep testing older models until enough compatible ones are found or the cap is reached.
    static func shouldContinue(tested: Int, compatible: Int) -> Bool {
        compatible < targetCompatible && tested < maxModelsToTest
    }

    static func recommended(in results: [PowerPack_ModelCheck]) -> PowerPack_ModelCheck? {
        results.first(where: \.isCompatible)
    }

    // MARK: Listing

    static func listModels(provider: PowerPack_AIProvider, apiKey: String, session: URLSession = .shared) async throws -> [PowerPack_ModelInfo] {
        let path: String
        switch provider {
        case .gemini: path = "/models?pageSize=1000"
        case .claude: path = "/models?limit=1000"
        case .openAI, .grok: path = "/models"
        }
        var request = URLRequest(url: URL(string: provider.defaultBaseURL + path)!)
        request.timeoutInterval = 20
        authorize(&request, provider: provider, apiKey: apiKey)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PowerPack_ModelFinderError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw PowerPack_ModelFinderError.keyRejected(provider) }
        // Gemini answers an invalid key with 400 API_KEY_INVALID.
        if status == 400, provider == .gemini, String(data: data, encoding: .utf8)?.contains("API_KEY_INVALID") == true {
            throw PowerPack_ModelFinderError.keyRejected(provider)
        }
        guard (200..<300).contains(status) else {
            throw PowerPack_ModelFinderError.listFailed(failureReason(status: status, body: data).text)
        }
        return try parseModelList(data, provider: provider)
    }

    static func parseModelList(_ data: Data, provider: PowerPack_AIProvider) throws -> [PowerPack_ModelInfo] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PowerPack_ModelFinderError.listFailed("Unreadable response")
        }
        switch provider {
        case .openAI, .grok:
            guard let items = json["data"] as? [[String: Any]] else { throw PowerPack_ModelFinderError.listFailed("Unexpected response") }
            return items.compactMap { item in
                guard let id = item["id"] as? String else { return nil }
                let created = (item["created"] as? Double).map(Date.init(timeIntervalSince1970:))
                return PowerPack_ModelInfo(id: id, displayName: nil, created: created)
            }
        case .claude:
            guard let items = json["data"] as? [[String: Any]] else { throw PowerPack_ModelFinderError.listFailed("Unexpected response") }
            let iso = ISO8601DateFormatter()
            return items.compactMap { item in
                guard let id = item["id"] as? String else { return nil }
                return PowerPack_ModelInfo(id: id,
                                           displayName: item["display_name"] as? String,
                                           created: (item["created_at"] as? String).flatMap(iso.date(from:)))
            }
        case .gemini:
            guard let items = json["models"] as? [[String: Any]] else { throw PowerPack_ModelFinderError.listFailed("Unexpected response") }
            return items.compactMap { item in
                guard let name = item["name"] as? String,
                      (item["supportedGenerationMethods"] as? [String])?.contains("generateContent") == true else { return nil }
                let id = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
                return PowerPack_ModelInfo(id: id, displayName: item["displayName"] as? String, created: nil)
            }
        }
    }

    // MARK: Candidate selection

    /// Chat-capable models only, newest first, dated snapshots hidden when their alias exists.
    static func candidates(from models: [PowerPack_ModelInfo], provider: PowerPack_AIProvider, limit: Int) -> [PowerPack_ModelInfo] {
        let chat = models.filter { isChatModel($0.id.lowercased(), provider: provider) }
        let ids = Set(chat.map(\.id))
        let deduped = chat.filter { model in
            guard let alias = aliasWithoutDate(model.id) else { return true }
            return !ids.contains(alias)
        }
        let sorted: [PowerPack_ModelInfo]
        if provider == .gemini {
            // Gemini's list has no dates; order by version number, stable before preview.
            sorted = deduped.sorted { a, b in
                let va = geminiVersion(a.id), vb = geminiVersion(b.id)
                if va != vb { return va > vb }
                let pa = isPreview(a.id), pb = isPreview(b.id)
                if pa != pb { return !pa }
                return a.id < b.id
            }
        } else {
            sorted = deduped.sorted { a, b in
                switch (a.created, b.created) {
                case let (x?, y?) where x != y: return x > y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.id > b.id
                }
            }
        }
        return Array(sorted.prefix(limit))
    }

    private static func isChatModel(_ id: String, provider: PowerPack_AIProvider) -> Bool {
        func excludes(_ words: [String]) -> Bool { !words.contains { id.contains($0) } }
        switch provider {
        case .openAI:
            let isChatFamily = id.hasPrefix("gpt-") || id.hasPrefix("chatgpt-")
                || (id.hasPrefix("o") && id.dropFirst().first?.isNumber == true)
            return isChatFamily && excludes(["embedding", "whisper", "tts", "dall-e", "davinci", "babbage",
                                             "moderation", "realtime", "audio", "transcribe", "image",
                                             "search", "computer-use", "instruct"])
        case .claude:
            return id.hasPrefix("claude")
        case .gemini:
            return id.hasPrefix("gemini") && excludes(["embedding", "tts", "live", "native-audio", "image", "aqa"])
        case .grok:
            return id.hasPrefix("grok") && excludes(["image", "imagine"])
        }
    }

    /// "gpt-4.1-2025-04-14" → "gpt-4.1"; "claude-sonnet-4-5-20250929" → "claude-sonnet-4-5".
    private static func aliasWithoutDate(_ id: String) -> String? {
        for pattern in ["-\\d{4}-\\d{2}-\\d{2}$", "-\\d{8}$"] {
            if let range = id.range(of: pattern, options: .regularExpression) {
                return String(id[..<range.lowerBound])
            }
        }
        return nil
    }

    private static func geminiVersion(_ id: String) -> Double {
        guard let range = id.range(of: "\\d+(\\.\\d+)?", options: .regularExpression) else { return 0 }
        return Double(id[range]) ?? 0
    }

    private static func isPreview(_ id: String) -> Bool {
        id.contains("preview") || id.contains("exp")
    }

    // MARK: Testing one model

    static func check(model: String,
                      provider: PowerPack_AIProvider,
                      purpose: PowerPack_ModelPurpose,
                      apiKey: String,
                      imageBase64: String?,
                      session: URLSession = .shared) async -> PowerPack_CheckOutcome {
        let url: URL
        switch provider {
        case .openAI, .grok: url = URL(string: provider.defaultBaseURL + "/chat/completions")!
        case .claude: url = URL(string: provider.defaultBaseURL + "/messages")!
        case .gemini:
            let escaped = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
            url = URL(string: provider.defaultBaseURL + "/models/\(escaped):generateContent")!
        }
        do {
            let (data, response) = try await PowerPack_AIRequestOptions.send(
                model: model,
                provider: provider,
                format: provider.requestFormat,
                build: { quirks in
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 30
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    authorize(&request, provider: provider, apiKey: apiKey)
                    request.httpBody = try JSONSerialization.data(withJSONObject: testBody(provider: provider, model: model, purpose: purpose, imageBase64: imageBase64, quirks: quirks))
                    return request
                },
                execute: { request in try await session.data(for: request) })
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (200..<300).contains(status) ? .compatible : .failed(failureReason(status: status, body: data))
        } catch {
            return .failed(.network(error.localizedDescription))
        }
    }

    /// The same body shape FoodFinder (vision) and LoopInsights (text, with system prompt) send.
    static func testBody(provider: PowerPack_AIProvider, model: String, purpose: PowerPack_ModelPurpose, imageBase64: String?, quirks: PowerPack_ModelQuirks = PowerPack_ModelQuirks()) throws -> [String: Any] {
        let system = "You are a test assistant."
        let prompt = "Reply with the single word OK."
        // No thinking-model minimum here: a cut-off reply still proves the request is accepted.
        let parameters = PowerPack_AIRequestOptions.parameters(format: provider.requestFormat, quirks: quirks, temperature: testTemperature, maxTokens: testMaxTokens)
        switch provider {
        case .openAI, .grok:
            var messages: [[String: Any]] = []
            if purpose == .vision, let image = imageBase64 {
                messages.append(["role": "user", "content": [
                    ["type": "text", "text": prompt],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(image)", "detail": "low"]],
                ]])
            } else {
                messages = [["role": "system", "content": system], ["role": "user", "content": prompt]]
            }
            let body: [String: Any] = ["model": model, "messages": messages]
            return body.merging(parameters) { $1 }

        case .claude:
            var body = parameters
            body["model"] = model
            if purpose == .vision, let image = imageBase64 {
                body["messages"] = [["role": "user", "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image]],
                    ["type": "text", "text": prompt],
                ]]]
            } else {
                body["system"] = system
                body["messages"] = [["role": "user", "content": prompt]]
            }
            return body

        case .gemini:
            var parts: [[String: Any]] = [["text": prompt]]
            var body = parameters
            if purpose == .vision, let image = imageBase64 {
                parts.append(["inline_data": ["mime_type": "image/jpeg", "data": image]])
            } else {
                body["system_instruction"] = ["parts": [["text": system]]]
            }
            body["contents"] = [["role": "user", "parts": parts]]
            return body
        }
    }

    private static func authorize(_ request: inout URLRequest, provider: PowerPack_AIProvider, apiKey: String) {
        switch provider {
        case .openAI, .grok:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .claude:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini:
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
    }

    /// A small solid-color JPEG, enough to prove a model accepts image input.
    static func testImageBase64() -> String? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32))
        let image = renderer.image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        return image.jpegData(compressionQuality: 0.8)?.base64EncodedString()
    }

    // MARK: Failure interpretation

    static func failureReason(status: Int, body: Data) -> PowerPack_FailureReason {
        switch status {
        case 401: return .keyRejected
        case 403, 404: return .notAvailableToKey
        case 429: return .rateLimited
        default: break
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = json?["error"] as? [String: Any]
        let message = (error?["message"] as? String) ?? (json?["message"] as? String) ?? ""
        let param = (error?["param"] as? String) ?? ""
        let haystack = (message + " " + param).lowercased()

        if haystack.contains("max_tokens") || haystack.contains("max_completion_tokens") { return .needsMaxCompletionTokens }
        if haystack.contains("temperature") { return .rejectsTemperature }
        if haystack.contains("image") || haystack.contains("vision") { return .noImageInput }
        if !message.isEmpty { return .other(String(message.prefix(160))) }
        return .other("HTTP \(status)")
    }

    // MARK: Cache

    private static func cacheKey(_ provider: PowerPack_AIProvider, _ purpose: PowerPack_ModelPurpose) -> String {
        "com.loopkit.Loop.powerPack.modelFinder.\(provider.rawValue).\(purpose.rawValue)"
    }

    static func saveCache(_ results: [PowerPack_ModelCheck], provider: PowerPack_AIProvider, purpose: PowerPack_ModelPurpose, at date: Date = Date(), defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(PowerPack_ModelFinderCache(date: date, results: results)) else { return }
        defaults.set(data, forKey: cacheKey(provider, purpose))
    }

    static func loadCache(provider: PowerPack_AIProvider, purpose: PowerPack_ModelPurpose, now: Date = Date(), defaults: UserDefaults = .standard) -> PowerPack_ModelFinderCache? {
        guard let data = defaults.data(forKey: cacheKey(provider, purpose)),
              let cache = try? JSONDecoder().decode(PowerPack_ModelFinderCache.self, from: data),
              now.timeIntervalSince(cache.date) < cacheLifetime else { return nil }
        return cache
    }
}
