import Foundation
import SQLite3
import XCTest
@testable import Backtrace

final class BacktraceCoreTests: XCTestCase {
    @MainActor
    func testAppearancePreferencePersists() throws {
        let suiteName = "BacktraceTests.Appearance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.appearance, .system)

        settings.appearance = .dark
        XCTAssertEqual(SettingsStore(defaults: defaults).appearance, .dark)

        settings.appearance = .light
        XCTAssertEqual(SettingsStore(defaults: defaults).appearance, .light)
    }

    func testSessionDatePresentationNeverDisplaysSeconds() throws {
        let date = Date(timeIntervalSince1970: 1_784_455_845)
        let secondsPattern = try NSRegularExpression(pattern: #"\d{1,2}:\d{2}:\d{2}"#)

        for value in [
            DatePresentation.dateTime(date),
            DatePresentation.time(date),
            DatePresentation.fullyQualified(date)
        ] {
            let range = NSRange(value.startIndex..., in: value)
            XCTAssertNil(secondsPattern.firstMatch(in: value, range: range), value)
        }
    }

    func testRelativeSessionDatesUseMinutePrecision() {
        let now = Date(timeIntervalSince1970: 1_784_455_845)
        XCTAssertEqual(DatePresentation.relative(now.addingTimeInterval(-42), relativeTo: now), "Now")
        XCTAssertEqual(DatePresentation.relative(now.addingTimeInterval(-125), relativeTo: now), "2 min ago")
        XCTAssertEqual(DatePresentation.relative(now.addingTimeInterval(3_650), relativeTo: now), "in 1 hr")
    }

    @MainActor
    func testSessionTagsPersistMultipleAssignmentsAndStayUnique() throws {
        let suiteName = "BacktraceTests.Tags.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = testSession(id: "tagged-session")
        let store = SessionStore(settings: SettingsStore(defaults: defaults), defaults: defaults)
        let important = try XCTUnwrap(
            store.createTag(named: "Important", color: .orange, assigningTo: session)
        )
        let followUp = try XCTUnwrap(
            store.createTag(named: "Follow Up", color: .blue, assigningTo: session)
        )

        XCTAssertEqual(Set(store.tags(for: session).map(\.id)), [important.id, followUp.id])

        let duplicate = try XCTUnwrap(
            store.createTag(named: "  important  ", color: .pink, assigningTo: session)
        )
        XCTAssertEqual(duplicate.id, important.id)
        XCTAssertEqual(store.tags.count, 2)

        let restored = SessionStore(settings: SettingsStore(defaults: defaults), defaults: defaults)
        XCTAssertEqual(Set(restored.tags(for: session).map(\.name)), ["Follow Up", "Important"])

        restored.toggleTag(important, for: session)
        XCTAssertEqual(restored.tags(for: session).map(\.id), [followUp.id])
        restored.deleteTag(followUp)
        XCTAssertTrue(restored.tags(for: session).isEmpty)

        let finalStore = SessionStore(settings: SettingsStore(defaults: defaults), defaults: defaults)
        XCTAssertEqual(finalStore.tags.map(\.name), ["Important"])
        XCTAssertTrue(finalStore.tags(for: session).isEmpty)
    }

    func testShellQuotingHandlesSpacesAndApostrophes() {
        XCTAssertEqual("/Users/me/My Project".shellQuoted, "'/Users/me/My Project'")
        XCTAssertEqual("Sam's repo".shellQuoted, "'Sam'\\''s repo'")
    }

    func testCodexProviderReadsMetadataAndIndexTitle() throws {
        let fixture = try FixtureDirectory()
        let sessions = fixture.url.appendingPathComponent("sessions/2026/07/19", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let id = "019f-1111-2222-3333-444444444444"
        let transcript = sessions.appendingPathComponent("rollout-2026-07-19T10-00-00-\(id).jsonl")
        try """
        {"timestamp":"2026-07-19T10:00:00.000Z","type":"session_meta","payload":{"id":"\(id)","timestamp":"2026-07-19T10:00:00.000Z","cwd":"/tmp/My Project","model_provider":"openai"}}
        {"timestamp":"2026-07-19T10:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"Build a fast session browser"}}
        {"timestamp":"2026-07-19T10:00:02.000Z","type":"event_msg","payload":{"type":"agent_message","message":"I will inspect the project."}}
        """.write(to: transcript, atomically: true, encoding: .utf8)
        let index = fixture.url.appendingPathComponent("session_index.jsonl")
        try "{\"id\":\"\(id)\",\"thread_name\":\"Backtrace app\",\"updated_at\":\"2026-07-19T10:00:02Z\"}\n"
            .write(to: index, atomically: true, encoding: .utf8)

        let provider = CodexProvider(roots: [fixture.url.appendingPathComponent("sessions")], indexURL: index)
        let value = try XCTUnwrap(provider.sessions().first)
        XCTAssertEqual(value.sessionID, id)
        XCTAssertEqual(value.title, "Backtrace app")
        XCTAssertEqual(value.projectPath, "/tmp/My Project")
        XCTAssertEqual(value.summary, "Build a fast session browser")
        XCTAssertEqual(value.resumeCommand, "cd '/tmp/My Project' && codex resume '\(id)'")
    }

    func testClaudeProviderPrefersCustomTitleAndBuildsScopedResumeCommand() throws {
        let fixture = try FixtureDirectory()
        let id = "a9c1570b-8550-45ca-b388-8417a7a8bd16"
        try fixture.writeClaudeSession(id: id, configDirectory: ".claude")

        let directory = ClaudeConfigDirectory(
            url: fixture.url.appendingPathComponent(".claude", isDirectory: true),
            source: .defaultLocation,
            isDefault: true
        )
        let value = try XCTUnwrap(ClaudeProvider(configDirectories: [directory]).sessions().first)
        XCTAssertEqual(value.title, "parser-investigation")
        XCTAssertEqual(value.gitBranch, "feature/history")
        XCTAssertEqual(value.model, "claude-sonnet")
        XCTAssertEqual(value.resumeCommand, "cd '/tmp/client' && claude --resume '\(id)'")
    }

    func testClaudeProviderReadsEveryProfileAndScopesResumeToItsConfigDirectory() throws {
        let fixture = try FixtureDirectory()
        let defaultID = "a9c1570b-8550-45ca-b388-8417a7a8bd16"
        let workID = "b1d2570b-8550-45ca-b388-8417a7a8bd17"
        try fixture.writeClaudeSession(id: defaultID, configDirectory: ".claude")
        try fixture.writeClaudeSession(id: workID, configDirectory: ".claude-work")

        let workURL = fixture.url.appendingPathComponent(".claude-work", isDirectory: true)
        let provider = ClaudeProvider(configDirectories: [
            ClaudeConfigDirectory(
                url: fixture.url.appendingPathComponent(".claude", isDirectory: true),
                source: .defaultLocation,
                isDefault: true
            ),
            ClaudeConfigDirectory(url: workURL, source: .added, isDefault: false)
        ])

        let sessions = try provider.sessions()
        XCTAssertEqual(Set(sessions.map(\.sessionID)), [defaultID, workID])

        let work = try XCTUnwrap(sessions.first { $0.sessionID == workID })
        XCTAssertEqual(work.configDirectory?.name, "work")
        XCTAssertEqual(
            work.resumeCommand,
            "cd '/tmp/client' && CLAUDE_CONFIG_DIR=\(workURL.path.shellQuoted) claude --resume '\(workID)'"
        )
        XCTAssertTrue(work.searchableText.contains("work"))
    }

    func testClaudeSessionsWithTheSameIDRemainDistinctAcrossProfiles() throws {
        let fixture = try FixtureDirectory()
        let id = "a9c1570b-8550-45ca-b388-8417a7a8bd16"
        try fixture.writeClaudeSession(id: id, configDirectory: ".claude")
        try fixture.writeClaudeSession(id: id, configDirectory: ".claude-work")

        let provider = ClaudeProvider(configDirectories: [
            ClaudeConfigDirectory(
                url: fixture.url.appendingPathComponent(".claude", isDirectory: true),
                source: .defaultLocation,
                isDefault: true
            ),
            ClaudeConfigDirectory(
                url: fixture.url.appendingPathComponent(".claude-work", isDirectory: true),
                source: .added,
                isDefault: false
            )
        ])

        let sessions = try provider.sessions()
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(Set(sessions.map(\.id)).count, 2)
        XCTAssertEqual(sessions.first(where: { $0.configDirectory?.isDefault == true })?.id, "claude:\(id)")
    }

    func testProvidersFollowASymlinkedSessionsRoot() throws {
        let fixture = try FixtureDirectory()
        let id = "a9c1570b-8550-45ca-b388-8417a7a8bd16"
        try fixture.writeClaudeSession(id: id, configDirectory: "Sync/claude")
        let config = fixture.url.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: config.appendingPathComponent("projects"),
            withDestinationURL: fixture.url.appendingPathComponent("Sync/claude/projects", isDirectory: true)
        )

        let directory = ClaudeConfigDirectory(url: config, source: .defaultLocation, isDefault: true)
        XCTAssertEqual(try ClaudeProvider(configDirectories: [directory]).sessions().map(\.sessionID), [id])
    }

    func testClaudeProfilesSharingOneSymlinkedProjectsFolderListEachSessionOnce() throws {
        let fixture = try FixtureDirectory()
        let id = "a9c1570b-8550-45ca-b388-8417a7a8bd16"
        try fixture.writeClaudeSession(id: id, configDirectory: ".claude")
        let other = fixture.url.appendingPathComponent(".claude-other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: other.appendingPathComponent("projects"),
            withDestinationURL: fixture.url.appendingPathComponent(".claude/projects", isDirectory: true)
        )

        let provider = ClaudeProvider(configDirectories: [
            ClaudeConfigDirectory(
                url: fixture.url.appendingPathComponent(".claude", isDirectory: true),
                source: .defaultLocation,
                isDefault: true
            ),
            ClaudeConfigDirectory(url: other, source: .environment, isDefault: false)
        ])

        let sessions = try provider.sessions()
        XCTAssertEqual(sessions.map(\.id), ["claude:\(id)"])
    }

    func testLoginShellEnvironmentReadsInteractiveZshConfiguration() throws {
        let fixture = try FixtureDirectory()
        let claudeDirectory = fixture.url.appendingPathComponent(".claude-work", isDirectory: true)
        let codexDirectory = fixture.url.appendingPathComponent(".codex-work", isDirectory: true)
        let zshrc = fixture.url.appendingPathComponent(".zshrc")
        try """
        export CLAUDE_CONFIG_DIR=\(claudeDirectory.path.shellQuoted)
        export CODEX_HOME=\(codexDirectory.path.shellQuoted)
        """.write(to: zshrc, atomically: true, encoding: .utf8)

        let values = LoginShellEnvironment.loadFromShell(
            extraEnvironment: ["ZDOTDIR": fixture.url.path],
            currentDirectory: fixture.url
        )

        XCTAssertEqual(values["CLAUDE_CONFIG_DIR"], claudeDirectory.path)
        XCTAssertEqual(values["CODEX_HOME"], codexDirectory.path)
    }

    func testClaudeConfigDirectoriesOnlyResolveTheDefaultAndExplicitlyAddedPaths() throws {
        let fixture = try FixtureDirectory()
        let manager = FileManager.default
        // A second profile sitting in the home directory stays invisible until
        // it is added by hand. Backtrace does not go looking for it.
        for name in [".claude", ".claude-work"] {
            try manager.createDirectory(
                at: fixture.url.appendingPathComponent("\(name)/projects", isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        func resolve(added: [String] = [], hidden: Set<String> = []) -> [ClaudeConfigDirectory] {
            // Ignore whatever this Mac's own shell points at.
            ClaudeConfigDirectories.resolve(home: fixture.url, added: added, hidden: hidden)
                .filter { $0.url.path.hasPrefix(fixture.url.path) }
        }

        let untouched = resolve()
        XCTAssertEqual(untouched.map(\.name), ["Default"])
        XCTAssertEqual(untouched.map(\.source), [.defaultLocation])
        XCTAssertTrue(untouched.allSatisfy(\.isDefault))
        XCTAssertEqual(
            untouched.first?.projectsRoot.path,
            fixture.url.appendingPathComponent(".claude/projects").path
        )

        let work = fixture.url.appendingPathComponent(".claude-work", isDirectory: true)
        let elsewhere = fixture.url.appendingPathComponent("elsewhere/claude", isDirectory: true)
        // An added directory is trusted even before it holds any projects, and
        // adding the default one again must not duplicate it.
        let withAdded = resolve(added: [
            work.path,
            elsewhere.path,
            fixture.url.appendingPathComponent(".claude", isDirectory: true).path
        ])
        XCTAssertEqual(withAdded.map(\.name), ["Default", "work", "claude"])
        XCTAssertEqual(withAdded.map(\.source), [.defaultLocation, .added, .added])
        XCTAssertEqual(withAdded.map(\.isDefault), [true, false, false])

        let withHidden = resolve(
            added: [work.path],
            hidden: [fixture.url.appendingPathComponent(".claude", isDirectory: true).path]
        )
        XCTAssertEqual(withHidden.map(\.name), ["work"])
    }

    func testClaudeConfigDirectoryPathInputAcceptsTheWaysPeopleTypeAPath() throws {
        let fixture = try FixtureDirectory()
        let manager = FileManager.default
        let work = fixture.url.appendingPathComponent(".claude-work", isDirectory: true)
        try manager.createDirectory(
            at: work.appendingPathComponent("projects", isDirectory: true),
            withIntermediateDirectories: true
        )

        func validate(_ input: String) -> ClaudeConfigDirectoryValidation {
            ClaudeConfigDirectories.validate(input, home: fixture.url, existing: [])
        }

        for input in [
            work.path,
            "  \(work.path)  ",
            "\(work.path)/",
            "'\(work.path)'",
            "\"\(work.path)\"",
            // Pointing at the transcripts resolves back to their parent.
            "\(work.path)/projects",
            // Bare names and tildes resolve inside the supplied home directory.
            ".claude-work",
            "~/.claude-work"
        ] {
            XCTAssertEqual(validate(input), .accepted(work, note: nil), "input: \(input)")
        }
    }

    func testClaudeConfigDirectoryPathInputExplainsEveryRejection() throws {
        let fixture = try FixtureDirectory()
        let manager = FileManager.default
        let unused = fixture.url.appendingPathComponent(".claude-unused", isDirectory: true)
        try manager.createDirectory(at: unused, withIntermediateDirectories: true)
        let file = fixture.url.appendingPathComponent("notes.txt")
        try "text".write(to: file, atomically: true, encoding: .utf8)

        let listed = ClaudeConfigDirectory(
            url: fixture.url.appendingPathComponent(".claude", isDirectory: true),
            source: .defaultLocation,
            isDefault: true
        )
        func validate(_ input: String) -> ClaudeConfigDirectoryValidation {
            ClaudeConfigDirectories.validate(input, home: fixture.url, existing: [listed])
        }

        XCTAssertEqual(validate(""), .empty)
        XCTAssertEqual(validate("   \n "), .empty)
        XCTAssertEqual(validate("/"), .rejected("Choose a Claude Code config directory, not the whole disk."))
        XCTAssertEqual(
            validate(listed.url.path),
            .rejected("Already listed as “Default” (Default).")
        )
        XCTAssertEqual(validate(file.path), .rejected("That path is a file, not a folder."))
        XCTAssertEqual(
            validate("/nowhere/at/all"),
            .rejected("Nothing exists at /nowhere/at/all.")
        )

        // A real folder that Claude Code has never written to is still usable,
        // but says up front that it holds nothing.
        let empty = validate(unused.path)
        XCTAssertEqual(empty.url, unused)
        XCTAssertFalse(empty.isRejected)
        XCTAssertNotNil(empty.message)
    }

    @MainActor
    func testClaudeConfigDirectorySettingsPersistAndSeparateAddedFromHidden() throws {
        let suiteName = "BacktraceTests.ClaudeConfig.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        settings.addClaudeConfigDirectory(URL(fileURLWithPath: "/tmp/profiles/.claude-work", isDirectory: true))
        settings.addClaudeConfigDirectory(URL(fileURLWithPath: "/tmp/profiles/.claude-work", isDirectory: true))
        XCTAssertEqual(settings.addedClaudeConfigDirectories, ["/tmp/profiles/.claude-work"])

        let restored = SettingsStore(defaults: defaults)
        XCTAssertEqual(restored.addedClaudeConfigDirectories, ["/tmp/profiles/.claude-work"])

        restored.removeClaudeConfigDirectory(
            ClaudeConfigDirectory(
                url: URL(fileURLWithPath: "/tmp/profiles/.claude-work", isDirectory: true),
                source: .added,
                isDefault: false
            )
        )
        XCTAssertTrue(restored.addedClaudeConfigDirectories.isEmpty)
        XCTAssertTrue(restored.hiddenClaudeConfigDirectories.isEmpty)

        // Removing a directory Backtrace resolves on its own hides it instead,
        // because the next scan would otherwise bring it straight back.
        let fromEnvironment = ClaudeConfigDirectory(
            url: URL(fileURLWithPath: "/tmp/profiles/.claude-client", isDirectory: true),
            source: .environment,
            isDefault: false
        )
        restored.removeClaudeConfigDirectory(fromEnvironment)
        XCTAssertEqual(
            SettingsStore(defaults: defaults).hiddenClaudeConfigDirectories,
            ["/tmp/profiles/.claude-client"]
        )

        restored.addClaudeConfigDirectory(fromEnvironment.url)
        XCTAssertTrue(restored.hiddenClaudeConfigDirectories.isEmpty)
        restored.removeClaudeConfigDirectory(fromEnvironment)
        restored.restoreHiddenClaudeConfigDirectories()
        XCTAssertTrue(SettingsStore(defaults: defaults).hiddenClaudeConfigDirectories.isEmpty)
    }

    @MainActor
    func testRefreshQueuesConfigChangesMadeDuringAnActiveScan() async throws {
        let suiteName = "BacktraceTests.RefreshQueue.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        let scanner = PausingSessionScanner()
        let store = SessionStore(settings: settings, scanner: scanner, defaults: defaults)
        let initialRefresh = Task { await store.refresh() }
        await scanner.waitUntilFirstScanStarts()

        let added = URL(fileURLWithPath: "/tmp/profiles/.claude-work", isDirectory: true)
        settings.addClaudeConfigDirectory(added)
        await store.refresh()
        await scanner.resumeFirstScan()
        await initialRefresh.value

        let snapshots = await scanner.addedDirectorySnapshots()
        XCTAssertEqual(snapshots, [[], [added.path]])
        XCTAssertEqual(store.claudeConfigDirectories.map(\.url.path), [added.path])
        XCTAssertFalse(store.isScanning)
    }

    func testGrokProviderHandlesDirectoryKeyedJSONL() throws {
        let fixture = try FixtureDirectory()
        let sessionFolder = fixture.url.appendingPathComponent("f0f46d28-254e-44a4-bc35-fb5b18a67c68", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
        let transcript = sessionFolder.appendingPathComponent("events.jsonl")
        try """
        {"type":"session_meta","sessionId":"f0f46d28-254e-44a4-bc35-fb5b18a67c68","cwd":"/tmp/grok-project","title":"Grok session","createdAt":"2026-07-17T08:00:00Z"}
        {"role":"user","content":"Investigate the build"}
        """.write(to: transcript, atomically: true, encoding: .utf8)

        let value = try XCTUnwrap(GrokProvider(roots: [fixture.url]).sessions().first)
        XCTAssertEqual(value.title, "Grok session")
        XCTAssertEqual(value.projectPath, "/tmp/grok-project")
        XCTAssertEqual(value.resumeCommand, "cd '/tmp/grok-project' && grok --resume 'f0f46d28-254e-44a4-bc35-fb5b18a67c68'")
    }

    func testGrokProviderReadsSummaryAndHidesUnusedSessions() throws {
        let fixture = try FixtureDirectory()
        let project = fixture.url.appendingPathComponent("%2Ftmp%2Fgrok-project", isDirectory: true)
        func writeSession(_ id: String, summary: String) throws {
            let folder = project.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try summary.write(to: folder.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
            try """
            {"type":"system","content":"You are Grok."}
            {"type":"user","content":[{"type":"text","text":"<user_info>\\nOS Version: macos\\n</user_info>"}]}
            """.write(to: folder.appendingPathComponent("chat_history.jsonl"), atomically: true, encoding: .utf8)
            // The newer of the summary date and the transcript's own date wins.
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                ofItemAtPath: folder.appendingPathComponent("chat_history.jsonl").path
            )
        }
        try writeSession("01a1237e-22a4-7b22-bd04-c0e7c8c656cd", summary: """
        {"info":{"id":"01a1237e-22a4-7b22-bd04-c0e7c8c656cd","cwd":"/tmp/grok-project"},"generated_title":"Install session browsers","created_at":"2026-10-10T01:47:11.426684Z","updated_at":"2026-10-10T03:18:47.791389Z","num_chat_messages":118,"current_model_id":"grok-4.7","head_branch":"master","last_recap":"We installed two browsers."}
        """)
        try writeSession("01a1237e-0000-7b22-bd04-c0e7c8c656cd", summary: """
        {"info":{"id":"01a1237e-0000-7b22-bd04-c0e7c8c656cd","cwd":"/tmp/grok-project"},"session_summary":"","num_chat_messages":2}
        """)
        try writeSession("01a1237e-1111-7b22-bd04-c0e7c8c656cd", summary: """
        {"info":{"id":"01a1237e-1111-7b22-bd04-c0e7c8c656cd","cwd":"/tmp/grok-project"},"session_summary":"","num_chat_messages":2}
        """)
        try """
        {"timestamp":"2026-10-10T02:10:33Z","session_id":"01a1237e-1111-7b22-bd04-c0e7c8c656cd","prompt":"Fix the scanner","is_bash":false}
        """.write(to: project.appendingPathComponent("prompt_history.jsonl"), atomically: true, encoding: .utf8)

        let sessions = try GrokProvider(roots: [fixture.url]).sessions().sorted { $0.sessionID < $1.sessionID }
        XCTAssertEqual(sessions.map(\.title), ["Fix the scanner", "Install session browsers"])
        let titled = try XCTUnwrap(sessions.last)
        XCTAssertEqual(titled.projectName, "grok-project")
        XCTAssertEqual(titled.gitBranch, "master")
        XCTAssertEqual(titled.model, "grok-4.7")
        XCTAssertEqual(titled.messageCount, 118)
        XCTAssertEqual(titled.summary, "We installed two browsers.")
        XCTAssertEqual(titled.sourceURL.lastPathComponent, "chat_history.jsonl")
        XCTAssertEqual(titled.updatedAt.timeIntervalSince1970, 1_791_602_327.791, accuracy: 0.01)
    }

    func testSessionHandoffKeepsTypedConversationAndBuildsLaunchCommand() throws {
        let session = AssistantSession(
            assistant: .grok,
            sessionID: "01a1237e-22a4-7b22-bd04-c0e7c8c656cd",
            title: "Install session browsers",
            summary: "We installed two browsers.",
            projectPath: "/tmp/grok project",
            gitBranch: "master",
            model: "grok-4.7",
            createdAt: nil,
            updatedAt: Date(timeIntervalSince1970: 1_791_602_327),
            messageCount: 4,
            fileSize: 0,
            sourceURL: URL(fileURLWithPath: "/tmp/sessions/chat_history.jsonl"),
            sourceFormat: .grokJSON,
            isArchived: false
        )
        func entry(_ role: TranscriptRole, _ text: String) -> TranscriptEntry {
            TranscriptEntry(id: UUID().uuidString, role: role, text: text, timestamp: nil)
        }
        let transcript = TranscriptPreview(entries: [
            entry(.system, "You are Grok."),
            entry(.user, "<user_info>\nOS Version: macos\n</user_info>"),
            entry(.user, "<user_query>\nInstall both browsers\n</user_query>"),
            entry(.tool, "exit: 0"),
            entry(.assistant, "Both are installed.")
        ], isTruncated: false)

        XCTAssertEqual(SessionHandoff.messages(from: transcript.entries), [
            .init(role: .user, text: "Install both browsers"),
            .init(role: .assistant, text: "Both are installed.")
        ])

        let document = SessionHandoff.document(for: session, transcript: transcript)
        XCTAssertTrue(document.hasPrefix("# Handoff: Install session browsers\n"))
        XCTAssertTrue(document.contains("- Assistant: Grok Build (grok-4.7)"))
        XCTAssertTrue(document.contains("## Summary\n\nWe installed two browsers."))
        XCTAssertTrue(document.contains("### User\n\nInstall both browsers\n\n### Grok Build\n\nBoth are installed."))
        XCTAssertFalse(document.contains("user_info"))
        XCTAssertFalse(document.contains("exit: 0"))

        let shared = SessionHandoff.document(for: session, transcript: transcript, purpose: .share)
        XCTAssertTrue(shared.hasPrefix("# Install session browsers\n"))
        XCTAssertFalse(shared.contains("Continue that work here"))
        XCTAssertFalse(shared.contains("/tmp/sessions/chat_history.jsonl"))
        XCTAssertTrue(shared.contains("### User\n\nInstall both browsers"))
        XCTAssertEqual(GistSharer.filename(for: session), "install-session-browsers-01a1237e.md")

        let long = (0..<10).map { SessionHandoff.Message(role: .user, text: "\($0)" + String(repeating: "x", count: 99)) }
        let (kept, omitted) = SessionHandoff.trimmed(long, budget: 350)
        XCTAssertEqual(kept.map { $0.text.prefix(1) }, ["0", "8", "9"])
        XCTAssertEqual(omitted, 7)

        let fixture = try FixtureDirectory()
        let file = try SessionHandoff.write(document, for: session, target: .claude, directory: fixture.url)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), document)
        XCTAssertEqual(
            SessionHandoff.launchCommand(for: .claude, session: session, handoffFile: file),
            "cd '/tmp/grok project' && claude \"$(cat '\(file.path)')\""
        )
        XCTAssertTrue(
            SessionHandoff.launchCommand(for: .openCode, session: session, handoffFile: file)
                .contains("opencode --prompt \"$(cat ")
        )
    }

    func testCodexResponseItemMessagesAreReadOnceWithoutInjectedContext() throws {
        let fixture = try FixtureDirectory()
        let id = "01a126f8-1c9b-73f0-905d-6858f215aee3"
        let file = fixture.url.appendingPathComponent("rollout-2026-10-10T10-59-16-\(id).jsonl")
        try """
        {"timestamp":"2026-10-10T17:59:16.903Z","type":"session_meta","payload":{"id":"\(id)","cwd":"/tmp/brain","timestamp":"2026-10-10T17:59:16.903Z"}}
        {"timestamp":"2026-10-10T17:59:17Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"Developer rules"}]}}
        {"timestamp":"2026-10-10T17:59:17Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /tmp/brain"}]}}
        {"timestamp":"2026-10-10T17:59:18Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Copy my aliases"}]}}
        {"timestamp":"2026-10-10T17:59:18Z","type":"event_msg","payload":{"type":"user_message","message":"Copy my aliases"}}
        {"timestamp":"2026-10-10T17:59:19Z","type":"response_item","payload":{"type":"custom_tool_call","name":"shell","input":"ls"}}
        {"timestamp":"2026-10-10T17:59:20Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"I will inspect them."}]}}
        """.write(to: file, atomically: true, encoding: .utf8)

        let session = try XCTUnwrap(
            CodexProvider(roots: [fixture.url], indexURL: fixture.url.appendingPathComponent("none.jsonl")).sessions().first
        )
        XCTAssertEqual(session.title, "Copy my aliases")

        let expectation = expectation(description: "transcript")
        Task {
            let transcript = await TranscriptLoader(installations: []).load(session)
            XCTAssertEqual(transcript.entries.map(\.role), [.user, .assistant])
            XCTAssertEqual(transcript.entries.map(\.text), ["Copy my aliases", "I will inspect them."])
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }

    func testSyncthingResolverReadsConfigurationAndLocatesSyncedFiles() throws {
        let configuration = try XCTUnwrap(SyncthingMachineResolver.parseConfiguration(Data("""
        <configuration version="51">
            <folder id="sync" label="Sync" path="/tmp/Sync" type="sendreceive">
                <device id="2NKIAG5-LT2OMI5" introducedBy=""></device>
            </folder>
            <device id="2JHI6FF-R2TDW75-JRJ5ZEU" name="mbp-16-m5"><address>dynamic</address></device>
            <device id="2NKIAG5-LT2OMI5-YFMH7QF" name="mbp-16-m4"><address>dynamic</address></device>
            <gui enabled="true" tls="false"><address>127.0.0.1:8384</address><apikey>secret</apikey></gui>
        </configuration>
        """.utf8)))
        XCTAssertEqual(configuration.baseURL.absoluteString, "http://127.0.0.1:8384")
        XCTAssertEqual(configuration.apiKey, "secret")
        XCTAssertEqual(configuration.deviceNames, ["2JHI6FF": "mbp-16-m5", "2NKIAG5": "mbp-16-m4"])

        let resolver = SyncthingMachineResolver(configuration: configuration)
        let folderPath = try XCTUnwrap(configuration.folders.first).path
        let inside = resolver.location(of: URL(fileURLWithPath: folderPath + "/ai/grok/sessions/%2Ftmp/a/chat_history.jsonl"))
        XCTAssertEqual(inside?.folder.id, "sync")
        XCTAssertEqual(inside?.relativePath, "ai/grok/sessions/%2Ftmp/a/chat_history.jsonl")
        XCTAssertNil(resolver.location(of: URL(fileURLWithPath: "/tmp/elsewhere/session.jsonl")))
    }

    func testSessionIsActiveOnlyShortlyAfterItsLastChange() {
        func session(updatedAt: Date) -> AssistantSession {
            AssistantSession(
                assistant: .codex, sessionID: "01a126f8-1c9b-73f0-905d-6858f215aee3", title: "t", summary: nil,
                projectPath: nil, gitBranch: nil, model: nil, createdAt: nil, updatedAt: updatedAt,
                messageCount: nil, fileSize: 0, sourceURL: URL(fileURLWithPath: "/tmp/a.jsonl"),
                sourceFormat: .codexJSONL, isArchived: false
            )
        }
        let now = Date()
        XCTAssertTrue(session(updatedAt: now.addingTimeInterval(-60)).isActive(at: now))
        XCTAssertFalse(session(updatedAt: now.addingTimeInterval(-600)).isActive(at: now))
    }

    func testShellAliasDetectorFindsAssistantLaunchersByName() {
        let output = """
        cc='claude --dangerously-skip-permissions'
        ccl='$HOME/.local/bin/sync-claude-mcp; env -u ANTHROPIC_API_KEY CLAUDE_CONFIG_DIR=$HOME/.claude-ccl claude --dangerously-skip-permissions'
        cdx='codex --dangerously-bypass-approvals-and-sandbox'
        alias gg='grok --yolo'
        oc2='env XDG_DATA_HOME=$HOME/.opencode-agent2 opencode'
        gs='git status'
        claudette='echo claudette'
        """
        let launchers = ShellAliasDetector.launchers(fromAliasOutput: output)
        XCTAssertEqual(launchers.map(\.name), ["cc", "ccl", "cdx", "gg", "oc2"])
        XCTAssertEqual(launchers.map(\.kind), [.claude, .claude, .codex, .grok, .openCode])
    }

    func testResumeCommandUsesLauncherAlias() {
        func session(_ kind: AssistantKind, archived: Bool = false) -> AssistantSession {
            AssistantSession(
                assistant: kind, sessionID: "abc12345", title: "t", summary: nil,
                projectPath: "/tmp/p", gitBranch: nil, model: nil, createdAt: nil, updatedAt: Date(),
                messageCount: nil, fileSize: 0, sourceURL: URL(fileURLWithPath: "/tmp/a.jsonl"),
                sourceFormat: .codexJSONL, isArchived: archived
            )
        }
        XCTAssertEqual(session(.claude).resumeCommand(launcher: "ccl"), "cd '/tmp/p' && ccl --resume 'abc12345'")
        XCTAssertEqual(session(.codex).resumeCommand(launcher: "cdx"), "cd '/tmp/p' && cdx resume 'abc12345'")
        XCTAssertEqual(
            session(.codex, archived: true).resumeCommand(launcher: "cdx"),
            "cd '/tmp/p' && codex unarchive 'abc12345' && cdx resume 'abc12345'"
        )
        XCTAssertEqual(session(.grok).resumeCommand(launcher: "gg"), "cd '/tmp/p' && gg --resume 'abc12345'")
        XCTAssertEqual(session(.openCode).resumeCommand(launcher: nil), "cd '/tmp/p' && opencode --session 'abc12345'")
    }

    func testSourceUpdaterListsCommitsTheRunningAppDoesNotHave() throws {
        let fixture = try FixtureDirectory()
        func git(_ arguments: [String], in directory: URL) throws -> String {
            let result = try XCTUnwrap(ProcessRunner.run(
                executable: SourceUpdater.git,
                arguments: ["-c", "user.name=Test", "-c", "user.email=test@example.com"] + arguments,
                currentDirectory: directory
            ))
            XCTAssertEqual(result.status, 0, result.text)
            return result.text
        }
        let remote = fixture.url.appendingPathComponent("remote.git")
        let checkout = fixture.url.appendingPathComponent("checkout")
        let other = fixture.url.appendingPathComponent("other")
        _ = try git(["init", "--quiet", "--bare", "--initial-branch=main", remote.path], in: fixture.url)
        _ = try git(["clone", "--quiet", remote.path, checkout.path], in: fixture.url)
        _ = try git(["commit", "--quiet", "--allow-empty", "-m", "First"], in: checkout)
        _ = try git(["push", "--quiet", "-u", "origin", "main"], in: checkout)
        let built = SourceBuild(directory: checkout, commit: try git(["rev-parse", "HEAD"], in: checkout))

        XCTAssertNil(try SourceUpdater.check(built))

        _ = try git(["clone", "--quiet", remote.path, other.path], in: fixture.url)
        _ = try git(["commit", "--quiet", "--allow-empty", "-m", "Add self-update"], in: other)
        _ = try git(["commit", "--quiet", "--allow-empty", "-m", "Fix titles"], in: other)
        _ = try git(["push", "--quiet"], in: other)

        let update = try XCTUnwrap(SourceUpdater.check(built))
        XCTAssertEqual(update.changes, ["Fix titles", "Add self-update"])
        XCTAssertEqual(update.commit, try git(["rev-parse", "HEAD"], in: other))
    }

    func testSearchIndexFindsWordsInsideConversationsAndTracksChanges() async throws {
        let fixture = try FixtureDirectory()
        let index = SearchIndex(url: fixture.url.appendingPathComponent("index.sqlite"))
        func session(_ id: String, updated: TimeInterval) -> AssistantSession {
            AssistantSession(
                assistant: .codex, sessionID: id, title: "Untitled", summary: nil, projectPath: nil,
                gitBranch: nil, model: nil, createdAt: nil, updatedAt: Date(timeIntervalSince1970: updated),
                messageCount: nil, fileSize: 10, sourceURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"),
                sourceFormat: .codexJSONL, isArchived: false
            )
        }
        let first = session("01a126f8-aaaa-73f0-905d-6858f215aee3", updated: 100)
        let second = session("01a126f8-bbbb-73f0-905d-6858f215aee3", updated: 200)

        let initiallyStale = await index.staleSessions(in: [first, second])
        XCTAssertEqual(initiallyStale.map(\.sessionID), [second.sessionID, first.sessionID])
        await index.store(first, body: "Copy my Omarchy aliases to the PC on the tailnet")
        await index.store(second, body: "Fix the Grok session titles")

        let matches = await index.search("omarch alias")
        XCTAssertEqual(Array(matches.keys), [first.id])
        XCTAssertTrue(matches[first.id]?.contains("Omarchy") == true)
        let none = await index.search("kubernetes")
        XCTAssertTrue(none.isEmpty)

        let afterStore = await index.staleSessions(in: [first, session(second.sessionID, updated: 300)])
        XCTAssertEqual(afterStore.map(\.sessionID), [second.sessionID])

        await index.removeAll(except: [second.id])
        let afterRemoval = await index.search("omarchy")
        XCTAssertTrue(afterRemoval.isEmpty)
    }

    func testCodexProviderReadsCompressedSessions() throws {
        try XCTSkipIf(SessionFileData.zstdExecutable == nil, "zstd is not installed")
        let fixture = try FixtureDirectory()
        let id = "019cb93e-8e02-78d3-9d92-3ec6889ce48e"
        let plain = fixture.url.appendingPathComponent("rollout-2026-03-04T06-26-50-\(id).jsonl")
        try """
        {"timestamp":"2026-03-04T14:26:50Z","type":"session_meta","payload":{"id":"\(id)","cwd":"/tmp/old"}}
        {"timestamp":"2026-03-04T14:26:51Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Plan the March launch"}]}}
        """.write(to: plain, atomically: true, encoding: .utf8)
        let compress = Process()
        compress.executableURL = SessionFileData.zstdExecutable
        compress.arguments = ["-q", "--rm", plain.path]
        try compress.run()
        compress.waitUntilExit()
        XCTAssertFalse(FileManager.default.fileExists(atPath: plain.path))

        let sessions = try CodexProvider(roots: [fixture.url], indexURL: fixture.url.appendingPathComponent("none.jsonl")).sessions()
        XCTAssertEqual(sessions.map(\.sessionID), [id])
        XCTAssertEqual(sessions.first?.title, "Plan the March launch")
        XCTAssertEqual(sessions.first?.sourceURL.pathExtension, "zst")
    }

    func testOpenCodeLegacyProviderReadsStructuredSession() throws {
        let fixture = try FixtureDirectory()
        let sessionRoot = fixture.url.appendingPathComponent("storage/session/global", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        let file = sessionRoot.appendingPathComponent("ses_example.json")
        try """
        {"id":"ses_example","directory":"/tmp/open-code","title":"Review architecture","time":{"created":1768062649435,"updated":1768068432003}}
        """.write(to: file, atomically: true, encoding: .utf8)

        let value = try XCTUnwrap(OpenCodeProvider(root: fixture.url, home: fixture.url).sessions().first)
        XCTAssertEqual(value.title, "Review architecture")
        XCTAssertEqual(value.projectPath, "/tmp/open-code")
        XCTAssertEqual(value.resumeCommand, "cd '/tmp/open-code' && opencode --session 'ses_example'")
    }

    func testOpenCodeProviderReadsSessionsFromItsDatabase() throws {
        let fixture = try FixtureDirectory()
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.url.appendingPathComponent("opencode.db").path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, """
        CREATE TABLE session (id text PRIMARY KEY, parent_id text, directory text, title text, model text,
            time_created integer, time_updated integer, time_archived integer);
        INSERT INTO session VALUES ('ses_root', NULL, '/tmp/client', 'Fix the parser',
            '{"id":"qwen3","providerID":"ollama"}', 1791560723000, 1791574849000, NULL);
        INSERT INTO session VALUES ('ses_child', 'ses_root', '/tmp/client', 'Subagent', NULL,
            1791560723000, 1791574849000, NULL);
        """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        let sessions = try OpenCodeProvider(root: fixture.url, home: fixture.url).sessions()
        XCTAssertEqual(sessions.map(\.sessionID), ["ses_root"])
        let value = try XCTUnwrap(sessions.first)
        XCTAssertEqual(value.title, "Fix the parser")
        XCTAssertEqual(value.model, "qwen3")
        XCTAssertEqual(value.updatedAt, Date(timeIntervalSince1970: 1_791_574_849))
        XCTAssertEqual(value.resumeCommand, "cd '/tmp/client' && opencode --session 'ses_root'")
    }

    func testTranscriptLoaderReturnsOnlyConversationMessages() async throws {
        let fixture = try FixtureDirectory()
        let file = fixture.url.appendingPathComponent("session.jsonl")
        try """
        {"timestamp":"2026-07-19T10:00:00.000Z","type":"session_meta","payload":{"id":"test","cwd":"/tmp"}}
        {"timestamp":"2026-07-19T10:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"Hello"}}
        {"timestamp":"2026-07-19T10:00:02.000Z","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"2026-07-19T10:00:03.000Z","type":"event_msg","payload":{"type":"agent_message","message":"Hi there"}}
        """.write(to: file, atomically: true, encoding: .utf8)
        let session = AssistantSession(
            assistant: .codex,
            sessionID: "test",
            title: "Test",
            summary: nil,
            projectPath: "/tmp",
            gitBranch: nil,
            model: nil,
            createdAt: nil,
            updatedAt: Date(),
            messageCount: nil,
            fileSize: 0,
            sourceURL: file,
            sourceFormat: .codexJSONL,
            isArchived: false
        )

        let preview = await TranscriptLoader(installations: []).load(session)
        XCTAssertEqual(preview.entries.map(\.text), ["Hello", "Hi there"])
        XCTAssertEqual(preview.entries.map(\.role), [.user, .assistant])
    }

    func testTranscriptLoaderCancelsSupersededJSONLWork() async throws {
        let fixture = try FixtureDirectory()
        let file = fixture.url.appendingPathComponent("large-session.jsonl")
        let metadata = #"{"type":"metadata","payload":{"padding":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}}"# + "\n"
        let message = #"{"type":"event_msg","payload":{"type":"user_message","message":"Should not be published"}}"# + "\n"
        try (String(repeating: metadata, count: 100_000) + String(repeating: message, count: 160))
            .write(to: file, atomically: true, encoding: .utf8)

        let session = AssistantSession(
            assistant: .codex,
            sessionID: "cancel-test",
            title: "Cancellation test",
            summary: nil,
            projectPath: "/tmp",
            gitBranch: nil,
            model: nil,
            createdAt: nil,
            updatedAt: Date(),
            messageCount: nil,
            fileSize: 0,
            sourceURL: file,
            sourceFormat: .codexJSONL,
            isArchived: false
        )

        let task = Task {
            await TranscriptLoader(installations: []).load(session)
        }
        await Task.yield()
        task.cancel()

        let clock = ContinuousClock()
        let started = clock.now
        let preview = await task.value
        let cancellationLatency = started.duration(to: clock.now)

        XCTAssertTrue(preview.entries.isEmpty)
        XCTAssertLessThan(cancellationLatency, .seconds(1))
    }

    func testLiveScannerWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["BACKTRACE_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set BACKTRACE_LIVE_TEST=1 to scan the current Mac's assistant histories.")
        }

        let result = await SessionScanner().scan()
        let counts = Dictionary(grouping: result.sessions, by: \.assistant).mapValues(\.count)
        let claudeCounts = Dictionary(
            grouping: result.sessions.compactMap(\.configDirectory),
            by: \.name
        ).mapValues(\.count)
        print("Backtrace live scan: \(result.installations.map(\.kind.displayName)); session counts: \(counts)")
        print("Claude Code config directories: \(result.claudeConfigDirectories.map { "\($0.name) [\($0.source)] \($0.url.path)" })")
        print("Claude Code sessions per profile: \(claudeCounts)")
        XCTAssertFalse(result.installations.isEmpty)
        XCTAssertTrue(result.sessions.allSatisfy { !$0.sessionID.isEmpty && !$0.title.isEmpty })
    }

    private func testSession(id: String) -> AssistantSession {
        AssistantSession(
            assistant: .codex,
            sessionID: id,
            title: "Tagged session",
            summary: nil,
            projectPath: "/tmp",
            gitBranch: nil,
            model: nil,
            createdAt: nil,
            updatedAt: Date(),
            messageCount: nil,
            fileSize: 0,
            sourceURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"),
            sourceFormat: .codexJSONL,
            isArchived: false
        )
    }
}

private actor PausingSessionScanner: SessionScanning {
    private var addedSnapshots: [[String]] = []
    private var firstScanContinuation: CheckedContinuation<Void, Never>?

    func scan(
        addedClaudeConfigDirectories: [String],
        hiddenClaudeConfigDirectories: Set<String>
    ) async -> ScanResult {
        addedSnapshots.append(addedClaudeConfigDirectories)
        if addedSnapshots.count == 1 {
            await withCheckedContinuation { continuation in
                firstScanContinuation = continuation
            }
        }

        let directories = addedClaudeConfigDirectories.map { path in
            ClaudeConfigDirectory(
                url: URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL,
                source: .added,
                isDefault: false
            )
        }
        return ScanResult(
            installations: [],
            sessions: [],
            claudeConfigDirectories: directories,
            warnings: []
        )
    }

    func waitUntilFirstScanStarts() async {
        while addedSnapshots.isEmpty {
            await Task.yield()
        }
    }

    func resumeFirstScan() {
        let continuation = firstScanContinuation
        firstScanContinuation = nil
        continuation?.resume()
    }

    func addedDirectorySnapshots() -> [[String]] {
        addedSnapshots
    }
}

private final class FixtureDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BacktraceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Writes a Claude Code transcript at `<fixture>/<configDirectory>/projects/-tmp-client/<id>.jsonl`.
    func writeClaudeSession(id: String, configDirectory: String) throws {
        let project = url.appendingPathComponent("\(configDirectory)/projects/-tmp-client", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try """
        {"type":"user","sessionId":"\(id)","cwd":"/tmp/client","gitBranch":"feature/history","timestamp":"2026-07-18T09:00:00.000Z","message":{"content":"Find the session parser bug"}}
        {"type":"assistant","sessionId":"\(id)","cwd":"/tmp/client","gitBranch":"feature/history","timestamp":"2026-07-18T09:01:00.000Z","message":{"model":"claude-sonnet","content":[{"type":"text","text":"I found it."}]}}
        {"type":"ai-title","aiTitle":"Generated title","sessionId":"\(id)"}
        {"type":"custom-title","customTitle":"parser-investigation","sessionId":"\(id)"}
        """.write(to: project.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
