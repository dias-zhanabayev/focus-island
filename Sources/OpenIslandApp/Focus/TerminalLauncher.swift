import AppKit
import FocusCore
import Foundation

protocol TerminalLaunching: Sendable {
    func run(command: String, in terminal: ResumeTerminal) throws
}

enum TerminalLaunchError: Error {
    case scriptFailed(String)
}

struct AppleScriptTerminalLauncher: TerminalLaunching {
    static func script(for terminal: ResumeTerminal, command: String) -> String? {
        let quoted = AppleScriptQuoting.string(command)
        switch terminal {
        case .terminal:
            return "tell application \"Terminal\"\nactivate\ndo script \(quoted)\nend tell"
        case .iTerm:
            return "tell application \"iTerm\"\nactivate\nset newWindow to (create window with default profile)\ntell current session of newWindow to write text \(quoted)\nend tell"
        case .ghostty:
            return nil
        }
    }

    func run(command: String, in terminal: ResumeTerminal) throws {
        if let source = Self.script(for: terminal, command: command) {
            try MainActor.assumeIsolated {
                var error: NSDictionary?
                NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error {
                    throw TerminalLaunchError.scriptFailed(error.description)
                }
            }
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-na", "Ghostty", "--args", "-e", "/bin/zsh", "-lc", "\(command); exec /bin/zsh -l"]
        try process.run()
    }
}
