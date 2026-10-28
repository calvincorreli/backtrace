import Foundation

enum SessionSourceFormat: String, Codable, Hashable, Sendable {
    case codexJSONL
    case claudeJSONL
    case grokJSON
    case openCodeLegacy
    case openCodeCLI
}

struct AssistantSession: Identifiable, Hashable, Sendable {
    let assistant: AssistantKind
    let sessionID: String
    let title: String
    let summary: String?
    let projectPath: String?
    let gitBranch: String?
    let model: String?
    let createdAt: Date?
    let updatedAt: Date
    let messageCount: Int?
    let fileSize: Int64
    let sourceURL: URL
    let sourceFormat: SessionSourceFormat
    let isArchived: Bool
    /// Claude Code sessions remember which config directory they came from, so
    /// the resume command can point Claude Code back at the same one.
    var configDirectory: ClaudeConfigDirectory? = nil

    var id: String {
        let base = "\(assistant.rawValue):\(sessionID)"
        // Preserve IDs for the default profile so existing favorites and tags
        // survive, while keeping copied sessions in other profiles distinct.
        guard assistant == .claude,
              let configDirectory,
              !configDirectory.isDefault else { return base }
        return "\(base):\(configDirectory.id)"
    }

    /// A session counts as active while its transcript is still being written.
    static let activeWindow: TimeInterval = 180

    func isActive(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(updatedAt) < Self.activeWindow
    }

    var projectName: String {
        guard let projectPath, !projectPath.isEmpty else { return "Unknown project" }
        return URL(fileURLWithPath: projectPath).lastPathComponent
    }

    var resumeCommand: String { resumeCommand(launcher: nil) }

    /// The command that resumes this session. A launcher is a shell alias for
    /// the assistant; it replaces the executable and carries its own settings.
    func resumeCommand(launcher: String?) -> String {
        let id = sessionID.shellQuoted
        let launch: String
        switch assistant {
        case .codex:
            let codex = launcher ?? "codex"
            launch = isArchived
                ? "codex unarchive \(id) && \(codex) resume \(id)"
                : "\(codex) resume \(id)"
        case .claude:
            if let launcher {
                launch = "\(launcher) --resume \(id)"
            } else {
                // Claude Code reads one config directory at a time, so a session
                // from a non-default profile only resumes with the variable set.
                let scope = configDirectory.flatMap { directory in
                    directory.isDefault ? nil : "CLAUDE_CONFIG_DIR=\(directory.url.path.shellQuoted) "
                } ?? ""
                launch = "\(scope)claude --resume \(id)"
            }
        case .grok:
            launch = "\(launcher ?? "grok") --resume \(id)"
        case .openCode:
            launch = "\(launcher ?? "opencode") --session \(id)"
        }

        guard let projectPath, !projectPath.isEmpty else { return launch }
        return "cd \(projectPath.shellQuoted) && \(launch)"
    }

    var searchableText: String {
        [
            title,
            summary,
            projectPath,
            gitBranch,
            model,
            sessionID,
            assistant.displayName,
            configDirectory.map(\.name)
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .foldedForSearch
    }
}

enum TranscriptRole: String, Hashable, Sendable {
    case user
    case assistant
    case tool
    case system
}

struct TranscriptEntry: Identifiable, Hashable, Sendable {
    let id: String
    let role: TranscriptRole
    let text: String
    let timestamp: Date?
}

struct TranscriptPreview: Sendable {
    let entries: [TranscriptEntry]
    let isTruncated: Bool

    static let empty = TranscriptPreview(entries: [], isTruncated: false)
}

struct ScanResult: Sendable {
    let installations: [AssistantInstallation]
    let sessions: [AssistantSession]
    let claudeConfigDirectories: [ClaudeConfigDirectory]
    let warnings: [String]
}
