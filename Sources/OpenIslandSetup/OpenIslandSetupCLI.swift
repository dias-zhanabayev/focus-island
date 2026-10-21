import Foundation
import OpenIslandCore

@main
struct OpenIslandSetupCLI {
    static func main() {
        do {
            let command = try SetupCommand(arguments: Array(CommandLine.arguments.dropFirst()))
            try command.run()
        } catch let error as SetupError {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

private struct SetupCommand {
    enum Action: String {
        case installClaude
        case uninstallClaude
        case statusClaude
    }

    let action: Action
    let claudeDirectory: URL
    let hooksBinary: URL?

    init(arguments: [String]) throws {
        guard let rawAction = arguments.first,
              let action = Action(rawValue: rawAction) else {
            throw SetupError.usage
        }

        self.action = action

        var hooksBinary: URL?
        var claudeDirectory = ClaudeConfigDirectory.resolved()

        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--hooks-binary":
                index += 1
                guard index < arguments.count else {
                    throw SetupError.missingValue("--hooks-binary")
                }
                hooksBinary = URL(fileURLWithPath: arguments[index]).standardizedFileURL

            case "--claude-dir":
                index += 1
                guard index < arguments.count else {
                    throw SetupError.missingValue("--claude-dir")
                }
                claudeDirectory = URL(fileURLWithPath: arguments[index]).standardizedFileURL

            default:
                throw SetupError.unexpectedArgument(arguments[index])
            }

            index += 1
        }

        if action == .installClaude, hooksBinary == nil {
            hooksBinary = HooksBinaryLocator.locate()
        }

        self.claudeDirectory = claudeDirectory
        self.hooksBinary = hooksBinary
    }

    func run() throws {
        switch action {
        case .installClaude:
            try installClaude()
        case .uninstallClaude:
            try uninstallClaude()
        case .statusClaude:
            try statusClaude()
        }
    }

    private func installClaude() throws {
        guard let hooksBinary else {
            throw SetupError.usage
        }

        let manager = ClaudeHookInstallationManager(claudeDirectory: claudeDirectory)
        let status = try manager.install(hooksBinaryURL: hooksBinary)

        print("Installed Open Island Claude hooks.")
        print("Claude dir: \(status.claudeDirectory.path)")
        print("Hooks binary: \(hooksBinary.path)")
        if status.hasClaudeIslandHooks {
            print("Note: claude-island hooks are still present alongside Open Island hooks.")
        }
    }

    private func uninstallClaude() throws {
        let manager = ClaudeHookInstallationManager(claudeDirectory: claudeDirectory)
        let status = try manager.uninstall()

        print("Removed Open Island Claude hooks.")
        print("Claude dir: \(status.claudeDirectory.path)")
        if status.hasClaudeIslandHooks {
            print("Preserved claude-island hooks.")
        }
    }

    private func statusClaude() throws {
        let manager = ClaudeHookInstallationManager(claudeDirectory: claudeDirectory)
        let status = try manager.status(hooksBinaryURL: hooksBinary)

        print("Claude dir: \(status.claudeDirectory.path)")
        print("Managed hooks present: \(status.managedHooksPresent ? "yes" : "no")")
        print("claude-island hooks present: \(status.hasClaudeIslandHooks ? "yes" : "no")")
        if let hooksBinary {
            print("Hooks binary: \(hooksBinary.path)")
        }
        if let manifest = status.manifest {
            print("Manifest: present")
            print("Hook command: \(manifest.hookCommand)")
        } else {
            print("Manifest: missing")
        }
    }
}

private enum SetupError: Error, LocalizedError {
    case usage
    case missingValue(String)
    case unexpectedArgument(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            """
            Usage:
              swift run OpenIslandSetup installClaude [--hooks-binary /abs/path/to/OpenIslandHooks] [--claude-dir /abs/path/to/.claude]
              swift run OpenIslandSetup uninstallClaude [--claude-dir /abs/path/to/.claude]
              swift run OpenIslandSetup statusClaude [--hooks-binary /abs/path/to/OpenIslandHooks] [--claude-dir /abs/path/to/.claude]
            """
        case let .missingValue(flag):
            "Missing value for \(flag)"
        case let .unexpectedArgument(argument):
            "Unexpected argument: \(argument)"
        }
    }
}
