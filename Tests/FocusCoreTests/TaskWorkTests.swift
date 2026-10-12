import Foundation
import GRDB
import Testing
@testable import FocusCore

struct TaskWorkTests {
    let t0 = Date(timeIntervalSince1970: 30_000)

    @Test
    func criteriaAddToggleDeleteProgress() throws {
        let service = TaskCriteriaService(store: try FocusStore.inMemory())
        let a = try service.add(taskID: "t1", text: "  first  ", now: t0)
        let b = try service.add(taskID: "t1", text: "second", now: t0)
        try service.add(taskID: "t2", text: "other", now: t0)
        #expect(a.text == "first")
        #expect(try service.criteria(taskID: "t1").map(\.id) == [a.id, b.id])
        #expect(try service.progress(taskID: "t1") == CriteriaProgress(done: 0, total: 2))
        try service.toggle(id: a.id)
        #expect(try service.progress(taskID: "t1") == CriteriaProgress(done: 1, total: 2))
        try service.toggle(id: a.id)
        #expect(try service.progress(taskID: "t1") == CriteriaProgress(done: 0, total: 2))
        try service.delete(id: b.id)
        #expect(try service.progress(taskID: "t1") == CriteriaProgress(done: 0, total: 1))
        #expect(try service.progress(taskID: "none") == CriteriaProgress(done: 0, total: 0))
    }

    @Test
    func toggleRecordsAndClearsCheckedAt() throws {
        let service = TaskCriteriaService(store: try FocusStore.inMemory())
        let a = try service.add(taskID: "t1", text: "a", now: t0)
        #expect(try service.criteria(taskID: "t1").first?.checkedAt == nil)
        try service.toggle(id: a.id, now: t0.addingTimeInterval(60))
        #expect(try service.criteria(taskID: "t1").first?.checkedAt == t0.addingTimeInterval(60))
        #expect(try service.criteria(taskID: "t1").first?.done == true)
        try service.toggle(id: a.id, now: t0.addingTimeInterval(120))
        #expect(try service.criteria(taskID: "t1").first?.checkedAt == nil)
        #expect(try service.criteria(taskID: "t1").first?.done == false)
    }

