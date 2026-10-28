import Foundation

struct CodexProvider: SessionProvider {
    let assistant = AssistantKind.codex
    let roots: [URL]
    let indexURL: URL

    init(home: URL) {
        roots = AssistantKind.codex.defaultHistoryRoots(home: home)
        indexURL = roots[0].deletingLastPathComponent().appendingPathComponent("session_index.jsonl")
    }

    init(roots: [URL], indexURL: URL) {
        self.roots = roots
        self.indexURL = indexURL
    }

    func sessions() throws -> [AssistantSession] {
        let titles = titleIndex()
        var result: [AssistantSession] = []

        for root in roots {
            let isArchived = root.lastPathComponent == "archived_sessions"
            for url in FileMetadata.files(below: root, extensions: ["jsonl", "zst"]) where SessionFileData.isSessionLog(url) {
                guard let session = cachedSession(at: url, titles: titles, isArchived: isArchived) else {
                    continue
                }
                result.append(session)
            }
        }
        return result
    }

    /// Compressed sessions cost a decompression to read, and Codex does not
    /// change them after compressing, so each one is parsed once per launch.
    private func cachedSession(at url: URL, titles: [String: String], isArchived: Bool) -> AssistantSession? {
        guard url.pathExtension == "zst" else {
            return try? session(at: url, titles: titles, isArchived: isArchived)
        }
        let file = FileMetadata.values(for: url)
        let key = "\(url.path)|\(file.modified.timeIntervalSince1970)|\(file.size)|\(isArchived)"
        if let cached = CompressedSessionCache.shared.value(for: key) {
            return cached.retitled(titles[cached.sessionID])
        }
        guard let parsed = try? session(at: url, titles: titles, isArchived: isArchived) else { return nil }
        CompressedSessionCache.shared.set(parsed, for: key)
        return parsed
    }

    private func titleIndex() -> [String: String] {
        guard let objects = try? JSONLReader.objects(at: indexURL).0 else { return [:] }
        var values: [String: String] = [:]
        for object in objects {
            guard let id = object["id"] as? String,
                  let title = object["thread_name"] as? String,
                  !title.isEmpty else { continue }
            values[id] = title
        }
        return values
    }

    private func session(
        at url: URL,
        titles: [String: String],
        isArchived: Bool
    ) throws -> AssistantSession? {
        let objects = try JSONLReader.sampledObjects(at: url)
        guard let metadata = objects.first(where: { ($0["type"] as? String) == "session_meta" }),
              let payload = metadata["payload"] as? [String: Any] else { return nil }

        let filename = url.lastPathComponent
            .replacingOccurrences(of: ".zst", with: "")
            .replacingOccurrences(of: ".jsonl", with: "")
        let id = JSONValue.string(payload, keys: ["id", "session_id"]) ?? idFromFilename(filename)
        guard let id else { return nil }

        let prompt = SessionText.firstPrompt(in: objects, assistant: .codex)
        let projectPath = JSONValue.string(payload, keys: ["cwd", "working_directory"])
        let indexedTitle = titles[id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = indexedTitle?.isEmpty == false
            ? indexedTitle!
            : (prompt?.clipped(to: 92) ?? fallbackTitle(projectPath: projectPath))
        let created = FlexibleDateParser.parse(payload["timestamp"] ?? metadata["timestamp"])
        let sampledUpdated = objects.compactMap { FlexibleDateParser.parse($0["timestamp"]) }.max()
        let file = FileMetadata.values(for: url)
        let model = objects.lazy.compactMap { object -> String? in
            guard (object["type"] as? String) == "turn_context",
                  let turn = object["payload"] as? [String: Any] else { return nil }
            return JSONValue.string(turn, keys: ["model"])
        }.first

        return AssistantSession(
            assistant: .codex,
            sessionID: id,
            title: title,
            summary: prompt?.clipped(to: 260),
            projectPath: projectPath,
            gitBranch: nil,
            model: model ?? JSONValue.string(payload, keys: ["model_provider"]),
            createdAt: created,
            updatedAt: max(file.modified, sampledUpdated ?? .distantPast),
            messageCount: nil,
            fileSize: file.size,
            sourceURL: url,
            sourceFormat: .codexJSONL,
            isArchived: isArchived
        )
    }

    private func idFromFilename(_ filename: String) -> String? {
        guard let range = filename.range(
            of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#,
            options: .regularExpression
        ) else { return nil }
        return String(filename[range])
    }

    private func fallbackTitle(projectPath: String?) -> String {
        guard let projectPath else { return "Untitled Codex session" }
        return "\(URL(fileURLWithPath: projectPath).lastPathComponent) session"
    }
}

private final class CompressedSessionCache: @unchecked Sendable {
    static let shared = CompressedSessionCache()

    private let lock = NSLock()
    private var values: [String: AssistantSession] = [:]

    func value(for key: String) -> AssistantSession? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ session: AssistantSession, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = session
    }
}

private extension AssistantSession {
    /// Codex can rename a thread after its file is compressed.
    func retitled(_ indexedTitle: String?) -> AssistantSession {
        guard let indexedTitle = indexedTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !indexedTitle.isEmpty, indexedTitle != title else { return self }
        var copy = AssistantSession(
            assistant: assistant, sessionID: sessionID, title: indexedTitle, summary: summary,
            projectPath: projectPath, gitBranch: gitBranch, model: model, createdAt: createdAt,
            updatedAt: updatedAt, messageCount: messageCount, fileSize: fileSize, sourceURL: sourceURL,
            sourceFormat: sourceFormat, isArchived: isArchived
        )
        copy.configDirectory = configDirectory
        return copy
    }
}
