import Foundation

public protocol LLMReviewing {
    func review(snapshot: TextSnapshot, configuration: AppConfiguration) async throws -> SuggestionBatch
    func performAction(
        request: AIActionRequest,
        configuration: AppConfiguration
    ) async throws -> ReviewActionResult
    func performAgentAction(
        request: AgentActionRequest,
        configuration: AppConfiguration
    ) async throws -> AgentResponse
    func performAgentToolTurn(
        request: AgentToolTurnRequest,
        configuration: AppConfiguration
    ) async throws -> AgentToolTurnResponse
    func requestGhostSuggestion(
        request: GhostSuggestionRequest,
        configuration: AppConfiguration
    ) async throws -> GhostSuggestion
    func performImpactStep(
        systemPrompt: String,
        userPrompt: String,
        configuration: AppConfiguration,
        timeout: Double
    ) async throws -> String
    func streamAgentFinalMessage(
        request: AgentFinalMessageRequest,
        configuration: AppConfiguration,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> String
}

public extension LLMReviewing {
    func streamAgentFinalMessage(
        request _: AgentFinalMessageRequest,
        configuration _: AppConfiguration,
        onDelta _: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        throw LLMError.emptyContent
    }
}

public enum LLMError: Error, LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case httpStatus(statusCode: Int, bodyPreview: String)
    case emptyContent
    case malformedJSON

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Invalid base URL."
        case .invalidResponse:
            return "Invalid LLM response."
        case .httpStatus(let statusCode, let bodyPreview):
            if bodyPreview.isEmpty {
                return "LLM HTTP \(statusCode)."
            }
            return "LLM HTTP \(statusCode): \(bodyPreview)"
        case .emptyContent:
            return "LLM returned empty content."
        case .malformedJSON:
            return "LLM returned malformed JSON."
        }
    }
}

private struct ChatCompletionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct ResponseFormat: Encodable {
        let type: String
    }

    let model: String
    let messages: [Message]
    let response_format: ResponseFormat?
    let temperature: Double
    let reasoning_effort: String?
    let stream: Bool?
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
            let reasoning_content: String?
        }
        let message: Message
    }
    let choices: [Choice]
}

private struct StreamingChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
            let reasoning_content: String?
        }

        let delta: Delta?
        let message: ChatCompletionResponse.Choice.Message?
    }

    let choices: [Choice]
}

public final class LLMClient: LLMReviewing {
    private let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    public func review(snapshot: TextSnapshot, configuration: AppConfiguration) async throws -> SuggestionBatch {
        let systemPrompt = reviewSystemPrompt(for: snapshot.languageHint)

        let userPrompt = """
        languageHint: \(snapshot.languageHint.rawValue)
        analysisText:
        \(snapshot.analysisText)
        """

        let content = try await performChat(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            configuration: configuration,
            timeout: configuration.reviewTimeoutSeconds
        )
        return try ReviewParsing.parseSuggestionBatch(content: content, snapshot: snapshot)
    }

    private func reviewSystemPrompt(for language: DetectedLanguage) -> String {
        switch language {
        case .en:
            return """
            You are Grammarless. Return strict JSON only:
            {"language":"en","suggestions":[{"kind":"grammar|rewrite","start":0,"end":0,"original":"","replacement":"","explanation":""}]}
            Rules:
            - Review only analysisText.
            - Do not return spelling suggestions for English.
            - Return up to 3 high-confidence suggestions.
            - start/end are UTF-16 offsets in analysisText; end is exclusive.
            - Copy original exactly from analysisText[start..<end].
            - Keep explanations short.
            - Prefer grammar for clear errors; use rewrite for wording/style improvements.
            - For subject-verb errors like "He do not knows", suggest "does not know".
            - Never use markdown.
            """
        case .zh:
            return """
            You are Grammarless. Return strict JSON only:
            {"language":"zh","suggestions":[{"kind":"spelling|grammar|rewrite","start":0,"end":0,"original":"","replacement":"","explanation":""}]}
            Rules:
            - Review only analysisText.
            - start/end are UTF-16 offsets in analysisText; end is exclusive.
            - Copy original exactly from analysisText[start..<end].
            - Keep explanations short.
            - spelling=错字, grammar=病句/语序/搭配, rewrite=更清晰表达.
            - Never use markdown.
            """
        case .mixed:
            return """
            You are Grammarless. Return strict JSON only:
            {"language":"mixed","suggestions":[{"kind":"spelling|grammar|rewrite","start":0,"end":0,"original":"","replacement":"","explanation":""}]}
            Rules:
            - Review only analysisText.
            - start/end are UTF-16 offsets in analysisText; end is exclusive.
            - Copy original exactly from analysisText[start..<end].
            - Keep explanations short.
            - spelling=typo/wrong character, grammar=grammar/syntax/collocation, rewrite=clearer wording.
            - Never use markdown.
            """
        }
    }

