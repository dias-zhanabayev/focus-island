import Foundation

public enum ClaudeTurnEndProbe {
    public static let quietInterval: TimeInterval = 90
    static let tailBytes = 64 * 1024
    static let turnRecordTypes: Set<String> = ["user", "assistant", "system", "attachment"]
    static let turnEndSubtypes: Set<String> = ["stop_hook_summary", "turn_duration"]

    public static func turnHasEnded(tail: String) -> Bool {
        for line in tail.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String,
                  turnRecordTypes.contains(type) else {
                continue
            }
            guard type == "system", let subtype = object["subtype"] as? String else {
                return false
            }
            return turnEndSubtypes.contains(subtype)
        }
        return false
    }

    public static func quietlyEnded(transcriptPath: String, now: Date, fileManager: FileManager = .default) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: transcriptPath),
              let modifiedAt = attributes[.modificationDate] as? Date,
              now.timeIntervalSince(modifiedAt) >= quietInterval,
              let tail = readTail(path: transcriptPath) else {
            return false
        }
        return turnHasEnded(tail: tail)
    }

    public static func sessionsToSettle(_ sessions: [AgentSession], now: Date, ended: (String) -> Bool) -> Set<String> {
        var result: Set<String> = []
        for session in sessions where session.phase == .running && session.tool == .claudeCode {
            guard now.timeIntervalSince(session.updatedAt) >= quietInterval,
                  let path = session.claudeMetadata?.transcriptPath,
                  ended(path) else {
                continue
            }
            result.insert(session.id)
        }
        return result
    }

    static func readTail(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
