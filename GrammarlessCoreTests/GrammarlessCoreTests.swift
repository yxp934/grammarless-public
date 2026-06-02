import Foundation
import XCTest
@testable import GrammarlessCore

private final class FakeSpellChecker: NSSpellChecker {
    var misspelledWords: Set<String> = []
    var guessMap: [String: [String]] = [:]

    override func checkSpelling(
        of stringToCheck: String,
        startingAt charIndex: Int,
        language: String?,
        wrap wrapFlag: Bool,
        inSpellDocumentWithTag tag: Int,
        wordCount: UnsafeMutablePointer<Int>?
    ) -> NSRange {
        guard misspelledWords.contains(stringToCheck) else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: 0, length: (stringToCheck as NSString).length)
    }

    override func guesses(
        forWordRange range: NSRange,
        in string: String,
        language: String?,
        inSpellDocumentWithTag tag: Int
    ) -> [String]? {
        let word = (string as NSString).substring(with: range)
        return guessMap[word]
    }
}

private final class FakeAPIKeyStore: APIKeyStoring {
    var apiKey: String?

    func readAPIKey() -> String? {
        apiKey
    }

    func writeAPIKey(_ apiKey: String) -> Bool {
        self.apiKey = apiKey
        return true
    }

    func deleteAPIKey() -> Bool {
        apiKey = nil
        return true
    }
}

private final class FakeAgentLLM: LLMReviewing {
    var turns: [AgentToolTurnResponse]
    private(set) var requests: [AgentToolTurnRequest] = []

    init(turns: [AgentToolTurnResponse]) {
        self.turns = turns
    }

    func review(snapshot: TextSnapshot, configuration: AppConfiguration) async throws -> SuggestionBatch {
        throw LLMError.emptyContent
    }

    func performAction(
        request: AIActionRequest,
        configuration: AppConfiguration
    ) async throws -> ReviewActionResult {
        throw LLMError.emptyContent
    }

    func performAgentAction(
        request: AgentActionRequest,
        configuration: AppConfiguration
    ) async throws -> AgentResponse {
        throw LLMError.emptyContent
    }

    func performAgentToolTurn(
        request: AgentToolTurnRequest,
        configuration: AppConfiguration
    ) async throws -> AgentToolTurnResponse {
        requests.append(request)
        guard !turns.isEmpty else { throw LLMError.emptyContent }
        return turns.removeFirst()
    }

    func requestGhostSuggestion(
        request: GhostSuggestionRequest,
        configuration: AppConfiguration
    ) async throws -> GhostSuggestion {
        throw LLMError.emptyContent
    }

    func performImpactStep(
        systemPrompt: String,
        userPrompt: String,
        configuration: AppConfiguration,
        timeout: Double
    ) async throws -> String {
        throw LLMError.emptyContent
    }
}

private final class FakeChatCompletionURLProtocol: URLProtocol {
    struct CapturedRequest {
        let systemPrompt: String
        let userPrompt: String
        let stream: Bool
    }

    static let lock = NSLock()
    static var capturedRequests: [CapturedRequest] = []
    static var responseContent = #"{"replacement":"Improved text.","explanation":"Done."}"#
    static var streamingChunks: [String] = []

    static func reset(
        responseContent: String = #"{"replacement":"Improved text.","explanation":"Done."}"#,
        streamingChunks: [String] = []
    ) {
        lock.lock()
        capturedRequests = []
        Self.responseContent = responseContent
        Self.streamingChunks = streamingChunks
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "fake-chat.local"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let payload = try JSONSerialization.jsonObject(with: Self.bodyData(for: request)) as? [String: Any]
            let messages = payload?["messages"] as? [[String: Any]] ?? []
            let systemPrompt = messages.first(where: { $0["role"] as? String == "system" })?["content"] as? String ?? ""
            let userPrompt = messages.first(where: { $0["role"] as? String == "user" })?["content"] as? String ?? ""
            let stream = payload?["stream"] as? Bool ?? false
            Self.lock.lock()
            Self.capturedRequests.append(CapturedRequest(systemPrompt: systemPrompt, userPrompt: userPrompt, stream: stream))
            let content = Self.responseContent
            let chunks = Self.streamingChunks
            Self.lock.unlock()

            if stream {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/event-stream; charset=utf-8"]
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                let streamParts = chunks.isEmpty ? [content] : chunks
                for part in streamParts {
                    let payload: [String: Any] = [
                        "choices": [
                            [
                                "delta": [
                                    "content": part,
                                ],
                            ],
                        ],
                    ]
                    let chunkData = try JSONSerialization.data(withJSONObject: payload)
                    client?.urlProtocol(self, didLoad: Data("data: ".utf8))
                    client?.urlProtocol(self, didLoad: chunkData)
                    client?.urlProtocol(self, didLoad: Data("\n\n".utf8))
                }
                client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
                client?.urlProtocolDidFinishLoading(self)
                return
            }

            let responsePayload: [String: Any] = [
                "choices": [
                    [
                        "message": [
                            "content": content,
                        ],
                    ],
                ],
            ]
            let responseData = try JSONSerialization.data(withJSONObject: responsePayload)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json; charset=utf-8"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseData)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func bodyData(for request: URLRequest) -> Data {
        if let httpBody = request.httpBody {
            return httpBody
        }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private actor DeltaRecorder {
    private var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func last() -> String? {
        values.last
    }
}

private func makeSnapshot(_ text: String = "Hello world.") -> TextSnapshot {
    TextSnapshot(
        appBundleId: "com.apple.TextEdit",
        elementIdentity: "test-element",
        fullText: text,
        selectedRange: NSRange(location: 6, length: 5),
        analysisText: text,
        analysisRangeInFullText: NSRange(location: 0, length: (text as NSString).length),
        elementBounds: CGRect(x: 10, y: 10, width: 480, height: 320),
        revision: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        languageHint: .en
    )
}

private func makeChineseSnapshot(
    fullText: String,
    analysisText: String? = nil,
    analysisLocation: Int = 0
) -> TextSnapshot {
    let analysis = analysisText ?? fullText
    return TextSnapshot(
        appBundleId: "com.apple.TextEdit",
        elementIdentity: "test-element",
        fullText: fullText,
        selectedRange: NSRange(location: analysisLocation, length: 0),
        analysisText: analysis,
        analysisRangeInFullText: NSRange(location: analysisLocation, length: (analysis as NSString).length),
        elementBounds: CGRect(x: 10, y: 10, width: 480, height: 320),
        revision: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        languageHint: .zh
    )
}

final class ParagraphContextExtractorTests: XCTestCase {
    func testMapsAnalysisRangeBackToFullText() {
        let text = "Hello world.\nThis is teh sample.\nBye."
        let selection = NSRange(location: 20, length: 0)
        let paragraph = ParagraphContextExtractor.extract(from: text, selectedRange: selection)
        XCTAssertEqual(paragraph.analysisText, "This is teh sample.\n")

        let analysisRange = NSRange(location: 8, length: 3)
        let mapped = ParagraphContextExtractor.mapAnalysisRangeToFullText(
            analysisRange: analysisRange,
            analysisRangeInFullText: paragraph.analysisRangeInFullText
        )
        let nsText = text as NSString
        XCTAssertEqual(nsText.substring(with: mapped), "teh")
    }

    func testExtractsLastParagraphWhenCaretIsAtEndOfText() {
        let text = "First line.\nSecond paragraph."
        let selection = NSRange(location: (text as NSString).length, length: 0)
        let paragraph = ParagraphContextExtractor.extract(from: text, selectedRange: selection)

        XCTAssertEqual(paragraph.analysisText, "Second paragraph.")
        XCTAssertEqual(paragraph.paragraphIdentity, "12:17")
    }

    func testVisibleRangeExpandsToAllVisibleParagraphs() {
        let first = "第一段错误。\n"
        let second = "第二段我门。\n"
        let third = "第三段中文,标点。\n"
        let fourth = "第四段结束。"
        let text = first + second + third + fourth
        let secondStart = (first as NSString).length
        let thirdStart = secondStart + (second as NSString).length
        let visibleRange = NSRange(
            location: secondStart + 2,
            length: (thirdStart + 4) - (secondStart + 2)
        )

        let paragraph = ParagraphContextExtractor.extract(
            from: text,
            selectedRange: NSRange(location: 0, length: 0),
            visibleRange: visibleRange
        )

        XCTAssertEqual(paragraph.analysisText, second + third)
        XCTAssertEqual(
            paragraph.analysisRangeInFullText,
            NSRange(location: secondStart, length: ((second + third) as NSString).length)
        )
        XCTAssertEqual(paragraph.paragraphIdentity, "\(secondStart):\(((second + third) as NSString).length)")
    }

    func testInvalidVisibleRangeFallsBackToCaretParagraph() {
        let text = "A.\nB.\nC."
        let selection = NSRange(location: ("A.\n" as NSString).length, length: 0)

        let paragraph = ParagraphContextExtractor.extract(
            from: text,
            selectedRange: selection,
            visibleRange: NSRange(location: 0, length: (text as NSString).length + 10)
        )

        XCTAssertEqual(paragraph.analysisText, "B.\n")
        XCTAssertEqual(paragraph.analysisRangeInFullText, NSRange(location: 3, length: 3))
    }
}

final class ConfigurationStoreTests: XCTestCase {
    func testSanitizesEmbeddedWhitespaceInNetworkSettings() {
        let configuration = AppConfiguration(
            baseURL: " https://inference.canopywave.io/ \n v1/\n",
            apiKey: " cw_\n secret\t key ",
            model: " zai/glm-5.1\n "
        ).sanitized()

        XCTAssertEqual(configuration.baseURL, "https://inference.canopywave.io/v1")
        XCTAssertEqual(configuration.apiKey, "cw_secretkey")
        XCTAssertEqual(configuration.model, "zai/glm-5.1")
    }

    func testFreshDefaultsDoNotWriteDevelopmentKeyDuringLaunch() throws {
        let suiteName = "GrammarlessCoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keyStore = FakeAPIKeyStore()

        let store = ConfigurationStore(defaults: defaults, apiKeyStore: keyStore)

        XCTAssertEqual(store.configuration.apiKey, AppConfiguration().apiKey)
        XCTAssertNil(keyStore.apiKey)
        XCTAssertNil(defaults.data(forKey: ConfigurationStore.storageKey))
    }

    func testPersistsAPIKeyOutsideDefaults() throws {
        let suiteName = "GrammarlessCoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keyStore = FakeAPIKeyStore()
        let store = ConfigurationStore(defaults: defaults, apiKeyStore: keyStore)

        store.update {
            $0.apiKey = "test-api-key-secret"
            $0.model = "test-model"
        }

        XCTAssertEqual(keyStore.apiKey, "test-api-key-secret")
        let data = try XCTUnwrap(defaults.data(forKey: ConfigurationStore.storageKey))
        let rawJSON = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(rawJSON.contains("test-api-key-secret"))

        let reloaded = ConfigurationStore(defaults: defaults, apiKeyStore: keyStore)
        XCTAssertEqual(reloaded.configuration.apiKey, "test-api-key-secret")
        XCTAssertEqual(reloaded.configuration.model, "test-model")
    }

    func testDecodingOlderConfigurationDefaultsLanguageAndGhost() throws {
        let json = """
        {
          "baseURL": "http://older.local/v1",
          "apiKey": "test-api-key-old",
          "model": "legacy-model",
          "debounceMilliseconds": 900,
          "reviewTimeoutSeconds": 12,
          "actionTimeoutSeconds": 20
        }
        """

        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.uiLanguage, .zh)
        XCTAssertTrue(decoded.isGhostTextEnabled)
        XCTAssertEqual(decoded.model, "legacy-model")
    }

    func testPersistsLanguageAndGhostSettings() throws {
        let suiteName = "GrammarlessCoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keyStore = FakeAPIKeyStore()
        let store = ConfigurationStore(defaults: defaults, apiKeyStore: keyStore)

        store.update {
            $0.uiLanguage = .en
            $0.isGhostTextEnabled = false
        }

        let reloaded = ConfigurationStore(defaults: defaults, apiKeyStore: keyStore)
        XCTAssertEqual(reloaded.configuration.uiLanguage, .en)
        XCTAssertFalse(reloaded.configuration.isGhostTextEnabled)
    }

    func testDisabledKeyStoreCanProvideDevelopmentFallbackWhenDefaultsHideKey() throws {
        let suiteName = "GrammarlessCoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let encoder = JSONEncoder()
        var persisted = AppConfiguration()
        persisted.apiKey = ""
        persisted.model = "test-model"
        defaults.set(try encoder.encode(persisted), forKey: ConfigurationStore.storageKey)

        let store = ConfigurationStore(
            defaults: defaults,
            apiKeyStore: DisabledAPIKeyStore(fallbackAPIKey: "test-api-key-dev-fallback")
        )

        XCTAssertEqual(store.configuration.apiKey, "test-api-key-dev-fallback")
        XCTAssertEqual(store.configuration.model, "test-model")
    }

    func testPersistedAPISettingsAreSanitizedAndBeatDevelopmentFallback() throws {
        let suiteName = "GrammarlessCoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let persisted = AppConfiguration(
            baseURL: " https://inference.canopywave.io/v1/\n",
            apiKey: " real-user-key\n",
            model: " deepseek/deepseek-v4-flash\n"
        )
        defaults.set(try encoder.encode(persisted), forKey: ConfigurationStore.storageKey)

        let store = ConfigurationStore(
            defaults: defaults,
            apiKeyStore: DisabledAPIKeyStore(fallbackAPIKey: "test-api-key-dev-fallback")
        )

        XCTAssertEqual(store.configuration.baseURL, "https://inference.canopywave.io/v1")
        XCTAssertEqual(store.configuration.apiKey, "real-user-key")
        XCTAssertEqual(store.configuration.model, "deepseek/deepseek-v4-flash")

        let data = try XCTUnwrap(defaults.data(forKey: ConfigurationStore.storageKey))
        let redecoded = try decoder.decode(AppConfiguration.self, from: data)
        XCTAssertEqual(redecoded.baseURL, "https://inference.canopywave.io/v1")
        XCTAssertEqual(redecoded.apiKey, "real-user-key")
        XCTAssertEqual(redecoded.model, "deepseek/deepseek-v4-flash")
    }

