import CoreGraphics
import CryptoKit
import Foundation

public enum DocumentIdentityKind: String, Codable, CaseIterable {
    case windowTitle
    case appElement
    case contentHash
}

public struct DocumentIdentity: Codable, Equatable, Hashable {
    public var kind: DocumentIdentityKind
    public var rawValue: String
    public var displayName: String

    public init(kind: DocumentIdentityKind, rawValue: String, displayName: String) {
        self.kind = kind
        self.rawValue = rawValue
        self.displayName = displayName
    }

    public static func resolve(
        snapshot: TextSnapshot,
        windowTitle: String?
    ) -> DocumentIdentity {
        if let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return DocumentIdentity(
                kind: .windowTitle,
                rawValue: "\(snapshot.appBundleId)|\(title)",
                displayName: title
            )
        }
        if !snapshot.elementIdentity.isEmpty {
            return DocumentIdentity(
                kind: .appElement,
                rawValue: "\(snapshot.appBundleId)|\(snapshot.elementIdentity)",
                displayName: snapshot.appBundleId
            )
        }
        let hash = normalizedContentHash(snapshot.fullText)
        return DocumentIdentity(kind: .contentHash, rawValue: hash, displayName: "Untitled Document")
    }

    public static func normalizedContentHash(_ text: String) -> String {
        let normalized = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public struct DocumentRecord: Codable, Equatable, Identifiable {
    public var id: String { identity.rawValue }
    public var identity: DocumentIdentity
    public var createdAt: Date
    public var updatedAt: Date
    public var summary: String

    public init(identity: DocumentIdentity, createdAt: Date = Date(), updatedAt: Date = Date(), summary: String = "") {
        self.identity = identity
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.summary = summary
    }
}

public struct TextPatch: Codable, Equatable, Identifiable {
    public var id: UUID
    public var rangeInFullText: NSRange
    public var originalText: String
    public var replacementText: String
    public var reason: String

    public init(
        id: UUID = UUID(),
        rangeInFullText: NSRange,
        originalText: String,
        replacementText: String,
        reason: String
    ) {
        self.id = id
        self.rangeInFullText = rangeInFullText
        self.originalText = originalText
        self.replacementText = replacementText
        self.reason = reason
    }

    public var isNoOp: Bool { originalText == replacementText }

    public func validate(against fullText: String) -> Bool {
        guard rangeInFullText.location != NSNotFound,
              rangeInFullText.location >= 0,
              rangeInFullText.length >= 0 else { return false }
        let nsText = fullText as NSString
        guard NSMaxRange(rangeInFullText) <= nsText.length else { return false }
        return nsText.substring(with: rangeInFullText) == originalText && !isNoOp
    }

    public func applying(to fullText: String) -> String? {
        guard validate(against: fullText) else { return nil }
        return (fullText as NSString).replacingCharacters(in: rangeInFullText, with: replacementText)
    }
}

public struct DocumentVersion: Codable, Equatable, Identifiable {
    public var id: UUID
    public var documentID: String
    public var createdAt: Date
    public var action: String
    public var beforeText: String
    public var afterText: String
    public var patches: [TextPatch]

    public init(
        id: UUID = UUID(),
        documentID: String,
        createdAt: Date = Date(),
        action: String,
        beforeText: String,
        afterText: String,
        patches: [TextPatch]
    ) {
        self.id = id
        self.documentID = documentID
        self.createdAt = createdAt
        self.action = action
        self.beforeText = beforeText
        self.afterText = afterText
        self.patches = patches
    }
}

public struct ConversationTurn: Codable, Equatable, Identifiable {
    public var id: UUID
    public var documentID: String
    public var createdAt: Date
    public var role: String
    public var content: String

    public init(id: UUID = UUID(), documentID: String, createdAt: Date = Date(), role: String, content: String) {
        self.id = id
        self.documentID = documentID
        self.createdAt = createdAt
        self.role = role
        self.content = content
    }
}

public struct ConversationSession: Codable, Equatable, Identifiable {
    public var id: UUID
    public var documentID: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        documentID: String,
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.documentID = documentID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct WritingPreference: Codable, Equatable, Identifiable {
    public var id: UUID
    public var documentID: String
    public var key: String
    public var value: String

    public init(id: UUID = UUID(), documentID: String, key: String, value: String) {
        self.id = id
        self.documentID = documentID
        self.key = key
        self.value = value
    }
}

public struct WritingMemoryContext: Codable, Equatable {
    public var documentSummary: String
    public var recentVersionSummaries: [String]
    public var recentConversation: [ConversationTurn]
    public var preferences: [WritingPreference]

    public init(
        documentSummary: String = "",
        recentVersionSummaries: [String] = [],
        recentConversation: [ConversationTurn] = [],
        preferences: [WritingPreference] = []
    ) {
        self.documentSummary = documentSummary
        self.recentVersionSummaries = recentVersionSummaries
        self.recentConversation = recentConversation
        self.preferences = preferences
    }
}

public enum AgentAction: String, Codable, CaseIterable, Identifiable {
    case ask
    case rewriteSelection
    case outline
    case continueWriting
    case summarize
    case tone
    case proofreadDocument

    public var id: String { rawValue }
}

public struct AgentActionRequest: Equatable {
    public var action: AgentAction
    public var instruction: String
    public var snapshot: TextSnapshot
    public var selectedRange: NSRange?
    public var memoryContext: WritingMemoryContext

    public init(
        action: AgentAction,
        instruction: String,
        snapshot: TextSnapshot,
        selectedRange: NSRange?,
        memoryContext: WritingMemoryContext
    ) {
        self.action = action
        self.instruction = instruction
        self.snapshot = snapshot
        self.selectedRange = selectedRange
        self.memoryContext = memoryContext
    }
}

public struct AgentResponse: Equatable {
    public var message: String
    public var patches: [TextPatch]
    public var outline: [String]

    public init(message: String, patches: [TextPatch] = [], outline: [String] = []) {
        self.message = message
        self.patches = patches
        self.outline = outline
    }
}

public struct AgentFinalMessageRequest: Equatable {
    public var instruction: String
    public var response: AgentResponse
    public var toolEvents: [AgentToolEvent]
    public var allowsCodeBlocks: Bool

    public init(
        instruction: String,
        response: AgentResponse,
        toolEvents: [AgentToolEvent] = [],
        allowsCodeBlocks: Bool = false
    ) {
        self.instruction = instruction
        self.response = response
        self.toolEvents = toolEvents
        self.allowsCodeBlocks = allowsCodeBlocks
    }
}

public struct GhostSuggestion: Codable, Equatable, Identifiable {
    public var id: UUID
    public var rangeInFullText: NSRange
    public var text: String
    public var explanation: String
    public var snapshotRevision: UUID

    public init(
        id: UUID = UUID(),
        rangeInFullText: NSRange,
        text: String,
        explanation: String,
        snapshotRevision: UUID
    ) {
        self.id = id
        self.rangeInFullText = rangeInFullText
        self.text = text
        self.explanation = explanation
        self.snapshotRevision = snapshotRevision
    }
}

public struct GhostSuggestionRequest: Equatable {
    public var snapshot: TextSnapshot
    public var caretRange: NSRange
    public var memoryContext: WritingMemoryContext

    public init(snapshot: TextSnapshot, caretRange: NSRange, memoryContext: WritingMemoryContext) {
        self.snapshot = snapshot
        self.caretRange = caretRange
        self.memoryContext = memoryContext
    }
}
