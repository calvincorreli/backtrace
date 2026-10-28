import AppKit
import SwiftUI

struct SessionDetailView: View {
    @EnvironmentObject private var store: SessionStore
    let session: AssistantSession
    @State private var copied = false
    @State private var copiedID = false
    @State private var transcript = TranscriptPreview.empty
    @State private var isLoadingTranscript = true
    @State private var transcriptTask: Task<Void, Never>?
    @State private var isEditingTags = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                header.padding(.bottom, 8)
                resumeCard.padding(.bottom, 8)
                metadataGrid
                SessionFileCard(session: session).padding(.bottom, 8)
                transcriptHeader
                transcriptContent
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            startTranscriptLoading()
        }
        .onDisappear {
            transcriptTask?.cancel()
            transcriptTask = nil
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.toggleFavorite(session)
                } label: {
                    Image(systemName: store.isFavorite(session) ? "pin.fill" : "pin")
                }
                .help(store.isFavorite(session) ? "Unpin Session" : "Pin Session")

                ShareLinkButton(session: session)

                Button {
                    revealSource()
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .help("Show Session File in Finder (⌥⌘R)")
            }
        }
        .sheet(isPresented: $isEditingTags) {
            SessionTagEditor(session: session)
                .environmentObject(store)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 15) {
                AssistantIcon(kind: session.assistant, size: 48)
                VStack(alignment: .leading, spacing: 8) {
                    Text(session.title)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        ProviderBadge(kind: session.assistant)
                        if session.isArchived {
                            Label("Archived", systemImage: "archivebox.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(.orange.opacity(0.1), in: Capsule())
                        }
                        if session.isActive() {
                            ActiveBadge(machine: store.machine(for: session))
                        }
                        HStack(spacing: 3) {
                            Text("Updated")
                            SessionDateText(date: session.updatedAt, style: .relative)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            HStack(spacing: 7) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(store.tags(for: session)) { tag in
                            TagPill(tag: tag)
                        }
                    }
                }

                Button {
                    isEditingTags = true
                } label: {
                    Label(store.tags(for: session).isEmpty ? "Add tags" : "Edit tags", systemImage: "plus")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Add or remove tags")
            }
        }
    }

    private var resumeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Resume command", systemImage: "terminal")
                    .font(.headline)
                Spacer()
                LauncherPicker(kind: session.assistant)
                Text("⇧⌘C")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }

            HStack(alignment: .center, spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(store.resumeCommand(for: session))
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.vertical, 2)
                }
                Button {
                    copyCommand()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .tint(copied ? .green : session.assistant.color)
                .help("Copy the resume command")
                Button {
                    copyID()
                } label: {
                    Label(copiedID ? "Copied" : "ID", systemImage: copiedID ? "checkmark" : "number")
                }
                .buttonStyle(.bordered)
                .help("Copy only the session ID")
                Button {
                    Task { await store.resumeInTerminal(session) }
                } label: {
                    Label("Open", systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
                .help("Resume this session in a new terminal tab")
                ContinueInMenu(session: session)
                    .menuStyle(.button)
                    .buttonStyle(.bordered)
                    .fixedSize()
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.separator.opacity(0.55), lineWidth: 1)
        }
    }

    private var metadataGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], alignment: .leading, spacing: 12) {
            MetadataCard(icon: "folder.fill", label: "Project", value: session.projectPath ?? "Unknown")
            MetadataCard(
                icon: "calendar",
                label: "Started",
                value: session.createdAt.map(DatePresentation.dateTime) ?? "Unknown",
                tooltip: session.createdAt.map(DatePresentation.fullyQualified)
            )
            MetadataCard(
                icon: "clock.fill",
                label: "Last activity",
                value: DatePresentation.dateTime(session.updatedAt),
                tooltip: DatePresentation.fullyQualified(session.updatedAt)
            )
            if let machine = store.machine(for: session) {
                MetadataCard(
                    icon: "laptopcomputer",
                    label: "Last touched on",
                    value: machine.isThisMac ? "\(machine.name) (this Mac)" : machine.name,
                    tooltip: "The machine that last changed this session, as recorded by Syncthing"
                )
            }
            if let branch = session.gitBranch, !branch.isEmpty {
                MetadataCard(icon: "arrow.triangle.branch", label: "Git branch", value: branch)
            }
            if let model = session.model, !model.isEmpty {
                MetadataCard(icon: "cpu", label: "Model", value: model)
            }
            if let directory = session.configDirectory, !directory.isDefault {
                MetadataCard(
                    icon: "person.crop.circle",
                    label: "Claude Code profile",
                    value: directory.name,
                    tooltip: directory.url.path
                )
            }
            MetadataCard(icon: "number", label: "Session ID", value: session.sessionID)
        }
    }

    private var transcriptHeader: some View {
        HStack {
            Text("Conversation preview")
                .font(.title3.weight(.semibold))
            Spacer()
            if transcript.isTruncated {
                Text("First 160 messages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var transcriptContent: some View {
        if isLoadingTranscript {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Loading conversation…")
                        .fontWeight(.medium)
                    Text("You can continue browsing while Backtrace reads this session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .center)
        } else if transcript.entries.isEmpty {
            ContentUnavailableView(
                "Preview Unavailable",
                systemImage: "text.bubble",
                description: Text("The session metadata is available, but this transcript format has no readable message preview.")
            )
            .frame(maxWidth: .infinity, minHeight: 180)
        } else {
            ForEach(transcript.entries) { entry in
                TranscriptBubble(entry: entry, color: session.assistant.color)
            }
        }
    }

    private func copyCommand() {
        store.copyResumeCommand(for: session)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            copied = false
        }
    }

    private func copyID() {
        store.copySessionID(for: session)
        copiedID = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            copiedID = false
        }
    }

    private func startTranscriptLoading() {
        transcriptTask?.cancel()
        transcript = .empty
        isLoadingTranscript = true

        let requestedSession = session
        transcriptTask = Task {
            // This task is deliberately independent of SwiftUI's view task
            // lifecycle, so replacing the detail view never waits for parsing.
            await Task.yield()
            let loaded = await store.transcript(for: requestedSession)
            guard !Task.isCancelled else { return }

            transcript = loaded
            isLoadingTranscript = false
        }
    }

    private func revealSource() {
        store.showSessionFileInFinder(session)
    }
}

/// Chooses how resume commands start an assistant: its own executable, or
/// one of the shell aliases that start it.
struct LauncherPicker: View {
    @EnvironmentObject private var store: SessionStore
    let kind: AssistantKind

    var body: some View {
        let aliases = store.launchers(for: kind)
        if !aliases.isEmpty {
            Picker("Launch with", selection: Binding(
                get: { store.launcher(for: kind) },
                set: { store.setLauncher($0, for: kind) }
            )) {
                Text(kind.executableName).tag(String?.none)
                Divider()
                ForEach(aliases) { alias in
                    Text(alias.name).tag(Optional(alias.name))
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            .help("The command or shell alias that resume commands use for \(kind.displayName)")
        }
    }
}

/// Marks a session whose transcript changed in the last few minutes.
struct ActiveBadge: View {
    let machine: SessionMachine?

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(.green)
                .frame(width: 7, height: 7)
            Text(machine.map { "Active on \($0.name)" } ?? "Active")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
                .lineLimit(1)
        }
        .help("This session changed in the last few minutes, so it is probably still open")
    }
}

/// Hands the session to another installed assistant in a new terminal tab.
struct ContinueInMenu: View {
    @EnvironmentObject private var store: SessionStore
    let session: AssistantSession

    var body: some View {
        let targets = store.handoffTargets(for: session)
        if !targets.isEmpty {
            Menu {
                ForEach(targets) { target in
                    Button(target.displayName) {
                        Task { await store.continueSession(session, in: target) }
                    }
                }
            } label: {
                Label("Continue in", systemImage: "arrow.triangle.branch")
            }
            .help("Start another assistant in a new terminal tab with a handoff from this session")
        }
    }
}

/// Shares the clean conversation as a secret gist. Once shared, it copies
/// the link again, opens it, or deletes the gist.
struct ShareLinkButton: View {
    @EnvironmentObject private var store: SessionStore
    let session: AssistantSession
    @State private var copied = false

    var body: some View {
        if store.sharingSessionIDs.contains(session.id) {
            ProgressView()
                .controlSize(.small)
                .help("Uploading the session to a secret gist")
        } else if let shared = store.sharedSessions[session.id] {
            Menu {
                Button("Copy Link") { copyLink() }
                Button("Open in Browser") {
                    if let url = URL(string: shared.url) { NSWorkspace.shared.open(url) }
                }
                Divider()
                Button("Delete Shared Link", role: .destructive) {
                    Task { await store.deleteSharedLink(for: session) }
                }
            } label: {
                Label(copied ? "Link Copied" : "Shared", systemImage: copied ? "checkmark" : "link")
            } primaryAction: {
                copyLink()
            }
            .help("Shared as a secret gist. Click to copy the link.")
        } else {
            Button {
                Task {
                    await store.shareSession(session)
                    if store.sharedSessions[session.id] != nil { flashCopied() }
                }
            } label: {
                Label("Share Link", systemImage: "square.and.arrow.up")
            }
            .help("Upload the prompts and replies, without tool output, as a secret GitHub gist and copy the link")
        }
    }

    private func copyLink() {
        Task {
            await store.shareSession(session)
            flashCopied()
        }
    }

    private func flashCopied() {
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            copied = false
        }
    }
}