    func testPersistedUserAPIKeyOverwritesStaleKeychainValue() throws {
        let suiteName = "GrammarlessCoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let encoder = JSONEncoder()
        let keyStore = FakeAPIKeyStore()
        keyStore.apiKey = "stale-key"
        let persisted = AppConfiguration(
            baseURL: "https://inference.canopywave.io/v1",
            apiKey: " fresh-key\n",
            model: "deepseek/deepseek-v4-flash"
        )
        defaults.set(try encoder.encode(persisted), forKey: ConfigurationStore.storageKey)

        let store = ConfigurationStore(defaults: defaults, apiKeyStore: keyStore)

        XCTAssertEqual(store.configuration.apiKey, "fresh-key")
        XCTAssertEqual(keyStore.apiKey, "fresh-key")
        let data = try XCTUnwrap(defaults.data(forKey: ConfigurationStore.storageKey))
        let rawJSON = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(rawJSON.contains("fresh-key"))
    }
}

final class LanguageRouterTests: XCTestCase {
    func testRoutesEnglishChineseAndMixed() {
        XCTAssertEqual(LanguageRouter.detectLanguage(for: "This is an English paragraph."), .en)
        XCTAssertEqual(LanguageRouter.detectLanguage(for: "这是一个中文段落。"), .zh)
        XCTAssertEqual(LanguageRouter.detectLanguage(for: "这是 mixed English 内容"), .mixed)
    }
}

final class ReviewParsingTests: XCTestCase {
    func testDropsInvalidAndOutOfRangeSuggestions() throws {
        let snapshot = TextSnapshot(
            appBundleId: "com.apple.TextEdit",
            elementIdentity: "1",
            fullText: "hello wrld",
            selectedRange: NSRange(location: 0, length: 0),
            analysisText: "hello wrld",
            analysisRangeInFullText: NSRange(location: 0, length: 10),
            elementBounds: .zero,
            revision: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            languageHint: .en
        )

        let content = """
        {
          "language":"en",
          "suggestions":[
            {"kind":"spelling","start":6,"end":10,"original":"wrld","replacement":"world","explanation":"Misspelled"},
            {"kind":"grammar","start":99,"end":101,"original":"xx","replacement":"yy","explanation":"bad range"},
            {"kind":"rewrite","start":0,"end":5,"original":"HELLO","replacement":"Hi","explanation":"bad original"}
          ]
        }
        """

        let batch = try ReviewParsing.parseSuggestionBatch(content: content, snapshot: snapshot)
        XCTAssertEqual(batch.suggestions.count, 1)
        XCTAssertEqual(batch.suggestions.first?.originalText, "wrld")
        XCTAssertEqual(batch.suggestions.first?.replacementText, "world")
    }

    func testDropsNoOpSuggestions() throws {
        let snapshot = TextSnapshot(
            appBundleId: "com.apple.TextEdit",
            elementIdentity: "1",
            fullText: "spanish",
            selectedRange: NSRange(location: 0, length: 0),
            analysisText: "spanish",
            analysisRangeInFullText: NSRange(location: 0, length: 7),
            elementBounds: .zero,
            revision: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            languageHint: .en
        )

        let content = """
        {
          "language":"en",
          "suggestions":[
            {"kind":"spelling","start":0,"end":7,"original":"spanish","replacement":"spanish","explanation":"no-op"},
            {"kind":"rewrite","start":0,"end":7,"original":"spanish","replacement":"Spanish","explanation":"proper noun"}
          ]
        }
        """

        let batch = try ReviewParsing.parseSuggestionBatch(content: content, snapshot: snapshot)
        XCTAssertEqual(batch.suggestions.count, 1)
        XCTAssertEqual(batch.suggestions.first?.replacementText, "Spanish")
    }

    func testParsesAgentToolTurnWithLossyArguments() throws {
        let snapshot = makeSnapshot("Hello world.")
        let content = """
        {
          "message": "",
          "tool_calls": [
            {
              "id": "call-1",
              "name": "draft_edit_patch",
              "arguments": {
                "start": 6,
                "end": 11,
                "replacement": "team",
                "reason": true
              }
            }
          ],
          "outline": ["检查上下文", "生成局部修改"]
        }
        """

        let response = try ReviewParsing.parseAgentToolTurnResponse(content: content, snapshot: snapshot)

        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls.first?.id, "call-1")
        XCTAssertEqual(response.toolCalls.first?.name, .draftEditPatch)
        XCTAssertEqual(response.toolCalls.first?.arguments["start"], "6")
        XCTAssertEqual(response.toolCalls.first?.arguments["end"], "11")
        XCTAssertEqual(response.toolCalls.first?.arguments["reason"], "true")
        XCTAssertEqual(response.outline, ["检查上下文", "生成局部修改"])
    }
}

final class LLMClientLanguagePromptTests: XCTestCase {
    func testPerformActionInjectsSelectedEnglishLanguageRule() async throws {
        FakeChatCompletionURLProtocol.reset()
        URLProtocol.registerClass(FakeChatCompletionURLProtocol.self)
        defer { URLProtocol.unregisterClass(FakeChatCompletionURLProtocol.self) }

        let client = LLMClient()
        let result = try await client.performAction(
            request: AIActionRequest(
                action: .formal,
                selectedText: "这是一句中文。",
                surroundingContext: "这是一句中文。",
                languageHint: .zh
            ),
            configuration: AppConfiguration(
                baseURL: "http://fake-chat.local/v1",
                apiKey: "test-api-key",
                model: "test-model",
                uiLanguage: .en
            )
        )

        XCTAssertEqual(result.replacement, "Improved text.")
        let captured = try XCTUnwrap(FakeChatCompletionURLProtocol.capturedRequests.first)
        XCTAssertTrue(captured.systemPrompt.contains("Selected response language: English."))
        XCTAssertTrue(captured.userPrompt.contains("selectedResponseLanguage: English"))
        XCTAssertTrue(captured.systemPrompt.contains("Do not switch languages"))
        XCTAssertTrue(captured.systemPrompt.contains("action=formal"))
    }

    func testGhostPromptRequestsNonEmptyEndContinuation() async throws {
        FakeChatCompletionURLProtocol.reset(
            responseContent: #"{"completion":" 下一句自然延续。","explanation":"继续文末思路"}"#
        )
        URLProtocol.registerClass(FakeChatCompletionURLProtocol.self)
        defer { URLProtocol.unregisterClass(FakeChatCompletionURLProtocol.self) }

        let text = "今天的训练让我意识到团队协作很重要。"
        let snapshot = p4Snapshot(
            text,
            selectedRange: NSRange(location: (text as NSString).length, length: 0)
        )
        let ghost = try await LLMClient().requestGhostSuggestion(
            request: GhostSuggestionRequest(
                snapshot: snapshot,
                caretRange: snapshot.selectedRange,
                memoryContext: WritingMemoryContext()
            ),
            configuration: AppConfiguration(
                baseURL: "http://fake-chat.local/v1",
                apiKey: "test-api-key",
                model: "test-model",
                uiLanguage: .zh
            )
        )

        XCTAssertEqual(ghost.text, "下一句自然延续。")
        let captured = try XCTUnwrap(FakeChatCompletionURLProtocol.capturedRequests.last)
        XCTAssertTrue(captured.systemPrompt.contains("completion MUST be non-empty"))
        XCTAssertFalse(captured.systemPrompt.contains("return completion=\"\" with a short explanation"))
    }

