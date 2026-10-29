
//
//  PowerPack_AIRequestOptionsTests.swift
//  LoopTests
//
//  Concept & design by Taylor Patterson. Coded & tested by Claude Code in October 2026.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import XCTest
@testable import Loop

final class PowerPack_AIRequestOptionsTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "PowerPack_AIRequestOptionsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private let openAITemperatureError = #"{"error":{"message":"Unsupported value: 'temperature' does not support 0.05 with this model. Only the default (1) value is supported.","type":"invalid_request_error","param":"temperature","code":"unsupported_value"}}"#
    private let openAIMaxTokensError = #"{"error":{"message":"Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.","type":"invalid_request_error","param":"max_tokens","code":"unsupported_parameter"}}"#
    private let anthropicTemperatureError = #"{"type":"error","error":{"type":"invalid_request_error","message":"temperature is not supported for this model."}}"#

    // MARK: - Saved quirks

    func testUnknownModelHasNoQuirks() {
        XCTAssertEqual(PowerPack_AIRequestOptions.quirks(for: "gpt-4o", defaults: defaults), PowerPack_ModelQuirks())
    }

    func testSavedQuirksAreReadBackIgnoringCaseAndSpaces() {
        let quirks = PowerPack_ModelQuirks(omitsTemperature: true, usesMaxCompletionTokens: true)
        PowerPack_AIRequestOptions.save(quirks, for: "GPT-5.2 ", defaults: defaults)
        XCTAssertEqual(PowerPack_AIRequestOptions.quirks(for: "gpt-5.2", defaults: defaults), quirks)
        XCTAssertEqual(PowerPack_AIRequestOptions.quirks(for: "gpt-4o", defaults: defaults), PowerPack_ModelQuirks())
    }

    // MARK: - Known starting quirks

    func testOpenAIReasoningModelsStartWithoutTemperatureAndWithMaxCompletionTokens() {
        for model in ["gpt-5", "gpt-5.2", "gpt-5-mini", "gpt-6", "o3", "o4-mini"] {
            XCTAssertEqual(PowerPack_AIRequestOptions.knownQuirks(provider: .openAI, model: model),
                           PowerPack_ModelQuirks(omitsTemperature: true, usesMaxCompletionTokens: true), model)
        }
    }

    func testOlderOpenAIModelsKeepTemperatureButUseMaxCompletionTokens() {
        for model in ["gpt-4o", "gpt-4.1-mini", "gpt-4o-mini"] {
            XCTAssertEqual(PowerPack_AIRequestOptions.knownQuirks(provider: .openAI, model: model),
                           PowerPack_ModelQuirks(omitsTemperature: false, usesMaxCompletionTokens: true), model)
        }
    }

    func testTokenRenameOnlyOnOpenAIItself() {
        // Other OpenAI-format hosts (Azure, Groq, Ollama) may not accept max_completion_tokens.
        XCTAssertFalse(PowerPack_AIRequestOptions.knownQuirks(provider: nil, model: "gpt-5.2").usesMaxCompletionTokens)
        XCTAssertTrue(PowerPack_AIRequestOptions.knownQuirks(provider: nil, model: "gpt-5.2").omitsTemperature)
        XCTAssertEqual(PowerPack_AIRequestOptions.knownQuirks(provider: .grok, model: "grok-4"), PowerPack_ModelQuirks())
    }

    func testClaudeModelsWithoutSampling() {
        for model in ["claude-opus-4-7", "claude-opus-4-8", "claude-opus-5", "claude-opus-5-5", "claude-sonnet-5",
                      "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1", "claude-sonnet-6", "anthropic/claude-opus-5-5"] {
            XCTAssertTrue(PowerPack_AIRequestOptions.knownQuirks(provider: .claude, model: model).omitsTemperature, model)
        }
    }

    func testOlderClaudeModelsKeepTemperature() {
        for model in ["claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5", "claude-sonnet-4-20250514",
                      "claude-sonnet-4-5-20250929", "claude-3-5-sonnet-20241022"] {
            XCTAssertEqual(PowerPack_AIRequestOptions.knownQuirks(provider: .claude, model: model), PowerPack_ModelQuirks(), model)
        }
    }

    func testGemini3AndLaterStartWithoutSampling() {
        // Google recommends the default temperature (1.0) for Gemini 3; lower values can degrade reasoning.
        XCTAssertTrue(PowerPack_AIRequestOptions.knownQuirks(provider: .gemini, model: "gemini-3-pro-preview").omitsTemperature)
        XCTAssertTrue(PowerPack_AIRequestOptions.knownQuirks(provider: .gemini, model: "gemini-3.1-flash").omitsTemperature)
        XCTAssertFalse(PowerPack_AIRequestOptions.knownQuirks(provider: .gemini, model: "gemini-2.5-flash").omitsTemperature)
        XCTAssertFalse(PowerPack_AIRequestOptions.knownQuirks(provider: .gemini, model: "gemini-2.0-flash").omitsTemperature)
    }

    func testUnsavedModelStartsWithKnownQuirks() {
        XCTAssertEqual(PowerPack_AIRequestOptions.quirks(for: "gpt-5.2", provider: .openAI, defaults: defaults),
                       PowerPack_ModelQuirks(omitsTemperature: true, usesMaxCompletionTokens: true))
    }

    func testSavedQuirksOverrideKnownQuirks() {
        PowerPack_AIRequestOptions.save(PowerPack_ModelQuirks(omitsTemperature: false, usesMaxCompletionTokens: false), for: "gpt-5.2", defaults: defaults)
        XCTAssertEqual(PowerPack_AIRequestOptions.quirks(for: "gpt-5.2", provider: .openAI, defaults: defaults), PowerPack_ModelQuirks())
    }

    // MARK: - Adapting to an error

    func testMaxCompletionTokensRejectionSwitchesBackToMaxTokens() {
        let json = #"{"error":{"message":"Unrecognized request argument supplied: max_completion_tokens","param":"max_completion_tokens"}}"#
        let next = PowerPack_AIRequestOptions.adapted(PowerPack_ModelQuirks(usesMaxCompletionTokens: true), format: .openAI, status: 400, body: Data(json.utf8))
        XCTAssertEqual(next, PowerPack_ModelQuirks(omitsTemperature: false, usesMaxCompletionTokens: false))
    }

    func testTemperatureRejectionOmitsTemperature() {
        let next = PowerPack_AIRequestOptions.adapted(PowerPack_ModelQuirks(), format: .openAI, status: 400, body: Data(openAITemperatureError.utf8))
        XCTAssertEqual(next, PowerPack_ModelQuirks(omitsTemperature: true, usesMaxCompletionTokens: false))
    }

    func testAnthropicTemperatureRejectionOmitsTemperature() {
        let next = PowerPack_AIRequestOptions.adapted(PowerPack_ModelQuirks(), format: .anthropic, status: 400, body: Data(anthropicTemperatureError.utf8))
        XCTAssertEqual(next?.omitsTemperature, true)
    }

    func testMaxTokensRejectionSwitchesTokenParameterForOpenAIFormat() {
        let next = PowerPack_AIRequestOptions.adapted(PowerPack_ModelQuirks(), format: .openAI, status: 400, body: Data(openAIMaxTokensError.utf8))
        XCTAssertEqual(next, PowerPack_ModelQuirks(omitsTemperature: false, usesMaxCompletionTokens: true))
    }

    func testMaxTokensErrorIsNotAdaptedForAnthropicFormat() {
        // Anthropic requires max_tokens; there is no other name to switch to.
        XCTAssertNil(PowerPack_AIRequestOptions.adapted(PowerPack_ModelQuirks(), format: .anthropic, status: 400, body: Data(openAIMaxTokensError.utf8)))
    }

    func testAlreadyAdaptedQuirkIsNotAdaptedAgain() {
        let quirks = PowerPack_ModelQuirks(omitsTemperature: true, usesMaxCompletionTokens: false)
        XCTAssertNil(PowerPack_AIRequestOptions.adapted(quirks, format: .openAI, status: 400, body: Data(openAITemperatureError.utf8)))
    }

    func testNonClientErrorsAreNotAdapted() {
        XCTAssertNil(PowerPack_AIRequestOptions.adapted(PowerPack_ModelQuirks(), format: .openAI, status: 500, body: Data(openAITemperatureError.utf8)))
        XCTAssertNil(PowerPack_AIRequestOptions.adapted(PowerPack_ModelQuirks(), format: .openAI, status: 401, body: Data(openAITemperatureError.utf8)))
    }

    func testUnrelatedBadRequestIsNotAdapted() {
        let json = #"{"error":{"message":"This model does not support image input."}}"#
        XCTAssertNil(PowerPack_AIRequestOptions.adapted(PowerPack_ModelQuirks(), format: .openAI, status: 400, body: Data(json.utf8)))
    }

    // MARK: - Request parameters

    func testOpenAIParametersByDefault() {
        let params = PowerPack_AIRequestOptions.parameters(format: .openAI, quirks: PowerPack_ModelQuirks(), temperature: 0.05, maxTokens: 4096)
        XCTAssertEqual(params["temperature"] as? Double, 0.05)
        XCTAssertEqual(params["max_tokens"] as? Int, 4096)
        XCTAssertNil(params["max_completion_tokens"])
    }

    func testOpenAIParametersWithQuirks() {
        let quirks = PowerPack_ModelQuirks(omitsTemperature: true, usesMaxCompletionTokens: true)
        let params = PowerPack_AIRequestOptions.parameters(format: .openAI, quirks: quirks, temperature: 0.05, maxTokens: 4096)
        XCTAssertNil(params["temperature"])
        XCTAssertNil(params["max_tokens"])
        XCTAssertEqual(params["max_completion_tokens"] as? Int, 4096)
    }

    func testAnthropicParametersAlwaysKeepMaxTokens() {
        let quirks = PowerPack_ModelQuirks(omitsTemperature: true, usesMaxCompletionTokens: true)
        let params = PowerPack_AIRequestOptions.parameters(format: .anthropic, quirks: quirks, temperature: 0, maxTokens: 8192)
        XCTAssertNil(params["temperature"])
        XCTAssertEqual(params["max_tokens"] as? Int, 8192)
    }

    func testGeminiParametersByDefault() {
        let params = PowerPack_AIRequestOptions.parameters(format: .gemini, quirks: PowerPack_ModelQuirks(), temperature: 0, maxTokens: 4096)
        let config = params["generationConfig"] as? [String: Any]
        XCTAssertEqual(config?["maxOutputTokens"] as? Int, 4096)
        XCTAssertEqual(config?["temperature"] as? Double, 0)
        XCTAssertNotNil(config?["topP"])
        XCTAssertNotNil(config?["topK"])
    }

    func testGeminiParametersWithoutSampling() {
        let params = PowerPack_AIRequestOptions.parameters(format: .gemini, quirks: PowerPack_ModelQuirks(omitsTemperature: true), temperature: 0, maxTokens: 4096)
        let config = params["generationConfig"] as? [String: Any]
        XCTAssertEqual(config?["maxOutputTokens"] as? Int, 4096)
        XCTAssertNil(config?["temperature"])
        XCTAssertNil(config?["topP"])
        XCTAssertNil(config?["topK"])
    }

    // MARK: - Output token minimum

    func testOutputTokenMinimumAppliesOnlyToModelsThatRejectTemperature() {
        XCTAssertEqual(PowerPack_AIRequestOptions.outputTokens(4096, quirks: PowerPack_ModelQuirks()), 4096)
        XCTAssertEqual(PowerPack_AIRequestOptions.outputTokens(4096, quirks: PowerPack_ModelQuirks(omitsTemperature: true)), PowerPack_AIRequestOptions.thinkingModelMinimumOutputTokens)
        XCTAssertEqual(PowerPack_AIRequestOptions.outputTokens(20000, quirks: PowerPack_ModelQuirks(omitsTemperature: true)), 20000)
    }

    // MARK: - Reading Claude responses

    func testAnthropicTextSkipsThinkingBlocks() {
        let json: [String: Any] = ["content": [
            ["type": "thinking", "thinking": "", "signature": "abc"],
            ["type": "text", "text": "{\"a\":1}"],
        ]]
        XCTAssertEqual(PowerPack_AIRequestOptions.anthropicText(from: json), "{\"a\":1}")
    }

    func testAnthropicTextJoinsTextBlocks() {
        let json: [String: Any] = ["content": [
            ["type": "text", "text": "{\"a\":"],
            ["type": "text", "text": "1}"],
        ]]
        XCTAssertEqual(PowerPack_AIRequestOptions.anthropicText(from: json), "{\"a\":1}")
    }

    func testAnthropicTextIsNilForOtherFormats() {
        let json: [String: Any] = ["choices": [["message": ["content": "hi"]]]]
        XCTAssertNil(PowerPack_AIRequestOptions.anthropicText(from: json))
    }

    // MARK: - Sending with retries

    private final class FakeProvider {
        var responses: [(Int, String)]
        var sentBodies: [[String: Any]] = []
        init(_ responses: [(Int, String)]) { self.responses = responses }

        func execute(_ request: URLRequest) async throws -> (Data, URLResponse) {
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            sentBodies.append(body)
            let (status, json) = responses.removeFirst()
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(json.utf8), response)
        }
    }

    private func request(_ quirks: PowerPack_ModelQuirks) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.example.com/v1/chat/completions")!)
        var body: [String: Any] = ["model": "custom-model"]
        body.merge(PowerPack_AIRequestOptions.parameters(format: .openAI, quirks: quirks, temperature: 0.05, maxTokens: 4096)) { $1 }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func testSendRetriesWithoutTemperatureAndSavesQuirk() async throws {
        let provider = FakeProvider([(400, openAITemperatureError), (200, "{}")])
        let (_, response) = try await PowerPack_AIRequestOptions.send(model: "custom-model", format: .openAI, defaults: defaults, build: request, execute: provider.execute)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(provider.sentBodies.count, 2)
        XCTAssertNotNil(provider.sentBodies[0]["temperature"])
        XCTAssertNil(provider.sentBodies[1]["temperature"])
        XCTAssertEqual(PowerPack_AIRequestOptions.quirks(for: "custom-model", defaults: defaults).omitsTemperature, true)
    }

    func testSendAdaptsTokenParameterThenTemperature() async throws {
        let provider = FakeProvider([(400, openAIMaxTokensError), (400, openAITemperatureError), (200, "{}")])
        _ = try await PowerPack_AIRequestOptions.send(model: "custom-model", format: .openAI, defaults: defaults, build: request, execute: provider.execute)
        XCTAssertEqual(provider.sentBodies.count, 3)
        XCTAssertNotNil(provider.sentBodies[2]["max_completion_tokens"])
        XCTAssertNil(provider.sentBodies[2]["temperature"])
    }

    func testSendUsesSavedQuirksOnFirstRequest() async throws {
        PowerPack_AIRequestOptions.save(PowerPack_ModelQuirks(omitsTemperature: true), for: "gpt-5.2", defaults: defaults)
        let provider = FakeProvider([(200, "{}")])
        _ = try await PowerPack_AIRequestOptions.send(model: "gpt-5.2", format: .openAI, defaults: defaults, build: request, execute: provider.execute)
        XCTAssertEqual(provider.sentBodies.count, 1)
        XCTAssertNil(provider.sentBodies[0]["temperature"])
    }

    func testSendUsesKnownQuirksOnFirstRequest() async throws {
        let provider = FakeProvider([(200, "{}")])
        _ = try await PowerPack_AIRequestOptions.send(model: "gpt-5.2", provider: .openAI, format: .openAI, defaults: defaults, build: request, execute: provider.execute)
        XCTAssertEqual(provider.sentBodies.count, 1)
        XCTAssertNil(provider.sentBodies[0]["temperature"])
        XCTAssertNotNil(provider.sentBodies[0]["max_completion_tokens"])
    }

    func testSendReturnsUnrelatedErrorWithoutRetrying() async throws {
        let provider = FakeProvider([(429, #"{"error":{"message":"Rate limit"}}"#)])
        let (_, response) = try await PowerPack_AIRequestOptions.send(model: "custom-model", format: .openAI, defaults: defaults, build: request, execute: provider.execute)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 429)
        XCTAssertEqual(provider.sentBodies.count, 1)
    }
}
