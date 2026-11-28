import Foundation
import Testing
@testable import OpenIslandApp

struct ClaudeRemoteControlLocatorTests {
    private func directory(_ records: [String: [String: Any]]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, record) in records {
            try JSONSerialization.data(withJSONObject: record).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    @Test
    func findsNewestBridgeSessionForCLISession() throws {
        let dir = try directory([
            "1.json": ["sessionId": "cli", "bridgeSessionId": "session_OLD", "updatedAt": 1],
            "2.json": ["sessionId": "cli", "bridgeSessionId": "session_01Emqhk5f38", "updatedAt": 5],
            "3.json": ["sessionId": "other", "bridgeSessionId": "session_X", "updatedAt": 9],
            "4.json": ["sessionId": "plain"],
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let locator = ClaudeRemoteControlLocator(directory: dir)
        #expect(locator.bridgeSessionID(forCLISessionID: "cli") == "session_01Emqhk5f38")
        #expect(locator.bridgeSessionID(forCLISessionID: "plain") == nil)
        #expect(locator.bridgeSessionID(forCLISessionID: "missing") == nil)
    }

    @Test
    func webURLOnlyForValidIDs() {
        #expect(ClaudeRemoteControlLocator.webURL(bridgeSessionID: "session_01Emqhk5f38")?.absoluteString == "https://claude.ai/code/session_01Emqhk5f38")
        #expect(ClaudeRemoteControlLocator.webURL(bridgeSessionID: "session_../evil") == nil)
        #expect(ClaudeRemoteControlLocator.webURL(bridgeSessionID: "local_abc") == nil)
    }

    @Test
    func opensInClaudeAppWhenInstalled() {
        #expect(ClaudeRemoteControlLocator.openURL(bridgeSessionID: "session_A1") { _ in true }?.absoluteString == "claude://claude.ai/code/session_A1")
        #expect(ClaudeRemoteControlLocator.openURL(bridgeSessionID: "session_A1") { _ in false }?.absoluteString == "https://claude.ai/code/session_A1")
    }
}
