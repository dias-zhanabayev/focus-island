import FocusCore
import Foundation
import OpenIslandCore

enum PromptSendResult: Equatable, Sendable {
    case sent
    case unsupported
    case failed
}

protocol PromptSending: Sendable {
    func send(_ text: String, to session: AgentSession) async -> PromptSendResult
}

struct TerminalPromptSender: PromptSending {
    enum Route: Equatable, Sendable {
        case textSender
        case iTerm
        case terminal
        case unsupported
    }

    static func route(for target: JumpTarget?) -> Route {
        guard let target else { return .unsupported }
        if target.tmuxTarget != nil { return .textSender }
        let app = target.terminalApp.lowercased()
        if app == "ghostty" { return .textSender }
        if app.contains("iterm") { return .iTerm }
        if app == "terminal" || app == "apple_terminal" { return .terminal }
        return .unsupported
    }

    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func iTermScript(text: String, sessionID: String?, tty: String?) -> String? {
        let id = sessionID?.isEmpty == false ? sessionID : nil
        let device = tty?.isEmpty == false ? tty : nil
        guard id != nil || device != nil else { return nil }
        var conditions: [String] = []
        if let id {
            conditions.append("id of aSession as text is \(AppleScriptQuoting.string(id))")
        }
        if let device {
            conditions.append("tty of aSession is \(AppleScriptQuoting.string(device))")
        }
        return """
        tell application "iTerm"
        if not (it is running) then return "error"
        repeat with aWindow in windows
        repeat with aTab in tabs of aWindow
        repeat with aSession in sessions of aTab
        if \(conditions.joined(separator: " or ")) then
        tell aSession to write text \(AppleScriptQuoting.string(text))
        return "ok"
        end if
        end repeat
        end repeat
        end repeat
        return "error"
        end tell
        """
    }

    static func terminalScript(text: String, tty: String) -> String? {
        guard !tty.isEmpty else { return nil }
        return """
        tell application "Terminal"
        if not (it is running) then return "error"
        repeat with aWindow in windows
        repeat with aTab in tabs of aWindow
        if tty of aTab is \(AppleScriptQuoting.string(tty)) then
        do script \(AppleScriptQuoting.string(text)) in aTab
        return "ok"
        end if
        end repeat
        end repeat
        return "error"
        end tell
        """
    }

    func send(_ rawText: String, to session: AgentSession) async -> PromptSendResult {
        let text = Self.normalized(rawText)
        let target = session.jumpTarget
        switch Self.route(for: target) {
        case .unsupported:
            return .unsupported
        case .textSender:
            let ok = await Task.detached { TerminalTextSender.send(text, to: session) }.value
            return ok ? .sent : .failed
        case .iTerm:
            guard let script = Self.iTermScript(text: text, sessionID: target?.terminalSessionID, tty: target?.terminalTTY) else {
                return .unsupported
            }
            return await Self.runOsascript(script) ? .sent : .failed
        case .terminal:
            guard let script = Self.terminalScript(text: text, tty: target?.terminalTTY ?? "") else {
                return .unsupported
            }
            return await Self.runOsascript(script) ? .sent : .failed
        }
    }

    static func runOsascript(_ script: String, timeout: TimeInterval = 2) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        let start = Date()
        while process.isRunning {
            if Date().timeIntervalSince(start) > timeout {
                process.terminate()
                return false
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard process.terminationStatus == 0 else { return false }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return output == "ok"
    }
}