    func testStreamAgentFinalMessageUsesStreamingMarkdownRules() async throws {
        FakeChatCompletionURLProtocol.reset(
            responseContent: "",
            streamingChunks: [
                "已准备好 ",
                "**2** 处修改",
                "\n- 第一处更简洁",
            ]
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeChatCompletionURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = LLMClient(urlSession: session)
        let recorder = DeltaRecorder()

        let content = try await client.streamAgentFinalMessage(
            request: AgentFinalMessageRequest(
                instruction: "请润色这段文字",
                response: AgentResponse(
                    message: "已经生成两处建议修改。",
                    patches: [
                        TextPatch(
                            rangeInFullText: NSRange(location: 0, length: 5),
                            originalText: "Hello",
                            replacementText: "Hi",
                            reason: "更自然"
                        )
                    ],
                    outline: ["先说明修改", "再给下一步建议"]
                ),
                toolEvents: [
                    AgentToolEvent(callID: "draft-1", name: .draftEditPatch, status: .succeeded, summary: "生成修改草案", detail: "done")
                ],
                allowsCodeBlocks: false
            ),
            configuration: AppConfiguration(
                baseURL: "http://fake-chat.local/v1",
                apiKey: "test-api-key",
                model: "test-model",
                uiLanguage: .zh
            ),
            onDelta: { await recorder.append($0) }
        )

        XCTAssertEqual(content, "已准备好 **2** 处修改\n- 第一处更简洁")
        let lastEmission = await recorder.last()
        XCTAssertEqual(lastEmission, content)
        let captured = try XCTUnwrap(FakeChatCompletionURLProtocol.capturedRequests.last)
        XCTAssertTrue(captured.stream)
        XCTAssertTrue(captured.systemPrompt.contains("Allowed Markdown"))
        XCTAssertTrue(captured.systemPrompt.contains("never output triple backticks"))
        XCTAssertTrue(captured.userPrompt.contains("allowCodeBlocks: false"))
    }
}

final class RewriteActionDiffTests: XCTestCase {
    func testRewriteActionsMatchCompactSidebarModes() {
        XCTAssertEqual(ReviewAction.allCases.map(\.rawValue), ["formal", "clarity", "shorten", "natural"])
    }

    func testMergedDiffDeletesEnglishWordWithoutMarkingWholeSentence() {
        let segments = RewriteDiff.mergedSegments(
            original: "This is very good.",
            revised: "This is good."
        )

        XCTAssertEqual(segments.filter { $0.operation == .deletion }.map(\.text).joined(), "very ")
        XCTAssertEqual(segments.filter { $0.operation == .insertion }.map(\.text).joined(), "")
        XCTAssertTrue(segments.contains { $0.operation == .equal && $0.text.contains("This is ") })
        XCTAssertTrue(segments.contains { $0.operation == .equal && $0.text.contains("good.") })
    }

    func testMergedDiffRefinesSingleWordReplacementToChangedCharacter() {
        let segments = RewriteDiff.mergedSegments(
            original: "OpenAi",
            revised: "OpenAI"
        )

        XCTAssertEqual(segments, [
            RewriteDiffSegment(operation: .equal, text: "OpenA"),
            RewriteDiffSegment(operation: .deletion, text: "i"),
            RewriteDiffSegment(operation: .insertion, text: "I"),
        ])
    }

    func testMergedDiffPreservesChineseCharacterReplacement() {
        let segments = RewriteDiff.mergedSegments(
            original: "我门应当尽快。",
            revised: "我们应当尽快。"
        )

        XCTAssertTrue(segments.contains { $0.operation == .equal && $0.text == "我" })
        XCTAssertTrue(segments.contains { $0.operation == .deletion && $0.text == "门" })
        XCTAssertTrue(segments.contains { $0.operation == .insertion && $0.text == "们" })
        XCTAssertFalse(segments.contains { $0.operation == .deletion && $0.text == "我门应当尽快。" })
        XCTAssertFalse(segments.contains { $0.operation == .insertion && $0.text == "我们应当尽快。" })
    }

    func testMergedDiffDoesNotCollapseFullSentenceWhenCharacterAnchorsExist() {
        let original = "OpenAi draft"
        let revised = "OpenAI drafts"
        let segments = RewriteDiff.mergedSegments(original: original, revised: revised)

        XCTAssertTrue(segments.contains { $0.operation == .equal && $0.text.contains("OpenA") })
        XCTAssertTrue(segments.contains { $0.operation == .equal && $0.text.contains("draft") })
        XCTAssertFalse(segments.contains { $0.operation == .deletion && $0.text == original })
        XCTAssertFalse(segments.contains { $0.operation == .insertion && $0.text == revised })
    }

    func testMergedDiffKeepsUnrelatedPhraseReplacementLocal() {
        let segments = RewriteDiff.mergedSegments(
            original: "This draft is very very long.",
            revised: "This draft is concise."
        )

        XCTAssertTrue(segments.contains { $0.operation == .deletion && $0.text.contains("very very long") })
        XCTAssertTrue(segments.contains { $0.operation == .insertion && $0.text.contains("concise") })
        XCTAssertFalse(segments.isEmpty)
    }

    func testMergedDiffPreservesChineseInlinePhraseChanges() {
        let segments = RewriteDiff.mergedSegments(
            original: "这个句子一下下不自然。",
            revised: "这个句子更自然。"
        )

        XCTAssertTrue(segments.contains { $0.operation == .deletion && $0.text.contains("一下下不") })
        XCTAssertTrue(segments.contains { $0.operation == .insertion && $0.text.contains("更") })
    }
}

final class OfflineChineseProofreadingTests: XCTestCase {
    func testReviewEngineReturnsSwiftNativeChineseSuggestions() async throws {
        let engine = ReviewEngine(llmClient: FakeAgentLLM(turns: []))
        let batch = try await engine.offlineChineseSuggestions(
            for: makeChineseSnapshot(fullText: "今天我门以经出发，中文,标点。")
        )

        XCTAssertTrue(batch.suggestions.contains { $0.originalText == "我门" && $0.replacementText == "我们" })
        XCTAssertTrue(batch.suggestions.contains { $0.originalText == "以经" && $0.replacementText == "已经" })
        XCTAssertTrue(batch.suggestions.contains { $0.originalText == "," && $0.replacementText == "，" })
    }

    func testEnglishModeDisablesOfflineChineseProofreading() async throws {
        let engine = ReviewEngine(llmClient: FakeAgentLLM(turns: []))
        let batch = try await engine.offlineChineseSuggestions(
            for: makeChineseSnapshot(fullText: "今天我门以经出发，中文,标点。"),
            configuration: AppConfiguration(uiLanguage: .en)
        )

        XCTAssertTrue(batch.suggestions.isEmpty)
    }

    func testCJKAutomaticProofreadingSkipsRemoteReview() {
        let engine = ReviewEngine(llmClient: FakeAgentLLM(turns: []))

        XCTAssertFalse(engine.shouldRunRemoteReview(for: makeChineseSnapshot(fullText: "中文,标点。")))
        XCTAssertFalse(engine.shouldRunRemoteReview(for: makeSnapshot("OpenAI 与中文混排。")))
        XCTAssertTrue(engine.shouldRunRemoteReview(for: makeSnapshot("This draft needs review.")))
    }
}

final class AgentToolingTests: XCTestCase {
    func testDraftEditPatchCreatesValidatedPatch() {
        let snapshot = makeSnapshot("Hello world.")
        let call = AgentToolCall(
            id: "draft-1",
            name: .draftEditPatch,
            arguments: [
                "start": "6",
                "end": "11",
                "original": "world",
                "replacement": "team",
                "reason": "make audience explicit",
            ]
        )

        let output = AgentToolExecutor.execute(
            call: call,
            context: AgentToolExecutionContext(
                snapshot: snapshot,
                selectedRange: snapshot.selectedRange,
                memoryContext: WritingMemoryContext()
            )
        )

        XCTAssertEqual(output.result.status, .succeeded)
        XCTAssertEqual(output.newPatches.count, 1)
        XCTAssertEqual(output.newPatches.first?.originalText, "world")
        XCTAssertEqual(output.newPatches.first?.replacementText, "team")
    }

    func testDraftEditPatchRejectsStaleOriginalAndNoOp() {
        let snapshot = makeSnapshot("Hello world.")
        let stale = AgentToolExecutor.execute(
            call: AgentToolCall(
                id: "stale",
                name: .draftEditPatch,
                arguments: [
                    "start": "6",
                    "end": "11",
                    "original": "planet",
                    "replacement": "team",
                ]
            ),
            context: AgentToolExecutionContext(
                snapshot: snapshot,
                selectedRange: snapshot.selectedRange,
                memoryContext: WritingMemoryContext()
            )
        )
        XCTAssertEqual(stale.result.status, .failed)
        XCTAssertTrue(stale.newPatches.isEmpty)

        let noop = AgentToolExecutor.execute(
            call: AgentToolCall(
                id: "noop",
                name: .draftEditPatch,
                arguments: [
                    "start": "6",
                    "end": "11",
                    "original": "world",
                    "replacement": "world",
                ]
            ),
            context: AgentToolExecutionContext(
                snapshot: snapshot,
                selectedRange: snapshot.selectedRange,
                memoryContext: WritingMemoryContext()
            )
        )
        XCTAssertEqual(noop.result.status, .failed)
        XCTAssertTrue(noop.newPatches.isEmpty)
    }

    func testDraftEditPatchRepairsModelOffsetWhenOriginalIsUnique() {
        let snapshot = makeSnapshot("Alpha beta gamma.")
        let output = AgentToolExecutor.execute(
            call: AgentToolCall(
                id: "repair-offset",
                name: .draftEditPatch,
                arguments: [
                    "start": "0",
                    "end": "5",
                    "original": "gamma",
                    "replacement": "delta",
                    "reason": "model supplied stale offsets with exact original",
                ]
            ),
            context: AgentToolExecutionContext(
                snapshot: snapshot,
                selectedRange: snapshot.selectedRange,
                memoryContext: WritingMemoryContext()
            )
        )

        XCTAssertEqual(output.result.status, .succeeded)
        XCTAssertEqual(output.newPatches.first?.rangeInFullText, NSRange(location: 11, length: 5))
        XCTAssertEqual(output.newPatches.first?.originalText, "gamma")
        XCTAssertEqual(output.newPatches.first?.replacementText, "delta")
    }

