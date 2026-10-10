import Foundation

public struct TranscriptSummary: Equatable, Sendable {
    public var sessionID: String
    public var cwd: String?
    public var title: String
    public var firstPrompt: String?
    public var lastPrompt: String?
    public var lastAssistantMessage: String?
    public var startedAt: Date
    public var lastActivityAt: Date
    public var transcriptPath: String
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let focusFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) static let focusPlain = ISO8601DateFormatter()
}

public enum TranscriptSummaryParser {
    public static let maxTitleLength = 80

    public static func parse(fileURL: URL) -> TranscriptSummary? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        var sessionID: String?
        var cwd: String?
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var firstPrompt: String?
        var lastPrompt: String?
        var lastPromptRecord: String?
        var lastAssistant: String?
        var customTitle: String?
        var aiTitle: String?

        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if sessionID == nil, let value = object["sessionId"] as? String { sessionID = value }
            if cwd == nil, let value = object["cwd"] as? String, !value.isEmpty { cwd = value }
            if let raw = object["timestamp"] as? String, let date = parseDate(raw) {
                firstTimestamp = firstTimestamp ?? date
                lastTimestamp = date
            }
            switch object["type"] as? String {
            case "user":
                guard object["isMeta"] as? Bool != true, object["isSidechain"] as? Bool != true,
                      let text = userText(object["message"]) else { continue }
                firstPrompt = firstPrompt ?? text
                lastPrompt = text
            case "assistant":
                if object["isSidechain"] as? Bool == true { continue }
                if let text = assistantText(object["message"]) {
                    lastAssistant = String(text.prefix(SessionHistory.maxAssistantMessageLength))
                }
            case "custom-title":
                customTitle = (object["customTitle"] as? String) ?? customTitle
            case "ai-title":
                aiTitle = (object["aiTitle"] as? String) ?? aiTitle
            case "last-prompt":
                lastPromptRecord = (object["lastPrompt"] as? String) ?? lastPromptRecord
            default:
                continue
            }
        }

        guard let sessionID, firstPrompt != nil || lastAssistant != nil || customTitle != nil || aiTitle != nil else {
            return nil
        }
        let modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date(timeIntervalSince1970: 0)
        let title = customTitle
            ?? aiTitle
            ?? firstPrompt.map { String($0.prefix(maxTitleLength)) }
            ?? SessionHistory.projectName(for: cwd)
            ?? sessionID
        return TranscriptSummary(
            sessionID: sessionID,
            cwd: cwd,
            title: title,
            firstPrompt: firstPrompt,
            lastPrompt: lastPromptRecord ?? lastPrompt,
            lastAssistantMessage: lastAssistant,
            startedAt: firstTimestamp ?? modifiedAt,
            lastActivityAt: lastTimestamp ?? modifiedAt,
            transcriptPath: fileURL.path
        )
    }

    static func parseDate(_ raw: String) -> Date? {
        ISO8601DateFormatter.focusFractional.date(from: raw) ?? ISO8601DateFormatter.focusPlain.date(from: raw)
    }

    static func userText(_ message: Any?) -> String? {
        guard let message = message as? [String: Any] else { return nil }
        let text: String?
        if let string = message["content"] as? String {
            text = string
        } else if let parts = message["content"] as? [[String: Any]] {
            let texts = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            text = texts.isEmpty ? nil : texts.joined(separator: "\n")
        } else {
            text = nil
        }
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty, !trimmed.hasPrefix("<") else {
            return nil
        }
        return trimmed
    }

    static func assistantText(_ message: Any?) -> String? {
        guard let message = message as? [String: Any], let parts = message["content"] as? [[String: Any]] else { return nil }
        let texts = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
}
