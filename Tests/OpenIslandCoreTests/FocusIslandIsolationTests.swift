import Foundation
import Testing
@testable import OpenIslandCore

struct FocusIslandIsolationTests {
    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-island-isolation-\(UUID().uuidString)", isDirectory: true)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func commands(in settings: [String: Any]) -> [String: [String]] {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        var result: [String: [String]] = [:]
        for (event, value) in hooks {
            for group in value as? [[String: Any]] ?? [] {
                for hook in group["hooks"] as? [[String: Any]] ?? [] {
                    if let command = hook["command"] as? String {
                        result[event, default: []].append(command)
                    }
                }
            }
        }
        return result
    }

    @Test
    func hookInstallAndUninstallTouchOnlyFocusIslandEntries() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let claudeDirectory = root.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)

        let openIslandCommand = "'/Users/u/Library/Application Support/OpenIsland/bin/OpenIslandHooks' --source claude"
        let vibeIslandCommand = "'/Users/u/Library/Application Support/VibeIsland/bin/VibeIslandHooks' --source claude"
        let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "Stop"]
        var hooks: [String: Any] = [:]
        for event in events {
            hooks[event] = [
                ["hooks": [["type": "command", "command": openIslandCommand]]],
                ["hooks": [["type": "command", "command": vibeIslandCommand]]],
            ]
        }
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: ["hooks": hooks]).write(to: settingsURL)

        let vibeManifestURL = claudeDirectory.appendingPathComponent("vibe-island-claude-hooks-install.json")
        let vibeManifestData = Data(#"{"hookCommand":"\#(vibeIslandCommand)","installedAt":"2026-01-01T00:00:00Z"}"#.utf8)
        try vibeManifestData.write(to: vibeManifestURL)

        let sourceBinary = root.appendingPathComponent("build/OpenIslandHooks")
        try FileManager.default.createDirectory(at: sourceBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: sourceBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sourceBinary.path)
        let managedBinary = root
            .appendingPathComponent("Library/Application Support/FocusIsland/bin/OpenIslandHooks")

        let manager = ClaudeHookInstallationManager(
            claudeDirectory: claudeDirectory,
            managedHooksBinaryURL: managedBinary
        )
        try manager.install(hooksBinaryURL: sourceBinary)
        try manager.install(hooksBinaryURL: sourceBinary)

        let installed = commands(in: try readJSON(settingsURL))
        for event in events {
            let list = try #require(installed[event])
            #expect(list.contains(openIslandCommand))
            #expect(list.contains(vibeIslandCommand))
            #expect(list.filter { $0.contains("FocusIsland") }.count == 1)
        }
        #expect(try Data(contentsOf: vibeManifestURL) == vibeManifestData)

        try manager.uninstall()

        let remaining = commands(in: try readJSON(settingsURL))
        for event in events {
            let list = try #require(remaining[event])
            #expect(list.sorted() == [openIslandCommand, vibeIslandCommand].sorted())
        }
        #expect(try Data(contentsOf: vibeManifestURL) == vibeManifestData)
        #expect(!FileManager.default.fileExists(
            atPath: claudeDirectory.appendingPathComponent(ClaudeHookInstallerManifest.fileName).path
        ))
    }

    @Test
    func uninstallIgnoresLeftoverVibeIslandManifest() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let claudeDirectory = root.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        let vibeCommand = "'/Users/u/Library/Application Support/VibeIsland/bin/VibeIslandHooks' --source claude"
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: [
            "hooks": ["Stop": [["hooks": [["type": "command", "command": vibeCommand]]]]],
        ]).write(to: settingsURL)
        try Data(#"{"hookCommand":"\#(vibeCommand)","installedAt":"2026-01-01T00:00:00Z"}"#.utf8)
            .write(to: claudeDirectory.appendingPathComponent("vibe-island-claude-hooks-install.json"))

        let manager = ClaudeHookInstallationManager(
            claudeDirectory: claudeDirectory,
            managedHooksBinaryURL: root.appendingPathComponent("FocusIsland/bin/OpenIslandHooks")
        )
        try manager.uninstall()

        #expect(commands(in: try readJSON(settingsURL))["Stop"] == [vibeCommand])
    }

    @Test
    func statusLineInstallRefusesWhenOpenIslandBridgePresent() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let claudeDirectory = root.appendingPathComponent(".claude", isDirectory: true)
        let openIslandBin = root.appendingPathComponent(".open-island/bin", isDirectory: true)
        let focusBin = root.appendingPathComponent("FocusIsland/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: openIslandBin, withIntermediateDirectories: true)

        let openIslandScript = openIslandBin.appendingPathComponent("open-island-statusline")
        let openIslandContents = Data("#!/bin/bash\necho open-island\n".utf8)
        try openIslandContents.write(to: openIslandScript)
        let originalStatusLine: [String: Any] = ["type": "command", "command": openIslandScript.path, "padding": 1]
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: ["statusLine": originalStatusLine]).write(to: settingsURL)
        let settingsBefore = try Data(contentsOf: settingsURL)

        let manager = ClaudeStatusLineInstallationManager(
            claudeDirectory: claudeDirectory,
            scriptDirectoryURL: focusBin
        )

        let before = try manager.status()
        #expect(before.providedByOtherIsland)
        #expect(!before.managedStatusLineConfigured)
        #expect(throws: ClaudeStatusLineInstallationError.self) { try manager.install() }
        #expect(throws: ClaudeStatusLineInstallationError.self) { try manager.installAsWrapper() }
        #expect(try Data(contentsOf: settingsURL) == settingsBefore)
        #expect(try Data(contentsOf: openIslandScript) == openIslandContents)
        #expect(!FileManager.default.fileExists(atPath: focusBin.appendingPathComponent("focus-island-statusline").path))

        let wrappedByOpenIsland: [String: Any] = [
            "statusLine": ["type": "command", "command": "/usr/local/bin/claude-hud"],
            "_openIslandOriginalStatusLine": ["type": "command", "command": "/usr/local/bin/claude-hud"],
        ]
        try JSONSerialization.data(withJSONObject: wrappedByOpenIsland).write(to: settingsURL)
        #expect(try manager.status().providedByOtherIsland)
        #expect(throws: ClaudeStatusLineInstallationError.self) { try manager.installAsWrapper() }
    }

    @Test
    func autoRepairSkipsWhenOtherIslandOwnsStatusLine() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let claudeDirectory = root.appendingPathComponent(".claude", isDirectory: true)
        let focusBin = root.appendingPathComponent("FocusIsland/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        let manager = ClaudeStatusLineInstallationManager(claudeDirectory: claudeDirectory, scriptDirectoryURL: focusBin)
        let focusScript = focusBin.appendingPathComponent("focus-island-statusline").path

        try JSONSerialization.data(withJSONObject: [
            "statusLine": ["type": "command", "command": focusScript],
        ]).write(to: settingsURL)
        let ownMissing = try manager.status()
        #expect(ownMissing.managedStatusLineNeedsRepair)
        #expect(ownMissing.shouldAutoRepair)

        try JSONSerialization.data(withJSONObject: [
            "statusLine": ["type": "command", "command": focusScript],
            focusIslandOriginalStatusLineKey: ["type": "command", "command": "/Users/x/.open-island/bin/open-island-statusline"],
        ]).write(to: settingsURL)
        let wrappingOpenIsland = try manager.status()
        #expect(wrappingOpenIsland.managedStatusLineNeedsRepair)
        #expect(wrappingOpenIsland.providedByOtherIsland)
        #expect(!wrappingOpenIsland.shouldAutoRepair)

        try JSONSerialization.data(withJSONObject: [
            "statusLine": ["type": "command", "command": focusScript],
            "_openIslandOriginalStatusLine": ["type": "command", "command": "/usr/local/bin/claude-hud"],
        ]).write(to: settingsURL)
        #expect(!(try manager.status().shouldAutoRepair))
        #expect(throws: ClaudeStatusLineInstallationError.self) { try manager.install() }
    }

    @Test
    func uninstallRestoresOpenIslandBridgeWrappedByEarlierInstall() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let claudeDirectory = root.appendingPathComponent(".claude", isDirectory: true)
        let openIslandBin = root.appendingPathComponent(".open-island/bin", isDirectory: true)
        let focusBin = root.appendingPathComponent("FocusIsland/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: openIslandBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: focusBin, withIntermediateDirectories: true)
        let openIslandScript = openIslandBin.appendingPathComponent("open-island-statusline")
        let openIslandContents = Data("#!/bin/bash\necho open-island\n".utf8)
        try openIslandContents.write(to: openIslandScript)
        let focusScript = focusBin.appendingPathComponent("focus-island-statusline")
        let delegateScript = focusBin.appendingPathComponent("focus-island-statusline-delegate")
        try Data("#!/bin/bash\n".utf8).write(to: focusScript)
        try Data("#!/bin/bash\n\(openIslandScript.path)\n".utf8).write(to: delegateScript)
        let savedOriginal: [String: Any] = ["type": "command", "command": openIslandScript.path, "padding": 1]
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: [
            "statusLine": ["type": "command", "command": focusScript.path, "padding": 2],
            focusIslandOriginalStatusLineKey: savedOriginal,
        ]).write(to: settingsURL)

        let manager = ClaudeStatusLineInstallationManager(claudeDirectory: claudeDirectory, scriptDirectoryURL: focusBin)
        #expect(try manager.status().providedByOtherIsland)
        try manager.uninstall()

        let after = try readJSON(settingsURL)
        let restored = try #require(after["statusLine"] as? [String: Any])
        #expect(restored["command"] as? String == openIslandScript.path)
        #expect(restored["padding"] as? Int == 1)
        #expect(restored["type"] as? String == "command")
        #expect(restored.count == 3)
        #expect(after[focusIslandOriginalStatusLineKey] == nil)
        #expect(try Data(contentsOf: openIslandScript) == openIslandContents)
        #expect(!FileManager.default.fileExists(atPath: focusScript.path))
        #expect(!FileManager.default.fileExists(atPath: delegateScript.path))
    }

    @Test
    func uninstallNeverRemovesOpenIslandStatusLine() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let claudeDirectory = root.appendingPathComponent(".claude", isDirectory: true)
        let openIslandBin = root.appendingPathComponent(".open-island/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: openIslandBin, withIntermediateDirectories: true)
        let openIslandScript = openIslandBin.appendingPathComponent("open-island-statusline")
        try Data("#!/bin/bash\n".utf8).write(to: openIslandScript)
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: [
            "statusLine": ["type": "command", "command": openIslandScript.path],
        ]).write(to: settingsURL)

        let manager = ClaudeStatusLineInstallationManager(
            claudeDirectory: claudeDirectory,
            scriptDirectoryURL: root.appendingPathComponent("FocusIsland/bin", isDirectory: true)
        )
        try manager.uninstall()

        let statusLine = try #require(try readJSON(settingsURL)["statusLine"] as? [String: Any])
        #expect(statusLine["command"] as? String == openIslandScript.path)
        #expect(FileManager.default.fileExists(atPath: openIslandScript.path))
    }
}
