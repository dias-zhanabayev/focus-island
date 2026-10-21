import Foundation
import GRDB
import Testing
@testable import FocusCore

struct PomodoroTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(planned: Int = 1500, paused: Double = 0, pausedAt: Date? = nil, startedAt: Date? = nil) -> Pomodoro {
        Pomodoro(id: "p1", taskId: "t1", phase: .focus, plannedSeconds: planned, startedAt: startedAt ?? t0, endedAt: nil, pausedSeconds: paused, pausedAt: pausedAt, completed: false)
    }

    @Test
    func v2DatabaseMigratesToV3() throws {
        let queue = try DatabaseQueue()
        try FocusStore.migrator(upTo: "v2").migrate(queue)
        try FocusStore.migrator(upTo: nil).migrate(queue)
        let tables = try queue.read { db in try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'") }
        #expect(tables.contains("pomodoros"))
        let indexes = try queue.read { db in try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'pomodoros'") }
        #expect(indexes.contains { $0.contains("taskId") })
    }

    @Test
    func completedFocusCountRespectsStartedBefore() throws {
        let store = try FocusStore.inMemory()
        let pomodoros = PomodoroStore(store: store)
        try pomodoros.start(taskID: "t1", phase: .focus, plannedSeconds: 60, now: t0)
        try pomodoros.finish(completed: true, now: t0.addingTimeInterval(60))
        try pomodoros.start(taskID: "t1", phase: .focus, plannedSeconds: 60, now: t0.addingTimeInterval(100))
        try pomodoros.finish(completed: true, now: t0.addingTimeInterval(160))
        #expect(try pomodoros.completedFocusCount(taskID: "t1", day: t0) == 2)
        #expect(try pomodoros.completedFocusCount(taskID: "t1", day: t0, startedBefore: t0.addingTimeInterval(100)) == 1)
        #expect(try pomodoros.completedFocusCount(day: t0) == 2)
    }

    @Test
    func clockRemainingAndProgress() {
        let p = sample()
        #expect(PomodoroClock.remaining(p, now: t0.addingTimeInterval(600)) == 900)
        #expect(PomodoroClock.progress(p, now: t0.addingTimeInterval(750)) == 0.5)
        #expect(PomodoroClock.remaining(p, now: t0.addingTimeInterval(9_999)) == 0)
        #expect(PomodoroClock.progress(p, now: t0.addingTimeInterval(9_999)) == 1)
        #expect(PomodoroClock.progress(p, now: t0.addingTimeInterval(-5)) == 0)
    }

    @Test
    func clockAccountsPausedAndOngoingPause() {
        let paused = sample(paused: 300)
        #expect(PomodoroClock.remaining(paused, now: t0.addingTimeInterval(600)) == 1200)
        let ongoing = sample(paused: 100, pausedAt: t0.addingTimeInterval(400))
        #expect(PomodoroClock.remaining(ongoing, now: t0.addingTimeInterval(1000)) == 1500 - 300)
        #expect(PomodoroClock.remaining(ongoing, now: t0.addingTimeInterval(5000)) == 1500 - 300)
    }

    @Test
    func clockExpiry() {
        let p = sample(paused: 60)
        #expect(PomodoroClock.expiryDate(p) == t0.addingTimeInterval(1560))
        #expect(!PomodoroClock.isExpired(p, now: t0.addingTimeInterval(1559)))
        #expect(PomodoroClock.isExpired(p, now: t0.addingTimeInterval(1560)))
        let ongoing = sample(pausedAt: t0.addingTimeInterval(100))
        #expect(!PomodoroClock.isExpired(ongoing, now: t0.addingTimeInterval(99_999)))
    }

    @Test
    func cycleIndexIsOneBasedModuloCycle() {
        #expect(PomodoroClock.cycleIndex(completedToday: 0, cycle: 4) == 1)
        #expect(PomodoroClock.cycleIndex(completedToday: 3, cycle: 4) == 4)
        #expect(PomodoroClock.cycleIndex(completedToday: 4, cycle: 4) == 1)
        #expect(PomodoroClock.cycleIndex(completedToday: 9, cycle: 4) == 2)
        #expect(PomodoroClock.cycleIndex(completedToday: 5, cycle: 0) == 1)
    }

    @Test
    func startCreatesActiveAndFinishesPrevious() throws {
        let store = try FocusStore.inMemory()
        let pomodoros = PomodoroStore(store: store)
        let first = try pomodoros.start(taskID: "t1", phase: .focus, plannedSeconds: 1500, now: t0)
        #expect(try pomodoros.active()?.id == first.id)
        let second = try pomodoros.start(taskID: "t2", phase: .break, plannedSeconds: 300, now: t0.addingTimeInterval(100))
        let active = try #require(try pomodoros.active())
        #expect(active.id == second.id)
        let stored = try store.dbQueue.read { db in try Pomodoro.fetchOne(db, key: first.id) }
        #expect(stored?.endedAt == t0.addingTimeInterval(100))
        #expect(stored?.completed == false)
    }

    @Test
    func pauseAndResumeAccumulate() throws {
        let pomodoros = PomodoroStore(store: try FocusStore.inMemory())
        _ = try pomodoros.start(taskID: "t1", phase: .focus, plannedSeconds: 1500, now: t0)
        let paused = try #require(try pomodoros.pause(now: t0.addingTimeInterval(100)))
        #expect(paused.pausedAt == t0.addingTimeInterval(100))
        let again = try pomodoros.pause(now: t0.addingTimeInterval(150))
        #expect(again?.pausedAt == t0.addingTimeInterval(100))
        let resumed = try #require(try pomodoros.resume(now: t0.addingTimeInterval(160)))
        #expect(resumed.pausedAt == nil)
        #expect(resumed.pausedSeconds == 60)
        #expect(try pomodoros.resume(now: t0.addingTimeInterval(200))?.pausedSeconds == 60)
    }

    @Test
    func pauseWithoutActiveReturnsNil() throws {
        let pomodoros = PomodoroStore(store: try FocusStore.inMemory())
        #expect(try pomodoros.pause(now: t0) == nil)
        #expect(try pomodoros.resume(now: t0) == nil)
        #expect(try pomodoros.finish(completed: true, now: t0) == nil)
    }

    @Test
    func finishWhilePausedCountsPauseAndClearsActive() throws {
        let store = try FocusStore.inMemory()
        let pomodoros = PomodoroStore(store: store)
        let started = try pomodoros.start(taskID: "t1", phase: .focus, plannedSeconds: 1500, now: t0)
        _ = try pomodoros.pause(now: t0.addingTimeInterval(100))
        let finished = try #require(try pomodoros.finish(completed: false, now: t0.addingTimeInterval(130)))
        #expect(finished.id == started.id)
        #expect(finished.endedAt == t0.addingTimeInterval(130))
        #expect(finished.pausedSeconds == 30)
        #expect(finished.pausedAt == nil)
        #expect(finished.completed == false)
        #expect(try pomodoros.active() == nil)
    }

    @Test
    func countsAndFocusSecondsForDay() throws {
        let store = try FocusStore.inMemory()
        let pomodoros = PomodoroStore(store: store)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.startOfDay(for: t0)
        let morning = day.addingTimeInterval(3600)
        _ = try pomodoros.start(taskID: "t1", phase: .focus, plannedSeconds: 1500, now: morning)
        _ = try pomodoros.finish(completed: true, now: morning.addingTimeInterval(1500))
        _ = try pomodoros.start(taskID: "t1", phase: .focus, plannedSeconds: 1500, now: morning.addingTimeInterval(2000))
        _ = try pomodoros.finish(completed: false, now: morning.addingTimeInterval(2600))
        _ = try pomodoros.start(taskID: "t1", phase: .break, plannedSeconds: 300, now: morning.addingTimeInterval(3000))
        _ = try pomodoros.finish(completed: true, now: morning.addingTimeInterval(3300))
        _ = try pomodoros.start(taskID: "t2", phase: .focus, plannedSeconds: 600, now: morning.addingTimeInterval(4000))
        _ = try pomodoros.finish(completed: true, now: morning.addingTimeInterval(4600))
        _ = try pomodoros.start(taskID: "t1", phase: .focus, plannedSeconds: 1500, now: day.addingTimeInterval(-3600))
        _ = try pomodoros.finish(completed: true, now: day.addingTimeInterval(-3600 + 1500))
        #expect(try pomodoros.completedFocusCount(taskID: "t1", day: morning, calendar: calendar) == 1)
        #expect(try pomodoros.completedFocusCount(taskID: "t2", day: morning, calendar: calendar) == 1)
        #expect(try pomodoros.completedFocusCount(day: morning, calendar: calendar) == 2)
        #expect(try pomodoros.focusSeconds(taskID: "t1", day: morning, calendar: calendar) == 1500 + 600)
        #expect(try pomodoros.focusSeconds(taskID: "t2", day: morning, calendar: calendar) == 600)
    }

    @Test
    func focusSecondsExcludesPausedTime() throws {
        let pomodoros = PomodoroStore(store: try FocusStore.inMemory())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let morning = calendar.startOfDay(for: t0).addingTimeInterval(3600)
        _ = try pomodoros.start(taskID: "t1", phase: .focus, plannedSeconds: 1500, now: morning)
        _ = try pomodoros.pause(now: morning.addingTimeInterval(100))
        _ = try pomodoros.resume(now: morning.addingTimeInterval(400))
        _ = try pomodoros.finish(completed: false, now: morning.addingTimeInterval(1000))
        #expect(try pomodoros.focusSeconds(taskID: "t1", day: morning, calendar: calendar) == 700)
    }

    @Test
    func recoverExpiredFinishesAtExpiry() throws {
        let store = try FocusStore.inMemory()
        let pomodoros = PomodoroStore(store: store)
        _ = try pomodoros.start(taskID: "t1", phase: .focus, plannedSeconds: 1500, now: t0)
        _ = try pomodoros.pause(now: t0.addingTimeInterval(100))
        _ = try pomodoros.resume(now: t0.addingTimeInterval(160))
        #expect(try pomodoros.recoverExpired(now: t0.addingTimeInterval(1559)) == nil)
        #expect(try pomodoros.active() != nil)
        let recovered = try #require(try pomodoros.recoverExpired(now: t0.addingTimeInterval(9_000)))
        #expect(recovered.completed == true)
        #expect(recovered.endedAt == t0.addingTimeInterval(1560))
        #expect(try pomodoros.active() == nil)
        #expect(try pomodoros.recoverExpired(now: t0.addingTimeInterval(9_000)) == nil)
    }

    @Test
    func recoverExpiredIgnoresPausedActive() throws {
        let pomodoros = PomodoroStore(store: try FocusStore.inMemory())
        _ = try pomodoros.start(taskID: "t1", phase: .focus, plannedSeconds: 1500, now: t0)
        _ = try pomodoros.pause(now: t0.addingTimeInterval(100))
        #expect(try pomodoros.recoverExpired(now: t0.addingTimeInterval(99_999)) == nil)
        #expect(try pomodoros.active() != nil)
    }

    @Test
    func deleteTaskStopsActivePomodoroAndDetachesRows() throws {
        let store = try FocusStore.inMemory()
        let board = BoardService(store: store)
        let pomodoros = PomodoroStore(store: store)
        let task = try board.createTask(title: "Задача", column: .inProgress, now: t0)
        let other = try board.createTask(title: "Другая", column: .todo, now: t0)
        _ = try pomodoros.start(taskID: task.id, phase: .focus, plannedSeconds: 1500, now: t0)
        _ = try pomodoros.finish(completed: true, now: t0.addingTimeInterval(1500))
        let active = try pomodoros.start(taskID: task.id, phase: .focus, plannedSeconds: 1500, now: t0.addingTimeInterval(1600))
        try board.deleteTask(id: task.id)
        #expect(try pomodoros.active() == nil)
        let rows = try store.dbQueue.read { db in try Pomodoro.fetchAll(db) }
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.taskId == nil })
        let stopped = try #require(rows.first { $0.id == active.id })
        #expect(stopped.completed == false)
        #expect(stopped.endedAt != nil)
        #expect(try board.snapshot().task(id: other.id)?.title == "Другая")
    }

    @Test
    func deleteOtherTaskKeepsActivePomodoro() throws {
        let store = try FocusStore.inMemory()
        let board = BoardService(store: store)
        let pomodoros = PomodoroStore(store: store)
        let task = try board.createTask(title: "Задача", column: .inProgress, now: t0)
        let other = try board.createTask(title: "Другая", column: .todo, now: t0)
        let active = try pomodoros.start(taskID: task.id, phase: .focus, plannedSeconds: 1500, now: t0)
        try board.deleteTask(id: other.id)
        #expect(try pomodoros.active()?.id == active.id)
        #expect(try pomodoros.active()?.taskId == task.id)
    }
}
