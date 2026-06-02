import Foundation
import SQLite3

public protocol WritingMemoryStore: AnyObject {
    func upsertDocument(identity: DocumentIdentity, summary: String) throws -> DocumentRecord
    func document(identity: DocumentIdentity) throws -> DocumentRecord?
    func recordVersion(_ version: DocumentVersion) throws
    func lastVersion(documentID: String) throws -> DocumentVersion?
    func createConversationSession(documentID: String, title: String) throws -> ConversationSession
    func listConversationSessions(documentID: String) throws -> [ConversationSession]
    func renameConversationSession(id: UUID, title: String) throws
    func deleteConversationSession(id: UUID) throws
    func appendConversationTurn(_ turn: ConversationTurn) throws
    func appendConversationTurn(_ turn: ConversationTurn, toSession sessionID: UUID?) throws
    func conversationTurns(inSession sessionID: UUID, limit: Int) throws -> [ConversationTurn]
    func memoryContext(documentID: String, limit: Int) throws -> WritingMemoryContext
    func memoryContext(documentID: String, sessionID: UUID?, limit: Int) throws -> WritingMemoryContext
    func cachedSuggestionBatch(documentID: String, segmentIdentity: String, segmentHash: String) throws -> SuggestionBatch?
    func upsertCachedSuggestionBatch(
        documentID: String,
        segmentIdentity: String,
        segmentHash: String,
        language: DetectedLanguage,
        batch: SuggestionBatch
    ) throws
}

public enum WritingMemoryError: Error, LocalizedError {
    case sqlite(String)
    case encodingFailed
    case decodingFailed

    public var errorDescription: String? {
        switch self {
        case let .sqlite(message):
            "SQLite memory error: \(message)"
        case .encodingFailed:
            "Failed to encode writing memory record."
        case .decodingFailed:
            "Failed to decode writing memory record."
        }
    }
}

