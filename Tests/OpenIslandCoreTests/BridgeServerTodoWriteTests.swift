import Foundation
import Testing
@testable import OpenIslandCore

struct BridgeServerTodoWriteTests {
    private func todoInput(_ items: [(String, String)]) -> ClaudeHookJSONValue {
        .object([
            "todos": .array(items.map { content, status in
                .object([
                    "content": .string(content),
                    "status": .string(status),
                    "activeForm": .string("Doing \(content)"),
                ])
            }),
        ])
    }

    @Test
    func postToolUseTodoWriteReplacesActiveTasks() throws {
        let socketURL = BridgeSocketLocation.uniqueTestURL()
        let server = BridgeServer(socketURL: socketURL)
        try server.start()
        defer { server.stop() }

        let sessionID = "claude-session-todowrite"
        func send(_ payload: ClaudeHookPayload) throws {
            _ = try BridgeCommandClient(socketURL: socketURL).send(.processClaudeHook(payload))
        }

        try send(ClaudeHookPayload(
            cwd: "/tmp/worktree",
            hookEventName: .postToolUse,
            sessionID: sessionID,
            toolName: "TodoWrite",
            toolInput: todoInput([("A", "in_progress"), ("B", "pending"), ("C", "pending")]),
            toolUseID: "todo-1"
        ))

        var tasks = server.sessionStateSnapshotForTests().session(id: sessionID)?.claudeMetadata?.activeTasks
        #expect(tasks?.map(\.title) == ["A", "B", "C"])
        #expect(tasks?.first?.status == .inProgress)

        try send(ClaudeHookPayload(
            cwd: "/tmp/worktree",
            hookEventName: .postToolUse,
            sessionID: sessionID,
            toolName: "TodoWrite",
            toolInput: todoInput([("A", "completed"), ("B", "in_progress")]),
            toolUseID: "todo-2"
        ))

        tasks = server.sessionStateSnapshotForTests().session(id: sessionID)?.claudeMetadata?.activeTasks
        #expect(tasks?.map(\.title) == ["A", "B"])
        #expect(tasks?.map(\.status) == [.completed, .inProgress])

        try send(ClaudeHookPayload(
            cwd: "/tmp/worktree",
            hookEventName: .postToolUse,
            sessionID: sessionID,
            toolName: "TodoWrite",
            toolInput: todoInput([]),
            toolUseID: "todo-3"
        ))

        tasks = server.sessionStateSnapshotForTests().session(id: sessionID)?.claudeMetadata?.activeTasks
        #expect(tasks == [])
    }
}
