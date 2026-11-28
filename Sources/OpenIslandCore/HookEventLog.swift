import Foundation

public struct HookEventLog: Sendable {
    public static let fileName = "hook-events.log"
    public static let maxBytes = 2_000_000

    public let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent(Self.fileName)
    }

    public static func line(for payload: ClaudeHookPayload, phaseBefore: SessionPhase?, at date: Date) -> String {
        var fields = [
            Self.timestamp(date),
            payload.hookEventName.rawValue,
            "session=\(payload.sessionID)",
            "before=\(phaseBefore?.rawValue ?? "none")",
        ]
        if let agentID = payload.agentID { fields.append("agent=\(agentID)") }
        if let agentType = payload.agentType { fields.append("agentType=\(agentType)") }
        if let source = payload.source { fields.append("source=\(source.rawValue)") }
        if let toolName = payload.toolName { fields.append("tool=\(toolName)") }
        if let notificationType = payload.notificationType { fields.append("notification=\(notificationType)") }
        if let prompt = payload.prompt { fields.append("prompt=\(Self.preview(prompt))") }
        fields.append("cwd=\(payload.cwd)")
        return fields.joined(separator: " ")
    }

    public func append(_ line: String) {
        let data = Data((line + "\n").utf8)
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int), size > Self.maxBytes {
            let previous = url.appendingPathExtension("1")
            try? manager.removeItem(at: previous)
            try? manager.moveItem(at: url, to: previous)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? data.write(to: url)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    static func preview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return "«\(flat.prefix(60))»"
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
