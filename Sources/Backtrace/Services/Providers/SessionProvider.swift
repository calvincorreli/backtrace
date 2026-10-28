import Foundation

protocol SessionProvider {
    var assistant: AssistantKind { get }
    func sessions() throws -> [AssistantSession]
}

enum FileMetadata {
    static func values(for url: URL) -> (modified: Date, size: Int64) {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return (
            values?.contentModificationDate ?? .distantPast,
            Int64(values?.fileSize ?? 0)
        )
    }

    static func files(
        below root: URL,
        extensions: Set<String>,
        excludingPathComponents: Set<String> = []
    ) -> [URL] {
        // The enumerator yields nothing for a root that is itself a symlink,
        // which is how histories synced from another folder are laid out.
        let root = root.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var result: [URL] = []
        for case let url as URL in enumerator {
            if Task.isCancelled { break }
            if !excludingPathComponents.isDisjoint(with: Set(url.pathComponents)) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                result.append(url)
            }
        }
        return result
    }
}

enum SessionText {
    /// Older Codex versions record a conversation as `user_message` and
    /// `agent_message` events. Newer ones record `message` response items
    /// with a role, and some files hold both forms of the same message.
    static func codexRole(of object: [String: Any]) -> TranscriptRole? {
        guard let payload = object["payload"] as? [String: Any] else { return nil }
        switch payload["type"] as? String {
        case "user_message": return .user
        case "agent_message": return .assistant
        case "message" where object["type"] as? String == "response_item":
            switch payload["role"] as? String {
            case "user": return .user
            case "assistant": return .assistant
            default: return nil
            }
        default: return nil
        }
    }

    static func firstPrompt(in objects: [[String: Any]], assistant: AssistantKind) -> String? {
        for object in objects {
            if let value = messageText(from: object, assistant: assistant, requestedRole: .user),
               value.isUsefulPrompt {
                return value.compactWhitespace
            }
        }
        return nil
    }

    static func messageText(
        from object: [String: Any],
        assistant: AssistantKind,
        requestedRole: TranscriptRole? = nil
    ) -> String? {
        switch assistant {
        case .codex:
            guard let payload = object["payload"] as? [String: Any] else { return nil }
            guard let role = codexRole(of: object),
                  requestedRole == nil || requestedRole == role else { return nil }
            if payload["type"] as? String == "message" {
                // Codex also records the context it injects as user messages.
                guard let text = JSONValue.textContent(payload["content"]),
                      role != .user || text.isUsefulPrompt else { return nil }
                return text
            }
            return JSONValue.string(payload, keys: ["message", "text"])

        case .claude:
            guard object["isMeta"] as? Bool != true else { return nil }
            let type = object["type"] as? String
            let role: TranscriptRole? = type == "user" ? .user : (type == "assistant" ? .assistant : nil)
            guard let role, requestedRole == nil || requestedRole == role,
                  let message = object["message"] as? [String: Any] else { return nil }
            return JSONValue.textContent(message["content"])

        case .grok, .openCode:
            let explicitRole = JSONValue.string(object, keys: ["role", "type"])
            let role: TranscriptRole?
            switch explicitRole {
            case "user", "user_message", "human": role = .user
            case "assistant", "agent", "agent_message": role = .assistant
            case "tool", "tool_result", "tool_use": role = .tool
            case "system": role = .system
            default: role = nil
            }
            guard let role, requestedRole == nil || requestedRole == role else { return nil }
            if let message = object["message"] as? [String: Any] {
                return JSONValue.textContent(message["content"])
                    ?? JSONValue.string(message, keys: ["text", "message"])
            }
            return JSONValue.textContent(object["content"])
                ?? JSONValue.string(object, keys: ["text", "message", "prompt"])
        }
    }
}
