import AppKit
import Foundation

/// Opens a new terminal tab and types a command into its shell, so the command
/// runs with the user's own PATH and the tab stays open afterward.
enum TerminalLauncher {
    enum Terminal {
        case ghostty
        case appleTerminal

        var displayName: String {
            switch self {
            case .ghostty: "Ghostty"
            case .appleTerminal: "Terminal"
            }
        }

        var script: String {
            switch self {
            case .ghostty:
                """
                on run argv
                    set theCommand to item 1 of argv
                    tell application "Ghostty"
                        set cfg to new surface configuration
                        set initial input of cfg to theCommand & linefeed
                        if (count of windows) > 0 then
                            new tab in front window with configuration cfg
                        else
                            new window with configuration cfg
                        end if
                        activate
                    end tell
                end run
                """
            case .appleTerminal:
                """
                on run argv
                    set theCommand to item 1 of argv
                    tell application "Terminal"
                        activate
                        do script theCommand
                    end tell
                end run
                """
            }
        }
    }

    /// macOS has no default-terminal setting, so prefer Ghostty when it is
    /// installed and fall back to the Terminal that ships with the system.
    @MainActor
    static func preferred() -> Terminal {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") != nil
            ? .ghostty
            : .appleTerminal
    }

    /// Returns nil on success, or a message that says why the tab did not open.
    static func openTab(running command: String, in terminal: Terminal) async -> String? {
        let result = await ProcessRunner.runCancellable(
            executable: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", terminal.script, command]
        )
        guard let result else { return "Could not start \(terminal.displayName)." }
        guard result.status != 0 else { return nil }
        return result.text.isEmpty
            ? "\(terminal.displayName) did not open a new tab."
            : "\(terminal.displayName) did not open a new tab: \(result.text)"
    }
}
