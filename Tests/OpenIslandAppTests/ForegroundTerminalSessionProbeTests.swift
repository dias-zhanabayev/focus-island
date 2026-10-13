import Testing
@testable import OpenIslandApp
import OpenIslandCore

@Suite(.serialized)
struct ForegroundTerminalSessionProbeTests {
    @Test
    func matchesGhosttyFrontmostTerminalBySessionID() async {
        let probe = ForegroundTerminalSessionProbe(
            frontmostBundleIdentifierProvider: { "com.mitchellh.ghostty" },
            appleScriptRunner: { _ in "ghostty-frontmost" }
        )

        let matches = await probe.matches(
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "open-island",
                paneTitle: "claude ~/open-island",
                terminalSessionID: "ghostty-frontmost"
            )
        )

        #expect(matches)
    }

    @Test
    func matchesTerminalFrontmostTabByTTY() async {
        let probe = ForegroundTerminalSessionProbe(
            frontmostBundleIdentifierProvider: { "com.apple.Terminal" },
            appleScriptRunner: { _ in "ttys001" }
        )

        let matches = await probe.matches(
            jumpTarget: JumpTarget(
                terminalApp: "Terminal",
                workspaceName: "open-island",
                paneTitle: "claude ~/open-island",
                terminalTTY: "/dev/ttys001"
            )
        )

        #expect(matches)
    }

    @Test
    func matchesITermFrontmostSessionByTTYFallback() async {
        let probe = ForegroundTerminalSessionProbe(
            frontmostBundleIdentifierProvider: { "com.googlecode.iterm2" },
            appleScriptRunner: { _ in "different-session\u{1f}/dev/ttys002" }
        )

        let matches = await probe.matches(
            jumpTarget: JumpTarget(
                terminalApp: "iTerm",
                workspaceName: "open-island",
                paneTitle: "claude ~/open-island",
                terminalSessionID: "tracked-session",
                terminalTTY: "/dev/ttys002"
            )
        )

        #expect(matches)
    }

    @Test
    func returnsFalseForUnsupportedFrontmostApp() async {
        let probe = ForegroundTerminalSessionProbe(
            frontmostBundleIdentifierProvider: { "com.example.Editor" },
            appleScriptRunner: { _ in "" }
        )

        let matches = await probe.matches(
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "open-island",
                paneTitle: "claude ~/open-island",
                terminalSessionID: "ghostty-frontmost"
            )
        )

        #expect(!matches)
    }

    func desktopSession(_ id: String) -> AgentSession {
        AgentSession(
            id: id, title: id, tool: .claudeCode, origin: .live, attachmentState: .attached, phase: .completed, summary: "", updatedAt: .now,
            jumpTarget: JumpTarget(terminalApp: ClaudeDesktopSessionLocator.terminalAppName, workspaceName: "api", paneTitle: "")
        )
    }

    @Test
    func matchesClaudeDesktopSessionThatIsOpen() async {
        let probe = ForegroundTerminalSessionProbe(
            frontmostBundleIdentifierProvider: { ForegroundTerminalSessionProbe.claudeDesktopBundleIdentifier },
            appleScriptRunner: { _ in "" },
            focusedDesktopSessionProvider: { "open" }
        )
        #expect(await probe.matches(session: desktopSession("open")))
        #expect(!(await probe.matches(session: desktopSession("other"))))
    }

    @Test
    func claudeDesktopSessionIsNotOnScreenWhenAnotherAppIsFrontmost() async {
        let probe = ForegroundTerminalSessionProbe(
            frontmostBundleIdentifierProvider: { "com.mitchellh.ghostty" },
            appleScriptRunner: { _ in "" },
            focusedDesktopSessionProvider: { "open" }
        )
        #expect(!(await probe.matches(session: desktopSession("open"))))
    }
}