    func testAgentToolLoopRunsMultipleModelDrivenTurns() async throws {
        let fakeLLM = FakeAgentLLM(turns: [
            AgentToolTurnResponse(
                toolCalls: [
                    AgentToolCall(id: "read-1", name: .readDocumentContext)
                ]
            ),
            AgentToolTurnResponse(
                toolCalls: [
                    AgentToolCall(
                        id: "draft-1",
                        name: .draftEditPatch,
                        arguments: [
                            "start": "6",
                            "end": "11",
                            "original": "world",
                            "replacement": "team",
                            "reason": "make greeting more specific",
                        ]
                    ),
                    AgentToolCall(id: "preview-1", name: .previewPatchDiff),
                ]
            ),
            AgentToolTurnResponse(message: "已准备好一处可确认修改。")
        ])
        let engine = ReviewEngine(llmClient: fakeLLM)

        let result = try await engine.performAgentToolLoop(
            request: AgentToolLoopRequest(
                instruction: "把问候对象改得更具体",
                snapshot: makeSnapshot("Hello world."),
                selectedRange: NSRange(location: 6, length: 5),
                memoryContext: WritingMemoryContext(documentSummary: "A greeting.")
            ),
            configuration: AppConfiguration()
        )

        XCTAssertEqual(fakeLLM.requests.count, 3)
        XCTAssertEqual(result.toolCalls.map(\.name), [.readDocumentContext, .draftEditPatch, .previewPatchDiff])
        XCTAssertEqual(result.events.count, 6)
        XCTAssertEqual(result.response.message, "已准备好一处可确认修改。")
        XCTAssertEqual(result.response.patches.count, 1)
        XCTAssertEqual(result.response.patches.first?.replacementText, "team")
    }
}

final class ReplacementPlannerTests: XCTestCase {
    func testStrategyOrderFavorsNativePaste() {
        let strategies = ReplacementPlanner.strategies(
            for: ReplacementCapabilities(
                supportsNativePaste: true,
                supportsAXSelectedText: true,
                supportsTypingFallback: true
            )
        )
        XCTAssertEqual(strategies, [.nativePaste, .axSelectedText, .typingFallback])
    }

    func testRevisionMismatchRejectsReplaceCommand() {
        let command = ReplaceCommand(
            targetRange: NSRange(location: 0, length: 5),
            expectedOriginalText: "hello",
            replacementText: "hi",
            strategy: .nativePaste,
            snapshotRevision: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        )
        XCTAssertFalse(
            ReplacementPlanner.validate(
                command: command,
                currentText: "hello world",
                currentRevision: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
            )
        )
    }
}

private final class FakeClipboardClient: ClipboardClient {
    private(set) var current = ClipboardSnapshot(string: "before")

    func snapshot() -> ClipboardSnapshot {
        current
    }

    func write(string: String) {
        current = ClipboardSnapshot(string: string)
    }

    func restore(snapshot: ClipboardSnapshot) {
        current = snapshot
    }
}

final class ClipboardSessionTests: XCTestCase {
    func testRestoresClipboardAfterTemporaryWrite() {
        let client = FakeClipboardClient()
        let session = ClipboardSession(client: client)
        session.writeTemporary("temporary")
        XCTAssertEqual(client.current.string, "temporary")
        session.restore()
        XCTAssertEqual(client.current.string, "before")
    }
}

final class ReviewMergeTests: XCTestCase {
    func testMergeProducesStableOrderedSuggestions() {
        let suggestionA = Suggestion(
            id: UUID(),
            kind: .spelling,
            source: .local,
            rangeInFullText: NSRange(location: 6, length: 4),
            originalText: "wrld",
            replacementText: "world",
            explanation: "sp",
            paragraphIdentity: "0:10"
        )
        let suggestionB = Suggestion(
            id: UUID(),
            kind: .grammar,
            source: .llm,
            rangeInFullText: NSRange(location: 0, length: 5),
            originalText: "Hello",
            replacementText: "Hello,",
            explanation: "gr",
            paragraphIdentity: "0:10"
        )
        let merged = ReviewEngine.merge(
            local: SuggestionBatch(snapshotRevision: UUID(), paragraphIdentity: "0:10", suggestions: [suggestionA]),
            remote: SuggestionBatch(snapshotRevision: UUID(), paragraphIdentity: "0:10", suggestions: [suggestionA, suggestionB])
        )
        XCTAssertEqual(merged.suggestions.map(\.originalText), ["Hello", "wrld"])
    }

    func testMergeDeduplicatesRemoteSuggestionWhenLocalProofIssueHasSameVisiblePatch() {
        let range = NSRange(location: 0, length: 2)
        let local = Suggestion(
            kind: .spelling,
            source: .local,
            rangeInFullText: range,
            originalText: "我门",
            replacementText: "我们",
            explanation: "local proof",
            paragraphIdentity: "0:2",
            proofIssueKind: .phoneticSimilarChar,
            proofIssueSeverity: .warning,
            proofIssueConfidence: 0.99,
            proofIssueDetectorSource: "pinyin_confusions",
            proofIssueAdvancedTip: "test",
            proofIssueAutofixSafe: true
        )
        let remote = Suggestion(
            kind: .spelling,
            source: .llm,
            rangeInFullText: range,
            originalText: "我门",
            replacementText: "我们",
            explanation: "remote duplicate",
            paragraphIdentity: "0:2"
        )
        let overlappingRemote = Suggestion(
            kind: .rewrite,
            source: .llm,
            rangeInFullText: NSRange(location: 0, length: 4),
            originalText: "我门今天",
            replacementText: "我们今天",
            explanation: "remote overlap",
            paragraphIdentity: "0:4"
        )

        let merged = ReviewEngine.merge(
            local: SuggestionBatch(snapshotRevision: UUID(), paragraphIdentity: "0:2", suggestions: [local]),
            remote: SuggestionBatch(snapshotRevision: UUID(), paragraphIdentity: "0:2", suggestions: [remote, overlappingRemote])
        )

        XCTAssertEqual(merged.suggestions.count, 1)
        XCTAssertEqual(merged.suggestions.first?.source, .local)
        XCTAssertEqual(merged.suggestions.first?.proofIssueKind, .phoneticSimilarChar)
    }
}

final class SuggestionBatchReuseTests: XCTestCase {
    func testReuseRequiresMatchingRevisionAndParagraph() {
        let revision = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let snapshot = TextSnapshot(
            appBundleId: "com.apple.TextEdit",
            elementIdentity: "1",
            fullText: "First.\n\nSecond.",
            selectedRange: NSRange(location: 0, length: 0),
            analysisText: "First.\n",
            analysisRangeInFullText: NSRange(location: 0, length: 7),
            elementBounds: .zero,
            revision: revision,
            languageHint: .en
        )
        let batch = SuggestionBatch(
            snapshotRevision: revision,
            paragraphIdentity: "0:7",
            suggestions: []
        )

        XCTAssertTrue(batch.isReusable(for: snapshot))

        let sameParagraphDifferentSelection = TextSnapshot(
            appBundleId: snapshot.appBundleId,
            elementIdentity: snapshot.elementIdentity,
            fullText: snapshot.fullText,
            selectedRange: NSRange(location: 2, length: 3),
            analysisText: snapshot.analysisText,
            analysisRangeInFullText: snapshot.analysisRangeInFullText,
            elementBounds: snapshot.elementBounds,
            revision: snapshot.revision,
            languageHint: snapshot.languageHint
        )
        XCTAssertTrue(batch.isReusable(for: sameParagraphDifferentSelection))

        let differentParagraph = TextSnapshot(
            appBundleId: snapshot.appBundleId,
            elementIdentity: snapshot.elementIdentity,
            fullText: snapshot.fullText,
            selectedRange: NSRange(location: 8, length: 0),
            analysisText: "Second.",
            analysisRangeInFullText: NSRange(location: 8, length: 7),
            elementBounds: snapshot.elementBounds,
            revision: snapshot.revision,
            languageHint: snapshot.languageHint
        )
        XCTAssertFalse(batch.isReusable(for: differentParagraph))

        let differentRevision = TextSnapshot(
            appBundleId: snapshot.appBundleId,
            elementIdentity: snapshot.elementIdentity,
            fullText: snapshot.fullText + " Changed",
            selectedRange: snapshot.selectedRange,
            analysisText: snapshot.analysisText,
            analysisRangeInFullText: snapshot.analysisRangeInFullText,
            elementBounds: snapshot.elementBounds,
            revision: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            languageHint: snapshot.languageHint
        )
        XCTAssertFalse(batch.isReusable(for: differentRevision))
    }
}

final class ReviewEngineLocalSuggestionTests: XCTestCase {
    func testLocalSuggestionsCatchEnglishSpellingAndGrammar() {
        let text = "He do not knows this stafs."
        let snapshot = TextSnapshot(
            appBundleId: "com.apple.TextEdit",
            elementIdentity: "1",
            fullText: text,
            selectedRange: NSRange(location: 0, length: 0),
            analysisText: text,
            analysisRangeInFullText: NSRange(location: 0, length: (text as NSString).length),
            elementBounds: .zero,
            revision: UUID(),
            languageHint: .en
        )

        let batch = ReviewEngine().localSuggestions(for: snapshot)

        XCTAssertTrue(batch.suggestions.contains(where: {
            $0.kind == .spelling && $0.originalText == "stafs" && $0.proofIssueKind == .spelling
        }))
        XCTAssertTrue(batch.suggestions.contains(where: {
            $0.kind == .grammar && $0.originalText == "do not knows" && $0.replacementText == "does not know" && $0.proofIssueKind == .grammarSelection
        }))
        XCTAssertEqual(batch.suggestions.map(\.originalText), ["do not knows", "stafs"])
    }

    func testLocalSuggestionsKeepCapitalizationOnlyCorrections() {
        let text = "spanish"
        let snapshot = TextSnapshot(
            appBundleId: "com.apple.TextEdit",
            elementIdentity: "1",
            fullText: text,
            selectedRange: NSRange(location: 0, length: 0),
            analysisText: text,
            analysisRangeInFullText: NSRange(location: 0, length: (text as NSString).length),
            elementBounds: .zero,
            revision: UUID(),
            languageHint: .en
        )
        let spellChecker = FakeSpellChecker()
        spellChecker.misspelledWords = ["spanish"]
        spellChecker.guessMap = ["spanish": ["Spanish", "spanish"]]

        let batch = ReviewEngine(spellChecker: spellChecker).localSuggestions(for: snapshot)

        XCTAssertEqual(batch.suggestions.count, 1)
        XCTAssertEqual(batch.suggestions.first?.originalText, "spanish")
        XCTAssertEqual(batch.suggestions.first?.replacementText, "Spanish")
    }

    func testLocalSuggestionsDropExactNoOpSpellingSuggestions() {
        let text = "spanish"
        let snapshot = TextSnapshot(
            appBundleId: "com.apple.TextEdit",
            elementIdentity: "1",
            fullText: text,
            selectedRange: NSRange(location: 0, length: 0),
            analysisText: text,
            analysisRangeInFullText: NSRange(location: 0, length: (text as NSString).length),
            elementBounds: .zero,
            revision: UUID(),
            languageHint: .en
        )
        let spellChecker = FakeSpellChecker()
        spellChecker.misspelledWords = ["spanish"]
        spellChecker.guessMap = ["spanish": ["spanish"]]

        let batch = ReviewEngine(spellChecker: spellChecker).localSuggestions(for: snapshot)

        XCTAssertTrue(batch.suggestions.isEmpty)
    }

