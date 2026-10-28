import Foundation

/// A shell alias that starts one of the assistants, such as `ccl` for Claude
/// Code with a separate config directory. Only the name is kept: alias bodies
/// can hold tokens, and the shell expands the alias when the command runs.
struct AssistantLauncher: Hashable, Sendable, Identifiable {
    let name: String
    let kind: AssistantKind

    var id: String { name }
}

enum ShellAliasDetector {
    /// Asks the user's interactive shell for its aliases, so aliases defined
    /// in `.zshrc` or `.bashrc` are included.
    static func detect(environment: [String: String] = ProcessInfo.processInfo.environment) async -> [AssistantLauncher] {
        let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let task = Task {
            await ProcessRunner.runCancellable(executable: URL(fileURLWithPath: shell), arguments: ["-ic", "alias"])
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(8))
            task.cancel()
        }
        let result = await task.value
        timeout.cancel()
        guard let result else { return [] }
        return launchers(fromAliasOutput: result.text)
    }

    static func launchers(fromAliasOutput output: String) -> [AssistantLauncher] {
        var result: [AssistantLauncher] = []
        for line in output.split(whereSeparator: \.isNewline) {
            var entry = Substring(line)
            if entry.hasPrefix("alias ") { entry = entry.dropFirst("alias ".count) }
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let name = String(entry[..<equals])
            guard !name.isEmpty, !name.contains(where: \.isWhitespace),
                  let kind = assistant(startedBy: unquoted(entry[entry.index(after: equals)...])) else { continue }
            result.append(AssistantLauncher(name: name, kind: kind))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The assistant whose executable the alias runs as a command word.
    static func assistant(startedBy body: String) -> AssistantKind? {
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ";&|()"))
        let words = body.components(separatedBy: separators).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        }
        for word in words {
            let command = word.split(separator: "/").last.map(String.init) ?? word
            if let kind = AssistantKind.allCases.first(where: { $0.executableName == command }) {
                return kind
            }
        }
        return nil
    }

    private static func unquoted(_ value: Substring) -> String {
        guard value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") else { return String(value) }
        return String(value.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
    }
}
