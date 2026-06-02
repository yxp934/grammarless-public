import Foundation

public enum AgentToolName: String, Codable, CaseIterable, Identifiable {
    case readSelectedText = "read_selected_text"
    case readVisibleText = "read_visible_text"
    case readDocumentContext = "read_document_context"
    case draftEditPatch = "draft_edit_patch"
    case checkConsistency = "check_consistency"
    case previewPatchDiff = "preview_patch_diff"
    case stagePatchForUserConfirmation = "stage_patch_for_user_confirmation"
    case rollbackLastVersion = "rollback_last_version"
    case redoLastAgentRun = "redo_last_agent_run"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .readSelectedText: return "读取选中文本"
        case .readVisibleText: return "读取可见文本"
        case .readDocumentContext: return "读取文档上下文"
        case .draftEditPatch: return "生成修改草案"
        case .checkConsistency: return "检查术语一致性"
        case .previewPatchDiff: return "生成差异预览"
        case .stagePatchForUserConfirmation: return "应用编辑工具"
        case .rollbackLastVersion: return "回滚上次修改"
        case .redoLastAgentRun: return "一键重做"
        }
    }

    public var detail: String {
        switch self {
        case .readSelectedText: return "获取用户当前选中的文本内容"
        case .readVisibleText: return "获取屏幕可见范围内的文本内容"
        case .readDocumentContext: return "读取文档、选区与长期记忆摘要"
        case .draftEditPatch: return "基于模型决策生成局部修改 patch"
        case .checkConsistency: return "校验候选修改与上下文一致性"
        case .previewPatchDiff: return "将修改草案转换为可确认的差异预览"
        case .stagePatchForUserConfirmation: return "将选定修改方案提交用户确认"
        case .rollbackLastVersion: return "准备回滚到上一个已记录版本"
        case .redoLastAgentRun: return "按上次用户目标重新执行工具链"
        }
    }
}

public enum AgentToolStatus: String, Codable, Equatable {
    case running
    case succeeded
    case failed
}

public struct AgentToolCall: Codable, Equatable, Identifiable {
    public var id: String
    public var name: AgentToolName
    public var arguments: [String: String]

    public init(id: String = UUID().uuidString, name: AgentToolName, arguments: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct AgentToolResult: Codable, Equatable, Identifiable {
    public var id: String
    public var callID: String
    public var name: AgentToolName
    public var status: AgentToolStatus
    public var summary: String
    public var content: String
    public var patchIDs: [UUID]

    public init(
        id: String = UUID().uuidString,
        callID: String,
        name: AgentToolName,
        status: AgentToolStatus,
        summary: String,
        content: String,
        patchIDs: [UUID] = []
    ) {
        self.id = id
        self.callID = callID
        self.name = name
        self.status = status
        self.summary = summary
        self.content = content
        self.patchIDs = patchIDs
    }
}

public struct AgentToolEvent: Codable, Equatable, Identifiable {
    public var id: String
    public var callID: String
    public var name: AgentToolName
    public var status: AgentToolStatus
    public var summary: String
    public var detail: String
    public var timestamp: Date

    public init(
        id: String = UUID().uuidString,
        callID: String,
        name: AgentToolName,
        status: AgentToolStatus,
        summary: String,
        detail: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.callID = callID
        self.name = name
        self.status = status
        self.summary = summary
        self.detail = detail
        self.timestamp = timestamp
    }
}

public struct AgentTranscriptEntry: Codable, Equatable, Identifiable {
    public var id: UUID
    public var role: String
    public var content: String

    public init(id: UUID = UUID(), role: String, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

public struct AgentToolTurnRequest: Equatable {
    public var instruction: String
    public var snapshot: TextSnapshot
    public var selectedRange: NSRange?
    public var memoryContext: WritingMemoryContext
    public var transcript: [AgentTranscriptEntry]
    public var stagedPatches: [TextPatch]
    public var turnIndex: Int

    public init(
        instruction: String,
        snapshot: TextSnapshot,
        selectedRange: NSRange?,
        memoryContext: WritingMemoryContext,
        transcript: [AgentTranscriptEntry] = [],
        stagedPatches: [TextPatch] = [],
        turnIndex: Int = 0
    ) {
        self.instruction = instruction
        self.snapshot = snapshot
        self.selectedRange = selectedRange
        self.memoryContext = memoryContext
        self.transcript = transcript
        self.stagedPatches = stagedPatches
        self.turnIndex = turnIndex
    }
}

public struct AgentToolTurnResponse: Equatable {
    public var message: String
    public var toolCalls: [AgentToolCall]
    public var patches: [TextPatch]
    public var outline: [String]

    public init(message: String = "", toolCalls: [AgentToolCall] = [], patches: [TextPatch] = [], outline: [String] = []) {
        self.message = message
        self.toolCalls = toolCalls
        self.patches = patches
        self.outline = outline
    }
}

public struct AgentToolLoopRequest: Equatable {
    public var instruction: String
    public var snapshot: TextSnapshot
    public var selectedRange: NSRange?
    public var memoryContext: WritingMemoryContext
    public var maxTurns: Int

    public init(
        instruction: String,
        snapshot: TextSnapshot,
        selectedRange: NSRange?,
        memoryContext: WritingMemoryContext,
        maxTurns: Int = 5
    ) {
        self.instruction = instruction
        self.snapshot = snapshot
        self.selectedRange = selectedRange
        self.memoryContext = memoryContext
        self.maxTurns = maxTurns
    }
}

public struct AgentToolLoopResult: Equatable {
    public var response: AgentResponse
    public var toolCalls: [AgentToolCall]
    public var toolResults: [AgentToolResult]
    public var events: [AgentToolEvent]

    public init(
        response: AgentResponse,
        toolCalls: [AgentToolCall],
        toolResults: [AgentToolResult],
        events: [AgentToolEvent]
    ) {
        self.response = response
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.events = events
    }
}

public enum AgentToolExecutionError: LocalizedError, Equatable {
    case unknownTool(String)
    case missingArgument(String)
    case invalidRange(String)
    case staleOriginal(expected: String, actual: String)
    case noPatchAvailable

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name): return "Unknown agent tool: \(name)"
        case .missingArgument(let key): return "Missing tool argument: \(key)"
        case .invalidRange(let value): return "Invalid tool range: \(value)"
        case .staleOriginal(let expected, let actual): return "Tool original text mismatch. expected=\(expected) actual=\(actual)"
        case .noPatchAvailable: return "No staged patch is available."
        }
    }
}

public struct AgentToolExecutionContext: Equatable {
    public var snapshot: TextSnapshot
    public var selectedRange: NSRange?
    public var memoryContext: WritingMemoryContext
    public var stagedPatches: [TextPatch]

