import Foundation
import Testing
@testable import OpenIslandApp

struct ClaudeDesktopSessionLocatorTests {
    func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-sessions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("acc/org", isDirectory: true), withIntermediateDirectories: true)
        return root
    }

    func write(_ root: URL, _ name: String, _ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: root.appendingPathComponent("acc/org/\(name).json"))
    }

    @Test
    func findsDesktopSessionByCLISessionID() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "local_aaa", ["sessionId": "local_aaa", "cliSessionId": "cli-1"])
        try write(root, "local_bbb", ["sessionId": "local_bbb", "cliSessionId": "cli-2", "note": "cli-1"])
        let locator = ClaudeDesktopSessionLocator(root: root)
        #expect(locator.desktopSessionID(forCLISessionID: "cli-1") == "local_aaa")
        #expect(locator.desktopSessionID(forCLISessionID: "cli-2") == "local_bbb")
        #expect(locator.desktopSessionID(forCLISessionID: "missing") == nil)
        #expect(locator.desktopSessionID(forCLISessionID: "") == nil)
    }

    @Test
    func skipsArchivedAndMalformedSessions() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "local_old", ["sessionId": "local_old", "cliSessionId": "cli-1", "isArchived": true])
        try write(root, "local_bad", ["sessionId": "local_bad id", "cliSessionId": "cli-2"])
        let locator = ClaudeDesktopSessionLocator(root: root)
        #expect(locator.desktopSessionID(forCLISessionID: "cli-1") == nil)
        #expect(locator.desktopSessionID(forCLISessionID: "cli-2") == nil)
        #expect(ClaudeDesktopSessionLocator(root: root.appendingPathComponent("nope")).desktopSessionID(forCLISessionID: "cli-1") == nil)
    }

    @Test
    func returnsDesktopTitlesForSeveralSessions() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "local_aaa", ["sessionId": "local_aaa", "cliSessionId": "cli-1", "title": "воронка"])
        try write(root, "local_bbb", ["sessionId": "local_bbb", "cliSessionId": "cli-2", "title": "  "])
        let found = ClaudeDesktopSessionLocator(root: root).sessions(forCLISessionIDs: ["cli-1", "cli-2", "cli-3"])
        #expect(found["cli-1"] == .init(id: "local_aaa", title: "воронка"))
        #expect(found["cli-2"] == .init(id: "local_bbb", title: nil))
        #expect(found["cli-3"] == nil)
    }

    @Test
    func buildsContinueDeepLink() {
        #expect(ClaudeDesktopSessionLocator.continueURL(desktopSessionID: "local_80faf7f1-f84a")?.absoluteString == "claude://code/continue?session=local_80faf7f1-f84a")
        #expect(ClaudeDesktopSessionLocator.continueURL(desktopSessionID: "x&y") == nil)
        #expect(ClaudeDesktopSessionLocator.isClaudeDesktop(terminalApp: "Claude.app"))
        #expect(!ClaudeDesktopSessionLocator.isClaudeDesktop(terminalApp: "Ghostty"))
    }
}
