import Foundation
import OpenIslandCore

extension ClaudeSessionRegistry {
    static func temporaryForTesting() -> ClaudeSessionRegistry {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-registry-tests-\(UUID().uuidString)", isDirectory: true)
        return ClaudeSessionRegistry(fileURL: directory.appendingPathComponent("claude-session-registry.json"))
    }
}