    func testLocalSuggestionsCatchChineseSpellingAndStyle() {
        let text = "我门今天需要把这份报告在明天之前尽快的去优化一下下。"
        let snapshot = TextSnapshot(
            appBundleId: "com.apple.TextEdit",
            elementIdentity: "1",
            fullText: text,
            selectedRange: NSRange(location: 0, length: 0),
            analysisText: text,
            analysisRangeInFullText: NSRange(location: 0, length: (text as NSString).length),
            elementBounds: .zero,
            revision: UUID(),
            languageHint: .zh
        )

        let batch = ReviewEngine().localSuggestions(for: snapshot)

        XCTAssertTrue(batch.suggestions.contains(where: {
            $0.kind == .spelling && $0.originalText == "我门" && $0.replacementText == "我们" && $0.proofIssueKind == .phoneticSimilarChar
        }))
        XCTAssertTrue(batch.suggestions.contains(where: {
            $0.kind == .grammar && $0.originalText == "尽快的去" && $0.replacementText == "尽快" && $0.proofIssueKind == .grammarRedundant
        }))
        XCTAssertTrue(batch.suggestions.contains(where: {
            $0.kind == .rewrite && $0.originalText == "一下下" && $0.replacementText == "一下" && $0.proofIssueKind == .styleRedundancy
        }))
        XCTAssertEqual(batch.suggestions.map(\.originalText), ["我门", "尽快的去", "一下下"])
    }

    func testMergeKeepsSameOrderAsLocalWhenRemoteAddsNoNewSuggestions() {
        let text = "He do not knows this stafs."
        let snapshot = TextSnapshot(
            appBundleId: "com.apple.TextEdit",
            elementIdentity: "1",
            fullText: text,
            selectedRange: NSRange(location: 0, length: 0),
            analysisText: text,
            analysisRangeInFullText: NSRange(location: 0, length: (text as NSString).length),
            elementBounds: .zero,
            revision: UUID(),
            languageHint: .en
        )

        let local = ReviewEngine().localSuggestions(for: snapshot)
        let merged = ReviewEngine.merge(local: local, remote: local)

        XCTAssertEqual(merged.suggestions.map(\.originalText), local.suggestions.map(\.originalText))
    }

    func testRedSuggestionOperationsCanUpdateDeleteAndAdd() throws {
        let text = "我门以经到达。"
        let snapshot = proofreadingSnapshot(text, languageHint: .zh)
        let existing = [
            Suggestion(
                kind: .spelling,
                source: .local,
                rangeInFullText: NSRange(location: 0, length: 2),
                originalText: "我门",
                replacementText: "我们",
                explanation: "local",
                paragraphIdentity: snapshot.paragraphIdentity,
                proofIssueKind: .phoneticSimilarChar
            ),
            Suggestion(
                kind: .spelling,
                source: .local,
                rangeInFullText: NSRange(location: 4, length: 2),
                originalText: "到达",
                replacementText: "抵达",
                explanation: "false red",
                paragraphIdentity: snapshot.paragraphIdentity,
                proofIssueKind: .spelling
            ),
        ]
        let content = """
        {"operations":[
          {"op":"update","id":"\(existing[0].stableIdentity)","start":0,"end":2,"original":"我门","replacement":"我们","explanation":"LLM confirmed typo."},
          {"op":"delete","id":"\(existing[1].stableIdentity)"},
          {"op":"add","start":2,"end":4,"original":"以经","replacement":"已经","explanation":"Missing red typo."}
        ]}
        """

        let batch = try ReviewParsing.parseRedSuggestionBatch(content: content, snapshot: snapshot, candidates: existing)

        XCTAssertEqual(batch.suggestions.count, 2)
        XCTAssertTrue(batch.suggestions.contains { $0.originalText == "我门" && $0.replacementText == "我们" && $0.explanation == "LLM confirmed typo." })
        XCTAssertTrue(batch.suggestions.contains { $0.originalText == "以经" && $0.replacementText == "已经" && $0.source == .llm })
        XCTAssertFalse(batch.suggestions.contains { $0.originalText == "到达" })
    }

    func testReviewEngineAdjudicatesRedSuggestionsThroughLLM() async throws {
        let text = "我门到了。"
        let snapshot = proofreadingSnapshot(text, languageHint: .zh)
        let suggestion = Suggestion(
            kind: .spelling,
            source: .local,
            rangeInFullText: NSRange(location: 0, length: 2),
            originalText: "我门",
            replacementText: "我们",
            explanation: "local",
            paragraphIdentity: snapshot.paragraphIdentity,
            proofIssueKind: .phoneticSimilarChar
        )
        FakeChatCompletionURLProtocol.reset(
            responseContent: #"{"operations":[{"op":"delete","id":"\#(suggestion.stableIdentity)"}]}"#
        )
        URLProtocol.registerClass(FakeChatCompletionURLProtocol.self)
        defer { URLProtocol.unregisterClass(FakeChatCompletionURLProtocol.self) }

        let engine = ReviewEngine(llmClient: LLMClient())
        let config = AppConfiguration(
            baseURL: "https://fake-chat.local/v1",
            apiKey: "test-key",
            model: "test-model",
            reviewTimeoutSeconds: 5,
            uiLanguage: .zh
        )

        let judged = try await engine.adjudicateRedSuggestions(
            for: snapshot,
            suggestions: [suggestion],
            configuration: config
        )

        XCTAssertTrue(judged.suggestions.isEmpty)
        let captured = try XCTUnwrap(FakeChatCompletionURLProtocol.capturedRequests.last)
        XCTAssertTrue(captured.systemPrompt.contains("Red Judge"))
        XCTAssertTrue(captured.userPrompt.contains(suggestion.stableIdentity))
    }
}

private func proofreadingSnapshot(_ text: String, languageHint: DetectedLanguage = .mixed) -> TextSnapshot {
    TextSnapshot(
        appBundleId: "com.apple.TextEdit",
        elementIdentity: "proof",
        fullText: text,
        selectedRange: NSRange(location: 0, length: 0),
        analysisText: text,
        analysisRangeInFullText: NSRange(location: 0, length: (text as NSString).length),
        elementBounds: .zero,
        revision: UUID(),
        languageHint: languageHint
    )
}

final class AdvancedProofreadingPipelineTests: XCTestCase {
    func testTextNormalizerAndSentenceSegmenterPreserveUTF16Offsets() {
        let normalized = TextNormalizer.normalize("ＡＢ１２　中文。Next")
        XCTAssertEqual(normalized.normalized, "AB12 中文。Next")
        XCTAssertEqual(normalized.normalizedToOriginalUTF16[0], 0)
        XCTAssertEqual(normalized.normalizedToOriginalUTF16[(normalized.normalized as NSString).length], ("ＡＢ１２　中文。Next" as NSString).length)

        let sentences = SentenceSegmenter.segment(
            "第一句。Second line\n第三句",
            baseRange: NSRange(location: 12, length: 0)
        )
        XCTAssertEqual(sentences.map(\.text), ["第一句。", "Second line\n", "第三句"])
        XCTAssertEqual(sentences[0].rangeInFullText.location, 12)
        XCTAssertEqual(sentences[1].rangeInFullText.location, 16)
    }

    func testP3PipelineDetectsAdvancedIssueTaxonomyWithPreciseRanges() {
        let text = """
        我门己经截止目前需要尽快的去进行优化一下，一下下即可。
        通过这项措施使效率提高。把问题被解决。中文,标点！！2026年2月31日，2026年5月1日星期六。
        金额伍佰万元整（500000元）。
        1. 一
        2. 二
        4. 四
        甲公司（以下简称客户）。乙公司（以下简称客户）。OpenAi在郫县，张三主任来了。
        """
        let issues = ProofreadingPipeline().issues(for: proofreadingSnapshot(text))
        let kinds = Set(issues.map(\.kind))

        let expectedKinds: Set<ProofIssueKind> = [
            .phoneticSimilarChar,
            .visualSimilarChar,
            .confusableWord,
            .grammarRedundant,
            .styleRedundancy,
            .grammarSelection,
            .grammarMissing,
            .grammarDisorder,
            .punctuation,
            .date,
            .amount,
            .sequenceNumber,
            .duplicateDefinition,
            .properNoun,
            .adminDivision,
            .leaderTitle,
        ]
        XCTAssertTrue(expectedKinds.isSubset(of: kinds), "missing kinds: \(expectedKinds.subtracting(kinds)) in \(issues.map { "\($0.kind.rawValue):\($0.sourceText)->\($0.replacementText ?? "nil")" })")

        let nsText = text as NSString
        for issue in issues {
            XCTAssertNotEqual(issue.rangeInFullText.location, NSNotFound)
            XCTAssertGreaterThan(issue.rangeInFullText.length, 0)
            XCTAssertLessThanOrEqual(NSMaxRange(issue.rangeInFullText), nsText.length)
            XCTAssertEqual(nsText.substring(with: issue.rangeInFullText), issue.sourceText)
        }

        XCTAssertTrue(issues.contains { $0.kind == .date && $0.sourceText == "2026年5月1日星期六" && $0.replacementText == "2026年5月1日星期五" })
        XCTAssertTrue(issues.contains { $0.kind == .punctuation && $0.sourceText == "," && $0.replacementText == "，" })
        XCTAssertTrue(issues.contains { $0.kind == .amount && $0.sourceText == "500000元" && $0.replacementText == "5000000元" })
    }

