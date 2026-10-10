import Foundation
import Testing
@testable import OpenIslandCore

struct ClaudeTodoParserTests {
    @Test
    func parsesTodos() {
        let input: ClaudeHookJSONValue = .object([
            "todos": .array([
                .object([
                    "content": .string("Write tests"),
                    "status": .string("completed"),
                    "activeForm": .string("Writing tests"),
                ]),
                .object([
                    "content": .string("Implement parser"),
                    "status": .string("in_progress"),
                    "activeForm": .string("Implementing parser"),
                ]),
                .object([
                    "content": .string("Ship"),
                    "status": .string("pending"),
                ]),
            ]),
        ])

        let tasks = ClaudeTodoParser.tasks(from: input)

        #expect(tasks == [
            ClaudeTaskInfo(id: "todo-0", title: "Write tests", status: .completed, activeForm: "Writing tests"),
            ClaudeTaskInfo(id: "todo-1", title: "Implement parser", status: .inProgress, activeForm: "Implementing parser"),
            ClaudeTaskInfo(id: "todo-2", title: "Ship", status: .pending, activeForm: nil),
        ])
    }

    @Test
    func malformedInputReturnsNil() {
        #expect(ClaudeTodoParser.tasks(from: nil) == nil)
        #expect(ClaudeTodoParser.tasks(from: .string("nope")) == nil)
        #expect(ClaudeTodoParser.tasks(from: .object([:])) == nil)
        #expect(ClaudeTodoParser.tasks(from: .object(["todos": .string("x")])) == nil)
    }

    @Test
    func emptyTodosClears() {
        let tasks = ClaudeTodoParser.tasks(from: .object(["todos": .array([])]))

        #expect(tasks == [])
    }

    @Test
    func itemWithoutContentIsSkippedButKeepsIndexIDs() {
        let input: ClaudeHookJSONValue = .object([
            "todos": .array([
                .object(["status": .string("pending")]),
                .object(["content": .string("Real"), "status": .string("bogus")]),
            ]),
        ])

        let tasks = ClaudeTodoParser.tasks(from: input)

        #expect(tasks == [ClaudeTaskInfo(id: "todo-1", title: "Real", status: .pending)])
    }

    @Test
    func oldTaskInfoJSONDecodesWithoutActiveForm() throws {
        let json = #"{"id":"t1","title":"Old","status":"in_progress"}"#.data(using: .utf8)!

        let info = try JSONDecoder().decode(ClaudeTaskInfo.self, from: json)

        #expect(info == ClaudeTaskInfo(id: "t1", title: "Old", status: .inProgress))
        #expect(info.activeForm == nil)
    }
}