    public func performAction(
        request: AIActionRequest,
        configuration: AppConfiguration
    ) async throws -> ReviewActionResult {
        let systemPrompt = """
        You are Grammarless. Return strict JSON only:
        {"replacement":"","explanation":""}
        Rules:
        - Always write replacement and explanation in the selected response language. Do not switch languages.
        - Edit only selectedText, not surroundingContext.
        - action=formal: make the wording more polished, professional, and formal while preserving meaning.
        - action=clarity: make the wording clearer and easier to understand while preserving meaning.
        - action=shorten: make the text more concise without losing the main point.
        - action=natural: make the wording sound natural and fluent while preserving meaning.
        - Keep explanation short.
        - Never use markdown.
        """
        let userPrompt = """
        action: \(request.action.rawValue)
        languageHint: \(request.languageHint.rawValue)
        selectedText:
        \(request.selectedText)

        surroundingContext:
        \(request.surroundingContext)
        """
        let content = try await performChat(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            configuration: configuration,
            timeout: configuration.actionTimeoutSeconds
        )
        return try ReviewParsing.parseActionResult(content: content)
    }

    public func performAgentAction(
        request: AgentActionRequest,
        configuration: AppConfiguration
    ) async throws -> AgentResponse {
        let content = try await performChat(
            systemPrompt: agentSystemPrompt(),
            userPrompt: agentUserPrompt(for: request),
            configuration: configuration,
            timeout: configuration.actionTimeoutSeconds
        )
        return try ReviewParsing.parseAgentResponse(content: content, snapshot: request.snapshot)
    }

    public func performAgentToolTurn(
        request: AgentToolTurnRequest,
        configuration: AppConfiguration
    ) async throws -> AgentToolTurnResponse {
        // Agent chat is intentionally model-driven and may need to inspect tool
        // transcripts before deciding on the next call. Keep proofing/ghost
        // suggestions responsive, but give each agent tool-turn a production
        // floor so normal gateway latency does not surface as a false UI failure.
        let agentTurnTimeout = max(configuration.actionTimeoutSeconds, 180)
        let content = try await performChat(
            systemPrompt: agentToolSystemPrompt(),
            userPrompt: agentToolUserPrompt(for: request),
            configuration: configuration,
            timeout: agentTurnTimeout
        )
        return try ReviewParsing.parseAgentToolTurnResponse(content: content, snapshot: request.snapshot)
    }

    public func requestGhostSuggestion(
        request: GhostSuggestionRequest,
        configuration: AppConfiguration
    ) async throws -> GhostSuggestion {
        let content = try await performChat(
            systemPrompt: ghostSystemPrompt(),
            userPrompt: ghostUserPrompt(for: request),
            configuration: configuration,
            timeout: configuration.actionTimeoutSeconds
        )
        return try ReviewParsing.parseGhostSuggestion(
            content: content,
            snapshot: request.snapshot,
            caretRange: request.caretRange
        )
    }

    public func performImpactStep(
        systemPrompt: String,
        userPrompt: String,
        configuration: AppConfiguration,
        timeout: Double
    ) async throws -> String {
        try await performChat(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            configuration: configuration,
            timeout: timeout
        )
    }

