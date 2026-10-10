import Foundation

public enum ShellQuoting {
    public static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum AppleScriptQuoting {
    public static func string(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

public enum ResumeCommand {
    public static func resume(sessionID: String, cwd: String) -> String {
        "cd \(ShellQuoting.singleQuoted(cwd)) && claude --resume \(ShellQuoting.singleQuoted(sessionID))"
    }

    public static func newSession(cwd: String) -> String {
        "cd \(ShellQuoting.singleQuoted(cwd)) && claude"
    }
}
