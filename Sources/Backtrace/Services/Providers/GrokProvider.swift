import Foundation

struct GrokProvider: SessionProvider {
    let assistant = AssistantKind.grok
    let roots: [URL]

    init(home: URL) {
        roots = AssistantKind.grok.defaultHistoryRoots(home: home)
    }

    init(roots: [URL]) {
        self.roots = roots
    }

    func sessions() throws -> [AssistantSession] {
        let candidates = roots.flatMap {
            FileMetadata.files(below: $0, extensions: ["jsonl", "json"])
        }
        var bestByID: [String: AssistantSession] = [:]

        // Grok Build keeps one folder per session, with the title, project and
        // branch in `summary.json`. That file is authoritative: the transcript
        // beside it opens with injected context, not with what the user typed.
        var sessionFolders: Set<String> = []
        var promptsByFolder: [String: [String: String]] = [:]
        for url in candidates where url.lastPathComponent == Self.summaryFilename {
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  let summary = JSONValue.object(from: data),
                  let id = (summary["info"] as? [String: Any]).flatMap({ JSONValue.string($0, keys: ["id"]) })
            else { continue }
            let folder = url.deletingLastPathComponent()
            sessionFolders.insert(folder.path)

            let history = folder.deletingLastPathComponent().appendingPathComponent(Self.promptHistoryFilename)
            if promptsByFolder[history.path] == nil {
                promptsByFolder[history.path] = firstPrompts(at: history)
            }
            if let session = session(
                id: id,
                summary: summary,
                folder: folder,
                summaryURL: url,
                firstPrompt: promptsByFolder[history.path]?[id]
            ) {
                bestByID[id] = session
            }
        }

        for url in candidates {
            guard url.lastPathComponent != Self.promptHistoryFilename,
                  !isInside(sessionFolders, url) else { continue }
            guard let candidate = try? session(at: url) else { continue }
            if let existing = bestByID[candidate.sessionID] {
                let candidateScore = metadataScore(candidate)
                let existingScore = metadataScore(existing)
                if candidateScore > existingScore || candidate.updatedAt > existing.updatedAt {
                    bestByID[candidate.sessionID] = candidate
                }
            } else {
                bestByID[candidate.sessionID] = candidate
            }
        }
        return Array(bestByID.values)
    }

    private static let summaryFilename = "summary.json"
    private static let promptHistoryFilename = "prompt_history.jsonl"
    private static let transcriptFilename = "chat_history.jsonl"

    /// Returns nil for a session that was opened and never used: Grok has not
    /// titled it and the user typed nothing into it.
    private func session(
        id: String,
        summary: [String: Any],
        folder: URL,
        summaryURL: URL,
        firstPrompt: String?
    ) -> AssistantSession? {
        let generatedTitle = JSONValue.string(summary, keys: ["generated_title", "session_summary"])?
            .compactWhitespace
        guard let title = [generatedTitle, firstPrompt?.clipped(to: 92)]
            .compactMap({ $0 }).first(where: { !$0.isEmpty }) else { return nil }

        let recap = JSONValue.string(summary, keys: ["last_recap", "last_turn_summary"])?.compactWhitespace
        let transcript = folder.appendingPathComponent(Self.transcriptFilename)
        let hasTranscript = FileManager.default.fileExists(atPath: transcript.path)
        let sourceURL = hasTranscript ? transcript : summaryURL
        let file = FileMetadata.values(for: sourceURL)
        let updated = ["updated_at", "last_active_at"].compactMap { FlexibleDateParser.parse(summary[$0]) }.first

        return AssistantSession(
            assistant: .grok,
            sessionID: id,
            title: title,
            summary: (recap ?? firstPrompt)?.clipped(to: 260),
            projectPath: (summary["info"] as? [String: Any]).flatMap { JSONValue.string($0, keys: ["cwd"]) },
            gitBranch: JSONValue.string(summary, keys: ["head_branch"]),
            model: JSONValue.string(summary, keys: ["current_model_id"]),
            createdAt: FlexibleDateParser.parse(summary["created_at"]),
            updatedAt: max(updated ?? .distantPast, file.modified),
            messageCount: (summary["num_chat_messages"] as? NSNumber)?.intValue,
            fileSize: file.size,
            sourceURL: sourceURL,
            sourceFormat: .grokJSON,
            isArchived: false
        )
    }