    func testReviewEngineMapsP3IssuesToExistingSuggestionSurface() {
        let text = "己经中文,标点。OpenAi在郫县。"
        let batch = ReviewEngine().localSuggestions(for: proofreadingSnapshot(text, languageHint: .zh))

        XCTAssertTrue(batch.suggestions.contains { $0.kind == .spelling && $0.proofIssueKind == .visualSimilarChar && $0.originalText == "己经" })
        XCTAssertTrue(batch.suggestions.contains { $0.kind == .grammar && $0.proofIssueKind == .punctuation && $0.originalText == "," })
        XCTAssertTrue(batch.suggestions.contains { $0.kind == .grammar && $0.proofIssueKind == .properNoun && $0.originalText == "OpenAi" })
        XCTAssertTrue(batch.suggestions.allSatisfy { $0.rangeInFullText.location != NSNotFound && !$0.isNoOpReplacement })
    }
}

final class LLMAdjudicatorTests: XCTestCase {
    func testParserAcceptsStrictJSONAndApplyRejectsHallucinatedOrMissingSemanticDecisions() {
        let acceptedID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let deterministicID = UUID(uuidString: "BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let missingSemanticID = UUID(uuidString: "CCCCCCCC-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

        let accepted = ProofIssue(
            id: acceptedID,
            kind: .confusableWord,
            severity: .warning,
            rangeInFullText: NSRange(location: 0, length: 4),
            sourceText: "截止目前",
            replacementText: "截至目前",
            confidence: 0.80,
            detectorSource: "test",
            explanation: "candidate",
            autofixSafe: false
        )
        let deterministic = ProofIssue(
            id: deterministicID,
            kind: .date,
            severity: .critical,
            rangeInFullText: NSRange(location: 5, length: 11),
            sourceText: "2026年2月31日",
            replacementText: "2026年2月28日",
            confidence: 0.99,
            detectorSource: "date",
            explanation: "deterministic",
            autofixSafe: false
        )
        let missingSemantic = ProofIssue(
            id: missingSemanticID,
            kind: .grammarSelection,
            severity: .warning,
            rangeInFullText: NSRange(location: 20, length: 4),
            sourceText: "进行优化",
            replacementText: "优化",
            confidence: 0.70,
            detectorSource: "grammar",
            explanation: "needs LLM",
            autofixSafe: false
        )

        let content = """
        {"decisions":[
          {"issueId":"\(acceptedID.uuidString)","decision":"revise","replacementText":"截至目前","confidence":0.93,"explanation":"上下文中应表示到当前时间点。"},
          {"issueId":"DDDDDDDD-BBBB-CCCC-DDDD-EEEEEEEEEEEE","decision":"accept","replacementText":"幻觉范围"}
        ]}
        """
        let decisions = LLMAdjudicator.parseDecisions(from: content)
        let applied = LLMAdjudicator.apply(decisions: decisions, to: [accepted, deterministic, missingSemantic])

        XCTAssertEqual(applied.map(\.id), [acceptedID, deterministicID])
        XCTAssertEqual(applied.first?.confidence, 0.93)
        XCTAssertEqual(applied.first?.explanation, "上下文中应表示到当前时间点。")
        XCTAssertTrue(applied.contains { $0.kind == .date })
        XCTAssertFalse(applied.contains { $0.id == missingSemanticID })
    }
}

final class IssueMergerTests: XCTestCase {
    func testOverlapResolutionPrefersCriticalIssueEvenWithLowerConfidence() {
        let warning = ProofIssue(
            kind: .confusableWord,
            severity: .warning,
            rangeInFullText: NSRange(location: 4, length: 4),
            sourceText: "Open",
            replacementText: "OPEN",
            confidence: 0.99,
            detectorSource: "warning",
            explanation: "warning",
            autofixSafe: false
        )
        let critical = ProofIssue(
            kind: .properNoun,
            severity: .critical,
            rangeInFullText: NSRange(location: 4, length: 6),
            sourceText: "OpenAi",
            replacementText: "OpenAI",
            confidence: 0.90,
            detectorSource: "critical",
            explanation: "critical",
            autofixSafe: true
        )

        let merged = IssueMerger.merge([warning, critical])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.kind, .properNoun)
        XCTAssertEqual(merged.first?.replacementText, "OpenAI")
    }
}

private func p4Snapshot(_ text: String, selectedRange: NSRange = NSRange(location: 0, length: 0)) -> TextSnapshot {
    TextSnapshot(
        appBundleId: "com.apple.TextEdit",
        elementIdentity: "p4",
        fullText: text,
        selectedRange: selectedRange,
        analysisText: text,
        analysisRangeInFullText: NSRange(location: 0, length: (text as NSString).length),
        elementBounds: .zero,
        revision: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        languageHint: .mixed
    )
}

final class P4PatchParsingTests: XCTestCase {
    func testTextPatchValidatesAndAppliesOnlyExactOriginal() {
        let patch = TextPatch(
            rangeInFullText: NSRange(location: 6, length: 5),
            originalText: "draft",
            replacementText: "paper",
            reason: "more specific"
        )

        XCTAssertTrue(patch.validate(against: "First draft."))
        XCTAssertEqual(patch.applying(to: "First draft."), "First paper.")
        XCTAssertFalse(patch.validate(against: "First Draft."))
    }

    func testParseAgentResponseDropsInvalidPatchesAndKeepsOutline() throws {
        let snapshot = p4Snapshot("Alpha beta gamma.")
        let content = """
        {"message":"Use a tighter term.","patches":[
          {"start":6,"end":10,"original":"beta","replacement":"delta","reason":"term"},
          {"start":0,"end":5,"original":"Wrong","replacement":"Nope","reason":"bad original"},
          {"start":30,"end":31,"original":"x","replacement":"y","reason":"bad range"}
        ],"outline":["Intro","Method"]}
        """

        let response = try ReviewParsing.parseAgentResponse(content: content, snapshot: snapshot)

        XCTAssertEqual(response.message, "Use a tighter term.")
        XCTAssertEqual(response.patches.count, 1)
        XCTAssertEqual(response.patches.first?.originalText, "beta")
        XCTAssertEqual(response.patches.first?.replacementText, "delta")
        XCTAssertEqual(response.outline, ["Intro", "Method"])
    }

    func testParseGhostSuggestionRequiresCollapsedRangeAndLengthLimit() throws {
        let snapshot = p4Snapshot("This paper shows", selectedRange: NSRange(location: 16, length: 0))
        let ghost = try ReviewParsing.parseGhostSuggestion(
            content: "{\"completion\":\" that the method is reliable.\",\"explanation\":\"continues the claim\"}",
            snapshot: snapshot,
            caretRange: snapshot.selectedRange
        )

        XCTAssertEqual(ghost.rangeInFullText, NSRange(location: 16, length: 0))
        XCTAssertEqual(ghost.text, "that the method is reliable.")

        XCTAssertThrowsError(
            try ReviewParsing.parseGhostSuggestion(
                content: "{\"completion\":\"x\",\"explanation\":\"\"}",
                snapshot: snapshot,
                caretRange: NSRange(location: 1, length: 2)
            )
        )
    }

    func testGhostEligibilityRequiresCollapsedCaretAtDocumentEnd() {
        XCTAssertTrue(
            p4Snapshot("This paper shows", selectedRange: NSRange(location: 16, length: 0))
                .hasCollapsedCaretAtDocumentEnd
        )
        XCTAssertFalse(
            p4Snapshot("This paper shows more", selectedRange: NSRange(location: 16, length: 0))
                .hasCollapsedCaretAtDocumentEnd
        )
        XCTAssertFalse(
            p4Snapshot("This paper shows", selectedRange: NSRange(location: 12, length: 4))
                .hasCollapsedCaretAtDocumentEnd
        )
    }
}

final class SQLiteWritingMemoryStoreTests: XCTestCase {
    func testSQLiteStorePersistsDocumentConversationVersionsAndContext() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GrammarlessCoreTests-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("memory.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SQLiteWritingMemoryStore(databaseURL: url)
        let identity = DocumentIdentity(kind: .windowTitle, rawValue: "com.apple.TextEdit|Draft", displayName: "Draft")

        let record = try store.upsertDocument(identity: identity, summary: "Initial summary")
        XCTAssertEqual(record.id, identity.rawValue)
        XCTAssertEqual(try store.document(identity: identity)?.summary, "Initial summary")

        let patch = TextPatch(
            rangeInFullText: NSRange(location: 0, length: 5),
            originalText: "Draft",
            replacementText: "Paper",
            reason: "rename"
        )
        let version = DocumentVersion(
            documentID: record.id,
            action: "agentPatch",
            beforeText: "Draft text",
            afterText: "Paper text",
            patches: [patch]
        )
        try store.recordVersion(version)
        try store.appendConversationTurn(ConversationTurn(documentID: record.id, role: "user", content: "Please improve it."))
        try store.appendConversationTurn(ConversationTurn(documentID: record.id, role: "assistant", content: "Patch proposed."))

        let loadedVersion = try XCTUnwrap(store.lastVersion(documentID: record.id))
        XCTAssertEqual(loadedVersion.action, "agentPatch")
        XCTAssertEqual(loadedVersion.patches, [patch])

        let context = try store.memoryContext(documentID: record.id, limit: 5)
        XCTAssertEqual(context.documentSummary, "Initial summary")
        XCTAssertEqual(context.recentConversation.map(\.role), ["user", "assistant"])
        XCTAssertEqual(context.recentVersionSummaries.count, 1)
        XCTAssertTrue(context.recentVersionSummaries[0].contains("patches=1"))
    }

    func testSQLiteStorePersistsSuggestionBatchCacheBySegmentHash() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GrammarlessCoreTests-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("memory.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SQLiteWritingMemoryStore(databaseURL: url)
        let identity = DocumentIdentity(kind: .windowTitle, rawValue: "com.apple.TextEdit|Cached Draft", displayName: "Cached Draft")
        let record = try store.upsertDocument(identity: identity, summary: "Cached")
        let batch = SuggestionBatch(
            snapshotRevision: UUID(),
            paragraphIdentity: "0:6",
            suggestions: [
                Suggestion(
                    kind: .spelling,
                    source: .local,
                    rangeInFullText: NSRange(location: 0, length: 2),
                    originalText: "我门",
                    replacementText: "我们",
                    explanation: "cached red",
                    paragraphIdentity: "0:6",
                    proofIssueKind: .phoneticSimilarChar
                ),
            ]
        )

        try store.upsertCachedSuggestionBatch(
            documentID: record.id,
            segmentIdentity: "0:6",
            segmentHash: "hash-a",
            language: .zh,
            batch: batch
        )

        let loaded = try XCTUnwrap(store.cachedSuggestionBatch(
            documentID: record.id,
            segmentIdentity: "0:6",
            segmentHash: "hash-a"
        ))
        XCTAssertEqual(loaded.suggestions, batch.suggestions)
        XCTAssertNil(try store.cachedSuggestionBatch(
            documentID: record.id,
            segmentIdentity: "0:6",
            segmentHash: "hash-b"
        ))
    }

    func testSQLiteStorePersistsManagedChatSessions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GrammarlessCoreTests-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("memory.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SQLiteWritingMemoryStore(databaseURL: url)
        let identity = DocumentIdentity(kind: .windowTitle, rawValue: "com.apple.TextEdit|Session Draft", displayName: "Session Draft")
        let record = try store.upsertDocument(identity: identity, summary: "Session summary")

        let first = try store.createConversationSession(documentID: record.id, title: "初稿润色")
        let second = try store.createConversationSession(documentID: record.id, title: "结构讨论")
        try store.appendConversationTurn(
            ConversationTurn(documentID: record.id, role: "user", content: "帮我修改第一段"),
            toSession: first.id
        )
        try store.appendConversationTurn(
            ConversationTurn(documentID: record.id, role: "assistant", content: "我会先读取上下文。"),
            toSession: first.id
        )
        try store.appendConversationTurn(
            ConversationTurn(documentID: record.id, role: "user", content: "帮我列提纲"),
            toSession: second.id
        )

        let listed = try store.listConversationSessions(documentID: record.id)
        XCTAssertEqual(Set(listed.map(\.id)), Set([first.id, second.id]))
        XCTAssertTrue(try store.conversationTurns(inSession: first.id, limit: 10).map(\.content).contains("帮我修改第一段"))
        XCTAssertEqual(try store.memoryContext(documentID: record.id, sessionID: second.id, limit: 10).recentConversation.map(\.content), ["帮我列提纲"])

        try store.renameConversationSession(id: first.id, title: "终稿修改方案")
        XCTAssertEqual(try store.listConversationSessions(documentID: record.id).first(where: { $0.id == first.id })?.title, "终稿修改方案")

        try store.deleteConversationSession(id: second.id)
        let afterDelete = try store.listConversationSessions(documentID: record.id)
        XCTAssertEqual(afterDelete.map(\.id), [first.id])
        XCTAssertEqual(try store.conversationTurns(inSession: second.id, limit: 10), [])
    }

}

final class ImpactDocumentSegmenterTests: XCTestCase {
    func testShortDocumentKeepsParagraphSegmentsWithoutGrammarAwareMerge() async throws {
        let text = "One.\n\nTwo."
        let result = try await ImpactDocumentSegmenter().segment(text: text)

        XCTAssertFalse(result.usedGrammarAwareSegmentation)
        XCTAssertEqual(result.segments.map(\.id), ["s0001", "s0002"])
        XCTAssertEqual(result.segments.map(\.paragraphIDs), [["p0001"], ["p0002"]])
        let nsText = text as NSString
        for segment in result.segments {
            XCTAssertEqual(nsText.substring(with: segment.rangeInFullText), segment.text)
        }
    }

