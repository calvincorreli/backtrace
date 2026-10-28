import SwiftUI

@main
@MainActor
struct BacktraceApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var store: SessionStore
    @StateObject private var updater = AppUpdater()

    init() {
        let settings = SettingsStore()
        _settings = StateObject(wrappedValue: settings)
        _store = StateObject(wrappedValue: SessionStore(
            settings: settings,
            machineResolver: SyncthingMachineResolver.detect(),
            searchIndex: SearchIndex.standard()
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(updater)
                .frame(minWidth: 980, minHeight: 620)
                .preferredColorScheme(settings.appearance.preferredColorScheme)
        }
        .defaultSize(width: 1_220, height: 780)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await updater.check(userInitiated: true) }
                }
                .disabled(updater.state == .checking || updater.state == .updating)
            }

            CommandGroup(after: .newItem) {
                Button("Refresh Sessions") {
                    Task { await store.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Copy Resume Command") {
                    if let session = store.selectedSession {
                        store.copyResumeCommand(for: session)
                    }
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(store.selectedSession == nil)

                Button("Copy Session ID") {
                    if let session = store.selectedSession {
                        store.copySessionID(for: session)
                    }
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(store.selectedSession == nil)

                Button("Show Session File in Finder") {
                    if let session = store.selectedSession {
                        store.showSessionFileInFinder(session)
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(store.selectedSession == nil)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(updater)
                .preferredColorScheme(settings.appearance.preferredColorScheme)
        }
    }
}