    /// The first prompt typed into each session, from the per-project history
    /// Grok keeps beside the session folders.
    private func firstPrompts(at url: URL) -> [String: String] {
        guard let (objects, _) = try? JSONLReader.objects(at: url) else { return [:] }
        var result: [String: String] = [:]
        for object in objects where object["is_bash"] as? Bool != true {
            guard let id = JSONValue.string(object, keys: ["session_id"]), result[id] == nil,
                  let prompt = JSONValue.string(object, keys: ["prompt"])?.compactWhitespace,
                  !prompt.isEmpty else { continue }
            result[id] = prompt
        }
        return result
    }

    private func isInside(_ folders: Set<String>, _ url: URL) -> Bool {
        guard !folders.isEmpty else { return false }
        var directory = url.deletingLastPathComponent()
        while directory.path.count > 1 {
            if folders.contains(directory.path) { return true }
            directory.deleteLastPathComponent()
        }
        return false
    }

    private func session(at url: URL) throws -> AssistantSession? {
        let objects: [[String: Any]]
        if url.pathExtension == "jsonl" {
            objects = try JSONLReader.sampledObjects(at: url)
        } else {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            if let object = JSONValue.object(from: data) {
                if let messages = object["messages"] as? [[String: Any]] {
                    objects = [object] + messages
                } else {
                    objects = [object]
                }
            } else if let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                objects = array
            } else {
                return nil
            }
        }
        guard !objects.isEmpty else { return nil }

        let nested = objects.flatMap { object -> [[String: Any]] in
            [object, object["payload"] as? [String: Any], object["session"] as? [String: Any]]
                .compactMap { $0 }
        }
        let id = nested.lazy.compactMap {
            JSONValue.string($0, keys: ["sessionId", "session_id", "id"])
        }.first ?? idFromFilename(url)
        guard let id, id.count >= 8 else { return nil }

        let projectPath = nested.lazy.compactMap {
            JSONValue.string($0, keys: ["cwd", "workingDirectory", "workspacePath", "directory"])
        }.first
        let explicitTitle = nested.lazy.compactMap {
            JSONValue.string($0, keys: ["title", "name", "sessionTitle"])
        }.first
        let prompt = SessionText.firstPrompt(in: objects, assistant: .grok)
        guard projectPath != nil || explicitTitle != nil || prompt != nil else { return nil }

        let dates = nested.flatMap { object in
            ["timestamp", "createdAt", "created_at", "updatedAt", "updated_at"]
                .compactMap { FlexibleDateParser.parse(object[$0]) }
        }
        let file = FileMetadata.values(for: url)

        return AssistantSession(
            assistant: .grok,
            sessionID: id,
            title: explicitTitle ?? prompt?.clipped(to: 92) ?? "Untitled Grok session",
            summary: prompt?.clipped(to: 260),
            projectPath: projectPath,
            gitBranch: nested.lazy.compactMap { JSONValue.string($0, keys: ["gitBranch", "branch"]) }.first,
            model: nested.lazy.compactMap { JSONValue.string($0, keys: ["model", "modelId", "model_id"]) }.first,
            createdAt: dates.min(),
            updatedAt: max(file.modified, dates.max() ?? .distantPast),
            messageCount: nil,
            fileSize: file.size,
            sourceURL: url,
            sourceFormat: .grokJSON,
            isArchived: false
        )
    }

    private func idFromFilename(_ url: URL) -> String? {
        let value = url.deletingPathExtension().lastPathComponent
        return value == "metadata" || value == "events" || value == "messages" ? url.deletingLastPathComponent().lastPathComponent : value
    }

    private func metadataScore(_ session: AssistantSession) -> Int {
        [session.projectPath, session.summary, session.model, session.gitBranch]
            .compactMap { $0 }.count
    }
}