    func testLongDocumentMergesSub100ParagraphWithNextParagraph() async throws {
        let short = "Short setup."
        let firstBody = String(repeating: "a", count: 520)
        let secondBody = String(repeating: "b", count: 520)
        let text = short + "\n\n" + firstBody + "\n\n" + secondBody

        let result = try await ImpactDocumentSegmenter().segment(text: text)

        XCTAssertTrue(result.usedGrammarAwareSegmentation)
        XCTAssertGreaterThanOrEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments.first?.paragraphIDs, ["p0001", "p0002"])
        XCTAssertEqual(result.segments.first?.source, .paragraphMerge)
    }

    func testLongSingleParagraphUsesLLMBoundaryCutsWhenValid() async throws {
        let text = String(repeating: "a", count: 699) + " " +
            String(repeating: "b", count: 699) + " " +
            String(repeating: "c", count: 100)
        let result = try await ImpactDocumentSegmenter().segment(text: text) { windowText, _ in
            XCTAssertEqual((windowText as NSString).length, 1_500)
            return [700, 1_400]
        }

        XCTAssertTrue(result.didUseLLMBoundaries)
        XCTAssertFalse(result.didFallbackHardSplit)
        XCTAssertEqual(result.segments.map { ($0.text as NSString).length }, [700, 700, 100])
        XCTAssertTrue(result.segments.allSatisfy { ($0.text as NSString).length <= 1_000 })
        XCTAssertTrue(result.segments.allSatisfy { $0.source == .llmBoundary })
    }

    func testInvalidLLMBoundaryFallsBackAndPreservesExactRanges() async throws {
        let text = String(repeating: "x", count: 1_250)
        let result = try await ImpactDocumentSegmenter().segment(text: text) { _, _ in
            [1_100]
        }

        XCTAssertFalse(result.didUseLLMBoundaries)
        XCTAssertTrue(result.didFallbackHardSplit)
        XCTAssertTrue(result.segments.allSatisfy { ($0.text as NSString).length <= 1_000 })
        let nsText = text as NSString
        for segment in result.segments {
            XCTAssertEqual(nsText.substring(with: segment.rangeInFullText), segment.text)
        }
    }

    func testUnsafeLLMBoundaryFallsBackToWordBoundary() async throws {
        let prefix = String(repeating: "word ", count: 199)
        let text = prefix +
            "that redundant prompts affect performance, while structured organized concise prompts perform better. " +
            String(repeating: "tail ", count: 220)
        let unsafeCutInsideThat = (prefix as NSString).length + 1

        let result = try await ImpactDocumentSegmenter().segment(text: text) { _, _ in
            [unsafeCutInsideThat]
        }

        XCTAssertFalse(result.didUseLLMBoundaries)
        XCTAssertTrue(result.didFallbackHardSplit)
        XCTAssertTrue(result.segments.allSatisfy { ($0.text as NSString).length <= 1_000 })
        XCTAssertFalse(result.segments.contains { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("hat ") })
        XCTAssertEqual(result.segments.map(\.text).joined(), text)
    }
}

private final class FakeImpactLLM: LLMReviewing {
    private let lock = NSLock()
    private var recordedImpactPrompts: [String] = []
    var impactPrompts: [String] {
        lock.withLock {
            recordedImpactPrompts
        }
    }
    var failingPromptMarkers: [String] = []

    func review(snapshot: TextSnapshot, configuration: AppConfiguration) async throws -> SuggestionBatch { throw LLMError.emptyContent }
    func performAction(request: AIActionRequest, configuration: AppConfiguration) async throws -> ReviewActionResult { throw LLMError.emptyContent }
    func performAgentAction(request: AgentActionRequest, configuration: AppConfiguration) async throws -> AgentResponse { throw LLMError.emptyContent }
    func performAgentToolTurn(request: AgentToolTurnRequest, configuration: AppConfiguration) async throws -> AgentToolTurnResponse { throw LLMError.emptyContent }
    func requestGhostSuggestion(request: GhostSuggestionRequest, configuration: AppConfiguration) async throws -> GhostSuggestion { throw LLMError.emptyContent }

    func performImpactStep(
        systemPrompt: String,
        userPrompt: String,
        configuration: AppConfiguration,
        timeout: Double
    ) async throws -> String {
        lock.withLock {
            recordedImpactPrompts.append(userPrompt)
        }
        if failingPromptMarkers.contains(where: { userPrompt.contains($0) }) {
            throw LLMError.emptyContent
        }
        if userPrompt.contains("classify the document genre") {
            return """
            {"primaryGenreID":"business_proposal","secondaryGenreIDs":[],"genreConfidence":0.91,"intent":"persuade approval","audience":"manager","formality":"professional","whyThisGenre":"problem and proposal language","formatSignals":["proposal"],"missingSignals":[]}
            """
        }
        if userPrompt.contains("analyze local structure") {
            let id = Self.segmentID(from: userPrompt)
            return """
            {"segmentID":"\(id)","paragraphIDs":[],"localRole":"claim","expectedRoleForGenre":"problem|solution|evidence|cta","servesDocumentPurpose":true,"structureIssue":"","formatIssue":"","recommendedMove":""}
            """
        }
        if userPrompt.contains("analyze single-segment logic") {
            let id = Self.segmentID(from: userPrompt)
            return """
            {"segmentID":"\(id)","mainClaim":"approve the plan","localEvidence":["cost reduction"],"logicGap":"needs stronger quantified support","overclaim":"","internalContradiction":"","evidenceStrength":"medium","recommendedFix":"add quantified evidence"}
            """
        }
        if userPrompt.contains("simulate reader reaction") {
            let id = Self.segmentID(from: userPrompt)
            return """
            {"segmentID":"\(id)","likelyTakeaway":"plan may help","likelyConfusion":"timeline unclear","likelyObjection":"why now","trustLevel":"medium","nextActionClarity":"unclear","emotionalReaction":"interested but cautious","recommendedFix":"make next step explicit"}
            """
        }
        if userPrompt.contains("analyze language clarity") {
            let id = Self.segmentID(from: userPrompt)
            return """
            {"segmentID":"\(id)","clarityIssues":[],"readabilityRisk":"low","styleFitRisk":"low","recommendedFix":""}
            """
        }
        if userPrompt.contains("analyze cross-paragraph logic") {
            return """
            {"globalClaims":[{"claimID":"c001","claim":"approve the plan","introducedIn":"s0001","supportedBy":["s0002"],"weakenedBy":[],"evidenceStrength":"medium","gap":"ROI details missing","readerQuestion":"What business impact justifies approval?"}],"crossParagraphGaps":["ROI details missing"],"contradictions":[],"redundancies":[],"missingBridges":[],"globalLogicSummary":"Core proposal is understandable but evidence is thin."}
            """
        }
        if userPrompt.contains("synthesize a complete Grammarless Increase Impact report") {
            return """
            {"overallScore":76,"oneSentenceDiagnosis":"方案方向清楚，但证据不足会降低批准概率。","executiveSummary":"需要补强 ROI 和下一步。","scores":[{"dimension":"purposeClarity","score":80,"reason":"请求基本清楚","topFix":"把批准请求提前","confidence":0.9},{"dimension":"structureLogic","score":74,"reason":"结构可读","topFix":"补桥接","confidence":0.8},{"dimension":"evidenceSufficiency","score":55,"reason":"证据偏弱","topFix":"补 ROI 数据","confidence":0.9},{"dimension":"readerReaction","score":68,"reason":"读者会有疑问","topFix":"回答 why now","confidence":0.8},{"dimension":"genreFit","score":82,"reason":"符合提案语气","topFix":"强化 CTA","confidence":0.8},{"dimension":"languageClarity","score":86,"reason":"语言清楚","topFix":"减少弱化词","confidence":0.8}],"topFindings":[{"dimension":"evidenceSufficiency","severity":"high","segmentIDs":["s0002"],"paragraphIDs":["p0002"],"title":"证据不足","explanation":"核心主张缺少业务影响数据。","evidence":"global logic gap","recommendation":"补充 ROI 或案例。","confidence":0.9}],"quickWins":["把批准请求提前"],"deeperRevisions":["补强 ROI 证据"],"readerSummary":"读者感兴趣但会追问价值。","structureSummary":"结构基本完整。","logicSummary":"跨段落逻辑存在证据缺口。","doNotChange":[]}
            """
        }
        throw LLMError.emptyContent
    }

    private static func segmentID(from prompt: String) -> String {
        guard let range = prompt.range(of: #"segmentID:\s*(s\d+)"#, options: .regularExpression) else { return "s0001" }
        let fragment = String(prompt[range])
        return fragment.components(separatedBy: CharacterSet.whitespacesAndNewlines).last ?? "s0001"
    }
}

private actor ImpactProgressBox {
    private(set) var events: [ImpactAnalysisProgress] = []

    func append(_ event: ImpactAnalysisProgress) {
        events.append(event)
    }
}

final class ImpactAnalysisOrchestratorTests: XCTestCase {
    func testGenreRegistryCoversBroadRubricCatalog() {
        let rubrics = ImpactGenreRegistry.allRubrics()
        XCTAssertGreaterThanOrEqual(rubrics.count, 90)
        XCTAssertEqual(Set(rubrics.map(\.id)).count, rubrics.count)
        XCTAssertTrue(rubrics.contains { $0.id == "business_proposal" })
        XCTAssertTrue(rubrics.contains { $0.id == "research_article" })
        XCTAssertTrue(rubrics.contains { $0.id == "ux_microcopy" })
        XCTAssertTrue(rubrics.contains { $0.id == "legal_memo" })
        for rubric in rubrics {
            XCTAssertFalse(rubric.languageRequirements.isEmpty, rubric.id)
            XCTAssertFalse(rubric.formatRequirements.isEmpty, rubric.id)
            for dimension in ImpactDimension.allCases {
                XCTAssertFalse((rubric.dimensionPrompts[dimension] ?? "").isEmpty, "\(rubric.id) \(dimension.rawValue)")
            }
        }
    }

