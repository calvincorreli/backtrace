import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var updater: AppUpdater
    @State private var isAddingConfigDirectory = false

    var body: some View {
        TabView {
            Form {
                Section("Appearance") {
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Label(appearance.displayName, systemImage: appearance.symbolName)
                                .tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section("Detected assistants") {
                    if store.installations.isEmpty {
                        Text("No supported assistants detected")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.installations) { installation in
                            HStack(spacing: 10) {
                                AssistantIcon(kind: installation.kind, size: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(installation.kind.displayName)
                                    Text(installation.version ?? installation.executableURL.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }

                Section {
                    ForEach(store.claudeConfigDirectories) { directory in
                        ClaudeConfigDirectoryRow(directory: directory)
                    }

                    Button {
                        isAddingConfigDirectory = true
                    } label: {
                        Label("Add Directory…", systemImage: "plus")
                    }

                    if !settings.hiddenClaudeConfigDirectories.isEmpty {
                        Button {
                            settings.restoreHiddenClaudeConfigDirectories()
                            Task { await store.refresh() }
                        } label: {
                            Label(
                                "Restore \(settings.hiddenClaudeConfigDirectories.count) Hidden",
                                systemImage: "arrow.uturn.backward"
                            )
                        }
                    }
                } header: {
                    Text("Claude Code config directories")
                } footer: {
                    Text("Claude Code reads one config directory at a time. Add the ones you use and Backtrace reads them together, setting `CLAUDE_CONFIG_DIR` in the resume command for any session outside the default directory. Backtrace reads only the directories listed here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(updater.versionDescription)
                            if let lastChecked = updater.lastChecked {
                                Text("Last checked \(lastChecked.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Check for Updates…") {
                            Task { await updater.check(userInitiated: true) }
                        }
                        .disabled(updater.state == .checking || updater.state == .updating)
                    }
                } header: {
                    Text("Updates")
                } footer: {
                    Text("Backtrace checks GitHub every few hours. An update pulls the new code into its source folder, builds it, and restarts the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Label("Session files are read-only", systemImage: "lock.shield.fill")
                    Text("Backtrace reads local transcript metadata and previews. It never uploads conversations, modifies a session, or launches an assistant.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section {
                    if settings.trackedFolders.isEmpty {
                        Text("Add project folders to organize or limit the session list. The assistants’ global history stores are still discovered automatically.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(settings.trackedFolders) { folder in
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading) {
                                    Text(folder.name)
                                    Text(folder.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button {
                                    settings.removeFolder(folder)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Button {
                        settings.chooseAndAddFolder()
                    } label: {
                        Label("Add Folder…", systemImage: "plus")
                    }
                } header: {
                    Text("Tracked project folders")
                }

                if !settings.trackedFolders.isEmpty {
                    Section {
                        Toggle("Show only sessions in tracked folders", isOn: $settings.restrictToTrackedFolders)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Folders", systemImage: "folder") }
        }
        .frame(width: 590, height: 450)
        .sheet(isPresented: $isAddingConfigDirectory) {
            AddClaudeConfigDirectorySheet()
                .environmentObject(store)
                .environmentObject(settings)
        }
    }
}

private struct AddClaudeConfigDirectorySheet: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @FocusState private var isFieldFocused: Bool

    private var validation: ClaudeConfigDirectoryValidation {
        ClaudeConfigDirectories.validate(
            path,
            home: FileManager.default.homeDirectoryForCurrentUser,
            existing: store.claudeConfigDirectories
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Add a Claude Code config directory")
                    .font(.headline)
                Text("Type the path `CLAUDE_CONFIG_DIR` points at. It is the folder that contains `projects`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("~/.claude-work", text: $path)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .focused($isFieldFocused)
                .onSubmit(add)

            Label {
                Text(validation.message ?? resolvedPathDescription)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: statusSymbol)
            }
            .font(.caption)
            .foregroundStyle(statusColor)
            .frame(minHeight: 30, alignment: .top)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Directory", action: add)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(validation.url == nil)
            }
        }
        .padding(20)
        .frame(width: 430)
        .onAppear { isFieldFocused = true }
    }

    private var resolvedPathDescription: String {
        if case .accepted(let url, _) = validation {
            return "Backtrace will read \(url.path)."
        }
        return "Paths starting with ~ or a bare name resolve inside your home folder."
    }

    private var statusSymbol: String {
        switch validation {
        case .empty: "info.circle"
        case .rejected: "exclamationmark.triangle.fill"
        case .accepted(_, let note): note == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch validation {
        case .empty: .secondary
        case .rejected: .red
        case .accepted(_, let note): note == nil ? .green : .orange
        }
    }

    private func add() {
        guard let url = validation.url else { return }
        settings.addClaudeConfigDirectory(url)
        dismiss()
        Task { await store.refresh() }
    }
}

private struct ClaudeConfigDirectoryRow: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var settings: SettingsStore
    let directory: ClaudeConfigDirectory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(AssistantKind.claude.color)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(directory.name)
                    Text(directory.source.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.7), in: Capsule())
                }
                Text(directory.url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if directory.exists {
                Text("\(store.count(in: directory)) sessions")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Label("Not found", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("This folder no longer exists.")
            }
            Button {
                settings.removeClaudeConfigDirectory(directory)
                Task { await store.refresh() }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(directory.source == .added ? "Stop reading this directory" : "Hide this directory")
        }
    }
}
