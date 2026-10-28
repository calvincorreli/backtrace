import AppKit
import SwiftUI

struct SessionListView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var sessionForTagEditing: AssistantSession?

    private var title: String {
        switch store.selection {
        case .all: "Sessions"
        case .assistant(let kind): kind.displayName
        case .tag(let id): store.tag(withID: id)?.name ?? "Tag"
        case .trackedFolder(let path): URL(fileURLWithPath: path).lastPathComponent
        case .claudeConfigDirectory(let path):
            store.claudeConfigDirectories.first { $0.id == path }?.name ?? "Claude Code Profile"
        }
    }

    var body: some View {
        Group {
            if store.visibleSessions.isEmpty {
                ContentUnavailableView {
                    Label(
                        store.searchText.isEmpty ? "No Sessions" : "No Results",
                        systemImage: store.searchText.isEmpty ? "bubble.left.and.exclamationmark.bubble.right" : "magnifyingglass"
                    )
                } description: {
                    Text(emptyMessage)
                } actions: {
                    if !store.searchText.isEmpty {
                        Button("Clear Search") { store.searchText = "" }
                    } else {
                        Button("Refresh") { Task { await store.refresh() } }
                    }
                }
            } else {
                List(selection: $store.selectedSessionID) {
                    ForEach(store.visibleSessions) { session in
                        SessionRow(session: session)
                            .tag(session.id)
                            .contextMenu {
                                Button("Copy Resume Command") {
                                    store.copyResumeCommand(for: session)
                                }
                                Button("Copy Session ID") {
                                    store.copySessionID(for: session)
                                }
                                Button(store.sharedSessions[session.id] == nil ? "Share Link (Secret Gist)" : "Copy Shared Link") {
                                    Task { await store.shareSession(session) }
                                }
                                ResumeWithMenu(session: session)
                                ContinueInMenu(session: session)
                                Button(store.isFavorite(session) ? "Unpin Session" : "Pin Session") {
                                    store.toggleFavorite(session)
                                }
                                Button("Edit Tags…") {
                                    sessionForTagEditing = session
                                }
                                Divider()
                                Button("Show Session File in Finder") {
                                    store.showSessionFileInFinder(session)
                                }
                                Button("Copy Session File Path") {
                                    store.copySessionFilePath(for: session)
                                }
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(store.indexStatus ?? "")
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Title, tag, folder, branch, or ID")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await store.refresh() }
                } label: {
                    if store.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(store.isScanning)
                .help("Refresh Sessions (⌘R)")
            }
        }
        .sheet(item: $sessionForTagEditing) { session in
            SessionTagEditor(session: session)
                .environmentObject(store)
        }
    }

    private var emptyMessage: String {
        if !store.searchText.isEmpty {
            return "Try a session title, tag, project folder, branch, model, or session ID."
        }
        if store.installations.isEmpty {
            return "No supported CLI assistant was detected in your shell or common install locations."
        }
        return "No saved sessions were found for this selection."
    }
}

private struct SessionRow: View {
    @EnvironmentObject private var store: SessionStore
    let session: AssistantSession

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            AssistantIcon(kind: session.assistant, size: 31)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(session.title)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                    if store.isFavorite(session) {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(session.assistant.color)
                    }
                    Spacer(minLength: 4)
                    if session.isActive() {
                        ActiveBadge(machine: nil)
                    } else {
                        SessionDateText(date: session.updatedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 6) {
                    Label(session.projectName, systemImage: "folder")
                    if let branch = session.gitBranch, !branch.isEmpty {
                        Text("·")
                        Label(branch, systemImage: "arrow.triangle.branch")
                    }
                    if let machine = store.machine(for: session) {
                        Text("·")
                        Label(machine.name, systemImage: "laptopcomputer")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if !sessionTags.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(Array(sessionTags.prefix(3))) { tag in
                            TagPill(tag: tag, compact: true)
                        }
                        if sessionTags.count > 3 {
                            Text("+\(sessionTags.count - 3)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                if !store.searchText.isEmpty, let excerpt = store.contentMatches[session.id], !excerpt.isEmpty {
                    Label(excerpt, systemImage: "text.magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if let summary = session.summary, summary != session.title {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var sessionTags: [SessionTag] {
        store.tags(for: session)
    }
}

/// Resumes a session in a new terminal tab with the assistant's executable
/// or any shell alias that starts it.
private struct ResumeWithMenu: View {
    @EnvironmentObject private var store: SessionStore
    let session: AssistantSession

    var body: some View {
        Menu("Resume in Terminal With") {
            Button(session.assistant.executableName) {
                Task { await store.resumeInTerminal(session, launcher: nil) }
            }
            ForEach(store.launchers(for: session.assistant)) { alias in
                Button(alias.name) {
                    Task { await store.resumeInTerminal(session, launcher: alias.name) }
                }
            }
        }
    }
}
