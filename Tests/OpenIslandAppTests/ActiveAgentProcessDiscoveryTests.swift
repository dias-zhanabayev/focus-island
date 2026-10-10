import Foundation
import Testing
@testable import OpenIslandApp
import OpenIslandCore

struct ActiveAgentProcessDiscoveryTests {
    @Test
    func discoverOnlyReturnsInteractiveClaudeProcesses() {
        let discovery = ActiveAgentProcessDiscovery { executablePath, arguments in
            if executablePath == "/bin/ps" {
                return """
                  101 1 ?? /Users/test/.local/bin/claude --resume abc
                  102 301 ttys002 claude
                  301 900 ttys002 -/opt/homebrew/bin/fish
                  401 900 ttys001 -/opt/homebrew/bin/fish
                  900 1 ?? /Applications/Ghostty.app/Contents/MacOS/ghostty
                """
            }

            guard executablePath == "/usr/sbin/lsof",
                  let pid = arguments.dropFirst(2).first else {
                return nil
            }

            switch pid {
            case "102":
                return """
                fcwd
                n/tmp/open-island
                """
            default:
                Issue.record("unexpected lsof lookup for pid \(pid)")
                return nil
            }
        }

        let snapshots = discovery.discover()

        #expect(snapshots.count == 1)
        #expect(snapshots.contains(.init(
            tool: .claudeCode,
            sessionID: nil,
            workingDirectory: "/tmp/open-island",
            terminalTTY: "/dev/ttys002",
            terminalApp: "Ghostty"
        )))
    }

    @Test
    func discoverClaudeSessionIDFromResumeFlagWhenTranscriptIsNotOpen() {
        let discovery = ActiveAgentProcessDiscovery { executablePath, _ in
            if executablePath == "/bin/ps" {
                return """
                  102 301 ttys002 /Users/test/.local/bin/claude --resume 9df061a9-6836-4ccb-b83b-aea3196eca43 --permission-mode acceptEdits
                  301 900 ttys002 -/opt/homebrew/bin/fish
                  900 1 ?? /Applications/Ghostty.app/Contents/MacOS/ghostty
                """
            }

            guard executablePath == "/usr/sbin/lsof" else {
                return nil
            }

            return """
            fcwd
            n/tmp/open-island
            """
        }

        let snapshots = discovery.discover()

        #expect(snapshots == [
            .init(
                tool: .claudeCode,
                sessionID: "9df061a9-6836-4ccb-b83b-aea3196eca43",
                workingDirectory: "/tmp/open-island",
                terminalTTY: "/dev/ttys002",
                terminalApp: "Ghostty"
            ),
        ])
    }

    /// VS Code forks (Cursor, Windsurf, Trae, Qoder) bundle Electron's "Code
    /// Helper" inside their .app bundles. Their helper paths therefore contain
    /// both "/<fork>.app/" and "/code helper", and Open Island used to match
    /// the broad "/code helper" check first → mis-attributed every fork to
    /// stock VS Code (#415). Verify each fork is recognized correctly.
    @Test(arguments: [
        ("/Applications/Cursor.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper", "Cursor"),
        ("/Applications/Windsurf.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper", "Windsurf"),
        ("/Applications/Trae.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper", "Trae"),
        ("/Applications/Qoder.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper", "Qoder"),
        ("/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper", "VS Code"),
    ])
    func recognizesVSCodeForkBeforeFallingBackToVSCode(parentCommand: String, expectedTerminal: String) {
        let discovery = ActiveAgentProcessDiscovery { executablePath, arguments in
            if executablePath == "/bin/ps" {
                return """
                  102 301 ttys002 /Users/test/.local/bin/claude
                  301 900 ttys002 -/opt/homebrew/bin/fish
                  900 1 ?? \(parentCommand)
                """
            }
            guard executablePath == "/usr/sbin/lsof" else {
                return nil
            }
            return """
            fcwd
            n/tmp/open-island
            """
        }

        let snapshots = discovery.discover()

        #expect(snapshots == [
            .init(
                tool: .claudeCode,
                sessionID: nil,
                workingDirectory: "/tmp/open-island",
                terminalTTY: "/dev/ttys002",
                terminalApp: expectedTerminal
            ),
        ])
    }

}
