import Foundation

/// Reads a session file, decompressing it first when the assistant stored it
/// compressed. Codex compresses older sessions to `.jsonl.zst`.
enum SessionFileData {
    enum Failure: Error {
        case missingDecompressor
        case decompressionFailed
    }

    static func isSessionLog(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst")
    }

    static func read(_ url: URL) throws -> Data {
        guard url.pathExtension == "zst" else {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        }
        guard let zstd = zstdExecutable else { throw Failure.missingDecompressor }
        guard let result = ProcessRunner.run(executable: zstd, arguments: ["-dcq", url.path]),
              result.status == 0 else { throw Failure.decompressionFailed }
        return result.output
    }

    /// `zstd` ships with Homebrew; an app started from the Dock does not get the shell's PATH.
    static let zstdExecutable: URL? = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
        .map { URL(fileURLWithPath: $0) }
}
