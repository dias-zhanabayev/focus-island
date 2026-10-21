import FocusCore
import Foundation
import OpenIslandCore
import Testing
@testable import OpenIslandApp

@MainActor
struct FocusCoordinatorSpanTests {
    let t0 = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 10))!

    func make(store: FocusStore? = nil, start: Bool = true) throws -> (FocusCoordinator, FocusStore) {
        let store = try store ?? FocusStore.inMemory()
        let defaults = UserDefaults(suiteName: "focus-span-\(UUID().uuidString)")!
        let coordinator = FocusCoordinator(store: store, defaults: defaults, launcher: RecordingLauncher(), gitDiff: StubGitDiff(files: []), clipboard: { _ in }, runBackfill: false)
        coordinator.settings.dayStartEnabled = false
        if start {
            coordinator.start(initialSessions: [], now: t0)
        }
        return (coordinator, store)
    }

    func session(_ id: String, _ phase: SessionPhase, at date: Date, cwd: String = "/tmp/proj") -> AgentSession {
        var session = AgentSession(
            id: id, title: id, tool: .claudeCode, origin: .live, attachmentState: .attached, phase: phase, summary: "", updatedAt: date, firstSeenAt: date,
            jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "proj", paneTitle: "", workingDirectory: cwd),
            claudeMetadata: ClaudeSessionMetadata(initialUserPrompt: "p", lastUserPrompt: "p", startupSource: .startup)
        )
        session.isHookManaged = true
        return session
    }

    func spans(_ store: FocusStore) throws -> [ActivitySpan] {
        try ActivityLog(store: store).spans(from: .distantPast, to: .distantFuture)
    }

    @Test
    func startClosesDanglingSpans() throws {
        let store = try FocusStore.inMemory()
        let log = ActivityLog(store: store)
        let dangling = try log.open(kind: .claude, sessionID: "old", taskID: nil, at: t0.addingTimeInterval(-3600))
        let you = try log.open(kind: .you, sessionID: nil, taskID: "t", at: t0.addingTimeInterval(-1800))
        let (coordinator, _) = try make(store: store, start: false)
        coordinator.start(initialSessions: [], now: t0)
        let all = try spans(store)
        #expect(all.first { $0.id == dangling }?.endedAt == t0.addingTimeInterval(-3600))
        #expect(all.first { $0.id == you }?.endedAt == t0.addingTimeInterval(-1800))
        let report = try #require(coordinator.dayReport(day: t0, now: t0.addingTimeInterval(7200)))
        #expect(report.claudeSeconds == 0)
        #expect(report.youSeconds == 0)
    }

    @Test
    func sessionsBeforeStartWriteNothing() throws {
        let (c, store) = try make(start: false)
        let restored = (1...4).map { session("r\($0)", .running, at: t0.addingTimeInterval(-60)) }
        c.sessionsDidChange(restored, now: t0.addingTimeInterval(-1))
        #expect(try spans(store).isEmpty)
        #expect(c.card == nil)
        c.start(initialSessions: restored, now: t0)
        #expect(c.card == nil)
        #expect(c.toast == nil)
        let all = try spans(store)
        #expect(all.count == 4)
        #expect(all.allSatisfy { $0.kind == .claude && $0.startedAt == t0 })
        #expect(c.hubRows.count == 4)
    }

    @Test
    func stopClosesSpansUntilWake() throws {
        let (c, store) = try make()
        c.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        c.createTask(title: "A", column: .todo, projectPath: nil)
        let taskID = try #require(c.board.tasks.first?.id)
        c.bind(sessionID: "s1", taskID: taskID)
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Terminal", url: nil, at: t0.addingTimeInterval(10)))
        #expect(try spans(store).count == 2)

        c.stop(now: t0.addingTimeInterval(20))
        #expect(try spans(store).allSatisfy { $0.endedAt == t0.addingTimeInterval(20) })
        c.tick(now: t0.addingTimeInterval(21))
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Terminal", url: nil, at: t0.addingTimeInterval(22)))
        #expect(try spans(store).count == 2)

        c.wake(now: t0.addingTimeInterval(3600))
        let reopened = try spans(store).filter { $0.endedAt == .distantFuture }
        #expect(reopened.count == 2)
        #expect(reopened.allSatisfy { $0.startedAt == t0.addingTimeInterval(3600) })
        #expect(Set(reopened.map(\.kind)) == [.claude, .you])
    }

    @Test
    func phaseTransitionsOpenAndCloseSpans() throws {
        let (c, store) = try make()
        c.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        c.createTask(title: "A", column: .todo, projectPath: nil)
        let taskID = try #require(c.board.tasks.first?.id)
        c.bind(sessionID: "s1", taskID: taskID)
        c.sessionsDidChange([session("s1", .waitingForApproval, at: t0.addingTimeInterval(10))], now: t0.addingTimeInterval(10))
        c.sessionsDidChange([session("s1", .running, at: t0.addingTimeInterval(20))], now: t0.addingTimeInterval(20))
        c.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(30))], now: t0.addingTimeInterval(30))
        c.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(35))], now: t0.addingTimeInterval(35))
        c.tick(now: t0.addingTimeInterval(36))
        #expect(try spans(store).count == 4)
        c.markSessionSeen("s1", now: t0.addingTimeInterval(40))

        let all = try spans(store)
        #expect(all.map(\.kind) == [.claude, .waiting, .claude, .waiting])
        #expect(all.map(\.taskId) == [taskID, taskID, taskID, taskID])
        #expect(all.map(\.startedAt) == [t0, t0.addingTimeInterval(10), t0.addingTimeInterval(20), t0.addingTimeInterval(30)])
        #expect(all.map(\.endedAt) == [t0.addingTimeInterval(10), t0.addingTimeInterval(20), t0.addingTimeInterval(30), t0.addingTimeInterval(40)])

        c.sessionsDidChange([session("s1", .running, at: t0.addingTimeInterval(50))], now: t0.addingTimeInterval(50))
        c.sessionsDidChange([], now: t0.addingTimeInterval(60))
        let last = try #require(try spans(store).last)
        #expect(last.kind == .claude)
        #expect(last.endedAt == t0.addingTimeInterval(60))

        let report = try #require(c.dayReport(day: t0, now: t0.addingTimeInterval(100)))
        #expect(report.claudeSeconds == 30)
        #expect(report.waitingSeconds == 20)
    }

    @Test
    func youSpanOnlyWithTerminalAndCurrentTask() throws {
        let (c, store) = try make()
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Terminal", url: nil, at: t0))
        #expect(try spans(store).isEmpty)

        c.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        c.createTask(title: "A", column: .todo, projectPath: nil)
        let taskID = try #require(c.board.tasks.first?.id)
        c.bind(sessionID: "s1", taskID: taskID)
        #expect(c.currentTask?.id == taskID)

        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Terminal", url: nil, at: t0.addingTimeInterval(10)))
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Safari", url: nil, at: t0.addingTimeInterval(20)))
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Terminal", url: nil, at: t0.addingTimeInterval(30)))
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.dt.Xcode", url: nil, at: t0.addingTimeInterval(40)))
        c.tick(now: t0.addingTimeInterval(41))

        let you = try spans(store).filter { $0.kind == .you }
        #expect(you.count == 2)
        #expect(you.allSatisfy { $0.taskId == taskID && $0.sessionId == nil })
        #expect(you.map(\.startedAt) == [t0.addingTimeInterval(10), t0.addingTimeInterval(30)])
        #expect(you[0].endedAt == t0.addingTimeInterval(20))
        #expect(you[1].endedAt == .distantFuture)

        c.createTask(title: "B", column: .todo, projectPath: nil)
        let other = try #require(c.board.tasks.first { $0.title == "B" }?.id)
        c.sessionsDidChange([session("s1", .running, at: t0), session("s2", .running, at: t0.addingTimeInterval(50))], now: t0.addingTimeInterval(50))
        c.bind(sessionID: "s2", taskID: other)
        c.tick(now: t0.addingTimeInterval(55))
        let after = try spans(store).filter { $0.kind == .you }
        #expect(after.count == 3)
        #expect(after[1].endedAt == t0.addingTimeInterval(55))
        #expect(after[2].taskId == other)
        #expect(after[2].startedAt == t0.addingTimeInterval(55))
    }

    @Test
    func weekReportCoversSevenDaysEndingToday() throws {
        let (c, _) = try make()
        c.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        let report = try #require(c.weekReport(endingAt: t0, now: t0.addingTimeInterval(600)))
        #expect(report.days.count == 7)
        #expect(report.days.last?.day == Calendar.current.startOfDay(for: t0))
        #expect(report.sessions == 1)
    }

    @Test
    func tomorrowNoteIsStoredInDayPlan() throws {
        let (c, _) = try make()
        c.setTomorrowNote("начать с тестов", day: t0)
        #expect(c.dayPlan(day: t0)?.tomorrowNote == "начать с тестов")
    }

    @Test
    func bindingMidRunBooksOpenTurnUnderTask() throws {
        let (c, store) = try make()
        c.sessionsDidChange([session("s1", .running, at: t0), session("s2", .running, at: t0)], now: t0)
        c.createTask(title: "A", column: .todo, projectPath: nil)
        let taskID = try #require(c.board.tasks.first?.id)
        c.bind(sessionID: "s1", taskID: taskID, now: t0.addingTimeInterval(30))
        c.createTaskForSession(sessionID: "s2", now: t0.addingTimeInterval(30))
        let created = try #require(c.board.tasks.first { $0.id != taskID }?.id)
        c.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(60)), session("s2", .completed, at: t0.addingTimeInterval(60))], now: t0.addingTimeInterval(60))
        c.markSessionSeen("s1", now: t0.addingTimeInterval(60))
        c.markSessionSeen("s2", now: t0.addingTimeInterval(60))

        let claude = try spans(store).filter { $0.kind == .claude }
        #expect(claude.count == 2)
        #expect(claude.first { $0.sessionId == "s1" }?.taskId == taskID)
        #expect(claude.first { $0.sessionId == "s2" }?.taskId == created)

        let report = try #require(c.dayReport(day: t0, now: t0.addingTimeInterval(100)))
        let lane = try #require(report.lanes.first { $0.taskID == taskID })
        let seconds = lane.segments.filter { $0.kind == .claude }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        #expect(seconds == 60)
    }

    @Test
    func screenLockClosesPresenceSpansButKeepsClaude() throws {
        let (c, store) = try make()
        c.sessionsDidChange([session("s1", .running, at: t0), session("s2", .running, at: t0)], now: t0)
        c.createTask(title: "A", column: .todo, projectPath: nil)
        let taskID = try #require(c.board.tasks.first?.id)
        c.bind(sessionID: "s1", taskID: taskID, now: t0)
        c.sessionsDidChange([session("s1", .running, at: t0), session("s2", .completed, at: t0.addingTimeInterval(5))], now: t0.addingTimeInterval(5))
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Terminal", url: nil, at: t0.addingTimeInterval(10)))
        let initiallyOpen = try spans(store).filter { $0.endedAt == .distantFuture }
        #expect(initiallyOpen.count == 3)
        #expect(Set(initiallyOpen.map(\.kind)) == [.claude, .waiting, .you])

        c.presenceDidChange(.screenLocked, now: t0.addingTimeInterval(100))
        var open = try spans(store).filter { $0.endedAt == .distantFuture }
        #expect(open.map(\.kind) == [.claude])
        #expect(try spans(store).filter { $0.kind == .you }.map(\.endedAt) == [t0.addingTimeInterval(100)])
        #expect(try spans(store).filter { $0.kind == .waiting }.map(\.endedAt) == [t0.addingTimeInterval(100)])

        c.tick(now: t0.addingTimeInterval(101))
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Terminal", url: nil, at: t0.addingTimeInterval(102)))
        c.sessionsDidChange([session("s1", .running, at: t0.addingTimeInterval(103)), session("s2", .completed, at: t0.addingTimeInterval(5))], now: t0.addingTimeInterval(103))
        open = try spans(store).filter { $0.endedAt == .distantFuture }
        #expect(open.map(\.kind) == [.claude])

        c.presenceDidChange(.screenUnlocked, now: t0.addingTimeInterval(500))
        open = try spans(store).filter { $0.endedAt == .distantFuture }
        #expect(Set(open.map(\.kind)) == [.claude, .you, .waiting])
        #expect(open.filter { $0.kind != .claude }.allSatisfy { $0.startedAt == t0.addingTimeInterval(500) })
        let report = try #require(c.dayReport(day: t0, now: t0.addingTimeInterval(600)))
        #expect(report.youSeconds == 190)
        #expect(report.claudeSeconds == 600)
    }

    @Test
    func parkedSessionHasNoWaitingSpan() throws {
        let (c, store) = try make()
        c.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        c.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(10))], now: t0.addingTimeInterval(10))
        #expect(try spans(store).last?.kind == .waiting)
        c.perform(.park(sessionID: "s1"), now: t0.addingTimeInterval(40))
        c.tick(now: t0.addingTimeInterval(50))
        c.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(10))], now: t0.addingTimeInterval(60))
        let waiting = try spans(store).filter { $0.kind == .waiting }
        #expect(waiting.count == 1)
        #expect(waiting.first?.endedAt == t0.addingTimeInterval(40))
    }

    @Test
    func dayStartNoteIsLatestWithinAWeek() throws {
        let (c, _) = try make()
        let calendar = Calendar.current
        let friday = try #require(calendar.date(byAdding: .day, value: -3, to: t0))
        let older = try #require(calendar.date(byAdding: .day, value: -9, to: t0))
        c.setTomorrowNote("старое", day: older)
        #expect(c.recentTomorrowNote(now: t0) == nil)
        c.setTomorrowNote("начать с тестов", day: friday)
        c.setTomorrowNote("сегодняшнее", day: t0)
        #expect(c.recentTomorrowNote(now: t0) == "начать с тестов")
    }

    @Test
    func taskAggregatesRefreshOnBindAndBoardAppearanceOnly() throws {
        let (c, _) = try make()
        c.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        c.createTask(title: "A", column: .todo, projectPath: nil)
        let taskID = try #require(c.board.tasks.first?.id)
        c.bind(sessionID: "s1", taskID: taskID, now: t0)
        #expect(c.aggregate(taskID: taskID).records.map(\.id) == ["s1"])
        let before = c.aggregate(taskID: taskID)
        c.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(30))], now: t0.addingTimeInterval(30))
        #expect(c.aggregate(taskID: taskID) == before)
        c.boardDidAppear()
        #expect(c.aggregate(taskID: taskID).records.first?.lastActivityAt == t0.addingTimeInterval(30))
    }
}
