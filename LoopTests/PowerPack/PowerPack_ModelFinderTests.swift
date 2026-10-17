//
//  PowerPack_ModelFinderTests.swift
//  LoopTests
//
//  Concept & design by Taylor Patterson. Coded & tested by Claude Code in October 2026.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import XCTest
@testable import Loop

final class PowerPack_ModelFinderTests: XCTestCase {

    // MARK: - Provider detection

    func testProviderDetectionFromBaseURL() {
        XCTAssertEqual(PowerPack_AIProvider.detect(baseURL: "https://api.openai.com/v1"), .openAI)
        XCTAssertEqual(PowerPack_AIProvider.detect(baseURL: "https://api.anthropic.com/v1"), .claude)
        XCTAssertEqual(PowerPack_AIProvider.detect(baseURL: "https://generativelanguage.googleapis.com/v1beta"), .gemini)
        XCTAssertEqual(PowerPack_AIProvider.detect(baseURL: "https://api.x.ai/v1"), .grok)
        XCTAssertNil(PowerPack_AIProvider.detect(baseURL: "https://my-azure.openai.azure.com"))
        XCTAssertNil(PowerPack_AIProvider.detect(baseURL: ""))
    }

    // MARK: - List parsing

    func testParseOpenAIList() throws {
        let json = #"{"data":[{"id":"gpt-4.1","created":1744300000},{"id":"text-embedding-3-small","created":1705000000}]}"#
        let models = try PowerPack_ModelFinder.parseModelList(Data(json.utf8), provider: .openAI)
        XCTAssertEqual(models.map(\.id), ["gpt-4.1", "text-embedding-3-small"])
        XCTAssertEqual(models.first?.created, Date(timeIntervalSince1970: 1744300000))
    }

    func testParseClaudeList() throws {
        let json = #"{"data":[{"id":"claude-sonnet-4-5","display_name":"Claude Sonnet 4.5","created_at":"2025-09-29T00:00:00Z","type":"model"}]}"#
        let models = try PowerPack_ModelFinder.parseModelList(Data(json.utf8), provider: .claude)
        XCTAssertEqual(models.first?.id, "claude-sonnet-4-5")
        XCTAssertEqual(models.first?.displayName, "Claude Sonnet 4.5")
        XCTAssertNotNil(models.first?.created)
    }

