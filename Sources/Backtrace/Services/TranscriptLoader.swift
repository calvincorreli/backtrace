import Foundation

struct TranscriptLoader: Sendable {
    let installations: [AssistantInstallation]
    /// The preview shows the start of a session; a handoff needs all of it.
    var messageLimit = 160

    func load(_ session: AssistantSession) async -> TranscriptPreview {
        let worker = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                switch session.sourceFormat {
                case .codexJSONL, .claudeJSONL:
                    return try loadJSONL(session)
                case .grokJSON:
                    return try loadGrok(session)
                case .openCodeLegacy:
                    return try loadOpenCodeLegacy(session)
                case .openCodeCLI:
                    return try await loadOpenCodeCLI(session)
                }
            } catch {
                return .empty
            }
        }

        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func loadJSONL(_ session: AssistantSession) throws -> TranscriptPreview {
        var messageCount = 0
        let (objects, wasCutShort) = try JSONLReader.objects(at: session.sourceURL) { object, _ in
            if SessionText.messageText(from: object, assistant: session.assistant) != nil {
                messageCount += 1
            }
            return Task.isCancelled || messageCount >= messageLimit
        }
        try Task.checkCancellation()
        var entries: [TranscriptEntry] = []
        for (index, object) in objects.enumerated() {
            try Task.checkCancellation()
            guard let text = SessionText.messageText(from: object, assistant: session.assistant)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            let role = role(for: object, assistant: session.assistant) ?? .system
            // Codex can record one message as both an event and a response item.
            if let previous = entries.last(where: { $0.role == role }), previous.text == text.clipped(to: 8_000) {
                continue
            }
            entries.append(TranscriptEntry(
                id: "\(session.id):\(index)",
                role: role,
                text: text.clipped(to: 8_000),
                timestamp: FlexibleDateParser.parse(object["timestamp"])
            ))
        }
        return TranscriptPreview(entries: entries, isTruncated: wasCutShort)
    }

    private func loadGrok(_ session: AssistantSession) throws -> TranscriptPreview {
        if session.sourceURL.pathExtension == "jsonl" {
            return try loadJSONL(session)
        }
        try Task.checkCancellation()
        let data = try Data(contentsOf: session.sourceURL, options: [.mappedIfSafe])
        try Task.checkCancellation()
        var objects: [[String: Any]] = []
        if let object = JSONValue.object(from: data) {
            objects = (object["messages"] as? [[String: Any]]) ?? [object]
        } else if let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            objects = array
        }
        var entries: [TranscriptEntry] = []
        for (index, object) in objects.prefix(messageLimit).enumerated() {
            try Task.checkCancellation()
            guard let text = SessionText.messageText(from: object, assistant: .grok), !text.isEmpty else { continue }
            entries.append(TranscriptEntry(
                id: "\(session.id):\(index)",
                role: role(for: object, assistant: .grok) ?? .system,
                text: text.clipped(to: 8_000),
                timestamp: FlexibleDateParser.parse(object["timestamp"])
            ))
        }
        return TranscriptPreview(entries: entries, isTruncated: objects.count > messageLimit)
    }

    private func loadOpenCodeLegacy(_ session: AssistantSession) throws -> TranscriptPreview {
        var storage = session.sourceURL.deletingLastPathComponent()
        while storage.path != "/", storage.lastPathComponent != "storage" {
            storage.deleteLastPathComponent()
        }
        guard storage.lastPathComponent == "storage" else {
            return TranscriptPreview(entries: [], isTruncated: false)
        }

        let messageRoot = storage.appendingPathComponent("message/\(session.sessionID)", isDirectory: true)
        var messages: [([String: Any], URL)] = []
        for url in FileMetadata.files(below: messageRoot, extensions: ["json"]) {
            try Task.checkCancellation()
            guard let data = try? Data(contentsOf: url), let object = JSONValue.object(from: data) else { continue }
            messages.append((object, url))
        }
        try Task.checkCancellation()
        messages.sort {
                FlexibleDateParser.parse(($0.0["time"] as? [String: Any])?["created"]) ?? .distantPast
                    < FlexibleDateParser.parse(($1.0["time"] as? [String: Any])?["created"]) ?? .distantPast
        }

        var entries: [TranscriptEntry] = []
        for (index, pair) in messages.prefix(messageLimit).enumerated() {
            try Task.checkCancellation()
            let message = pair.0
            guard let messageID = message["id"] as? String,
                  let roleString = message["role"] as? String else { continue }
            let partRoot = storage.appendingPathComponent("part/\(messageID)", isDirectory: true)
            var texts: [String] = []
            for url in FileMetadata.files(below: partRoot, extensions: ["json"]) {
                try Task.checkCancellation()
                guard let data = try? Data(contentsOf: url),
                      let part = JSONValue.object(from: data),
                      (part["type"] as? String) == "text",
                      let text = part["text"] as? String else { continue }
                texts.append(text)
            }
            guard !texts.isEmpty else { continue }
            let created = FlexibleDateParser.parse((message["time"] as? [String: Any])?["created"])
            entries.append(TranscriptEntry(
                id: "\(session.id):\(index)",
                role: roleString == "user" ? .user : .assistant,
                text: texts.joined(separator: "\n").clipped(to: 8_000),
                timestamp: created
            ))
        }
        return TranscriptPreview(entries: entries, isTruncated: messages.count > messageLimit)
    }

    private func loadOpenCodeCLI(_ session: AssistantSession) async throws -> TranscriptPreview {
        try Task.checkCancellation()
        guard let executable = installations.first(where: { $0.kind == .openCode })?.executableURL,
              let result = await ProcessRunner.runCancellable(
                executable: executable,
                arguments: ["export", session.sessionID],
                currentDirectory: session.projectPath.map { URL(fileURLWithPath: $0) },
                extraEnvironment: ["OPENCODE_DISABLE_AUTOUPDATE": "true"]
              ), result.status == 0,
              let root = JSONValue.object(from: result.output) else {
            try Task.checkCancellation()
            return .empty
        }

        let messages = root["messages"] as? [[String: Any]] ?? []
        var entries: [TranscriptEntry] = []
        for (index, wrapper) in messages.prefix(messageLimit).enumerated() {
            try Task.checkCancellation()
            let info = wrapper["info"] as? [String: Any] ?? wrapper
            let roleString = info["role"] as? String ?? "system"
            let parts = wrapper["parts"] as? [[String: Any]] ?? []
            let text = parts.compactMap { part -> String? in
                guard (part["type"] as? String) == "text" else { return nil }
                return part["text"] as? String
            }.joined(separator: "\n")
            guard !text.isEmpty else { continue }
            entries.append(TranscriptEntry(
                id: "\(session.id):\(index)",
                role: roleString == "user" ? .user : .assistant,
                text: text.clipped(to: 8_000),
                timestamp: FlexibleDateParser.parse((info["time"] as? [String: Any])?["created"])
            ))
        }
        return TranscriptPreview(entries: entries, isTruncated: messages.count > messageLimit)
    }

    private func role(for object: [String: Any], assistant: AssistantKind) -> TranscriptRole? {
        switch assistant {
        case .codex:
            return SessionText.codexRole(of: object)
        case .claude:
            switch object["type"] as? String {
            case "user": return .user
            case "assistant": return .assistant
            default: return nil
            }
        case .grok, .openCode:
            switch JSONValue.string(object, keys: ["role", "type"]) {
            case "user", "user_message", "human": return .user
            case "assistant", "agent", "agent_message": return .assistant
            case "tool", "tool_use", "tool_result": return .tool
            case "system": return .system
            default: return nil
            }
        }
    }
}
