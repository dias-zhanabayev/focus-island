import Foundation

struct TurnSummary: Equatable, Sendable {
    let text: String
    let needsAction: Bool
}

enum CompletionSummaryText {
    nonisolated static let maxLength = 220

    nonisolated static func brief(_ markdown: String) -> String {
        var paragraph: [String] = []
        var inFence = false
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                if !paragraph.isEmpty { break }
                continue
            }
            if inFence { continue }
            if line.isEmpty || line.hasPrefix("|") || line.hasPrefix("#") || isRule(line) {
                if !paragraph.isEmpty { break }
                continue
            }
            paragraph.append(stripListMarker(line))
        }
        let text = cleanInline(paragraph.joined(separator: " "))
        guard text.count > maxLength else { return text }
        let cut = text.prefix(maxLength)
        let trimmed = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:—-")) + "…"
    }

    nonisolated static func hasMore(brief: String, full: String) -> Bool {
        let full = full.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return false }
        return brief.isEmpty || cleanInline(full.components(separatedBy: .newlines).joined(separator: " ")) != brief
    }

    nonisolated static func summary(statusDetail: String?, needsAction: String?) -> TurnSummary? {
        if let needs = needsAction?.trimmingCharacters(in: .whitespacesAndNewlines), !needs.isEmpty {
            return TurnSummary(text: capitalized(needs), needsAction: true)
        }
        if let detail = statusDetail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            return TurnSummary(text: capitalized(detail), needsAction: false)
        }
        return nil
    }

    nonisolated private static func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    nonisolated private static func isRule(_ line: String) -> Bool {
        let chars = Set(line.replacingOccurrences(of: " ", with: ""))
        return line.count >= 3 && (chars == ["-"] || chars == ["*"] || chars == ["_"])
    }

    nonisolated private static func stripListMarker(_ line: String) -> String {
        var value = line
        if value.hasPrefix(">") { value = String(value.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if let range = value.range(of: #"^([-*+]|\d+[.)])\s+"#, options: .regularExpression) {
            value.removeSubrange(range)
        }
        return value
    }

    nonisolated private static func cleanInline(_ text: String) -> String {
        var value = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        for token in ["**", "__", "`"] {
            value = value.replacingOccurrences(of: token, with: "")
        }
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