    func testParseGeminiListKeepsOnlyGenerateContent() throws {
        let json = #"""
        {"models":[
          {"name":"models/gemini-2.5-flash","displayName":"Gemini 2.5 Flash","supportedGenerationMethods":["generateContent","countTokens"]},
          {"name":"models/text-embedding-004","supportedGenerationMethods":["embedContent"]}
        ]}
        """#
        let models = try PowerPack_ModelFinder.parseModelList(Data(json.utf8), provider: .gemini)
        XCTAssertEqual(models.map(\.id), ["gemini-2.5-flash"])
    }

    func testParseGrokList() throws {
        let json = #"{"data":[{"id":"grok-4","created":1752000000,"object":"model"}]}"#
        XCTAssertEqual(try PowerPack_ModelFinder.parseModelList(Data(json.utf8), provider: .grok).map(\.id), ["grok-4"])
    }

    func testParseRejectsGarbage() {
        XCTAssertThrowsError(try PowerPack_ModelFinder.parseModelList(Data("nope".utf8), provider: .openAI))
    }

    // MARK: - Candidate selection

    private func m(_ id: String, _ created: TimeInterval? = nil) -> PowerPack_ModelInfo {
        PowerPack_ModelInfo(id: id, displayName: nil, created: created.map(Date.init(timeIntervalSince1970:)))
    }

    func testOpenAIDropsNonChatModels() {
        let all = ["gpt-4.1", "gpt-4o", "o3", "text-embedding-3-large", "whisper-1", "tts-1", "dall-e-3",
                   "omni-moderation-latest", "gpt-4o-realtime-preview", "gpt-4o-audio-preview",
                   "gpt-4o-transcribe", "gpt-image-1", "davinci-002", "gpt-4o-search-preview", "computer-use-preview"]
            .map { m($0, 1) }
        let ids = Set(PowerPack_ModelFinder.candidates(from: all, provider: .openAI, limit: 20).map(\.id))
        XCTAssertEqual(ids, ["gpt-4.1", "gpt-4o", "o3"])
    }

    func testDatedSnapshotsHiddenWhenAliasExists() {
        let all = [m("gpt-4.1", 10), m("gpt-4.1-2025-04-14", 11), m("gpt-4o-2024-05-13", 5)]
        let ids = PowerPack_ModelFinder.candidates(from: all, provider: .openAI, limit: 20).map(\.id)
        XCTAssertEqual(Set(ids), ["gpt-4.1", "gpt-4o-2024-05-13"])
    }

    func testNewestFirstAndLimited() {
        let all = (1...12).map { m("gpt-test-\($0)", TimeInterval($0)) }
        let ids = PowerPack_ModelFinder.candidates(from: all, provider: .openAI, limit: 8).map(\.id)
        XCTAssertEqual(ids.count, 8)
        XCTAssertEqual(ids.first, "gpt-test-12")
    }

    func testGeminiOrdersByVersionAndDropsSpecialPurposeModels() {
        let all = ["gemini-1.5-flash", "gemini-2.5-pro", "gemini-2.0-flash", "gemini-2.5-flash-preview-tts",
                   "gemini-2.0-flash-live-001", "imagen-3.0-generate-002", "aqa", "gemini-2.5-flash-image-preview",
                   "gemini-2.5-flash"].map { m($0) }
        let ids = PowerPack_ModelFinder.candidates(from: all, provider: .gemini, limit: 20).map(\.id)
        XCTAssertEqual(Array(ids.prefix(2)).sorted(), ["gemini-2.5-flash", "gemini-2.5-pro"])
        XCTAssertFalse(ids.contains("gemini-2.5-flash-preview-tts"))
        XCTAssertFalse(ids.contains("gemini-2.0-flash-live-001"))
        XCTAssertFalse(ids.contains("imagen-3.0-generate-002"))
        XCTAssertFalse(ids.contains("aqa"))
        XCTAssertFalse(ids.contains("gemini-2.5-flash-image-preview"))
        XCTAssertEqual(ids.last, "gemini-1.5-flash")
    }

    func testGeminiPrefersStableOverPreviewAtSameVersion() {
        let ids = PowerPack_ModelFinder.candidates(from: [m("gemini-2.5-flash-preview-05-20"), m("gemini-2.5-flash")], provider: .gemini, limit: 20).map(\.id)
        XCTAssertEqual(ids, ["gemini-2.5-flash", "gemini-2.5-flash-preview-05-20"])
    }

    func testGrokDropsImageGenerationModels() {
        let ids = PowerPack_ModelFinder.candidates(from: [m("grok-4", 3), m("grok-2-image-1212", 2), m("grok-3-mini", 1)], provider: .grok, limit: 20).map(\.id)
        XCTAssertEqual(ids, ["grok-4", "grok-3-mini"])
    }

    func testKeepsTestingOlderModelsUntilEnoughPass() {
        XCTAssertTrue(PowerPack_ModelFinder.shouldContinue(tested: 8, compatible: 0))
        XCTAssertTrue(PowerPack_ModelFinder.shouldContinue(tested: 12, compatible: 2))
        XCTAssertFalse(PowerPack_ModelFinder.shouldContinue(tested: 12, compatible: 3))
        XCTAssertFalse(PowerPack_ModelFinder.shouldContinue(tested: 24, compatible: 0))
    }

    // MARK: - Test request bodies

    func testOpenAITextBodyHasTemperatureMaxTokensAndSystem() throws {
        let body = try PowerPack_ModelFinder.testBody(provider: .openAI, model: "gpt-4.1", purpose: .text, imageBase64: nil)
        XCTAssertEqual(body["model"] as? String, "gpt-4.1")
        XCTAssertNotNil(body["temperature"])
        XCTAssertNotNil(body["max_tokens"])
        let messages = body["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.first?["role"] as? String, "system")
    }

    func testOpenAIVisionBodyIncludesImage() throws {
        let body = try PowerPack_ModelFinder.testBody(provider: .openAI, model: "gpt-4.1", purpose: .vision, imageBase64: "AAAA")
        let content = ((body["messages"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]]
        XCTAssertTrue(content?.contains { $0["type"] as? String == "image_url" } ?? false)
    }

    func testClaudeBodies() throws {
        let text = try PowerPack_ModelFinder.testBody(provider: .claude, model: "claude-x", purpose: .text, imageBase64: nil)
        XCTAssertNotNil(text["system"])
        XCTAssertNotNil(text["temperature"])
        XCTAssertNotNil(text["max_tokens"])
        let vision = try PowerPack_ModelFinder.testBody(provider: .claude, model: "claude-x", purpose: .vision, imageBase64: "AAAA")
        let content = ((vision["messages"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]]
        XCTAssertTrue(content?.contains { $0["type"] as? String == "image" } ?? false)
    }

    func testGeminiBodies() throws {
        let text = try PowerPack_ModelFinder.testBody(provider: .gemini, model: "gemini-2.5-flash", purpose: .text, imageBase64: nil)
        let config = text["generationConfig"] as? [String: Any]
        XCTAssertNotNil(config?["temperature"])
        XCTAssertNotNil(config?["maxOutputTokens"])
        XCTAssertNotNil(text["system_instruction"])
        let vision = try PowerPack_ModelFinder.testBody(provider: .gemini, model: "gemini-2.5-flash", purpose: .vision, imageBase64: "AAAA")
        let parts = (((vision["contents"] as? [[String: Any]])?.first)?["parts"]) as? [[String: Any]]
        XCTAssertTrue(parts?.contains { $0["inline_data"] != nil } ?? false)
    }

    // MARK: - Failure reasons

    func testFailureReasonTemperature() {
        let json = #"{"error":{"message":"Unsupported parameter: 'temperature' is not supported with this model.","type":"invalid_request_error","param":"temperature","code":"unsupported_parameter"}}"#
        XCTAssertEqual(PowerPack_ModelFinder.failureReason(status: 400, body: Data(json.utf8)), .rejectsTemperature)
    }

    func testFailureReasonMaxTokens() {
        let json = #"{"error":{"message":"Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.","param":"max_tokens"}}"#
        XCTAssertEqual(PowerPack_ModelFinder.failureReason(status: 400, body: Data(json.utf8)), .needsMaxCompletionTokens)
    }

    func testFailureReasonImage() {
        let json = #"{"error":{"type":"invalid_request_error","message":"This model does not support image input."}}"#
        XCTAssertEqual(PowerPack_ModelFinder.failureReason(status: 400, body: Data(json.utf8)), .noImageInput)
    }

    func testFailureReasonAuthAndAccessAndRate() {
        XCTAssertEqual(PowerPack_ModelFinder.failureReason(status: 401, body: Data()), .keyRejected)
        XCTAssertEqual(PowerPack_ModelFinder.failureReason(status: 403, body: Data()), .notAvailableToKey)
        XCTAssertEqual(PowerPack_ModelFinder.failureReason(status: 404, body: Data()), .notAvailableToKey)
        XCTAssertEqual(PowerPack_ModelFinder.failureReason(status: 429, body: Data()), .rateLimited)
    }

    func testFailureReasonFallsBackToProviderMessage() {
        let json = #"{"error":{"message":"Something specific went wrong","status":"INVALID_ARGUMENT"}}"#
        XCTAssertEqual(PowerPack_ModelFinder.failureReason(status: 400, body: Data(json.utf8)), .other("Something specific went wrong"))
    }

    // MARK: - Results

    func testRecommendedIsFirstCompatible() {
        let results = [
            PowerPack_ModelCheck(model: m("a"), outcome: .failed(.rejectsTemperature)),
            PowerPack_ModelCheck(model: m("b"), outcome: .compatible),
            PowerPack_ModelCheck(model: m("c"), outcome: .compatible),
        ]
        XCTAssertEqual(PowerPack_ModelFinder.recommended(in: results)?.model.id, "b")
    }

    func testCacheRoundTripAndExpiry() throws {
        let defaults = UserDefaults(suiteName: "PowerPack_ModelFinderTests")!
        defaults.removePersistentDomain(forName: "PowerPack_ModelFinderTests")
        let results = [PowerPack_ModelCheck(model: m("gpt-4.1", 5), outcome: .compatible)]
        let now = Date()
        PowerPack_ModelFinder.saveCache(results, provider: .openAI, purpose: .vision, at: now, defaults: defaults)
        XCTAssertEqual(PowerPack_ModelFinder.loadCache(provider: .openAI, purpose: .vision, now: now.addingTimeInterval(3600), defaults: defaults)?.results, results)
        XCTAssertNil(PowerPack_ModelFinder.loadCache(provider: .openAI, purpose: .text, now: now, defaults: defaults))
        XCTAssertNil(PowerPack_ModelFinder.loadCache(provider: .openAI, purpose: .vision, now: now.addingTimeInterval(25 * 3600), defaults: defaults))
    }
}
