import AppKit
import Foundation

/// Finds new commits on the GitHub copy of Backtrace and rebuilds the app from its source checkout.
///
/// `scripts/build-app.sh` writes the source folder and commit into Info.plist. The updater fetches
/// that folder's upstream branch, and counts the commits the running app does not have.
struct SourceBuild: Sendable, Equatable {
    let directory: URL
    let commit: String

    static func current(bundle: Bundle = .main) -> SourceBuild? {
        guard let path = bundle.object(forInfoDictionaryKey: "BacktraceSourcePath") as? String,
              let commit = bundle.object(forInfoDictionaryKey: "BacktraceSourceCommit") as? String,
              !path.isEmpty, !commit.isEmpty
        else { return nil }
        return SourceBuild(directory: URL(fileURLWithPath: path, isDirectory: true), commit: commit)
    }
}

struct AvailableUpdate: Sendable, Equatable {
    let commit: String
    let changes: [String]
}

enum AppUpdateError: LocalizedError {
    case failed(step: String, output: String)

    var errorDescription: String? {
        switch self {
        case let .failed(step, output):
            let tail = output.split(separator: "\n").suffix(12).joined(separator: "\n")
            return tail.isEmpty ? "\(step) failed." : "\(step) failed:\n\n\(tail)"
        }
    }
}

enum SourceUpdater {
    static let git = URL(fileURLWithPath: "/usr/bin/git")

    /// Never let git stop and wait for a password or a host-key answer.
    static let quietGit = [
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_SSH_COMMAND": "ssh -o BatchMode=yes -o ConnectTimeout=15",
    ]

    static func check(_ build: SourceBuild) throws -> AvailableUpdate? {
        try runGit(["fetch", "--quiet", "origin"], in: build.directory, step: "Checking GitHub")
        let upstream = try runGit(["rev-parse", "@{upstream}"], in: build.directory, step: "Finding the upstream branch")
        let log = try runGit(
            ["log", "--format=%s", "\(build.commit)..\(upstream)"],
            in: build.directory,
            step: "Listing new changes"
        )
        let changes = log.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return changes.isEmpty ? nil : AvailableUpdate(commit: upstream, changes: changes)
    }

    /// Pulls the new commits and builds a fresh app. Returns a copy of the app outside the checkout.
    static func pullAndBuild(_ build: SourceBuild, stagingDirectory: URL) throws -> URL {
        // dist/ is tracked, and every local build changes it.
        try runGit(["checkout", "--", "dist"], in: build.directory, step: "Cleaning the old build")
        try runGit(["pull", "--ff-only", "--quiet"], in: build.directory, step: "Getting the new version")

        var environment = quietGit
        let xcode = "/Applications/Xcode.app/Contents/Developer"
        if FileManager.default.fileExists(atPath: xcode) {
            environment["DEVELOPER_DIR"] = xcode
        }
        let script = build.directory.appendingPathComponent("scripts/build-app.sh")
        try run(URL(fileURLWithPath: "/bin/bash"), [script.path], in: build.directory, environment: environment, step: "Building")

        let staged = stagingDirectory.appendingPathComponent("Backtrace.app")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try run(
            URL(fileURLWithPath: "/usr/bin/ditto"),
            [build.directory.appendingPathComponent("dist/Backtrace.app").path, staged.path],
            in: build.directory,
            step: "Copying the new app"
        )
        try runGit(["checkout", "--", "dist"], in: build.directory, step: "Cleaning the build folder")
        return staged
    }

    /// Waits for this process to quit, swaps the app, and opens the new one.
    static func installAfterQuit(staged: URL, installed: URL) throws {
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf "$3" && /usr/bin/ditto "$2" "$3" && /bin/rm -rf "$2"
        /usr/bin/open "$3"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "backtrace-update", String(ProcessInfo.processInfo.processIdentifier), staged.path, installed.path]
        try process.run()
    }

    @discardableResult
    private static func runGit(_ arguments: [String], in directory: URL, step: String) throws -> String {
        try run(git, arguments, in: directory, environment: quietGit, step: step)
    }

    @discardableResult
    private static func run(
        _ executable: URL,
        _ arguments: [String],
        in directory: URL,
        environment: [String: String] = [:],
        step: String
    ) throws -> String {
        guard let result = ProcessRunner.run(
            executable: executable,
            arguments: arguments,
            currentDirectory: directory,
            extraEnvironment: environment
        ) else {
            throw AppUpdateError.failed(step: step, output: "Could not start \(executable.lastPathComponent).")
        }
        guard result.status == 0 else {
            throw AppUpdateError.failed(step: step, output: result.text)
        }
        return result.text
    }
}

@MainActor
final class AppUpdater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableUpdate)
        case updating
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published var isShowingUpdate = false
    @Published private(set) var lastChecked: Date?

    let build: SourceBuild?
    private static let checkInterval: TimeInterval = 6 * 60 * 60

    init(build: SourceBuild? = .current()) {
        self.build = build
    }

    var availableUpdate: AvailableUpdate? {
        if case let .available(update) = state { return update }
        return nil
    }

    var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        guard let build else { return "Version \(version)" }
        return "Version \(version) (\(build.commit.prefix(7)))"
    }

    /// Checks at launch and then every few hours. Quiet unless a new version exists.
    func checkPeriodically() async {
        while !Task.isCancelled {
            await check(userInitiated: false)
            try? await Task.sleep(for: .seconds(Self.checkInterval))
        }
    }

    func check(userInitiated: Bool) async {
        guard let build else {
            if userInitiated {
                state = .failed("This copy of Backtrace was not built by scripts/build-app.sh, so it does not know its source folder.")
                isShowingUpdate = true
            }
            return
        }
        guard state != .updating, state != .checking else { return }

        state = .checking
        if userInitiated { isShowingUpdate = true }
        let result = await Task.detached(priority: .utility) {
            Result { try SourceUpdater.check(build) }
        }.value
        lastChecked = Date()

        switch result {
        case let .success(update?):
            state = .available(update)
            if userInitiated { isShowingUpdate = true }
        case .success(nil):
            state = .upToDate
            if userInitiated { isShowingUpdate = true }
        case let .failure(error):
            // A failed background check (offline, asleep) should not interrupt anyone.
            state = userInitiated ? .failed(error.localizedDescription) : .idle
            if userInitiated { isShowingUpdate = true }
        }
    }

    func installUpdate() {
        guard let build, state != .updating else { return }
        state = .updating

        let staging = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backtrace/Update", isDirectory: true)
        let installed = Bundle.main.bundleURL

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try SourceUpdater.pullAndBuild(build, stagingDirectory: staging) }
            }.value

            do {
                let staged = try result.get()
                try SourceUpdater.installAfterQuit(staged: staged, installed: installed)
                NSApp.terminate(nil)
            } catch {
                state = .failed(error.localizedDescription)
                isShowingUpdate = true
            }
        }
    }
}
