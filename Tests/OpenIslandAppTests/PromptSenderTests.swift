import FocusCore
import Foundation
import OpenIslandCore
import Testing
@testable import OpenIslandApp

struct PromptSenderTests {
    @Test
    func iTermScriptPrefersSessionIDAndEscapes() {
        let script = TerminalPromptSender.iTermScript(text: TerminalPromptSender.normalized("say \"hi\"\nnext"), sessionID: "ABC-1", tty: "/dev/ttys001")
        #expect(script != nil)
        #expect(script?.contains("id of aSession as text is \"ABC-1\"") == true)
        #expect(script?.contains("tty of aSession is \"/dev/ttys001\"") == true)
        #expect(script?.contains("write text \"say \\\"hi\\\" next\"") == true)
    }

    @Test
    func iTermScriptWithTTYOnly() {
        let script = TerminalPromptSender.iTermScript(text: "go", sessionID: nil, tty: "/dev/ttys002")
        #expect(script != nil)
        #expect(script?.contains("id of aSession as text") == false)
        #expect(script?.contains("tty of aSession is \"/dev/ttys002\"") == true)
    }

    @Test
    func iTermScriptNilWithoutIdentifiers() {
        #expect(TerminalPromptSender.iTermScript(text: "go", sessionID: nil, tty: nil) == nil)
        #expect(TerminalPromptSender.iTermScript(text: "go", sessionID: "", tty: "") == nil)
    }

    @Test
    func terminalScriptMatchesTTYAndEscapes() {
        let script = TerminalPromptSender.terminalScript(text: TerminalPromptSender.normalized("a \"b\" \\ c\nd"), tty: "/dev/ttys003")
        #expect(script?.contains("tty of aTab is \"/dev/ttys003\"") == true)
        #expect(script?.contains("do script \"a \\\"b\\\" \\\\ c d\" in aTab") == true)
    }

    @Test
    func terminalScriptNilWithoutTTY() {
        #expect(TerminalPromptSender.terminalScript(text: "go", tty: "") == nil)
    }

    @Test
    func normalizerCollapsesLineBreaks() {
        #expect(TerminalPromptSender.normalized("  a\r\nb\rc\nd \n") == "a b c d")
        #expect(!TerminalPromptSender.normalized("x\ny").contains("\n"))
    }

    @Test
    func scriptsGuardRunningApp() {
        let guardLine = "if not (it is running) then return \"error\""
        #expect(TerminalPromptSender.iTermScript(text: "g", sessionID: "1", tty: nil)?.contains(guardLine) == true)
        #expect(TerminalPromptSender.terminalScript(text: "g", tty: "/dev/ttys1")?.contains(guardLine) == true)
    }

    @Test
    func routingDecisions() {
        func target(_ app: String, tmux: String? = nil) -> JumpTarget {
            JumpTarget(terminalApp: app, workspaceName: "w", paneTitle: "p", terminalTTY: "/dev/ttys001", tmuxTarget: tmux)
        }
        #expect(TerminalPromptSender.route(for: nil) == .unsupported)
        #expect(TerminalPromptSender.route(for: target("Warp")) == .unsupported)
        #expect(TerminalPromptSender.route(for: target("Warp", tmux: "s:0.0")) == .textSender)
        #expect(TerminalPromptSender.route(for: target("Ghostty")) == .textSender)
        #expect(TerminalPromptSender.route(for: target("iTerm")) == .iTerm)
        #expect(TerminalPromptSender.route(for: target("iTerm2")) == .iTerm)
        #expect(TerminalPromptSender.route(for: target("Terminal")) == .terminal)
        #expect(TerminalPromptSender.route(for: target("apple_terminal")) == .terminal)
    }
}
