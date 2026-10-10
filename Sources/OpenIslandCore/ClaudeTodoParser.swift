import Foundation

public enum ClaudeTodoParser {
    public static func tasks(from input: ClaudeHookJSONValue?) -> [ClaudeTaskInfo]? {
        guard case let .object(object)? = input,
              case let .array(items)? = object["todos"] else {
            return nil
        }

        var tasks: [ClaudeTaskInfo] = []
        for (index, item) in items.enumerated() {
            guard case let .object(fields) = item,
                  case let .string(content)? = fields["content"] else {
                continue
            }

            var status = ClaudeTaskInfo.Status.pending
            if case let .string(raw)? = fields["status"],
               let parsed = ClaudeTaskInfo.Status(rawValue: raw) {
                status = parsed
            }

            var activeForm: String?
            if case let .string(value)? = fields["activeForm"] {
                activeForm = value
            }

            tasks.append(ClaudeTaskInfo(
                id: "todo-\(index)",
                title: content,
                status: status,
                activeForm: activeForm
            ))
        }
        return tasks
    }
}