public final class SQLiteWritingMemoryStore: WritingMemoryStore {
    private let databaseURL: URL
    private var db: OpaquePointer?
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
            throw WritingMemoryError.sqlite(Self.message(db))
        }
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    public static func defaultDatabaseURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("Grammarless", isDirectory: true)
            .appendingPathComponent("grammarless.sqlite")
    }

    public static func defaultStore() throws -> SQLiteWritingMemoryStore {
        try SQLiteWritingMemoryStore(databaseURL: defaultDatabaseURL())
    }

    public static var defaultDatabaseURLForDisplay: String {
        (try? defaultDatabaseURL().path) ?? "~/Library/Application Support/Grammarless/grammarless.sqlite"
    }

    public func upsertDocument(identity: DocumentIdentity, summary: String = "") throws -> DocumentRecord {
        try locked {
            let now = Date()
            if var existing = try documentUnlocked(identity: identity) {
                existing.updatedAt = now
                if !summary.isEmpty { existing.summary = summary }
                try execute(
                    "UPDATE documents SET kind=?, display_name=?, summary=?, updated_at=? WHERE id=?",
                    [identity.kind.rawValue, identity.displayName, existing.summary, Self.encodeDate(now), identity.rawValue]
                )
                return existing
            }
            let record = DocumentRecord(identity: identity, createdAt: now, updatedAt: now, summary: summary)
            try execute(
                "INSERT INTO documents(id, kind, display_name, summary, created_at, updated_at) VALUES(?, ?, ?, ?, ?, ?)",
                [identity.rawValue, identity.kind.rawValue, identity.displayName, summary, Self.encodeDate(now), Self.encodeDate(now)]
            )
            return record
        }
    }

    public func document(identity: DocumentIdentity) throws -> DocumentRecord? {
        try locked { try documentUnlocked(identity: identity) }
    }

    public func recordVersion(_ version: DocumentVersion) throws {
        try locked {
            guard let data = try? encoder.encode(version.patches), let json = String(data: data, encoding: .utf8) else {
                throw WritingMemoryError.encodingFailed
            }
            try execute(
                "INSERT INTO versions(id, document_id, action, before_text, after_text, patches_json, created_at) VALUES(?, ?, ?, ?, ?, ?, ?)",
                [version.id.uuidString, version.documentID, version.action, version.beforeText, version.afterText, json, Self.encodeDate(version.createdAt)]
            )
            try execute(
                "UPDATE documents SET updated_at=? WHERE id=?",
                [Self.encodeDate(version.createdAt), version.documentID]
            )
        }
    }

    public func lastVersion(documentID: String) throws -> DocumentVersion? {
        try locked { try lastVersionUnlocked(documentID: documentID) }
    }

    public func createConversationSession(documentID: String, title: String) throws -> ConversationSession {
        try locked {
            let now = Date()
            let session = ConversationSession(
                documentID: documentID,
                title: normalizedSessionTitle(title),
                createdAt: now,
                updatedAt: now
            )
            try execute(
                "INSERT INTO conversation_sessions(id, document_id, title, created_at, updated_at) VALUES(?, ?, ?, ?, ?)",
                [session.id.uuidString, documentID, session.title, Self.encodeDate(now), Self.encodeDate(now)]
            )
            try execute(
                "UPDATE documents SET updated_at=? WHERE id=?",
                [Self.encodeDate(now), documentID]
            )
            return session
        }
    }

    public func listConversationSessions(documentID: String) throws -> [ConversationSession] {
        try locked { try conversationSessionsUnlocked(documentID: documentID) }
    }

    public func renameConversationSession(id: UUID, title: String) throws {
        try locked {
            let now = Date()
            try execute(
                "UPDATE conversation_sessions SET title=?, updated_at=? WHERE id=?",
                [normalizedSessionTitle(title), Self.encodeDate(now), id.uuidString]
            )
        }
    }

    public func deleteConversationSession(id: UUID) throws {
        try locked {
            try execute("DELETE FROM session_conversation_turns WHERE session_id=?", [id.uuidString])
            try execute("DELETE FROM conversation_sessions WHERE id=?", [id.uuidString])
        }
    }

    public func appendConversationTurn(_ turn: ConversationTurn) throws {
        try locked {
            try appendConversationTurnUnlocked(turn)
        }
    }

    public func appendConversationTurn(_ turn: ConversationTurn, toSession sessionID: UUID?) throws {
        try locked {
            try appendConversationTurnUnlocked(turn)
            if let sessionID {
                try execute(
                    "INSERT INTO session_conversation_turns(id, session_id, document_id, role, content, created_at) VALUES(?, ?, ?, ?, ?, ?)",
                    [turn.id.uuidString, sessionID.uuidString, turn.documentID, turn.role, turn.content, Self.encodeDate(turn.createdAt)]
                )
                try execute(
                    "UPDATE conversation_sessions SET updated_at=? WHERE id=?",
                    [Self.encodeDate(turn.createdAt), sessionID.uuidString]
                )
            }
        }
    }

    public func conversationTurns(inSession sessionID: UUID, limit: Int = 20) throws -> [ConversationTurn] {
        try locked { try sessionConversationUnlocked(sessionID: sessionID, limit: limit) }
    }

    public func memoryContext(documentID: String, limit: Int = 5) throws -> WritingMemoryContext {
        try memoryContext(documentID: documentID, sessionID: nil, limit: limit)
    }

    public func memoryContext(documentID: String, sessionID: UUID?, limit: Int = 5) throws -> WritingMemoryContext {
        try locked {
            let summary = try documentSummaryUnlocked(documentID: documentID)
            let versions = try recentVersionSummariesUnlocked(documentID: documentID, limit: limit)
            let turns: [ConversationTurn] = if let sessionID {
                try sessionConversationUnlocked(sessionID: sessionID, limit: limit)
            } else {
                try recentConversationUnlocked(documentID: documentID, limit: limit)
            }
            return WritingMemoryContext(
                documentSummary: summary,
                recentVersionSummaries: versions,
                recentConversation: turns,
                preferences: []
            )
        }
    }

    public func cachedSuggestionBatch(
        documentID: String,
        segmentIdentity: String,
        segmentHash: String
    ) throws -> SuggestionBatch? {
        try locked {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(
                """
                SELECT suggestions_json
                FROM suggestion_batches
                WHERE document_id=? AND segment_identity=? AND segment_hash=?
                ORDER BY updated_at DESC
                LIMIT 1
                """,
                &statement
            )
            bind(documentID, at: 1, statement: statement)
            bind(segmentIdentity, at: 2, statement: statement)
            bind(segmentHash, at: 3, statement: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard let data = stringColumn(statement, 0).data(using: .utf8),
                  let batch = try? decoder.decode(SuggestionBatch.self, from: data) else {
                throw WritingMemoryError.decodingFailed
            }
            return batch
        }
    }

    public func upsertCachedSuggestionBatch(
        documentID: String,
        segmentIdentity: String,
        segmentHash: String,
        language: DetectedLanguage,
        batch: SuggestionBatch
    ) throws {
        try locked {
            guard let data = try? encoder.encode(batch),
                  let json = String(data: data, encoding: .utf8) else {
                throw WritingMemoryError.encodingFailed
            }
            let now = Date()
            let id = "\(documentID)|\(segmentIdentity)"
            try execute(
                """
                INSERT INTO suggestion_batches(
                  id, document_id, segment_identity, segment_hash, snapshot_revision,
                  language, suggestions_json, created_at, updated_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  segment_hash=excluded.segment_hash,
                  snapshot_revision=excluded.snapshot_revision,
                  language=excluded.language,
                  suggestions_json=excluded.suggestions_json,
                  updated_at=excluded.updated_at
                """,
                [
                    id,
                    documentID,
                    segmentIdentity,
                    segmentHash,
                    batch.snapshotRevision.uuidString,
                    language.rawValue,
                    json,
                    Self.encodeDate(now),
                    Self.encodeDate(now),
                ]
            )
            try execute(
                "UPDATE documents SET updated_at=? WHERE id=?",
                [Self.encodeDate(now), documentID]
            )
        }
    }

    private func migrate() throws {
        try locked {
            try execute("PRAGMA journal_mode=WAL", [])
            try execute(
                """
                CREATE TABLE IF NOT EXISTS documents(
                  id TEXT PRIMARY KEY,
                  kind TEXT NOT NULL,
                  display_name TEXT NOT NULL,
                  summary TEXT NOT NULL DEFAULT '',
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL
                )
                """,
                []
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS versions(
                  id TEXT PRIMARY KEY,
                  document_id TEXT NOT NULL,
                  action TEXT NOT NULL,
                  before_text TEXT NOT NULL,
                  after_text TEXT NOT NULL,
                  patches_json TEXT NOT NULL,
                  created_at TEXT NOT NULL
                )
                """,
                []
            )
            try execute(
                "CREATE INDEX IF NOT EXISTS idx_versions_document_created ON versions(document_id, created_at)",
                []
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS conversation_turns(
                  id TEXT PRIMARY KEY,
                  document_id TEXT NOT NULL,
                  role TEXT NOT NULL,
                  content TEXT NOT NULL,
                  created_at TEXT NOT NULL
                )
                """,
                []
            )
            try execute(
                "CREATE INDEX IF NOT EXISTS idx_turns_document_created ON conversation_turns(document_id, created_at)",
                []
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS conversation_sessions(
                  id TEXT PRIMARY KEY,
                  document_id TEXT NOT NULL,
                  title TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL
                )
                """,
                []
            )
            try execute(
                "CREATE INDEX IF NOT EXISTS idx_sessions_document_updated ON conversation_sessions(document_id, updated_at)",
                []
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS session_conversation_turns(
                  id TEXT PRIMARY KEY,
                  session_id TEXT NOT NULL,
                  document_id TEXT NOT NULL,
                  role TEXT NOT NULL,
                  content TEXT NOT NULL,
                  created_at TEXT NOT NULL
                )
                """,
                []
            )
            try execute(
                "CREATE INDEX IF NOT EXISTS idx_session_turns_session_created ON session_conversation_turns(session_id, created_at)",
                []
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS writing_preferences(
                  id TEXT PRIMARY KEY,
                  document_id TEXT NOT NULL,
                  key TEXT NOT NULL,
                  value TEXT NOT NULL
                )
                """,
                []
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS suggestion_batches(
                  id TEXT PRIMARY KEY,
                  document_id TEXT NOT NULL,
                  segment_identity TEXT NOT NULL,
                  segment_hash TEXT NOT NULL,
                  snapshot_revision TEXT NOT NULL,
                  language TEXT NOT NULL,
                  suggestions_json TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL
                )
                """,
                []
            )
            try execute(
                "CREATE INDEX IF NOT EXISTS idx_suggestion_batches_document_segment ON suggestion_batches(document_id, segment_identity, segment_hash)",
                []
            )
        }
    }

    private func documentUnlocked(identity: DocumentIdentity) throws -> DocumentRecord? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT id, kind, display_name, summary, created_at, updated_at FROM documents WHERE id=?", &statement)
        bind(identity.rawValue, at: 1, statement: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try decodeDocument(statement: statement)
    }

    private func documentSummaryUnlocked(documentID: String) throws -> String {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT summary FROM documents WHERE id=?", &statement)
        bind(documentID, at: 1, statement: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return "" }
        return stringColumn(statement, 0)
    }

    private func lastVersionUnlocked(documentID: String) throws -> DocumentVersion? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(
            "SELECT id, document_id, action, before_text, after_text, patches_json, created_at FROM versions WHERE document_id=? ORDER BY created_at DESC LIMIT 1",
            &statement
        )
        bind(documentID, at: 1, statement: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try decodeVersion(statement: statement)
    }

    private func conversationSessionsUnlocked(documentID: String) throws -> [ConversationSession] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(
            "SELECT id, document_id, title, created_at, updated_at FROM conversation_sessions WHERE document_id=? ORDER BY updated_at DESC, created_at DESC",
            &statement
        )
        bind(documentID, at: 1, statement: statement)
        var sessions: [ConversationSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            sessions.append(decodeConversationSession(statement: statement))
        }
        return sessions
    }

    private func appendConversationTurnUnlocked(_ turn: ConversationTurn) throws {
        try execute(
            "INSERT INTO conversation_turns(id, document_id, role, content, created_at) VALUES(?, ?, ?, ?, ?)",
            [turn.id.uuidString, turn.documentID, turn.role, turn.content, Self.encodeDate(turn.createdAt)]
        )
        try execute(
            "UPDATE documents SET updated_at=? WHERE id=?",
            [Self.encodeDate(turn.createdAt), turn.documentID]
        )
    }

    private func recentVersionSummariesUnlocked(documentID: String, limit: Int) throws -> [String] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(
            "SELECT action, patches_json, created_at FROM versions WHERE document_id=? ORDER BY created_at DESC LIMIT ?",
            &statement
        )
        bind(documentID, at: 1, statement: statement)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let action = stringColumn(statement, 0)
            let patchesJSON = stringColumn(statement, 1)
            let createdAt = stringColumn(statement, 2)
            let count: Int = if let data = patchesJSON.data(using: .utf8), let patches = try? decoder.decode([TextPatch].self, from: data) {
                patches.count
            } else {
                0
            }
            result.append("\(createdAt): \(action), patches=\(count)")
        }
        return result
    }

    private func recentConversationUnlocked(documentID: String, limit: Int) throws -> [ConversationTurn] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(
            "SELECT id, document_id, role, content, created_at FROM conversation_turns WHERE document_id=? ORDER BY created_at DESC LIMIT ?",
            &statement
        )
        bind(documentID, at: 1, statement: statement)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var turns: [ConversationTurn] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            turns.append(
                ConversationTurn(
                    id: UUID(uuidString: stringColumn(statement, 0)) ?? UUID(),
                    documentID: stringColumn(statement, 1),
                    createdAt: Self.decodeDate(stringColumn(statement, 4)),
                    role: stringColumn(statement, 2),
                    content: stringColumn(statement, 3)
                )
            )
        }
        return turns.reversed()
    }

    private func sessionConversationUnlocked(sessionID: UUID, limit: Int) throws -> [ConversationTurn] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(
            "SELECT id, document_id, role, content, created_at FROM session_conversation_turns WHERE session_id=? ORDER BY created_at DESC LIMIT ?",
            &statement
        )
        bind(sessionID.uuidString, at: 1, statement: statement)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var turns: [ConversationTurn] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            turns.append(
                ConversationTurn(
                    id: UUID(uuidString: stringColumn(statement, 0)) ?? UUID(),
                    documentID: stringColumn(statement, 1),
                    createdAt: Self.decodeDate(stringColumn(statement, 4)),
                    role: stringColumn(statement, 2),
                    content: stringColumn(statement, 3)
                )
            )
        }
        return turns.reversed()
    }

    private func decodeConversationSession(statement: OpaquePointer?) -> ConversationSession {
        ConversationSession(
            id: UUID(uuidString: stringColumn(statement, 0)) ?? UUID(),
            documentID: stringColumn(statement, 1),
            title: stringColumn(statement, 2),
            createdAt: Self.decodeDate(stringColumn(statement, 3)),
            updatedAt: Self.decodeDate(stringColumn(statement, 4))
        )
    }

    private func decodeDocument(statement: OpaquePointer?) throws -> DocumentRecord {
        let kind = DocumentIdentityKind(rawValue: stringColumn(statement, 1)) ?? .contentHash
        let identity = DocumentIdentity(
            kind: kind,
            rawValue: stringColumn(statement, 0),
            displayName: stringColumn(statement, 2)
        )
        return DocumentRecord(
            identity: identity,
            createdAt: Self.decodeDate(stringColumn(statement, 4)),
            updatedAt: Self.decodeDate(stringColumn(statement, 5)),
            summary: stringColumn(statement, 3)
        )
    }

    private func decodeVersion(statement: OpaquePointer?) throws -> DocumentVersion {
        guard let data = stringColumn(statement, 5).data(using: .utf8),
              let patches = try? decoder.decode([TextPatch].self, from: data)
        else {
            throw WritingMemoryError.decodingFailed
        }
        return DocumentVersion(
            id: UUID(uuidString: stringColumn(statement, 0)) ?? UUID(),
            documentID: stringColumn(statement, 1),
            createdAt: Self.decodeDate(stringColumn(statement, 6)),
            action: stringColumn(statement, 2),
            beforeText: stringColumn(statement, 3),
            afterText: stringColumn(statement, 4),
            patches: patches
        )
    }

    private func execute(_ sql: String, _ values: [String]) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(sql, &statement)
        for (index, value) in values.enumerated() {
            bind(value, at: Int32(index + 1), statement: statement)
        }
        guard sqlite3_step(statement) == SQLITE_DONE || sqlite3_column_count(statement) > 0 else {
            throw WritingMemoryError.sqlite(Self.message(db))
        }
    }

    private func prepare(_ sql: String, _ statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw WritingMemoryError.sqlite(Self.message(db))
        }
    }

    private func bind(_ value: String, at index: Int32, statement: OpaquePointer?) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func normalizedSessionTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "新会话" }
        guard trimmed.count > 40 else { return trimmed }
        return String(trimmed.prefix(40)) + "…"
    }

    private func stringColumn(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: cString)
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static func message(_ db: OpaquePointer?) -> String {
        guard let message = sqlite3_errmsg(db) else { return "unknown" }
        return String(cString: message)
    }

    private static func encodeDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func decodeDate(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text) ?? Date(timeIntervalSince1970: 0)
    }
}
