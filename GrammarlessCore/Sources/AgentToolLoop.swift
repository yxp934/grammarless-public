import Foundation

public final class AgentToolLoop {
    private let llmClient: LLMReviewing

    public init(llmClient: LLMReviewing) {
        self.llmClient = llmClient
    }

    public func run(
        request: AgentToolLoopRequest,
        configuration: AppConfiguration
    ) async throws -> AgentToolLoopResult {
        var transcript: [AgentTranscriptEntry] = []
        var stagedPatches: [TextPatch] = []
        var allCalls: [AgentToolCall] = []
        var allResults: [AgentToolResult] = []
        var events: [AgentToolEvent] = []
        var finalMessage = ""
        var finalOutline: [String] = []

        for turnIndex in 0..<max(1, request.maxTurns) {
            let turnRequest = AgentToolTurnRequest(
                instruction: request.instruction,
                snapshot: request.snapshot,
                selectedRange: request.selectedRange,
                memoryContext: request.memoryContext,
                transcript: transcript,
                stagedPatches: stagedPatches,
                turnIndex: turnIndex
            )
            let turnResponse = try await llmClient.performAgentToolTurn(
                request: turnRequest,
                configuration: configuration
            )
            if !turnResponse.message.isEmpty {
                finalMessage = turnResponse.message
                transcript.append(AgentTranscriptEntry(role: "assistant", content: turnResponse.message))
            }
            if !turnResponse.outline.isEmpty {
                finalOutline = turnResponse.outline
            }
            if !turnResponse.patches.isEmpty {
                stagedPatches.append(contentsOf: turnResponse.patches)
            }
            guard !turnResponse.toolCalls.isEmpty else {
                break
            }

            for call in turnResponse.toolCalls {
                allCalls.append(call)
                events.append(
                    AgentToolEvent(
                        callID: call.id,
                        name: call.name,
                        status: .running,
                        summary: call.name.displayName,
                        detail: call.name.detail
                    )
                )
                let output = AgentToolExecutor.execute(
                    call: call,
                    context: AgentToolExecutionContext(
                        snapshot: request.snapshot,
                        selectedRange: request.selectedRange,
                        memoryContext: request.memoryContext,
                        stagedPatches: stagedPatches
                    )
                )
                stagedPatches.append(contentsOf: output.newPatches)
                allResults.append(output.result)
                events.append(
                    AgentToolEvent(
                        callID: call.id,
                        name: call.name,
                        status: output.result.status,
                        summary: output.result.summary,
                        detail: output.result.content
                    )
                )
                transcript.append(
                    AgentTranscriptEntry(
                        role: "tool",
                        content: "tool=\(call.name.rawValue) status=\(output.result.status.rawValue)\n\(output.result.content)"
                    )
                )
            }
        }

        guard !finalMessage.isEmpty || !stagedPatches.isEmpty || !finalOutline.isEmpty || !allResults.isEmpty else {
            throw LLMError.emptyContent
        }
        let response = AgentResponse(message: finalMessage, patches: stagedPatches, outline: finalOutline)
        return AgentToolLoopResult(
            response: response,
            toolCalls: allCalls,
            toolResults: allResults,
            events: events
        )
    }
}
