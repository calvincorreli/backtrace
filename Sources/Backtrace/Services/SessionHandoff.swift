import Foundation

/// Turns a session from one assistant into a prompt that another assistant can
/// pick up from. No assistant can resume another's session file, so the handoff
/// carries the conversation as context for a new session.
enum SessionHandoff {
    static let messageCharacterLimit = 4_000
    static let conversationCharacterBudget = 120_000

    struct Message: Equatable {
        let role: TranscriptRole
        let text: String
    }

    /// What the user typed and what the assistant answered, without tool
    /// output, system prompts, or context the source assistant injected.
    static func messages(from entries: [TranscriptEntry]) -> [Message] {
        entries.compactMap { entry in
            guard entry.role == .user || entry.role == .assistant else { return nil }
            var text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if entry.role == .user {
                guard text.isUsefulPrompt else { return nil }
                text = text.removingWrapper(tag: "user_query")
            }
            guard !text.isEmpty else { return nil }
            return Message(role: entry.role, text: text.clipped(to: messageCharacterLimit))
        }
    }

    /// Keeps the opening request and the most recent messages when the
    /// conversation is too long to hand over whole.
    static func trimmed(_ messages: [Message], budget: Int = conversationCharacterBudget) -> (kept: [Message], omitted: Int) {
        guard messages.reduce(0, { $0 + $1.text.count }) > budget, let first = messages.first else {
            return (messages, 0)
        }
        var remaining = budget - first.text.count
        var tail: [Message] = []
        for message in messages.dropFirst().reversed() {
            guard message.text.count <= remaining else { break }
            remaining -= message.text.count
            tail.append(message)
        }
        return ([first] + tail.reversed(), messages.count - 1 - tail.count)
    }

    enum Purpose {
        /// A prompt for another assistant to continue the work.
        case handoff
        /// A readable copy of the conversation for other people.
        case share
    }

    static func document(for session: AssistantSession, transcript: TranscriptPreview, purpose: Purpose = .handoff) -> String {
        let source = session.assistant.displayName
        let (messages, omitted) = trimmed(messages(from: transcript.entries))

        var lines: [String]
        switch purpose {
        case .handoff:
            lines = [
                "# Handoff: \(session.title)",
                "",
                "This is a handoff from a \(source) session. Continue that work here.",
                "",
                "1. Read the conversation below. It is context from the earlier session, not a new request.",
                "2. Check the current state of the working directory, because the work may have moved on.",
                "3. Tell me in a few lines where the work stopped and what the next step is. Then wait for my instruction."
            ]
        case .share:
            lines = [
                "# \(session.title)",
                "",
                "A \(source) session: the prompts and the replies. Tool output is left out."
            ]
        }
        lines += [
            "",
            "## Session",
            "",
            "- Assistant: \(source)" + (session.model.map { " (\($0))" } ?? "")
        ]
        if let projectPath = session.projectPath { lines.append("- Project: \(projectPath)") }
        if let gitBranch = session.gitBranch { lines.append("- Branch: \(gitBranch)") }
        lines.append("- Last active: \(session.updatedAt.formatted(.iso8601))")
        lines.append("- Session ID: \(session.sessionID)")
        if purpose == .handoff { lines.append("- Full transcript: \(session.sourceURL.path)") }

        if let summary = session.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty,
           messages.first.map({ !$0.text.compactWhitespace.hasPrefix(summary.prefix(60)) }) ?? true {
            lines += ["", "## Summary", "", summary]
        }

        lines += ["", "## Conversation"]
        if messages.isEmpty {
            lines += ["", purpose == .handoff
                ? "No readable messages. Read the full transcript file listed above."
                : "No readable messages."]
        }
        for (index, message) in messages.enumerated() {
            lines += ["", "### \(message.role == .user ? "User" : source)", "", message.text]
            if index == 0, omitted > 0 {
                lines += ["", purpose == .handoff
                    ? "_\(omitted) earlier messages are left out. They are in the full transcript file._"
                    : "_\(omitted) earlier messages are left out._"]
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func write(_ document: String, for session: AssistantSession, target: AssistantKind, directory: URL? = nil) throws -> URL {
        let folder = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backtrace/Handoffs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "\(session.assistant.rawValue)-to-\(target.rawValue)-\(session.sessionID.prefix(13)).md"
            .replacingOccurrences(of: "/", with: "-")
        let url = folder.appendingPathComponent(name)
        try document.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Starts the target assistant in the session's project with the handoff
    /// as its first prompt, so the assistant needs no permission to read a
    /// file outside the project.
    static func launchCommand(for target: AssistantKind, session: AssistantSession, handoffFile: URL) -> String {
        let prompt = "\"$(cat \(handoffFile.path.shellQuoted))\""
        let launch: String
        switch target {
        case .codex, .claude, .grok:
            launch = "\(target.executableName) \(prompt)"
        case .openCode:
            launch = "\(target.executableName) --prompt \(prompt)"
        }
        guard let projectPath = session.projectPath, !projectPath.isEmpty else { return launch }
        return "cd \(projectPath.shellQuoted) && \(launch)"
    }
}

private extension String {
    func removingWrapper(tag: String) -> String {
        let open = "<\(tag)>", close = "</\(tag)>"
        guard hasPrefix(open), hasSuffix(close) else { return self }
        return String(dropFirst(open.count).dropLast(close.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
