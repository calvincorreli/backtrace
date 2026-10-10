import Foundation
import SQLite3

struct OpenCodeProvider: SessionProvider {
    let assistant = AssistantKind.openCode
    let root: URL
    let executableURL: URL?
    let home: URL

    init(home: URL, executableURL: URL?) {
        self.home = home
        root = AssistantKind.openCode.defaultHistoryRoots(home: home)[0]
        self.executableURL = executableURL
    }

    init(root: URL, executableURL: URL? = nil, home: URL) {
        self.root = root
        self.executableURL = executableURL
        self.home = home
    }

    func sessions() throws -> [AssistantSession] {
        var byID: [String: AssistantSession] = [:]
        let legacyRoot = root.appendingPathComponent("storage/session", isDirectory: true)
        for url in FileMetadata.files(below: legacyRoot, extensions: ["json"]) {
            if let session = try? legacySession(at: url) {
                byID[session.sessionID] = session
            }
        }

        for session in databaseSessions() where byID[session.sessionID] == nil {
            byID[session.sessionID] = session
        }

        if byID.isEmpty, let executableURL {
            for session in cliSessions(executableURL: executableURL) {
                byID[session.sessionID] = session
            }
        }
        return Array(byID.values)
    }

    private func legacySession(at url: URL) throws -> AssistantSession? {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let object = JSONValue.object(from: data),
              let id = object["id"] as? String,
              id != "global" else { return nil }
        let time = object["time"] as? [String: Any]
        let created = FlexibleDateParser.parse(time?["created"])
        let updated = FlexibleDateParser.parse(time?["updated"])
        let file = FileMetadata.values(for: url)
        return AssistantSession(
            assistant: .openCode,
            sessionID: id,
            title: JSONValue.string(object, keys: ["title"]) ?? "Untitled OpenCode session",
            summary: summaryText(object["summary"]),
            projectPath: JSONValue.string(object, keys: ["directory"]),
            gitBranch: nil,
            model: nil,
            createdAt: created,
            updatedAt: max(file.modified, updated ?? .distantPast),
            messageCount: nil,
            fileSize: file.size,
            sourceURL: url,
            sourceFormat: .openCodeLegacy,
            isArchived: false
        )
    }

    /// Current OpenCode keeps every session in one SQLite database. The CLI
    /// only lists sessions for the project it is run from, so asking it from
    /// the home directory finds nothing; the database has them all.
    private func databaseSessions() -> [AssistantSession] {
        let databaseURL = root.appendingPathComponent("opencode.db").resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }

        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        sqlite3_busy_timeout(handle, 500)

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        // Sessions with a parent are subagent runs, which cannot be resumed on their own.
        guard sqlite3_prepare_v2(handle, "SELECT * FROM session WHERE parent_id IS NULL", -1, &statement, nil) == SQLITE_OK else {
            return []
        }

        var columns: [String: Int32] = [:]
        for index in 0..<sqlite3_column_count(statement) {
            columns[String(cString: sqlite3_column_name(statement, index))] = index
        }
        func text(_ name: String) -> String? {
            guard let index = columns[name], let value = sqlite3_column_text(statement, index) else { return nil }
            let string = String(cString: value)
            return string.isEmpty ? nil : string
        }
        func date(_ name: String) -> Date? {
            guard let index = columns[name], sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
            return Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, index)) / 1_000)
        }

        let size = FileMetadata.values(for: databaseURL).size
        var result: [AssistantSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text("id") else { continue }
            let model = text("model").flatMap { value -> String? in
                guard let object = JSONValue.object(from: Data(value.utf8)) else { return value }
                return JSONValue.string(object, keys: ["id", "modelID"])
            }
            let created = date("time_created")
            result.append(AssistantSession(
                assistant: .openCode,
                sessionID: id,
                title: text("title") ?? "Untitled OpenCode session",
                summary: nil,
                projectPath: text("directory"),
                gitBranch: nil,
                model: model,
                createdAt: created,
                updatedAt: date("time_updated") ?? created ?? .distantPast,
                messageCount: nil,
                fileSize: size,
                sourceURL: databaseURL,
                sourceFormat: .openCodeCLI,
                isArchived: date("time_archived") != nil
            ))
        }
        return result
    }

    private func cliSessions(executableURL: URL) -> [AssistantSession] {
        guard let result = ProcessRunner.run(
            executable: executableURL,
            arguments: ["session", "list", "--format", "json"],
            currentDirectory: home,
            extraEnvironment: ["OPENCODE_DISABLE_AUTOUPDATE": "true"]
        ), result.status == 0,
        let values = parseJSONArray(from: result.output) else { return [] }

        return values.compactMap { object in
            guard let id = object["id"] as? String else { return nil }
            let time = object["time"] as? [String: Any]
            return AssistantSession(
                assistant: .openCode,
                sessionID: id,
                title: JSONValue.string(object, keys: ["title"]) ?? "Untitled OpenCode session",
                summary: summaryText(object["summary"]),
                projectPath: JSONValue.string(object, keys: ["directory"]),
                gitBranch: JSONValue.string(object, keys: ["branch"]),
                model: JSONValue.string(object, keys: ["model", "modelID"]),
                createdAt: FlexibleDateParser.parse(time?["created"] ?? object["createdAt"]),
                updatedAt: FlexibleDateParser.parse(time?["updated"] ?? object["updatedAt"]) ?? .distantPast,
                messageCount: object["messageCount"] as? Int,
                fileSize: 0,
                sourceURL: root,
                sourceFormat: .openCodeCLI,
                isArchived: false
            )
        }
    }

    private func summaryText(_ value: Any?) -> String? {
        if let value = value as? String { return value.clipped(to: 260) }
        guard let object = value as? [String: Any] else { return nil }
        return JSONValue.string(object, keys: ["text", "title", "description"])?.clipped(to: 260)
    }

    private func parseJSONArray(from data: Data) -> [[String: Any]]? {
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array
        }
        guard let start = data.firstIndex(of: 0x5B), let end = data.lastIndex(of: 0x5D), start <= end else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: Data(data[start...end])) as? [[String: Any]]
    }
}