    func testAnalyzeImpactRunsFourPathsAndReducer() async throws {
        let fake = FakeImpactLLM()
        let engine = ReviewEngine(llmClient: fake)
        let snapshot = makeSnapshot("We should approve the plan.\n\nIt can reduce support cost.")

        let report = try await engine.analyzeImpact(
            snapshot: snapshot,
            configuration: AppConfiguration(),
            memoryContext: WritingMemoryContext(documentSummary: "proposal")
        )

        XCTAssertEqual(report.primaryGenre.id, "business_proposal")
        XCTAssertEqual(report.overallScore, 76)
        XCTAssertEqual(report.scores.count, 6)
        XCTAssertEqual(report.globalLogicResult.globalClaims.first?.claimID, "c001")
        XCTAssertEqual(report.structureResults.count, 2)
        XCTAssertEqual(report.localLogicResults.count, 2)
        XCTAssertEqual(report.readerReactionResults.count, 2)
        XCTAssertEqual(report.languageClarityResults.count, 2)
        XCTAssertTrue(fake.impactPrompts.contains { $0.contains("analyze cross-paragraph logic") })
        XCTAssertTrue(fake.impactPrompts.contains { $0.contains("synthesize a complete Grammarless Increase Impact report") })
    }

    func testAnalyzeImpactPromptsCarrySelectedEnglishLanguage() async throws {
        let fake = FakeImpactLLM()
        let engine = ReviewEngine(llmClient: fake)
        let snapshot = makeSnapshot("We should approve the plan.\n\nIt can reduce support cost.")
        let progressBox = ImpactProgressBox()

        _ = try await engine.analyzeImpact(
            snapshot: snapshot,
            configuration: AppConfiguration(uiLanguage: .en),
            memoryContext: WritingMemoryContext(documentSummary: "proposal"),
            progressHandler: { progress in
                await progressBox.append(progress)
            }
        )

        XCTAssertFalse(fake.impactPrompts.isEmpty)
        XCTAssertTrue(fake.impactPrompts.allSatisfy { $0.contains("Selected response language: English.") })
        XCTAssertTrue(fake.impactPrompts.allSatisfy { $0.contains("Do not switch languages.") })
        let progressMessages = await progressBox.events.map(\.message)
        XCTAssertTrue(progressMessages.contains { $0.contains("Segmenting the document") })
        XCTAssertFalse(progressMessages.contains { $0.contains("正在") || $0.contains("完成") })
    }

    func testAnalyzeImpactRecordsPartialFailuresAndProgressWithoutFakeReaderResults() async throws {
        let fake = FakeImpactLLM()
        fake.failingPromptMarkers = ["simulate reader reaction"]
        let engine = ReviewEngine(llmClient: fake)
        let snapshot = makeSnapshot("We should approve the plan.\n\nIt can reduce support cost.")
        let progressBox = ImpactProgressBox()

        let report = try await engine.analyzeImpact(
            snapshot: snapshot,
            configuration: AppConfiguration(),
            memoryContext: WritingMemoryContext(documentSummary: "proposal"),
            progressHandler: { progress in
                await progressBox.append(progress)
            }
        )

        XCTAssertEqual(report.readerReactionResults.count, 0)
        XCTAssertEqual(report.analysisFailures.count, 2)
        XCTAssertTrue(report.analysisFailures.allSatisfy { $0.path == .readerReaction })
        XCTAssertTrue(fake.impactPrompts.contains { $0.contains("analysisFailures") })
        let events = await progressBox.events
        XCTAssertTrue(events.contains { $0.path == .segmentation })
        XCTAssertTrue(events.contains { $0.path == .readerReaction && $0.completed == 2 })
        XCTAssertTrue(events.contains { $0.path == .reducer && $0.completed == 1 })
    }

    func testImpactPathParsersToleratePartialJSONAndBuildLanguagePatchCandidates() async throws {
        let snapshot = makeSnapshot("This draft has a weak phrase that should be clearer.")
        let segment = ImpactSegment(
            id: "s0001",
            paragraphIDs: ["p0001"],
            rangeInFullText: NSRange(location: 0, length: (snapshot.fullText as NSString).length),
            text: snapshot.fullText,
            source: .paragraph
        )

        let structure = try ImpactParsing.parseStructure(
            #"{"segmentID":"s0001","servesDocumentPurpose":"true","recommendedMove":"Keep it near the claim."}"#,
            fallbackSegment: segment
        )
        XCTAssertEqual(structure.paragraphIDs, ["p0001"])
        XCTAssertTrue(structure.servesDocumentPurpose)
        XCTAssertEqual(structure.structureIssue, "")

        let clarity = try ImpactParsing.parseClarity(
            #"{"segmentID":"s0001","clarityIssues":[{"type":"vague","original":"weak phrase","replacement":"clear phrase","recommendation":"Use a clearer noun phrase."},{"type":"typo","original":"hat should","replacement":"that should","recommendation":"Do not patch partial tokens."}]}"#,
            fallbackSegment: segment
        )
        XCTAssertEqual(clarity.clarityIssues.first?.severity, .medium)
        XCTAssertEqual(clarity.clarityIssues.first?.replacement, "clear phrase")

        let paragraph = ImpactParagraph(
            id: "p0001",
            rangeInFullText: segment.rangeInFullText,
            text: snapshot.fullText,
            kind: .body
        )
        let segmentation = ImpactSegmentationResult(
            documentLengthUTF16: (snapshot.fullText as NSString).length,
            paragraphs: [paragraph],
            segments: [segment],
            usedGrammarAwareSegmentation: false,
            didUseLLMBoundaries: false,
            didFallbackHardSplit: false
        )
        let classification = ImpactGenreClassification(
            primaryGenreID: "business_proposal",
            genreConfidence: 0.9,
            intent: "persuade",
            audience: "manager",
            formality: "professional",
            whyThisGenre: "proposal"
        )
        let report = try ImpactParsing.parseReducerReport(
            #"{"overallScore":70,"oneSentenceDiagnosis":"Clear enough.","executiveSummary":"Clear enough.","scores":[{"dimension":"purposeClarity","score":70,"reason":"ok","topFix":"clarify","confidence":0.8},{"dimension":"structureLogic","score":70,"reason":"ok","topFix":"bridge","confidence":0.8},{"dimension":"evidenceSufficiency","score":70,"reason":"ok","topFix":"evidence","confidence":0.8},{"dimension":"readerReaction","score":70,"reason":"ok","topFix":"answer objection","confidence":0.8},{"dimension":"genreFit","score":70,"reason":"ok","topFix":"fit","confidence":0.8},{"dimension":"languageClarity","score":70,"reason":"ok","topFix":"wording","confidence":0.8}],"topFindings":[],"quickWins":[],"deeperRevisions":[],"readerSummary":"","structureSummary":"","logicSummary":"","doNotChange":[]}"#,
            snapshot: snapshot,
            segmentation: segmentation,
            classification: classification,
            rubric: ImpactGenreRegistry.rubric(id: "business_proposal")!,
            structure: [structure],
            globalLogic: ImpactGlobalLogicResult(),
            localLogic: [],
            readers: [],
            clarity: [clarity],
            failures: []
        )

        XCTAssertEqual(report.patchCandidates.count, 1)
        XCTAssertEqual(report.patchCandidates.first?.originalText, "weak phrase")
        XCTAssertEqual(report.patchCandidates.first?.replacementText, "clear phrase")
        XCTAssertFalse(report.patchCandidates.contains { $0.originalText == "hat should" })
        XCTAssertTrue(report.patchCandidates.first?.validate(against: snapshot.fullText) ?? false)
    }

    func testImpactReducerParserToleratesPartialAndLooselyTypedJSON() async throws {
        let snapshot = makeSnapshot("Approve the plan because it reduces support cost.")
        let segment = ImpactSegment(
            id: "s0001",
            paragraphIDs: ["p0001"],
            rangeInFullText: NSRange(location: 0, length: (snapshot.fullText as NSString).length),
            text: snapshot.fullText,
            source: .paragraph
        )
        let paragraph = ImpactParagraph(
            id: "p0001",
            rangeInFullText: segment.rangeInFullText,
            text: snapshot.fullText,
            kind: .body
        )
        let segmentation = ImpactSegmentationResult(
            documentLengthUTF16: (snapshot.fullText as NSString).length,
            paragraphs: [paragraph],
            segments: [segment],
            usedGrammarAwareSegmentation: false,
            didUseLLMBoundaries: false,
            didFallbackHardSplit: false
        )
        let classification = ImpactGenreClassification(
            primaryGenreID: "business_proposal",
            genreConfidence: 0.9,
            intent: "persuade",
            audience: "manager",
            formality: "professional",
            whyThisGenre: "proposal"
        )

        let report = try ImpactParsing.parseReducerReport(
            """
            {
              "overallScore":"81 / 100",
              "oneSentenceDiagnosis":123,
              "scores":[
                {"dimension":"purpose_clarity","score":"82","reason":true,"confidence":"90%"},
                {"dimension":"Evidence Sufficiency","score":"55","topFix":"Add quantified ROI","confidence":"0.7"},
                {"dimension":"unknown_dimension","score":99}
              ],
              "topFindings":[
                {"dimension":"evidence_sufficiency","severity":"HIGH","segmentIDs":"s0001","paragraphIDs":["p0001"],"title":"Thin evidence","confidence":"70%"}
              ],
              "quickWins":"Move the ask earlier"
            }
            """,
            snapshot: snapshot,
            segmentation: segmentation,
            classification: classification,
            rubric: ImpactGenreRegistry.rubric(id: "business_proposal")!,
            structure: [],
            globalLogic: ImpactGlobalLogicResult(),
            localLogic: [],
            readers: [],
            clarity: [],
            failures: []
        )

        XCTAssertEqual(report.overallScore, 81)
        XCTAssertEqual(report.oneSentenceDiagnosis, "123")
        XCTAssertEqual(report.scores.count, 6)
        XCTAssertEqual(report.scores.first { $0.dimension == .purposeClarity }?.score, 82)
        XCTAssertEqual(report.scores.first { $0.dimension == .purposeClarity }?.confidence ?? -1, 0.9, accuracy: 0.001)
        XCTAssertEqual(report.scores.first { $0.dimension == .evidenceSufficiency }?.topFix, "Add quantified ROI")
        XCTAssertEqual(report.scores.first { $0.dimension == .languageClarity }?.confidence ?? -1, 0)
        XCTAssertEqual(report.topFindings.first?.severity, .high)
        XCTAssertEqual(report.topFindings.first?.segmentIDs, ["s0001"])
        XCTAssertEqual(report.quickWins, ["Move the ask earlier"])
        XCTAssertTrue(report.analysisFailures.contains { $0.path == .reducer && $0.message.contains("unknown score dimension") })
        XCTAssertTrue(report.analysisFailures.contains { $0.path == .reducer && $0.message.contains("languageClarity") })
    }
}