    public init(
        snapshot: TextSnapshot,
        selectedRange: NSRange?,
        memoryContext: WritingMemoryContext,
        stagedPatches: [TextPatch] = []
    ) {
        self.snapshot = snapshot
        self.selectedRange = selectedRange
        self.memoryContext = memoryContext
        self.stagedPatches = stagedPatches
    }
}

public struct AgentToolExecutionOutput: Equatable {
    public var result: AgentToolResult
    public var newPatches: [TextPatch]

    public init(result: AgentToolResult, newPatches: [TextPatch] = []) {
        self.result = result
        self.newPatches = newPatches
    }
}

public enum AgentToolExecutor {
    public static func execute(
        call: AgentToolCall,
        context: AgentToolExecutionContext
    ) -> AgentToolExecutionOutput {
        do {
            return try executeThrowing(call: call, context: context)
        } catch {
            return AgentToolExecutionOutput(
                result: AgentToolResult(
                    callID: call.id,
                    name: call.name,
                    status: .failed,
                    summary: error.localizedDescription,
                    content: error.localizedDescription
                )
            )
        }
    }

    private static func executeThrowing(
        call: AgentToolCall,
        context: AgentToolExecutionContext
    ) throws -> AgentToolExecutionOutput {
        let nsText = context.snapshot.fullText as NSString
        switch call.name {
        case .readSelectedText:
            let range = normalizedSelectedRange(context)
            let text = substring(nsText, range)
            return output(call, "已读取选中文本", "selectedRange=\(range.location):\(range.length)\n\(text)")
        case .readVisibleText:
            let range = context.snapshot.analysisRangeInFullText
            return output(call, "已读取屏幕可见文本", "visibleRange=\(range.location):\(range.length)\n\(context.snapshot.analysisText)")
        case .readDocumentContext:
            let selectedRange = normalizedSelectedRange(context)
            let selectedText = substring(nsText, selectedRange)
            let content = """
            documentLengthUTF16=\(nsText.length)
            languageHint=\(context.snapshot.languageHint.rawValue)
            selectedRange=\(selectedRange.location):\(selectedRange.length)
            selectedText=\(selectedText)
            documentSummary=\(context.memoryContext.documentSummary)
            recentVersions=\(context.memoryContext.recentVersionSummaries.joined(separator: " | "))
            recentConversation=\(context.memoryContext.recentConversation.map { "\($0.role): \($0.content)" }.joined(separator: " | "))
            """
            return output(call, "已读取文档上下文", content)
        case .draftEditPatch:
            let expectedOriginal = call.arguments["original"] ?? ""
            let replacement = try required("replacement", in: call.arguments)
            var range = try range(from: call.arguments, in: nsText, fallbackOriginal: expectedOriginal)
            var original = substring(nsText, range)
            if !expectedOriginal.isEmpty, expectedOriginal != original {
                if let repairedRange = uniqueRange(of: expectedOriginal, in: nsText) {
                    range = repairedRange
                    original = expectedOriginal
                } else {
                    throw AgentToolExecutionError.staleOriginal(expected: expectedOriginal, actual: original)
                }
            }
            let patch = TextPatch(
                rangeInFullText: range,
                originalText: original,
                replacementText: replacement,
                reason: call.arguments["reason"] ?? "model drafted edit patch"
            )
            guard patch.validate(against: context.snapshot.fullText) else {
                throw AgentToolExecutionError.invalidRange("no-op or stale patch at \(range.location):\(range.length)")
            }
            let content = "patchID=\(patch.id.uuidString) range=\(range.location):\(range.length) originalLength=\((original as NSString).length) replacementLength=\((replacement as NSString).length)"
            return AgentToolExecutionOutput(
                result: AgentToolResult(
                    callID: call.id,
                    name: call.name,
                    status: .succeeded,
                    summary: "已生成修改草案",
                    content: content,
                    patchIDs: [patch.id]
                ),
                newPatches: [patch]
            )
        case .checkConsistency:
            let invalid = context.stagedPatches.filter { !$0.validate(against: context.snapshot.fullText) }
            let content = "stagedPatchCount=\(context.stagedPatches.count) invalidPatchCount=\(invalid.count)"
            return output(call, invalid.isEmpty ? "一致性检查通过" : "发现失效修改", content)
        case .previewPatchDiff:
            guard !context.stagedPatches.isEmpty else { throw AgentToolExecutionError.noPatchAvailable }
            let previews = context.stagedPatches.map { patch in
                "patchID=\(patch.id.uuidString) range=\(patch.rangeInFullText.location):\(patch.rangeInFullText.length) deleteUTF16=\((patch.originalText as NSString).length) insertUTF16=\((patch.replacementText as NSString).length) reason=\(patch.reason)"
            }.joined(separator: "\n")
            return output(call, "已生成差异预览", previews)
        case .stagePatchForUserConfirmation:
            guard !context.stagedPatches.isEmpty else { throw AgentToolExecutionError.noPatchAvailable }
            return output(call, "已提交用户确认", "stagedPatchCount=\(context.stagedPatches.count)")
        case .rollbackLastVersion:
            return output(call, "已检查回滚能力", "Rollback requires explicit user confirmation in the Grammarless UI.")
        case .redoLastAgentRun:
            return output(call, "已准备重做", "Redo requires explicit user confirmation in the Grammarless UI.")
        }
    }

