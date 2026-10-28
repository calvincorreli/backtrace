import Foundation

/// A session shared as a secret GitHub gist.
struct SharedSession: Codable, Hashable, Sendable {
    let url: String
    let sharedAt: Date

    var gistID: String { URL(string: url)?.lastPathComponent ?? url }
}

/// Shares the clean copy of a session as a secret gist with the GitHub CLI.
/// Secret gists are unlisted, but anyone who has the link can read them.
enum GistSharer {
    enum Failure: LocalizedError {
        case missingCLI
        case command(String)

        var errorDescription: String? {
            switch self {
            case .missingCLI:
                "The GitHub CLI (gh) is not installed. Install it with `brew install gh`, then run `gh auth login`."
            case .command(let output):
                output.isEmpty ? "The GitHub CLI failed." : output
            }
        }
    }

    static func share(_ document: String, for session: AssistantSession) async throws -> SharedSession {
        let gh = try executable()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Backtrace-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(filename(for: session))
        try document.write(to: file, atomically: true, encoding: .utf8)

        let result = await ProcessRunner.runCancellable(
            executable: gh,
            arguments: ["gist", "create", "--desc", session.title, file.path]
        )
        guard let result, result.status == 0,
              let url = result.text.components(separatedBy: .newlines).last(where: { $0.hasPrefix("https://") })
        else { throw Failure.command(result?.text ?? "") }
        return SharedSession(url: url, sharedAt: Date())
    }

    static func delete(_ shared: SharedSession) async throws {
        let result = await ProcessRunner.runCancellable(
            executable: try executable(),
            arguments: ["gist", "delete", shared.gistID, "--yes"]
        )
        guard let result, result.status == 0 else { throw Failure.command(result?.text ?? "") }
    }

    /// A readable file name, so the gist page has a sensible title.
    static func filename(for session: AssistantSession) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let slug = session.title.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .unicodeScalars.filter { allowed.contains($0) }
            .map(String.init).joined()
            .split(separator: "-").joined(separator: "-")
        return "\(slug.isEmpty ? "session" : String(slug.prefix(60)))-\(session.sessionID.prefix(8)).md"
    }

    /// An app started from the Dock does not get the shell's PATH.
    private static func executable() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "\(home)/.local/bin/gh", "/usr/bin/gh"]
            where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw Failure.missingCLI
    }
}