    public func streamAgentFinalMessage(
        request: AgentFinalMessageRequest,
        configuration: AppConfiguration,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        let content = try await performStreamingChat(
            systemPrompt: finalMessageSystemPrompt(),
            userPrompt: finalMessageUserPrompt(for: request),
            configuration: configuration,
            timeout: max(configuration.actionTimeoutSeconds, 180),
            throttleInterval: 0.05,
            onDelta: onDelta
        )
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LLMError.emptyContent
        }
        return trimmed
    }

    private func agentSystemPrompt() -> String {
        """
        You are Grammarless Longform Agent. Return strict JSON only:
        {"message":"","patches":[{"start":0,"end":0,"original":"","replacement":"","reason":""}],"outline":[]}
        Rules:
        - Use only the provided documentText, selectedText, instruction, and memoryContext.
        - Never invent fallback, template, placeholder, or canned output.
        - If you cannot safely edit, return a concise message explaining why and an empty patches array.
        - start/end are UTF-16 offsets in full documentText; end is exclusive.
        - Copy original exactly from documentText[start..<end]. For insertion, use start=end and original="".
        - Keep patches minimal and local. Do not rewrite the whole document unless explicitly asked.
        - For rewriteSelection/tone, patch only selectedRange when selectedRange.length > 0.
        - For continueWriting, insert at selectedRange.location when selectedRange.length == 0, otherwise replace selectedRange.
        - For outline/summarize/ask, prefer message/outline and do not create patches unless the user explicitly asks to modify the document.
        - Write assistant messages, outline items, and patch reasons in the selected response language.
        - For patch replacement text, use the selected response language unless the user explicitly asks to preserve, quote, or translate differently.
        - Never use markdown fences.
        """
    }

    private func agentToolSystemPrompt() -> String {
        """
        You are Grammarless Agent Chat. Return strict JSON only.
        Schema:
        {"message":"","tool_calls":[{"id":"","name":"read_selected_text|read_visible_text|read_document_context|draft_edit_patch|check_consistency|preview_patch_diff|stage_patch_for_user_confirmation|rollback_last_version|redo_last_agent_run","arguments":{}}],"outline":[]}

        Rules:
        - The user describes a goal in natural language. You decide which tools to call; the user must not choose tools.
        - For edits, first call a read tool, then draft_edit_patch, then preview_patch_diff or stage_patch_for_user_confirmation.
        - draft_edit_patch arguments require UTF-16 start, end, replacement, and reason. Include original when you know it.
        - If the user asks to edit text, do not answer with prose only. A valid draft_edit_patch must be staged before the final message.
        - If a tool-drafted patch failed, correct the start/end/original and try draft_edit_patch again; do not just describe the replacement.
        - start/end are offsets in the full documentText supplied in the user prompt; end is exclusive.
        - Keep patches minimal. Do not rewrite the whole document unless explicitly asked.
        - Write assistant messages, outline items, tool-facing summaries, and patch reasons in the selected response language.
        - For patch replacement text, use the selected response language unless the user explicitly asks to preserve, quote, or translate differently.
        - Never invent document content, fallback text, templates, or canned output.
        - If you need more information, call read_document_context or answer with a concise message and no tool_calls.
        - When tool results are sufficient, return a final message with tool_calls=[].
        - Never use markdown fences.
        """
    }

    private func agentUserPrompt(for request: AgentActionRequest) -> String {
        let selectedRange = request.selectedRange ?? request.snapshot.selectedRange
        let selectedText = selectedSubstring(from: request.snapshot.fullText, range: selectedRange)
        return """
        action: \(request.action.rawValue)
        instruction:
        \(request.instruction)

        languageHint: \(request.snapshot.languageHint.rawValue)
        documentLengthUTF16: \((request.snapshot.fullText as NSString).length)
        selectedRangeUTF16: \(selectedRange.location):\(selectedRange.length)
        selectedText:
        \(selectedText)

        memoryContext:
        documentSummary: \(request.memoryContext.documentSummary)
        recentVersions:
        \(request.memoryContext.recentVersionSummaries.joined(separator: "\n"))
        recentConversation:
        \(request.memoryContext.recentConversation.map { "\($0.role): \($0.content)" }.joined(separator: "\n"))
        preferences:
        \(request.memoryContext.preferences.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))

        documentText:
        \(request.snapshot.fullText)
        """
    }

    private func agentToolUserPrompt(for request: AgentToolTurnRequest) -> String {
        let selectedRange = request.selectedRange ?? request.snapshot.selectedRange
        let selectedText = selectedSubstring(from: request.snapshot.fullText, range: selectedRange)
        let stagedPatchSummary = request.stagedPatches.map {
            "patchID=\($0.id.uuidString) range=\($0.rangeInFullText.location):\($0.rangeInFullText.length) original=\($0.originalText) replacement=\($0.replacementText) reason=\($0.reason)"
        }.joined(separator: "\n")
        let transcript = request.transcript.map { "\($0.role): \($0.content)" }.joined(separator: "\n\n")
        return """
        turnIndex: \(request.turnIndex)
        userInstruction:
        \(request.instruction)

        languageHint: \(request.snapshot.languageHint.rawValue)
        documentLengthUTF16: \((request.snapshot.fullText as NSString).length)
        selectedRangeUTF16: \(selectedRange.location):\(selectedRange.length)
        selectedText:
        \(selectedText)

        memoryContext:
        documentSummary: \(request.memoryContext.documentSummary)
        recentVersions:
        \(request.memoryContext.recentVersionSummaries.joined(separator: "\n"))
        recentConversation:
        \(request.memoryContext.recentConversation.map { "\($0.role): \($0.content)" }.joined(separator: "\n"))
        preferences:
        \(request.memoryContext.preferences.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))

        stagedPatches:
        \(stagedPatchSummary)

        previousToolTranscript:
        \(transcript)

        documentUTF16LineRanges:
        \(utf16LineRanges(for: request.snapshot.fullText))

        documentText:
        \(request.snapshot.fullText)
        """
    }

    private func ghostSystemPrompt() -> String {
        """
        You are Grammarless Ghost Text. Return strict JSON only:
        {"completion":"","explanation":""}
        Rules:
        - You are an inline autocomplete engine. Continue immediately after caretTextBefore using documentText and memoryContext.
        - Return only the gray inline completion, not the already typed text.
        - Maximum 80 UTF-16 code units; prefer one short phrase or sentence.
        - The completion text must be written in the selected response language while matching the nearby tone and punctuation style.
        - Ignore chat/session history, Impact reports, and prior assistant replies; never complete with conversation text.
        - For non-empty caretTextBefore at document end, completion MUST be non-empty. Do not answer that no safe completion is available.
        - completion="" is allowed only when documentText and caretTextBefore are both empty.
        - Bad output for non-empty document: {"completion":"","explanation":"no safe completion"}.
        - Good output for non-empty document: {"completion":"继续写一句自然的下一句。","explanation":"延续文末意思"}.
        - Never use markdown.
        """
    }

    private func finalMessageSystemPrompt() -> String {
        """
        You are Grammarless Assistant Reply Renderer.
        Rewrite the structured agent result into a user-facing Markdown reply.

        Allowed Markdown:
        - unordered or ordered lists
        - bold
        - inline code
        - fenced code blocks only when allowCodeBlocks=true and the user explicitly asked for code

        Rules:
        - Be concise, helpful, and action-oriented.
        - Prefer short paragraphs plus lists when they improve scanability.
        - If patches were prepared, briefly explain what was prepared and what the user can do next.
        - If an outline is useful, render it as a short list.
        - Never invent edits, tool results, or document content.
        - Do not mention hidden JSON, UTF-16 offsets, internal memory, or raw tool protocol fields unless the user explicitly asked.
        - When allowCodeBlocks=false, never output triple backticks.
        - Do not wrap the whole answer in a code block.
        """
    }

    private func ghostUserPrompt(for request: GhostSuggestionRequest) -> String {
        let nsText = request.snapshot.fullText as NSString
        let caretLocation = min(max(request.caretRange.location, 0), nsText.length)
        let beforeLength = min(caretLocation, 600)
        let beforeRange = NSRange(location: caretLocation - beforeLength, length: beforeLength)
        let afterLength = min(240, nsText.length - caretLocation)
        let afterRange = NSRange(location: caretLocation, length: afterLength)
        return """
        languageHint: \(request.snapshot.languageHint.rawValue)
        caretRangeUTF16: \(request.caretRange.location):\(request.caretRange.length)
        caretTextBefore:
        \(nsText.substring(with: beforeRange))

        caretTextAfter:
        \(nsText.substring(with: afterRange))

        memoryContext:
        documentSummary: \(request.memoryContext.documentSummary)
        recentVersions:
        \(request.memoryContext.recentVersionSummaries.joined(separator: "\n"))

        documentText:
        \(request.snapshot.fullText)
        """
    }

    private func finalMessageUserPrompt(for request: AgentFinalMessageRequest) -> String {
        let outline = request.response.outline.enumerated().map { index, item in
            "\(index + 1). \(item)"
        }.joined(separator: "\n")

        let patchPreview = request.response.patches.prefix(6).map { patch in
            "- original: \(compactPromptValue(patch.originalText, limit: 120))\n  replacement: \(compactPromptValue(patch.replacementText, limit: 120))\n  reason: \(compactPromptValue(patch.reason, limit: 120))"
        }.joined(separator: "\n")

        let eventSummary = request.toolEvents.prefix(8).map { event in
            "- \(event.name.rawValue) [\(event.status.rawValue)]: \(compactPromptValue(event.summary, limit: 100))"
        }.joined(separator: "\n")

        return """
        allowCodeBlocks: \(request.allowsCodeBlocks ? "true" : "false")

        userInstruction:
        \(request.instruction)

        agentStructuredResult:
        rawMessage:
        \(request.response.message)

        outline:
        \(outline.isEmpty ? "none" : outline)

        patchCount: \(request.response.patches.count)
        patches:
        \(patchPreview.isEmpty ? "none" : patchPreview)

        toolEvents:
        \(eventSummary.isEmpty ? "none" : eventSummary)
        """
    }

    private func selectedSubstring(from text: String, range: NSRange) -> String {
        let nsText = text as NSString
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length >= 0,
              NSMaxRange(range) <= nsText.length else {
            return ""
        }
        return nsText.substring(with: range)
    }

    private func utf16LineRanges(for text: String, limit: Int = 40) -> String {
        let nsText = text as NSString
        guard nsText.length > 0 else { return "0:0-0 " }
        var lines: [String] = []
        var location = 0
        var index = 1
        while location < nsText.length, lines.count < limit {
            let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
            let rawLine = nsText.substring(with: lineRange)
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            let preview = rawLine.count > 180 ? String(rawLine.prefix(180)) + "…" : rawLine
            lines.append("\(index):\(lineRange.location)-\(NSMaxRange(lineRange)) \(preview)")
            let next = NSMaxRange(lineRange)
            if next <= location { break }
            location = next
            index += 1
        }
        if location < nsText.length {
            lines.append("…")
        }
        return lines.joined(separator: "\n")
    }

    private func performChat(
        systemPrompt: String,
        userPrompt: String,
        configuration: AppConfiguration,
        timeout: Double
    ) async throws -> String {
        let request = try makeChatRequest(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            configuration: configuration,
            timeout: timeout,
            responseFormat: .init(type: "json_object"),
            stream: false
        )

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw LLMError.httpStatus(
                statusCode: httpResponse.statusCode,
                bodyPreview: Self.responsePreview(from: data)
            )
        }
        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let message = decoded.choices.first?.message,
              let content = Self.bestMessageContent(message),
              !content.isEmpty else {
            throw LLMError.emptyContent
        }
        return content
    }

    private func performStreamingChat(
        systemPrompt: String,
        userPrompt: String,
        configuration: AppConfiguration,
        timeout: Double,
        throttleInterval: TimeInterval,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        let request = try makeChatRequest(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            configuration: configuration,
            timeout: timeout,
            responseFormat: nil,
            stream: true
        )

        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
            }
            throw LLMError.httpStatus(
                statusCode: httpResponse.statusCode,
                bodyPreview: Self.responsePreview(from: body)
            )
        }

        var aggregated = ""
        var lastEmission = Date.distantPast
        var lastEmittedContent = ""
        var eventDataLines: [String] = []
        var sawSSEPayload = false
        var rawResponseLines: [String] = []

        func emitIfNeeded(force: Bool = false) async {
            guard aggregated != lastEmittedContent else { return }
            if force || Date().timeIntervalSince(lastEmission) >= throttleInterval {
                lastEmission = Date()
                lastEmittedContent = aggregated
                await onDelta(aggregated)
            }
        }

        func processEventDataLines() async throws -> Bool {
            guard !eventDataLines.isEmpty else { return false }
            defer { eventDataLines.removeAll(keepingCapacity: true) }

            let payload = eventDataLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty else { return false }
            if payload == "[DONE]" {
                return true
            }

            let delta = try Self.streamingDelta(from: payload)
            guard !delta.isEmpty else { return false }
            aggregated += delta
            await emitIfNeeded()
            return false
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.hasPrefix("data:") {
                sawSSEPayload = true
                if try await processEventDataLines() {
                    break
                }
                eventDataLines.append(Self.ssePayload(from: line))
                continue
            }
            if line.isEmpty {
                if try await processEventDataLines() {
                    break
                }
                continue
            }
            if sawSSEPayload {
                continue
            }
            rawResponseLines.append(line)
        }

        _ = try await processEventDataLines()

        if !sawSSEPayload, !rawResponseLines.isEmpty {
            aggregated = try Self.nonStreamingMessageContent(from: rawResponseLines.joined(separator: "\n"))
        }

        await emitIfNeeded(force: true)
        guard !aggregated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.emptyContent
        }
        return aggregated
    }

    private func makeChatRequest(
        systemPrompt: String,
        userPrompt: String,
        configuration: AppConfiguration,
        timeout: Double,
        responseFormat: ChatCompletionRequest.ResponseFormat?,
        stream: Bool
    ) throws -> URLRequest {
        let cleanConfiguration = configuration.sanitized()
        let baseURL = cleanConfiguration.baseURL
        guard !baseURL.isEmpty, let url = URL(string: "\(baseURL)/chat/completions") else {
            throw LLMError.invalidBaseURL
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if !cleanConfiguration.apiKey.isEmpty {
            request.addValue("Bearer \(cleanConfiguration.apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body = ChatCompletionRequest(
            model: cleanConfiguration.model,
            messages: [
                .init(role: "system", content: Self.localizedSystemPrompt(systemPrompt, language: cleanConfiguration.uiLanguage)),
                .init(role: "user", content: Self.localizedUserPrompt(userPrompt, language: cleanConfiguration.uiLanguage)),
            ],
            response_format: responseFormat,
            temperature: 0,
            reasoning_effort: "low",
            stream: stream ? true : nil
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private static func localizedSystemPrompt(_ systemPrompt: String, language: GrammarlessLanguageMode) -> String {
        """
        \(systemPrompt)

        Selected response language: \(language.promptLanguageName).
        Mandatory language rule:
        - \(language.promptLanguageInstruction)
        - Exact document quotes, code, model IDs, offsets, schema keys, and copied original text must remain exact.
        """
    }

    private static func localizedUserPrompt(_ userPrompt: String, language: GrammarlessLanguageMode) -> String {
        """
        selectedResponseLanguage: \(language.promptLanguageName)
        selectedResponseLanguageRule: \(language.promptLanguageInstruction)

        \(userPrompt)
        """
    }

    private static func bestMessageContent(_ message: ChatCompletionResponse.Choice.Message) -> String? {
        let content = message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !content.isEmpty {
            return content
        }
        let reasoningContent = message.reasoning_content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !reasoningContent.isEmpty {
            return reasoningContent
        }
        return nil
    }

    private static func streamingDelta(from payload: String) throws -> String {
        let data = Data(payload.utf8)
        let decoded = try JSONDecoder().decode(StreamingChatCompletionResponse.self, from: data)
        return decoded.choices.compactMap { choice in
            let content = choice.delta?.content ?? choice.message?.content ?? choice.delta?.reasoning_content ?? choice.message?.reasoning_content
            guard let content, !content.isEmpty else { return nil }
            return content
        }.joined()
    }

    private static func nonStreamingMessageContent(from rawResponse: String) throws -> String {
        let data = Data(rawResponse.utf8)
        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let message = decoded.choices.first?.message,
              let content = bestMessageContent(message),
              !content.isEmpty else {
            throw LLMError.emptyContent
        }
        return content
    }

    private static func ssePayload(from line: String) -> String {
        var payload = String(line.dropFirst("data:".count))
        if payload.first == " " {
            payload.removeFirst()
        }
        return payload
    }

    private func compactPromptValue(_ value: String, limit: Int) -> String {
        let compact = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard compact.count > limit else { return compact }
        return String(compact.prefix(limit)) + "…"
    }

    private static func responsePreview(from data: Data) -> String {
        guard !data.isEmpty else { return "" }
        let raw = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.count > 240 else { return raw }
        return String(raw.prefix(240)) + "…"
    }
}