    private static func output(_ call: AgentToolCall, _ summary: String, _ content: String) -> AgentToolExecutionOutput {
        AgentToolExecutionOutput(
            result: AgentToolResult(
                callID: call.id,
                name: call.name,
                status: .succeeded,
                summary: summary,
                content: content
            )
        )
    }

    private static func normalizedSelectedRange(_ context: AgentToolExecutionContext) -> NSRange {
        let nsText = context.snapshot.fullText as NSString
        let range = context.selectedRange ?? context.snapshot.selectedRange
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length >= 0,
              NSMaxRange(range) <= nsText.length else {
            return NSRange(location: 0, length: 0)
        }
        return range
    }

    private static func substring(_ nsText: NSString, _ range: NSRange) -> String {
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length >= 0,
              NSMaxRange(range) <= nsText.length else { return "" }
        return nsText.substring(with: range)
    }

    private static func required(_ key: String, in arguments: [String: String]) throws -> String {
        guard let value = arguments[key], !value.isEmpty else {
            throw AgentToolExecutionError.missingArgument(key)
        }
        return value
    }

    private static func range(
        from arguments: [String: String],
        in nsText: NSString,
        fallbackOriginal: String = ""
    ) throws -> NSRange {
        guard let startText = arguments["start"], let start = Int(startText),
              let endText = arguments["end"], let end = Int(endText) else {
            if !fallbackOriginal.isEmpty, let repairedRange = uniqueRange(of: fallbackOriginal, in: nsText) {
                return repairedRange
            }
            if arguments["start"] == nil {
                throw AgentToolExecutionError.missingArgument("start")
            }
            throw AgentToolExecutionError.missingArgument("end")
        }
        guard start >= 0, end >= start, end <= nsText.length else {
            if !fallbackOriginal.isEmpty, let repairedRange = uniqueRange(of: fallbackOriginal, in: nsText) {
                return repairedRange
            }
            throw AgentToolExecutionError.invalidRange("\(start):\(end)")
        }
        return NSRange(location: start, length: end - start)
    }

    private static func uniqueRange(of text: String, in nsText: NSString) -> NSRange? {
        guard !text.isEmpty else { return nil }
        let fullRange = NSRange(location: 0, length: nsText.length)
        let first = nsText.range(of: text, options: [], range: fullRange)
        guard first.location != NSNotFound else { return nil }
        let searchStart = NSMaxRange(first)
        guard searchStart < nsText.length else { return first }
        let secondSearchRange = NSRange(location: searchStart, length: nsText.length - searchStart)
        let second = nsText.range(of: text, options: [], range: secondSearchRange)
        return second.location == NSNotFound ? first : nil
    }
}
