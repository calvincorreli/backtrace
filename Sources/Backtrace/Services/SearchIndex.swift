import Foundation
import SQLite3

/// A full-text index of what was said in each session: the prompts and the
/// replies, without tool output. It lives in the Caches folder, so it can be
/// deleted at any time and is rebuilt on the next scan.
actor SearchIndex {
    /// Cap the text kept per session so one huge session cannot bloat the index.
    static let bodyCharacterLimit = 400_000

    nonisolated(unsafe) private let db: OpaquePointer?

    init(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        if sqlite3_open(url.path, &handle) != SQLITE_OK {
            sqlite3_close(handle)
            handle = nil
        }
        db = handle
        Self.execute(handle, """
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS documents (
                session_id TEXT PRIMARY KEY,
                modified REAL NOT NULL,
                size INTEGER NOT NULL
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS bodies USING fts5(
                session_id UNINDEXED, body, tokenize = 'unicode61 remove_diacritics 2'
            );
            """)
    }

    static func standard() -> SearchIndex {
        SearchIndex(url: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backtrace/SearchIndex.sqlite"))
    }

    deinit {
        sqlite3_close(db)
    }

    /// Sessions that are new or changed since they were indexed, newest first.
    func staleSessions(in sessions: [AssistantSession]) -> [AssistantSession] {
        var indexed: [String: (Double, Int64)] = [:]
        query("SELECT session_id, modified, size FROM documents") { row in
            indexed[Self.text(row, 0)] = (sqlite3_column_double(row, 1), sqlite3_column_int64(row, 2))
        }
        return sessions
            .filter { session in
                guard let (modified, size) = indexed[session.id] else { return true }
                return modified != session.updatedAt.timeIntervalSince1970 || size != session.fileSize
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func store(_ session: AssistantSession, body: String) {
        let clipped = String(body.prefix(Self.bodyCharacterLimit))
        Self.execute(db, "BEGIN")
        run("DELETE FROM bodies WHERE session_id = ?", [session.id])
        run("INSERT INTO bodies (session_id, body) VALUES (?, ?)", [session.id, clipped])
        run(
            "INSERT OR REPLACE INTO documents (session_id, modified, size) VALUES (?, ?, ?)",
            [session.id, session.updatedAt.timeIntervalSince1970, session.fileSize]
        )
        Self.execute(db, "COMMIT")
    }

    /// Drops sessions whose files are gone.
    func removeAll(except ids: Set<String>) {
        var stale: [String] = []
        query("SELECT session_id FROM documents") { row in
            let id = Self.text(row, 0)
            if !ids.contains(id) { stale.append(id) }
        }
        guard !stale.isEmpty else { return }
        Self.execute(db, "BEGIN")
        for id in stale {
            run("DELETE FROM bodies WHERE session_id = ?", [id])
            run("DELETE FROM documents WHERE session_id = ?", [id])
        }
        Self.execute(db, "COMMIT")
    }

    /// Sessions whose conversation contains every word of the query (as a
    /// word prefix), with a short excerpt around the match.
    func search(_ text: String, limit: Int = 2_000) -> [String: String] {
        guard let match = Self.matchExpression(for: text) else { return [:] }
        var result: [String: String] = [:]
        query(
            "SELECT session_id, snippet(bodies, 1, '', '', '…', 14) FROM bodies WHERE bodies MATCH ? ORDER BY rank LIMIT ?",
            [match, limit]
        ) { row in
            result[Self.text(row, 0)] = Self.text(row, 1).compactWhitespace
        }
        return result
    }

    static func matchExpression(for text: String) -> String? {
        let words = text.foldedForSearch
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    // MARK: - SQLite

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func execute(_ db: OpaquePointer?, _ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private static func text(_ row: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(row, column).map { String(cString: $0) } ?? ""
    }

    private func run(_ sql: String, _ values: [Any]) {
        query(sql, values) { _ in }
    }

    private func query(_ sql: String, _ values: [Any] = [], row handle: (OpaquePointer?) -> Void) {
        guard let db else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let value as String: sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case let value as Double: sqlite3_bind_double(statement, index, value)
            case let value as Int64: sqlite3_bind_int64(statement, index, value)
            case let value as Int: sqlite3_bind_int64(statement, index, Int64(value))
            default: sqlite3_bind_null(statement, index)
            }
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            handle(statement)
        }
    }
}
