import Foundation
import GRDB
import Testing
@testable import FocusCore

struct FocusStoreTests {
    @Test
    func migrationsCreateAllTables() throws {
        let store = try FocusStore.inMemory()
        let tables = try store.dbQueue.read { db in
            try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(tables.isSuperset(of: ["tasks", "sessions", "distraction_episodes", "next_action_events", "backfill_files"]))
    }

    @Test
    func taskRoundTrips() throws {
        let store = try FocusStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_000)
        let task = FocusTask(id: "t1", title: "Сделать доску", details: nil, boardColumn: .todo, position: 1, projectPath: "/tmp/p", note: nil, createdAt: now, updatedAt: now, doneAt: nil)
        try store.dbQueue.write { db in try task.insert(db) }
        let loaded = try store.dbQueue.read { db in try FocusTask.fetchOne(db, key: "t1") }
        #expect(loaded == task)
    }

    @Test
    func openWithRecoveryBacksUpCorruptFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("focus.sqlite")
        try Data("not a database".utf8).write(to: file)
        let result = FocusStore.openWithRecovery(fileURL: file, now: Date(timeIntervalSince1970: 42))
        guard case let .recovered(backup) = result.outcome else {
            Issue.record("expected recovered outcome, got \(result.outcome)")
            return
        }
        #expect(backup.lastPathComponent == "focus.sqlite.bak-42")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        let count = try result.store.dbQueue.read { db in try FocusTask.fetchCount(db) }
        #expect(count == 0)
    }

    @Test
    func openWithRecoveryOpensHealthyFileNormally() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = dir.appendingPathComponent("focus.sqlite")
        _ = try FocusStore(fileURL: file)
        let result = FocusStore.openWithRecovery(fileURL: file, now: Date(timeIntervalSince1970: 42))
        #expect(result.outcome == .normal)
    }

    @Test
    func nonCorruptFailureDoesNotMoveFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = dir.appendingPathComponent("focus.sqlite", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let result = FocusStore.openWithRecovery(fileURL: path, now: Date(timeIntervalSince1970: 42))
        #expect(result.outcome == .inMemoryFallback)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("focus.sqlite.bak-42").path))
        let count = try result.store.dbQueue.read { db in try FocusTask.fetchCount(db) }
        #expect(count == 0)
    }

    @Test
    func migratesV1DatabaseToV2() throws {
        let queue = try DatabaseQueue()
        try FocusStore.migrator(upTo: "v1").migrate(queue)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO tasks (id, title, boardColumn, position, createdAt, updatedAt) VALUES ('t1', 'Старая', 'todo', 1, ?, ?)", arguments: [Date(timeIntervalSince1970: 10), Date(timeIntervalSince1970: 10)])
            try db.execute(sql: "INSERT INTO sessions (id, title, startedAt, lastActivityAt, status, taskId) VALUES ('s1', 'Сессия', ?, ?, 'live', 't1')", arguments: [Date(timeIntervalSince1970: 10), Date(timeIntervalSince1970: 20)])
        }
        try FocusStore.migrator(upTo: nil).migrate(queue)
        let session = try queue.read { db in try SessionRecord.fetchOne(db, key: "s1") }
        let task = try queue.read { db in try FocusTask.fetchOne(db, key: "t1") }
        #expect(task?.title == "Старая")
        #expect(session?.taskId == "t1")
        #expect(session?.parkedAt == nil)
        #expect(session?.lastSeenAt == nil)
        let tables = try queue.read { db in
            try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(tables.isSuperset(of: ["task_criteria", "queued_prompts", "activity_spans", "day_plans"]))
    }

    @Test
    func sessionRecordPersistsParkedAndLastSeen() throws {
        let store = try FocusStore.inMemory()
        let parked = Date(timeIntervalSince1970: 500)
        let seen = Date(timeIntervalSince1970: 600)
        var record = SessionRecord(id: "s1", cwd: nil, projectName: nil, title: "S", firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, startedAt: Date(timeIntervalSince1970: 1), lastActivityAt: Date(timeIntervalSince1970: 2), endedAt: nil, status: .live, taskId: nil, transcriptPath: nil)
        record.parkedAt = parked
        record.lastSeenAt = seen
        try store.dbQueue.write { db in try record.insert(db) }
        let loaded = try store.dbQueue.read { db in try SessionRecord.fetchOne(db, key: "s1") }
        #expect(loaded == record)
    }

    @Test
    func criterionRoundTrip() throws {
        let store = try FocusStore.inMemory()
        let criterion = TaskCriterion(id: "c1", taskId: "t1", text: "Тесты зелёные", done: true, position: 2.5, createdAt: Date(timeIntervalSince1970: 100))
        try store.dbQueue.write { db in try criterion.insert(db) }
        let loaded = try store.dbQueue.read { db in try TaskCriterion.fetchOne(db, key: "c1") }
        #expect(loaded == criterion)
    }

    @Test
    func queuedPromptRoundTrip() throws {
        let store = try FocusStore.inMemory()
        let prompt = QueuedPrompt(id: "q1", sessionId: "s1", taskId: nil, text: "Продолжай", createdAt: Date(timeIntervalSince1970: 100), sentAt: Date(timeIntervalSince1970: 200))
        try store.dbQueue.write { db in try prompt.insert(db) }
        let loaded = try store.dbQueue.read { db in try QueuedPrompt.fetchOne(db, key: "q1") }
        #expect(loaded == prompt)
    }

    @Test
    func activitySpanInsertSetsID() throws {
        let store = try FocusStore.inMemory()
        var span = ActivitySpan(kind: .waiting, sessionId: "s1", taskId: "t1", startedAt: Date(timeIntervalSince1970: 100), endedAt: nil)
        try store.dbQueue.write { db in try span.insert(db) }
        #expect(span.id != nil)
        let loaded = try store.dbQueue.read { db in try ActivitySpan.fetchOne(db, key: span.id) }
        #expect(loaded == span)
    }

    @Test
    func dayPlanFocusTaskIdsRoundTrip() throws {
        let store = try FocusStore.inMemory()
        let plan = DayPlan(day: "2026-10-10", focusTaskIds: ["a", "b"], tomorrowNote: "Дописать тесты", dayStartShownAt: Date(timeIntervalSince1970: 300))
        let empty = DayPlan(day: "2026-10-11")
        try store.dbQueue.write { db in
            try plan.insert(db)
            try empty.insert(db)
        }
        let loaded = try store.dbQueue.read { db in try DayPlan.fetchOne(db, key: "2026-10-10") }
        let loadedEmpty = try store.dbQueue.read { db in try DayPlan.fetchOne(db, key: "2026-10-11") }
        let raw = try store.dbQueue.read { db in try String.fetchOne(db, sql: "SELECT focusTaskIds FROM day_plans WHERE day = '2026-10-11'") }
        #expect(loaded == plan)
        #expect(loadedEmpty == empty)
        #expect(raw == "[]")
    }
}