    @Test
    func v3DatabaseMigratesToV4KeepingCriteria() throws {
        let queue = try DatabaseQueue()
        try FocusStore.migrator(upTo: "v3").migrate(queue)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO task_criteria (id, taskId, text, done, position, createdAt) VALUES ('c1', 't1', 'x', 1, 1, ?)", arguments: [t0])
        }
        try FocusStore.migrator(upTo: nil).migrate(queue)
        let columns = try queue.read { db in try db.columns(in: "task_criteria").map(\.name) }
        #expect(columns.contains("checkedAt"))
        let row = try queue.read { db in try TaskCriterion.fetchOne(db, key: "c1") }
        #expect(row?.done == true)
        #expect(row?.checkedAt == nil)
    }

    @Test
    func criteriaRejectBlankText() throws {
        let service = TaskCriteriaService(store: try FocusStore.inMemory())
        #expect(throws: BoardError.emptyTitle) {
            try service.add(taskID: "t1", text: "  \n ", now: t0)
        }
    }

    @Test
    func enqueueReplacesUnsentPrompt() throws {
        let queue = PromptQueue(store: try FocusStore.inMemory())
        let first = try queue.enqueue(sessionID: "s1", taskID: "t1", text: "one", now: t0)
        let second = try queue.enqueue(sessionID: "s1", taskID: nil, text: "two", now: t0.addingTimeInterval(1))
        #expect(first.id != second.id)
        let pending = try #require(try queue.pending(sessionID: "s1"))
        #expect(pending.text == "two")
        #expect(pending.taskId == nil)
        #expect(try queue.pendingSessionIDs() == ["s1"])
    }

    @Test
    func enqueueBlankTextDiscards() throws {
        let queue = PromptQueue(store: try FocusStore.inMemory())
        try queue.enqueue(sessionID: "s1", taskID: nil, text: "one", now: t0)
        try queue.enqueue(sessionID: "s1", taskID: nil, text: "   ", now: t0)
        #expect(try queue.pending(sessionID: "s1") == nil)
        #expect(try queue.pendingSessionIDs().isEmpty)
    }

    @Test
    func markSentRemovesFromPending() throws {
        let queue = PromptQueue(store: try FocusStore.inMemory())
        let prompt = try queue.enqueue(sessionID: "s1", taskID: nil, text: "one", now: t0)
        try queue.enqueue(sessionID: "s2", taskID: nil, text: "two", now: t0)
        try queue.markSent(id: prompt.id, at: t0.addingTimeInterval(5))
        #expect(try queue.pending(sessionID: "s1") == nil)
        #expect(try queue.pendingSessionIDs() == ["s2"])
        try queue.discard(sessionID: "s2")
        #expect(try queue.pendingSessionIDs().isEmpty)
    }

    @Test
    func dayKeyUsesCalendarTimeZoneAtMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 3 * 3600)!
        let utc = Date(timeIntervalSince1970: 1_760_000_000)
        let beforeMidnight = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 23, minute: 59, second: 59))!
        let afterMidnight = beforeMidnight.addingTimeInterval(1)
        #expect(DayPlanStore.dayKey(beforeMidnight, calendar: calendar) == "2026-03-09")
        #expect(DayPlanStore.dayKey(afterMidnight, calendar: calendar) == "2026-03-10")
        var other = calendar
        other.timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(DayPlanStore.dayKey(afterMidnight, calendar: other) == "2026-03-09")
        _ = utc
    }

    @Test
    func dayPlanWritesAreUpserts() throws {
        let store = DayPlanStore(store: try FocusStore.inMemory())
        #expect(try store.plan(day: "2026-03-10") == nil)
        try store.setFocusTasks(["a", "b"], day: "2026-03-10")
        try store.setTomorrowNote("note", day: "2026-03-10")
        try store.markDayStartShown(day: "2026-03-10", at: t0)
        try store.setFocusTasks(["c"], day: "2026-03-10")
        let plan = try #require(try store.plan(day: "2026-03-10"))
        #expect(plan.focusTaskIds == ["c"])
        #expect(plan.tomorrowNote == "note")
        #expect(plan.dayStartShownAt == t0)
        try store.setTomorrowNote(nil, day: "2026-03-10")
        #expect(try store.plan(day: "2026-03-10")?.tomorrowNote == nil)
        try store.markDayStartShown(day: "2026-03-11", at: t0)
        #expect(try store.plan(day: "2026-03-11")?.focusTaskIds == [])
    }

    @Test
    func allProgressGroupsByTask() throws {
        let service = TaskCriteriaService(store: try FocusStore.inMemory())
        let a = try service.add(taskID: "t1", text: "a", now: t0)
        try service.add(taskID: "t1", text: "b", now: t0)
        try service.add(taskID: "t2", text: "c", now: t0)
        try service.toggle(id: a.id)
        #expect(try service.allProgress() == ["t1": CriteriaProgress(done: 1, total: 2), "t2": CriteriaProgress(done: 0, total: 1)])
    }

    @Test
    func markSentMatchesSessionAndSentText() throws {
        let queue = PromptQueue(store: try FocusStore.inMemory())
        let first = try queue.enqueue(sessionID: "s1", taskID: nil, text: "same", now: t0)
        let second = try queue.enqueue(sessionID: "s1", taskID: nil, text: "same", now: t0.addingTimeInterval(1))
        #expect(first.id != second.id)
        try queue.markSent(sessionID: "s1", text: "same", at: t0.addingTimeInterval(2))
        #expect(try queue.pending(sessionID: "s1") == nil)
        try queue.enqueue(sessionID: "s1", taskID: nil, text: "edited", now: t0.addingTimeInterval(3))
        try queue.markSent(sessionID: "s1", text: "same", at: t0.addingTimeInterval(4))
        #expect(try queue.pending(sessionID: "s1")?.text == "edited")
    }

    @Test
    func pendingPromptsOfEndedSessionsAreDiscarded() throws {
        let store = try FocusStore.inMemory()
        let queue = PromptQueue(store: store)
        func record(_ id: String, status: SessionRecordStatus) -> SessionRecord {
            SessionRecord(id: id, cwd: nil, projectName: nil, title: id, firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, startedAt: t0, lastActivityAt: t0, endedAt: status == .ended ? t0 : nil, status: status, taskId: nil, transcriptPath: nil)
        }
        try store.dbQueue.write { db in
            try record("live", status: .live).insert(db)
            try record("gone", status: .ended).insert(db)
        }
        try queue.enqueue(sessionID: "live", taskID: nil, text: "a", now: t0)
        try queue.enqueue(sessionID: "gone", taskID: nil, text: "b", now: t0)
        #expect(try queue.pendingSessionIDs() == ["live"])
        try queue.discardForEndedSessions()
        #expect(try queue.pending(sessionID: "gone") == nil)
        #expect(try queue.pending(sessionID: "live")?.text == "a")
    }

    @Test
    func latestTomorrowNoteLooksBackAWeek() throws {
        let store = DayPlanStore(store: try FocusStore.inMemory())
        try store.setTomorrowNote("старая", day: "2026-03-01")
        try store.setTomorrowNote("пятница", day: "2026-03-06")
        try store.setTomorrowNote("", day: "2026-03-07")
        try store.setTomorrowNote("сегодняшняя", day: "2026-03-09")
        #expect(try store.latestTomorrowNote(before: "2026-03-09", notBefore: "2026-03-02") == "пятница")
        #expect(try store.latestTomorrowNote(before: "2026-03-06", notBefore: "2026-02-27") == "старая")
        #expect(try store.latestTomorrowNote(before: "2026-03-06", notBefore: "2026-03-02") == nil)
    }
}
