import Foundation

extension String {
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    var foldedForSearch: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    var compactWhitespace: String {
        split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    func clipped(to length: Int) -> String {
        guard count > length else { return self }
        return String(prefix(max(0, length - 1))) + "…"
    }

    var isUsefulPrompt: Bool {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        let ignoredPrefixes = [
            "<environment_context>",
            "<system-reminder>",
            "<user_info>",
            "<permissions instructions>",
            "# AGENTS.md instructions"
        ]
        return !ignoredPrefixes.contains { value.hasPrefix($0) }
    }
}
