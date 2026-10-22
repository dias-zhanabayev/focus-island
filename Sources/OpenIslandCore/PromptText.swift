import Foundation

public enum PromptText {
    static let harnessTags = [
        "system-reminder",
        "command-name",
        "command-message",
        "command-args",
        "local-command-stdout",
        "local-command-stderr",
        "local-command-caveat",
        "user-prompt-submit-hook",
        "bash-input",
        "bash-stdout",
        "bash-stderr",
        "task-notification",
        "ide_selection",
        "ide_opened_file",
    ]

    public static func clean(_ text: String?) -> String? {
        guard var result = text else { return nil }
        for tag in harnessTags {
            result = removeBlocks(tag: tag, from: result)
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func removeBlocks(tag: String, from text: String) -> String {
        var result = text
        let open = "<\(tag)"
        let close = "</\(tag)>"
        while let start = result.range(of: open) {
            let after = result[start.upperBound...]
            guard let next = after.first, next == ">" || next == " " || next == "\n" else {
                break
            }
            if let end = result.range(of: close, range: start.upperBound..<result.endIndex) {
                result.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                result.removeSubrange(start.lowerBound..<result.endIndex)
            }
        }
        return result
    }
}
