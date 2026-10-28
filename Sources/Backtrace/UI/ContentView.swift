import Combine
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: SessionStore
    private let refreshTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 238, max: 285)
        } content: {
            SessionListView()
                .navigationSplitViewColumnWidth(min: 320, ideal: 390, max: 500)
        } detail: {
            if let session = store.selectedSession {
                SessionDetailView(session: session)
                    .id(session.id)
            } else {
                EmptyDetailView()
            }
        }
        .task {
            await store.refresh()
        }
        .onReceive(refreshTimer) { _ in
            Task { await store.refresh() }
        }
        .alert("Something Went Wrong", isPresented: Binding(
            get: { store.handoffError != nil },
            set: { if !$0 { store.handoffError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.handoffError ?? "")
        }
        .onChange(of: store.visibleSessions.map(\.id)) { _, ids in
            if let selected = store.selectedSessionID, ids.contains(selected) { return }
            store.selectedSessionID = ids.first
        }
    }
}

private struct EmptyDetailView: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        ContentUnavailableView {
            BacktraceMark(size: 58)
        } description: {
            if store.isScanning {
                Text("Finding local assistant sessions…")
            } else if store.installations.isEmpty {
                Text("Backtrace will show sessions when Codex, Claude Code, Grok Build, or OpenCode is installed.")
            } else {
                Text("Select a session to inspect its details and copy its resume command.")
            }
        } actions: {
            if store.installations.isEmpty, !store.isScanning {
                Button("Scan Again") {
                    Task { await store.refresh() }
                }
            }
        }
    }
}
