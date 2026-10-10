import Foundation
import OpenIslandCore
import Testing
@testable import OpenIslandApp

struct ProcessTerminalAppAdoptionTests {
    private func session(_ id: String, app: String, tty: String?, tool: AgentTool = .claudeCode) -> AgentSession {
        AgentSession(
            id: id, title: id, tool: tool, origin: .live, attachmentState: .attached, phase: .completed, summary: "", updatedAt: Date(),
            jumpTarget: JumpTarget(terminalApp: app, workspaceName: "w", paneTitle: "p", workingDirectory: "/tmp/w", terminalTTY: tty)
        )
    }

    private let key: (AgentSession) -> String? = { $0.jumpTarget?.terminalTTY }

    @Test
    func unknownSessionAdoptsProcessTerminalApp() {
        let result = ProcessMonitoringCoordinator.adoptingTerminalApps(
            sessions: [session("a", app: "Unknown", tty: "/dev/ttys000")],
            appByTTY: ["/dev/ttys000": "PyCharm"],
            ttyKey: key
        )
        #expect(result.first?.jumpTarget?.terminalApp == "PyCharm")
    }

    @Test
    func knownTerminalAppIsKept() {
        let result = ProcessMonitoringCoordinator.adoptingTerminalApps(
            sessions: [session("a", app: "Ghostty", tty: "/dev/ttys000")],
            appByTTY: ["/dev/ttys000": "PyCharm"],
            ttyKey: key
        )
        #expect(result.first?.jumpTarget?.terminalApp == "Ghostty")
    }

    @Test
    func unknownWithoutMatchingTTYStaysUnknown() {
        let result = ProcessMonitoringCoordinator.adoptingTerminalApps(
            sessions: [session("a", app: "Unknown", tty: "/dev/ttys001"), session("b", app: "Unknown", tty: nil)],
            appByTTY: ["/dev/ttys000": "PyCharm"],
            ttyKey: key
        )
        #expect(result.map { $0.jumpTarget?.terminalApp } == ["Unknown", "Unknown"])
    }

    @Test
    @MainActor
    func claudeDesktopSessionsStayVisibleForTwelveHours() {
        #expect(ProcessMonitoringCoordinator.claudeDesktopStalenessTimeout == 12 * 60 * 60)
    }
}
