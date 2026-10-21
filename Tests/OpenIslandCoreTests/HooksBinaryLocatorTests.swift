import Foundation
import Testing
@testable import OpenIslandCore

struct HooksBinaryLocatorTests {
    @Test
    func locateFindsBundledHelperBinaryInsideAppBundle() throws {
        let rootURL = temporaryRootURL(named: "hooks-binary-locator")
        let executableDirectory = rootURL
            .appendingPathComponent("Open Island.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
        let helperBinaryURL = rootURL
            .appendingPathComponent("Open Island.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("OpenIslandHooks")

        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try makeExecutable(at: helperBinaryURL, contents: "bundled-helper")

        let locatedURL = HooksBinaryLocator.locate(
            currentDirectory: rootURL,
            executableDirectory: executableDirectory,
            environment: [:]
        )

        #expect(locatedURL?.path == helperBinaryURL.standardizedFileURL.path)
    }

    @Test
    func locateIgnoresLegacyVibeIslandHelper() throws {
        let rootURL = temporaryRootURL(named: "hooks-binary-locator-legacy")
        let executableDirectory = rootURL
            .appendingPathComponent("Focus Island.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
        let helperBinaryURL = rootURL
            .appendingPathComponent("Focus Island.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("VibeIslandHooks")

        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try makeExecutable(at: helperBinaryURL, contents: "legacy-bundled-helper")

        let locatedURL = HooksBinaryLocator.locate(
            currentDirectory: rootURL,
            executableDirectory: executableDirectory,
            environment: [:]
        )

        #expect(locatedURL?.lastPathComponent != "VibeIslandHooks")
        #expect(!ManagedHooksBinary.candidateURLs().contains { $0.path.contains("VibeIsland") })
    }

    @Test
    func locateHonoursOnlyFocusIslandEnvironmentOverride() throws {
        let rootURL = temporaryRootURL(named: "hooks-binary-locator-env")
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let focusBinary = rootURL.appendingPathComponent("focus/OpenIslandHooks")
        let openIslandBinary = rootURL.appendingPathComponent("open/OpenIslandHooks")
        try makeExecutable(at: focusBinary, contents: "focus")
        try makeExecutable(at: openIslandBinary, contents: "open")

        let viaFocus = HooksBinaryLocator.locate(
            currentDirectory: rootURL,
            executableDirectory: nil,
            environment: ["FOCUS_ISLAND_HOOKS_BINARY": focusBinary.path]
        )
        #expect(viaFocus?.path == focusBinary.standardizedFileURL.path)

        let viaLegacy = HooksBinaryLocator.locate(
            currentDirectory: rootURL,
            executableDirectory: nil,
            environment: ["OPEN_ISLAND_HOOKS_BINARY": openIslandBinary.path, "VIBE_ISLAND_HOOKS_BINARY": openIslandBinary.path]
        )
        #expect(viaLegacy?.path != openIslandBinary.standardizedFileURL.path)
    }
}

private func temporaryRootURL(named name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("open-island-\(name)-\(UUID().uuidString)", isDirectory: true)
}

private func makeExecutable(at url: URL, contents: String) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}
