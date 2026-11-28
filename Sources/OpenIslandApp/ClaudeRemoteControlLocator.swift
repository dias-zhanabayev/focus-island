import Foundation

struct ClaudeRemoteControlLocator: Sendable {
    let directory: URL

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/sessions", isDirectory: true)) {
        self.directory = directory
    }

    private struct Record: Decodable {
        let sessionId: String?
        let bridgeSessionId: String?
        let updatedAt: Double?
        let name: String?
    }

    func names(forCLISessionIDs ids: Set<String>) -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var best: [String: (name: String, updatedAt: Double)] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  let id = record.sessionId, ids.contains(id),
                  record.bridgeSessionId != nil,
                  let name = record.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            let updatedAt = record.updatedAt ?? 0
            if let current = best[id], current.updatedAt >= updatedAt { continue }
            best[id] = (name, updatedAt)
        }
        return best.mapValues(\.name)
    }

    func bridgeSessionID(forCLISessionID cliSessionID: String) -> String? {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var best: (id: String, updatedAt: Double)?
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  record.sessionId == cliSessionID,
                  let bridge = record.bridgeSessionId,
                  Self.isBridgeSessionID(bridge) else { continue }
            let updatedAt = record.updatedAt ?? 0
            if best == nil || updatedAt > best!.updatedAt {
                best = (bridge, updatedAt)
            }
        }
        return best?.id
    }

    static func isBridgeSessionID(_ id: String) -> Bool {
        id.range(of: "^session_[A-Za-z0-9]{1,64}$", options: .regularExpression) != nil
    }

    static func webURL(bridgeSessionID: String) -> URL? {
        guard isBridgeSessionID(bridgeSessionID) else { return nil }
        return URL(string: "https://claude.ai/code/\(bridgeSessionID)")
    }

    static func appURL(bridgeSessionID: String) -> URL? {
        guard isBridgeSessionID(bridgeSessionID) else { return nil }
        return URL(string: "claude://claude.ai/code/\(bridgeSessionID)")
    }

    static func openURL(bridgeSessionID: String, appInstalled: (URL) -> Bool) -> URL? {
        if let app = appURL(bridgeSessionID: bridgeSessionID), appInstalled(app) {
            return app
        }
        return webURL(bridgeSessionID: bridgeSessionID)
    }
}
