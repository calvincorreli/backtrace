import SwiftUI

struct UpdateToolbarButton: View {
    @EnvironmentObject private var updater: AppUpdater

    var body: some View {
        if updater.state == .updating {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Updating…")
            }
            .help("Building the new version. Backtrace restarts when it is done.")
        } else {
            Button {
                updater.isShowingUpdate = true
            } label: {
                Label("Update Available", systemImage: "arrow.down.circle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .tint(.accentColor)
            .help("A new version of Backtrace is on GitHub.")
        }
    }
}

struct UpdateSheet: View {
    @EnvironmentObject private var updater: AppUpdater
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch updater.state {
            case let .available(update):
                Label("A new version of Backtrace is ready", systemImage: "arrow.down.circle.fill")
                    .font(.headline)
                Text("\(update.changes.count) new \(update.changes.count == 1 ? "change" : "changes") on GitHub:")
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(update.changes.enumerated()), id: \.offset) { _, change in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•")
                                Text(change).textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                Text("Updating builds the app from source. It takes about a minute, then Backtrace restarts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Later") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Update and Restart") {
                        updater.installUpdate()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            case .upToDate:
                Label("Backtrace is up to date", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                Text(updater.versionDescription)
                    .foregroundStyle(.secondary)
                closeButton
            case let .failed(message):
                Label("Update failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                ScrollView {
                    Text(message)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                closeButton
            case .checking, .updating, .idle:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(updater.state == .updating ? "Building the new version…" : "Checking GitHub…")
                }
                closeButton
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var closeButton: some View {
        HStack {
            Spacer()
            Button("OK") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
