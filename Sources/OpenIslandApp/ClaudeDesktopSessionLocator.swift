import Foundation

struct ClaudeDesktopSessionLocator: Sendable {
    static let terminalAppName = "claude.app"

    let root: URL

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)) {
        self.root = root
    }

    struct DesktopSession: Equatable, Sendable {
        let id: String
        let title: String?
        var turnSummary: TurnSummary? = nil
        var lastActivityAt: Date? = nil
        var priorCLISessionIDs: [String] = []
    }

    func desktopSessionID(forCLISessionID cliSessionID: String) -> String? {
        sessions(forCLISessionIDs: [cliSessionID])[cliSessionID]?.id
    }

    func sessions(forCLISessionIDs cliSessionIDs: Set<String>) -> [String: DesktopSession] {
        let wanted = cliSessionIDs.filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return [:] }
        let needles = wanted.compactMap { $0.data(using: .utf8) }
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return [:]
        }
        var files: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "json" && url.lastPathComponent.hasPrefix("local_") {
            let modified = (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            files.append((url, modified))
        }
        var found: [String: DesktopSession] = [:]
        for file in files.sorted(by: { $0.modified > $1.modified }) {
            guard found.count < wanted.count else { break }
            guard let data = try? Data(contentsOf: file.url),
                  needles.contains(where: { data.range(of: $0) != nil }),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cliID = object["cliSessionId"] as? String,
                  wanted.contains(cliID), found[cliID] == nil,
                  object["isArchived"] as? Bool != true,
                  let id = object["sessionId"] as? String,
                  Self.isDesktopSessionID(id) else { continue }
            let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            found[cliID] = DesktopSession(
                id: id,
                title: title?.isEmpty == false ? title : nil,
                turnSummary: Self.turnSummary(object),
                lastActivityAt: (object["lastActivityAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
                priorCLISessionIDs: (object["priorCliSessionIds"] as? [String]) ?? []
            )
        }
        return found
    }

    static func turnSummary(_ object: [String: Any]) -> TurnSummary? {
        guard let summary = object["postTurnSummary"] as? [String: Any] else { return nil }
        if let summarized = summary["summarizes_uuid"] as? String,
           let last = object["lastAssistantUuid"] as? String,
           summarized != last {
            return nil
        }
        return CompletionSummaryText.summary(
            statusDetail: summary["status_detail"] as? String,
            needsAction: summary["needs_action"] as? String
        )
    }

    static func isClaudeDesktop(terminalApp: String) -> Bool {
        terminalApp.trimmingCharacters(in: .whitespaces).lowercased() == terminalAppName
    }

    static func isDesktopSessionID(_ id: String) -> Bool {
        id.range(of: "^local_[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil
    }

    static func continueURL(desktopSessionID: String) -> URL? {
        guard isDesktopSessionID(desktopSessionID) else { return nil }
        return URL(string: "claude://code/continue?session=\(desktopSessionID)")
    }
}
