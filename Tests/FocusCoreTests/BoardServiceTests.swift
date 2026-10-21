import Foundation
import GRDB
import Testing
@testable import FocusCore

struct BoardServiceTests {
    let t0 = Date(timeIntervalSince1970: 10_000)

    func makeService() throws -> (BoardService, FocusStore) {
        let store = try FocusStore.inMemory()
        return (BoardService(store: store), store)
    }

    func insertSession(_ store: FocusStore, id: String, taskId: String? = nil, status: SessionRecordStatus = .live, lastActivityAt: Date) throws {
        let record = SessionRecord(id: id, cwd: "/tmp/p", projectName: "p", title: id, firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, startedAt: lastActivityAt, lastActivityAt: lastActivityAt, endedAt: nil, status: status, taskId: taskId, transcriptPath: nil)
        try store.dbQueue.write { db in try record.insert(db) }
    }

    @Test
    func createAppendsToEndOfColumn() throws {
        let (service, _) = try makeService()
        let a = try service.createTask(title: "A", column: .todo, now: t0)
        let b = try service.createTask(title: "B", column: .todo, now: t0)
        let todo = try service.snapshot().tasks(in: .todo)
        #expect(todo.map(\.id) == [a.id, b.id])
        #expect(b.position > a.position)
    }

