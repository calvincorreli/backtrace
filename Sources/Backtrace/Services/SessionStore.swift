import AppKit
import Combine
import Foundation

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var installations: [AssistantInstallation] = []
    @Published private(set) var sessions: [AssistantSession] = []
    @Published private(set) var claudeConfigDirectories: [ClaudeConfigDirectory] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScan: Date?
    @Published private(set) var warnings: [String] = []
    @Published var selection: SidebarSelection = .all
    @Published var selectedSessionID: String?
    @Published var searchText = ""
    @Published private(set) var tags: [SessionTag] = []
    @Published var handoffError: String?
    /// Shell aliases that start each assistant, found in the user's shell.
    @Published private(set) var launchers: [AssistantLauncher] = []
    @Published private var preferredLaunchers: [String: String] = [:]
    /// Gists made from sessions, by session ID, so a link can be copied again or deleted.
    @Published private(set) var sharedSessions: [String: SharedSession] = [:]
    @Published private(set) var sharingSessionIDs: Set<String> = []
    /// Sessions whose conversation matches the search, with an excerpt of the match.
    @Published private(set) var contentMatches: [String: String] = [:]
    /// Shown while conversations are still being added to the search index.
    @Published private(set) var indexStatus: String?
    private let searchIndex: SearchIndex?
    private var indexTask: Task<Void, Never>?
    private var indexRequested = false
    private var launchersTask: Task<Void, Never>?
    @Published private(set) var machinesBySessionID: [String: SessionMachine] = [:]

    let settings: SettingsStore
    private let scanner: any SessionScanning
    private var refreshRequested = false
    private var transcriptCache: [String: TranscriptPreview] = [:]
    private let machineResolver: (any SessionMachineResolving)?
    /// When each session's machine was last looked up, so only changed sessions are asked about again.
    private var machineLookupDates: [String: Date] = [:]
    private var machineTask: Task<Void, Never>?
    private var favoriteIDs: Set<String>
    private var tagIDsBySession: [String: Set<UUID>] = [:]
    private let defaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []

    private enum Keys {
        static let favoriteSessionIDs = "favoriteSessionIDs"
        static let tagArchive = "sessionTagArchive"
        static let preferredLaunchers = "preferredLaunchers"
        static let sharedSessions = "sharedSessions"
    }

    private struct TagArchive: Codable {
        let tags: [SessionTag]
        let tagIDsBySession: [String: Set<UUID>]
    }

    init(
        settings: SettingsStore,
        scanner: any SessionScanning = SessionScanner(),
        defaults: UserDefaults = .standard,
        machineResolver: (any SessionMachineResolving)? = nil,
        searchIndex: SearchIndex? = nil
    ) {
        self.searchIndex = searchIndex
        self.settings = settings
        self.scanner = scanner
        self.machineResolver = machineResolver
        self.defaults = defaults
        favoriteIDs = Set(defaults.stringArray(forKey: Keys.favoriteSessionIDs) ?? [])
        preferredLaunchers = defaults.dictionary(forKey: Keys.preferredLaunchers) as? [String: String] ?? [:]
        if let data = defaults.data(forKey: Keys.sharedSessions),
           let shared = try? JSONDecoder().decode([String: SharedSession].self, from: data) {
            sharedSessions = shared
        }
        if let data = defaults.data(forKey: Keys.tagArchive),
           let archive = try? JSONDecoder().decode(TagArchive.self, from: data) {
            tags = archive.tags
            let validIDs = Set(archive.tags.map(\.id))
            tagIDsBySession = archive.tagIDsBySession.compactMapValues { ids in
                let valid = ids.intersection(validIDs)
                return valid.isEmpty ? nil : valid
            }
        }
        settings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        $searchText
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.searchContent() }
            .store(in: &cancellables)
    }

    var visibleSessions: [AssistantSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).foldedForSearch
        return sessions.filter { session in
            guard matchesSelection(session), matchesTrackedFolders(session) else { return false }
            guard !query.isEmpty else { return true }
            let tagSearchText = tags(for: session).map(\.name).joined(separator: " ").foldedForSearch
            return session.searchableText.contains(query) || tagSearchText.contains(query)
                || contentMatches[session.id] != nil
        }
        .sorted { lhs, rhs in
            let lhsFavorite = favoriteIDs.contains(lhs.id)
            let rhsFavorite = favoriteIDs.contains(rhs.id)
            if lhsFavorite != rhsFavorite { return lhsFavorite }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    var selectedSession: AssistantSession? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    func refresh() async {
        if launchersTask == nil {
            launchersTask = Task { launchers = await ShellAliasDetector.detect() }
        }
        guard !isScanning else {
            refreshRequested = true
            return
        }
        isScanning = true
        repeat {
            refreshRequested = false
            let result = await scanner.scan(
                addedClaudeConfigDirectories: settings.addedClaudeConfigDirectories,
                hiddenClaudeConfigDirectories: settings.hiddenClaudeConfigDirectories
            )
            apply(result)
        } while refreshRequested
        isScanning = false
    }

    private func apply(_ result: ScanResult) {
        installations = result.installations
        sessions = result.sessions
        claudeConfigDirectories = result.claudeConfigDirectories
        warnings = result.warnings
        lastScan = Date()
        resolveMachines()
        updateSearchIndex()

        if case .claudeConfigDirectory(let path) = selection,
           !claudeConfigDirectories.contains(where: { $0.id == path }) {
            selection = .all
        }

        if selectedSessionID == nil || !sessions.contains(where: { $0.id == selectedSessionID }) {
            selectedSessionID = visibleSessions.first?.id
        }
    }

    func transcript(for session: AssistantSession) async -> TranscriptPreview {
        if let cached = transcriptCache[session.id] {
            return cached
        }

        let loaded = await TranscriptLoader(installations: installations).load(session)
        if !Task.isCancelled {
            transcriptCache[session.id] = loaded
        }
        return loaded
    }

    func count(for kind: AssistantKind) -> Int {
        sessions.lazy.filter { $0.assistant == kind }.count
    }

    func count(in folder: TrackedFolder) -> Int {
        sessions.lazy.filter { session in
            guard let path = session.projectPath else { return false }
            return path == folder.path || path.hasPrefix(folder.path + "/")
        }.count
    }

    func count(in directory: ClaudeConfigDirectory) -> Int {
        sessions.lazy.filter { $0.configDirectory?.id == directory.id }.count
    }

    func count(for tag: SessionTag) -> Int {
        sessions.lazy.filter { self.tagIDsBySession[$0.id]?.contains(tag.id) == true }.count
    }

    func tag(withID id: UUID) -> SessionTag? {
        tags.first { $0.id == id }
    }

    func tags(for session: AssistantSession) -> [SessionTag] {
        guard let assignedIDs = tagIDsBySession[session.id] else { return [] }
        return tags.filter { assignedIDs.contains($0.id) }
    }

    func isTagged(_ session: AssistantSession, with tag: SessionTag) -> Bool {
        tagIDsBySession[session.id]?.contains(tag.id) == true
    }

    var nextTagColor: TagColor {
        let colors = TagColor.allCases
        return colors[tags.count % colors.count]
    }

    @discardableResult
    func createTag(named rawName: String, color: TagColor, assigningTo session: AssistantSession? = nil) -> SessionTag? {
        let name = normalizedTagName(rawName)
        guard !name.isEmpty else { return nil }

        if let existing = tags.first(where: { $0.name.foldedForSearch == name.foldedForSearch }) {
            if let session {
                assign(existing, to: session)
            }
            return existing
        }

        let tag = SessionTag(name: name, color: color)
        tags.append(tag)
        sortTags()
        if let session {
            tagIDsBySession[session.id, default: []].insert(tag.id)
        }
        persistTags()
        return tag
    }

    @discardableResult
    func renameTag(_ tag: SessionTag, to rawName: String) -> Bool {
        let name = normalizedTagName(rawName)
        guard !name.isEmpty else { return false }
        guard !tags.contains(where: {
            $0.id != tag.id && $0.name.foldedForSearch == name.foldedForSearch
        }) else { return false }
        guard let index = tags.firstIndex(where: { $0.id == tag.id }) else { return false }

        tags[index] = SessionTag(id: tag.id, name: name, color: tag.color)
        sortTags()
        persistTags()
        return true
    }

    func deleteTag(_ tag: SessionTag) {
        tags.removeAll { $0.id == tag.id }
        tagIDsBySession = tagIDsBySession.compactMapValues { ids in
            let remaining = ids.subtracting([tag.id])
            return remaining.isEmpty ? nil : remaining
        }
        if selection == .tag(tag.id) {
            selection = .all
        }
        persistTags()
    }

    func toggleTag(_ tag: SessionTag, for session: AssistantSession) {
        if isTagged(session, with: tag) {
            tagIDsBySession[session.id]?.remove(tag.id)
            if tagIDsBySession[session.id]?.isEmpty == true {
                tagIDsBySession.removeValue(forKey: session.id)
            }
        } else {
            tagIDsBySession[session.id, default: []].insert(tag.id)
        }
        persistTags()
        objectWillChange.send()
    }

    func assign(_ tag: SessionTag, to session: AssistantSession) {
        guard !isTagged(session, with: tag) else { return }
        tagIDsBySession[session.id, default: []].insert(tag.id)
        persistTags()
        objectWillChange.send()
    }

    func isFavorite(_ session: AssistantSession) -> Bool {
        favoriteIDs.contains(session.id)
    }

    func toggleFavorite(_ session: AssistantSession) {
        if favoriteIDs.contains(session.id) {
            favoriteIDs.remove(session.id)
        } else {
            favoriteIDs.insert(session.id)
        }
        defaults.set(Array(favoriteIDs), forKey: Keys.favoriteSessionIDs)
        objectWillChange.send()
    }

    func launchers(for kind: AssistantKind) -> [AssistantLauncher] {
        launchers.filter { $0.kind == kind }
    }

    /// The alias chosen for an assistant, or nil for its plain executable.
    func launcher(for kind: AssistantKind) -> String? {
        guard let name = preferredLaunchers[kind.rawValue],
              launchers.contains(where: { $0.name == name && $0.kind == kind }) else { return nil }
        return name
    }

    func setLauncher(_ name: String?, for kind: AssistantKind) {
        preferredLaunchers[kind.rawValue] = name
        defaults.set(preferredLaunchers, forKey: Keys.preferredLaunchers)
    }

    func resumeCommand(for session: AssistantSession, launcher: String? = nil) -> String {
        session.resumeCommand(launcher: launcher ?? self.launcher(for: session.assistant))
    }

    func copyResumeCommand(for session: AssistantSession) {
        copyToPasteboard(resumeCommand(for: session))
    }

    func copySessionID(for session: AssistantSession) {
        copyToPasteboard(session.sessionID)
    }

    /// Resumes the session in a new terminal tab, through the interactive
    /// shell so that aliases expand.
    func resumeInTerminal(_ session: AssistantSession, launcher: String? = nil) async {
        handoffError = await TerminalLauncher.openTab(
            running: resumeCommand(for: session, launcher: launcher),
            in: TerminalLauncher.preferred()
        )
    }

    func copySessionFilePath(for session: AssistantSession) {
        copyToPasteboard(session.sourceURL.path)
    }

    /// Uploads the clean conversation as a secret gist and copies its link.
    /// A session shared before keeps its link; delete it to make a new one.
    func shareSession(_ session: AssistantSession) async {
        if let shared = sharedSessions[session.id] {
            copyToPasteboard(shared.url)
            return
        }
        guard !sharingSessionIDs.contains(session.id) else { return }
        sharingSessionIDs.insert(session.id)
        defer { sharingSessionIDs.remove(session.id) }

        let transcript = await TranscriptLoader(installations: installations, messageLimit: .max).load(session)
        let document = SessionHandoff.document(for: session, transcript: transcript, purpose: .share)
        do {
            let shared = try await GistSharer.share(document, for: session)
            sharedSessions[session.id] = shared
            persistSharedSessions()
            copyToPasteboard(shared.url)
        } catch {
            handoffError = "Could not share the session: \(error.localizedDescription)"
        }
    }

    func deleteSharedLink(for session: AssistantSession) async {
        guard let shared = sharedSessions[session.id] else { return }
        do {
            try await GistSharer.delete(shared)
        } catch {
            handoffError = "Could not delete the gist: \(error.localizedDescription)"
            return
        }
        sharedSessions[session.id] = nil
        persistSharedSessions()
    }

    private func persistSharedSessions() {
        if let data = try? JSONEncoder().encode(sharedSessions) {
            defaults.set(data, forKey: Keys.sharedSessions)
        }
    }

    func showSessionFileInFinder(_ session: AssistantSession) {
        NSWorkspace.shared.activateFileViewerSelecting([session.sourceURL])
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    /// Adds new and changed sessions to the search index in the background,
    /// newest first. A scan that arrives while indexing runs it again afterward.
    private func updateSearchIndex() {
        guard let searchIndex else { return }
        guard indexTask == nil else {
            indexRequested = true
            return
        }
        let sessions = self.sessions
        let installations = self.installations
        indexTask = Task.detached(priority: .utility) { [weak self] in
            await searchIndex.removeAll(except: Set(sessions.map(\.id)))
            let stale = await searchIndex.staleSessions(in: sessions)
            for (offset, session) in stale.enumerated() {
                if Task.isCancelled { break }
                if offset % 20 == 0 {
                    let status = "Indexing conversations: \(offset.formatted()) of \(stale.count.formatted())"
                    await self?.indexingProgressed(status: status)
                }
                let transcript = await TranscriptLoader(installations: installations, messageLimit: .max).load(session)
                let body = ([session.title] + SessionHandoff.messages(from: transcript.entries).map(\.text))
                    .joined(separator: "\n\n")
                await searchIndex.store(session, body: body)
            }
            await self?.indexingFinished()
        }
    }

    private func indexingProgressed(status: String) {
        indexStatus = status
        searchContent()
    }

    private func indexingFinished() {
        indexTask = nil
        indexStatus = nil
        searchContent()
        if indexRequested {
            indexRequested = false
            updateSearchIndex()
        }
    }

    private func searchContent() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let searchIndex, !query.isEmpty else {
            if !contentMatches.isEmpty { contentMatches = [:] }
            return
        }
        Task {
            let matches = await searchIndex.search(query)
            // Drop results for a query the user has since changed.
            guard query == searchText.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            contentMatches = matches
        }
    }

    func machine(for session: AssistantSession) -> SessionMachine? {
        machinesBySessionID[session.id]
    }

    /// Looks up the machine for each new or changed session, newest first, and
    /// publishes the names in batches so the list fills in without waiting.
    private func resolveMachines() {
        guard let machineResolver else { return }
        let pending = sessions.filter { machineLookupDates[$0.id] != $0.updatedAt }
        guard !pending.isEmpty else { return }
        machineTask?.cancel()
        machineTask = Task {
            var batch: [(AssistantSession, SessionMachine?)] = []
            for session in pending {
                if Task.isCancelled { return }
                batch.append((session, await machineResolver.machine(forFileAt: session.sourceURL)))
                if batch.count == 50 || session.id == pending.last?.id {
                    for (session, machine) in batch {
                        machineLookupDates[session.id] = session.updatedAt
                        machinesBySessionID[session.id] = machine
                    }
                    batch.removeAll()
                }
            }
        }
    }

    /// The assistants a session can be handed to: every installed one but its own.
    func handoffTargets(for session: AssistantSession) -> [AssistantKind] {
        AssistantKind.allCases.filter { kind in
            kind != session.assistant && installations.contains { $0.kind == kind }
        }
    }

    /// Writes a handoff for the session and starts the target assistant with
    /// it in a new terminal tab.
    func continueSession(_ session: AssistantSession, in target: AssistantKind) async {
        let transcript = await TranscriptLoader(installations: installations, messageLimit: .max).load(session)
        let document = SessionHandoff.document(for: session, transcript: transcript)
        do {
            let file = try SessionHandoff.write(document, for: session, target: target)
            let command = SessionHandoff.launchCommand(for: target, session: session, handoffFile: file)
            handoffError = await TerminalLauncher.openTab(running: command, in: TerminalLauncher.preferred())
        } catch {
            handoffError = "Could not write the handoff file: \(error.localizedDescription)"
        }
    }

    private func matchesSelection(_ session: AssistantSession) -> Bool {
        switch selection {
        case .all:
            true
        case .assistant(let kind):
            session.assistant == kind
        case .tag(let id):
            tagIDsBySession[session.id]?.contains(id) == true
        case .trackedFolder(let path):
            session.projectPath == path || session.projectPath?.hasPrefix(path + "/") == true
        case .claudeConfigDirectory(let path):
            session.configDirectory?.id == path
        }
    }

    private func matchesTrackedFolders(_ session: AssistantSession) -> Bool {
        guard settings.restrictToTrackedFolders, !settings.trackedFolders.isEmpty else { return true }
        guard let projectPath = session.projectPath else { return false }
        return settings.trackedFolders.contains {
            projectPath == $0.path || projectPath.hasPrefix($0.path + "/")
        }
    }

    private func normalizedTagName(_ name: String) -> String {
        String(name.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(32))
    }

    private func sortTags() {
        tags.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func persistTags() {
        let archive = TagArchive(tags: tags, tagIDsBySession: tagIDsBySession)
        if let data = try? JSONEncoder().encode(archive) {
            defaults.set(data, forKey: Keys.tagArchive)
        }
    }
}