/// The file the session was read from, with a way to find it in Finder.
private struct SessionFileCard: View {
    @EnvironmentObject private var store: SessionStore
    let session: AssistantSession
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc")
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(sizeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(session.sourceURL.path)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Button("Show in Finder") {
                        store.showSessionFileInFinder(session)
                    }
                    Button(copied ? "Copied" : "Copy Path") {
                        store.copySessionFilePath(for: session)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.4))
                            copied = false
                        }
                    }
                }
                .buttonStyle(.link)
                .font(.callout)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
        .padding(12)
        .background(.quaternary.opacity(0.26), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var sizeLabel: String {
        guard session.fileSize > 0 else { return "Session file" }
        return "Session file · \(ByteCountFormatter.string(fromByteCount: session.fileSize, countStyle: .file))"
    }
}

private struct MetadataCard: View {
    let icon: String
    let label: String
    let value: String
    var tooltip: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .help(tooltip ?? value)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
        .padding(12)
        .background(.quaternary.opacity(0.26), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct TranscriptBubble: View {
    let entry: TranscriptEntry
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: roleIcon)
                Text(roleTitle)
                    .fontWeight(.semibold)
                if let timestamp = entry.timestamp {
                    SessionDateText(date: timestamp, style: .time)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            .foregroundStyle(roleColor)

            Text(entry.text)
                .font(.callout)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(bubbleColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var roleTitle: String {
        switch entry.role {
        case .user: "You"
        case .assistant: "Assistant"
        case .tool: "Tool"
        case .system: "System"
        }
    }

    private var roleIcon: String {
        switch entry.role {
        case .user: "person.fill"
        case .assistant: "sparkles"
        case .tool: "wrench.and.screwdriver.fill"
        case .system: "gearshape.fill"
        }
    }

    private var roleColor: Color {
        entry.role == .assistant ? color : .secondary
    }

    private var bubbleColor: Color {
        entry.role == .assistant ? color.opacity(0.075) : Color.secondary.opacity(0.055)
    }
}