    @Test
    func createRejectsBlankTitle() throws {
        let (service, _) = try makeService()
        #expect(throws: BoardError.emptyTitle) {
            try service.createTask(title: "   ", column: .todo, now: t0)
        }
    }

    @Test
    func moveBeforeAnotherTaskReorders() throws {
        let (service, _) = try makeService()
        let a = try service.createTask(title: "A", column: .todo, now: t0)
        let b = try service.createTask(title: "B", column: .todo, now: t0)
        let c = try service.createTask(title: "C", column: .todo, now: t0)
        try service.moveTask(id: c.id, to: .todo, beforeTaskID: a.id, now: t0)
        #expect(try service.snapshot().tasks(in: .todo).map(\.id) == [c.id, a.id, b.id])
        try service.moveTask(id: a.id, to: .todo, beforeTaskID: b.id, now: t0)
        #expect(try service.snapshot().tasks(in: .todo).map(\.id) == [c.id, a.id, b.id])
        try service.moveTask(id: c.id, to: .todo, beforeTaskID: b.id, now: t0)
        #expect(try service.snapshot().tasks(in: .todo).map(\.id) == [a.id, c.id, b.id])
    }

    @Test
    func moveToDoneSetsDoneAtAndMovingOutClearsIt() throws {
        let (service, _) = try makeService()
        let a = try service.createTask(title: "A", column: .inProgress, now: t0)
        try service.moveTask(id: a.id, to: .done, beforeTaskID: nil, now: t0.addingTimeInterval(5))
        #expect(try service.snapshot().task(id: a.id)?.doneAt == t0.addingTimeInterval(5))
        try service.moveTask(id: a.id, to: .todo, beforeTaskID: nil, now: t0.addingTimeInterval(6))
        #expect(try service.snapshot().task(id: a.id)?.doneAt == nil)
    }

    @Test
    func bindingMovesTodoTaskToInProgress() throws {
        let (service, store) = try makeService()
        let a = try service.createTask(title: "A", column: .todo, now: t0)
        try insertSession(store, id: "s1", lastActivityAt: t0)
        try service.bindSession(sessionID: "s1", toTaskID: a.id, now: t0)
        #expect(try service.snapshot().task(id: a.id)?.boardColumn == .inProgress)
        let record = try store.dbQueue.read { db in try SessionRecord.fetchOne(db, key: "s1") }
        #expect(record?.taskId == a.id)
    }

    @Test
    func bindingKeepsDoneTaskInDone() throws {
        let (service, store) = try makeService()
        let a = try service.createTask(title: "A", column: .done, now: t0)
        try insertSession(store, id: "s1", lastActivityAt: t0)
        try service.bindSession(sessionID: "s1", toTaskID: a.id, now: t0)
        #expect(try service.snapshot().task(id: a.id)?.boardColumn == .done)
    }

    @Test
    func bindingUnknownSessionThrows() throws {
        let (service, _) = try makeService()
        let a = try service.createTask(title: "A", column: .todo, now: t0)
        #expect(throws: BoardError.unknownSession) {
            try service.bindSession(sessionID: "nope", toTaskID: a.id, now: t0)
        }
    }

    @Test
    func createTaskForSessionTruncatesTitleAndBinds() throws {
        let (service, store) = try makeService()
        try insertSession(store, id: "s1", lastActivityAt: t0)
        let long = String(repeating: "я", count: 120)
        let task = try service.createTaskForSession(sessionID: "s1", title: long, projectPath: "/tmp/p", now: t0)
        #expect(task.title.count == 80)
        #expect(task.boardColumn == .inProgress)
        let record = try store.dbQueue.read { db in try SessionRecord.fetchOne(db, key: "s1") }
        #expect(record?.taskId == task.id)
    }

    @Test
    func deleteTaskUnbindsSessions() throws {
        let (service, store) = try makeService()
        let a = try service.createTask(title: "A", column: .todo, now: t0)
        try insertSession(store, id: "s1", taskId: a.id, lastActivityAt: t0)
        try service.deleteTask(id: a.id)
        #expect(try service.snapshot().tasks.isEmpty)
        let record = try store.dbQueue.read { db in try SessionRecord.fetchOne(db, key: "s1") }
        #expect(record?.taskId == nil)
    }

    @Test
    func currentTaskPrefersMostRecentBoundLiveSession() throws {
        let (service, _) = try makeService()
        let a = try service.createTask(title: "A", column: .inProgress, now: t0)
        let b = try service.createTask(title: "B", column: .inProgress, now: t0)
        let snapshot = try service.snapshot()
        let older = SessionRecord(id: "s1", cwd: nil, projectName: nil, title: "", firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, startedAt: t0, lastActivityAt: t0, endedAt: nil, status: .live, taskId: a.id, transcriptPath: nil)
        var newer = older
        newer.id = "s2"
        newer.taskId = b.id
        newer.lastActivityAt = t0.addingTimeInterval(60)
        #expect(snapshot.currentTask(liveSessions: [older, newer])?.id == b.id)
        #expect(snapshot.currentTask(liveSessions: [])?.id == a.id)
    }

    @Test
    func updateTaskDoesNotChangeColumnOrDoneAt() throws {
        let (service, _) = try makeService()
        let a = try service.createTask(title: "A", column: .todo, now: t0)
        try service.moveTask(id: a.id, to: .done, beforeTaskID: nil, now: t0.addingTimeInterval(5))
        let stored = try service.snapshot().task(id: a.id)
        #expect(stored?.boardColumn == .done)
        let doneAtValue = stored?.doneAt
        var stale = a
        stale.title = "Updated"
        stale.boardColumn = .todo
        stale.doneAt = nil
        try service.updateTask(stale, now: t0.addingTimeInterval(10))
        let updated = try service.snapshot().task(id: a.id)
        #expect(updated?.title == "Updated")
        #expect(updated?.boardColumn == .done)
        #expect(updated?.doneAt == doneAtValue)
    }

    @Test
    func createTaskForSessionWithUnknownSessionLeavesNoTask() throws {
        let (service, _) = try makeService()
        #expect(throws: BoardError.unknownSession) {
            try service.createTaskForSession(sessionID: "nope", title: "Test", projectPath: nil, now: t0)
        }
        #expect(try service.snapshot().tasks.isEmpty)
    }

    @Test
    func deleteTaskCascadesCriteriaAndNullsPromptAndSpanTask() throws {
        let (service, store) = try makeService()
        let task = try service.createTask(title: "T", column: .todo, now: t0)
        let other = try service.createTask(title: "O", column: .todo, now: t0)
        let criteria = TaskCriteriaService(store: store)
        try criteria.add(taskID: task.id, text: "c", now: t0)
        try criteria.add(taskID: other.id, text: "keep", now: t0)
        let queue = PromptQueue(store: store)
        try queue.enqueue(sessionID: "s1", taskID: task.id, text: "p", now: t0)
        try store.dbQueue.write { db in
            var span = ActivitySpan(kind: .claude, sessionId: "s1", taskId: task.id, startedAt: t0)
            try span.insert(db)
        }
        try service.deleteTask(id: task.id)
        #expect(try criteria.criteria(taskID: task.id).isEmpty)
        #expect(try criteria.criteria(taskID: other.id).count == 1)
        #expect(try queue.pending(sessionID: "s1")?.taskId == nil)
        #expect(try queue.pending(sessionID: "s1")?.text == "p")
        let spanTask = try store.dbQueue.read { db in try ActivitySpan.fetchAll(db) }
        #expect(spanTask.count == 1)
        #expect(spanTask[0].taskId == nil)
    }
}
