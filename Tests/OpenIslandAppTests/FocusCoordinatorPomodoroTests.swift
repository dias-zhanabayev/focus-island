import FocusCore
import Foundation
import OpenIslandCore
import Testing
@testable import OpenIslandApp

@MainActor
struct FocusCoordinatorPomodoroTests {
    let t0 = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 9))!

    final class Box {
        var jumps: [String] = []
        var presented = 0
    }

    struct Harness {
        let coordinator: FocusCoordinator
        let store: FocusStore
        let box: Box
        let defaults: UserDefaults
    }

    func make(start: Bool = true, store: FocusStore? = nil, initial: [AgentSession] = []) throws -> Harness {
        let store = try store ?? FocusStore.inMemory()
        let defaults = UserDefaults(suiteName: "focus-pomodoro-\(UUID().uuidString)")!
        let coordinator = FocusCoordinator(store: store, defaults: defaults, launcher: RecordingLauncher(), promptSender: RecordingPromptSender(result: .unsupported), gitDiff: StubGitDiff(files: []), clipboard: { _ in }, runBackfill: false)
        coordinator.settings.dayStartEnabled = false
        coordinator.settings.autoBreakEnabled = false
        let box = Box()
        coordinator.jumpToSession = { box.jumps.append($0) }
        coordinator.presentCard = { box.presented += 1 }
        if start {
            coordinator.start(initialSessions: initial, now: t0)
        }
        return Harness(coordinator: coordinator, store: store, box: box, defaults: defaults)
    }

    func session(_ id: String, _ phase: SessionPhase, at date: Date, cwd: String = "/tmp/proj", prompt: String = "p") -> AgentSession {
        var session = AgentSession(
            id: id, title: "title-\(id)", tool: .claudeCode, origin: .live, attachmentState: .attached, phase: phase, summary: "", updatedAt: date, firstSeenAt: date.addingTimeInterval(-3600),
            jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "proj", paneTitle: "", workingDirectory: cwd),
            claudeMetadata: ClaudeSessionMetadata(initialUserPrompt: "p", lastUserPrompt: prompt, startupSource: .startup)
        )
        session.isHookManaged = true
        return session
    }

    func task(_ h: Harness, _ title: String, column: BoardColumn = .todo, projectPath: String? = "/tmp/proj") throws -> String {
        h.coordinator.createTask(title: title, column: column, projectPath: projectPath)
        return try #require(h.coordinator.board.tasks.first { $0.title == title }?.id)
    }

    func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    @Test
    func newCardPriorities() {
        #expect(FocusCard.onboarding.priority == 10)
        #expect(FocusCard.nudge.priority == 9)
        #expect(FocusCard.pomodoroEnd(pomodoroID: "p").priority == 8)
        #expect(FocusCard.breakEnd(pomodoroID: "p").priority == 8)
        #expect(FocusCard.returned(sessionID: "a").priority == 7)
        #expect(FocusCard.reEntry(sessionID: "a").priority == 6)
        #expect(FocusCard.overload(newSessionID: "a").priority == 5)
        #expect(FocusCard.nextAction(triggeringSessionID: "a", eventID: nil).priority == 4)
        #expect(FocusCard.dayStart.priority == 2)
        #expect(FocusCard.pickTask.priority == 2)
        #expect(!FocusCard.canReplace(.nudge, with: .pomodoroEnd(pomodoroID: "p")))
        #expect(FocusCard.canReplace(.returned(sessionID: "a"), with: .pomodoroEnd(pomodoroID: "p")))
        #expect(!FocusCard.canReplace(.pomodoroEnd(pomodoroID: "p"), with: .returned(sessionID: "a")))
    }

    @Test
    func startTaskMovesBindsAndStartsClampedFocus() throws {
        let h = try make()
        let c = h.coordinator
        let other = try task(h, "Other", column: .inProgress)
        let target = try task(h, "Target")
        c.sessionsDidChange([session("s1", .running, at: at(0)), session("s2", .completed, at: at(0))], now: at(0))
        c.bind(sessionID: "s2", taskID: other, now: at(1))
        c.startTask(taskID: target, sessionIDs: ["s1", "s2"], focusMinutes: 200, now: at(2))
        #expect(c.board.task(id: target)?.boardColumn == .inProgress)
        #expect(c.currentTask?.id == target)
        #expect(c.taskID(forSession: "s1") == target)
        #expect(c.taskID(forSession: "s2") == target)
        let snapshot = try #require(c.pomodoro)
        #expect(snapshot.taskID == target)
        #expect(snapshot.taskTitle == "Target")
        #expect(snapshot.phase == .focus)
        #expect(snapshot.plannedSeconds == 120 * 60)
        #expect(snapshot.remainingSeconds == 120 * 60)
        #expect(snapshot.isPaused == false)
        #expect(snapshot.cycleIndex == 1)
        #expect(snapshot.cycle == 4)
        #expect(snapshot.progress == 0)
    }

    @Test
    func startTaskClampsLowMinutesAndNilStartsNothing() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        let b = try task(h, "B")
        c.startTask(taskID: a, sessionIDs: [], focusMinutes: nil, now: at(0))
        #expect(c.pomodoro == nil)
        #expect(c.currentTask?.id == a)
        c.startTask(taskID: b, sessionIDs: [], focusMinutes: 2, now: at(1))
        #expect(c.pomodoro?.plannedSeconds == 5 * 60)
        #expect(c.currentTask?.id == b)
    }

    @Test
    func requestStartTaskSetsPendingAndMoves() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.requestStartTask(taskID: a)
        #expect(c.pendingStartTaskID == a)
        #expect(c.board.task(id: a)?.boardColumn == .inProgress)
        c.clearPendingStartTask()
        #expect(c.pendingStartTaskID == nil)
    }

    @Test
    func bindableSessionsOrderAndDefaults() throws {
        let h = try make()
        let c = h.coordinator
        let target = try task(h, "Target", projectPath: "/tmp/proj")
        let other = try task(h, "Other", column: .inProgress, projectPath: "/tmp/other")
        c.sessionsDidChange([
            session("far", .running, at: at(3), cwd: "/tmp/other"),
            session("own", .running, at: at(2), cwd: "/tmp/proj/sub"),
            session("taken", .running, at: at(1), cwd: "/tmp/proj"),
            session("bound", .running, at: at(1), cwd: "/tmp/proj"),
        ], now: at(3))
        c.bind(sessionID: "taken", taskID: other, now: at(4))
        c.bind(sessionID: "bound", taskID: target, now: at(4))
        let rows = c.bindableSessions(forTaskID: target)
        #expect(rows.map(\.id) == ["own", "taken", "far"])
        #expect(rows.map(\.isSameProject) == [true, true, false])
        #expect(rows.map(\.defaultSelected) == [true, false, false])
        #expect(rows.map(\.boundTaskTitle) == [nil, "Other", nil])
        #expect(rows.first?.title == "title-own")
    }

    @Test
    func tickCountsDownPausesAndResumes() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        #expect(c.startPomodoro(taskID: a, minutes: 25, now: at(0)))
        c.tick(now: at(10.4))
        #expect(c.pomodoro?.remainingSeconds == 25 * 60 - 10)
        c.pausePomodoro(now: at(11))
        #expect(c.pomodoro?.isPaused == true)
        c.tick(now: at(100))
        #expect(c.pomodoro?.remainingSeconds == 25 * 60 - 11)
        c.resumePomodoro(now: at(100))
        #expect(c.pomodoro?.isPaused == false)
        c.tick(now: at(110))
        #expect(c.pomodoro?.remainingSeconds == 25 * 60 - 21)
    }

    @Test
    func startPomodoroRejectsNonPositive() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        #expect(!c.startPomodoro(taskID: a, minutes: 0, now: at(0)))
        #expect(!c.startPomodoro(taskID: a, minutes: -5, now: at(0)))
        #expect(c.pomodoro == nil)
    }

    @Test
    func stopPomodoroShowsNoCard() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.startPomodoro(taskID: a, minutes: 25, now: at(0))
        c.stopPomodoro(now: at(60))
        #expect(c.pomodoro == nil)
        c.tick(now: at(3600))
        #expect(c.card == nil)
        #expect(c.pomodoroCountToday == 0)
    }

    @Test
    func focusExpiryPresentsEndCardAndCounts() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        let id = try #require(c.pomodoro?.id)
        let before = h.box.presented
        c.tick(now: at(301))
        #expect(c.card == .pomodoroEnd(pomodoroID: id))
        #expect(h.box.presented == before + 1)
        #expect(c.pomodoro == nil)
        #expect(c.pomodoroCountToday == 1)
        #expect(c.todaySummary.pomodoroCount == 1)
    }

    @Test
    func pauseAfterExpiryHandlesExpiryFirst() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        let id = try #require(c.pomodoro?.id)
        c.pausePomodoro(now: at(400))
        #expect(c.card == .pomodoroEnd(pomodoroID: id))
        #expect(c.pomodoro == nil)
        #expect(c.pomodoroCountToday == 1)
    }

    @Test
    func startBreakSavesNoteAndBreakEndShowsCard() throws {
        let h = try make()
        let c = h.coordinator
        c.settings.pomodoroBreakMinutes = 3
        let a = try task(h, "A")
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        c.tick(now: at(300))
        c.startBreak(nextStep: "  дописать тест  ", now: at(305))
        #expect(c.board.task(id: a)?.note == "дописать тест")
        #expect(c.card == nil)
        let snapshot = try #require(c.pomodoro)
        #expect(snapshot.phase == .break)
        #expect(snapshot.plannedSeconds == 180)
        #expect(snapshot.cycleIndex == 1)
        let breakID = snapshot.id
        c.tick(now: at(485))
        #expect(c.card == .breakEnd(pomodoroID: breakID))
        #expect(c.pomodoroCountToday == 1)
        let summary = try #require(c.breakSummary(pomodoroID: breakID))
        #expect(summary.note == "дописать тест")
        #expect(summary.taskTitle == "A")
    }

    @Test
    func emptyNextStepKeepsNote() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        var stored = try #require(c.board.task(id: a))
        stored.note = "старое"
        c.updateTask(stored)
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        c.tick(now: at(300))
        c.endForToday(nextStep: "   ", now: at(301))
        #expect(c.board.task(id: a)?.note == "старое")
        #expect(c.card == nil)
        #expect(c.pomodoro == nil)
    }

    @Test
    func continueFocusStartsSameLengthWithoutBreak() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.startPomodoro(taskID: a, minutes: 10, now: at(0))
        c.tick(now: at(600))
        c.continueFocus(nextStep: "шаг", now: at(601))
        #expect(c.card == nil)
        #expect(c.pomodoro?.phase == .focus)
        #expect(c.pomodoro?.plannedSeconds == 600)
        #expect(c.pomodoro?.cycleIndex == 2)
        #expect(c.board.task(id: a)?.note == "шаг")
    }

    @Test
    func breakEndActions() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.sessionsDidChange([session("s1", .completed, at: at(0)), session("s2", .waitingForAnswer, at: at(0))], now: at(0))
        c.bind(sessionID: "s1", taskID: a, now: at(0))
        c.bind(sessionID: "s2", taskID: a, now: at(0))
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        c.tick(now: at(300))
        c.startBreak(nextStep: nil, minutes: 5, now: at(300))
        c.tick(now: at(600))
        guard case .breakEnd = c.card else {
            Issue.record("expected breakEnd, got \(String(describing: c.card))")
            return
        }
        c.extendBreak(minutes: 5, now: at(601))
        #expect(c.card == nil)
        #expect(c.pomodoro?.phase == .break)
        #expect(c.pomodoro?.plannedSeconds == 300)
        c.tick(now: at(901))
        guard case .breakEnd = c.card else {
            Issue.record("expected breakEnd after extension")
            return
        }
        c.resumeAfterBreak(now: at(902))
        #expect(c.card == nil)
        #expect(h.box.jumps.last == "s2")
        #expect(c.pomodoro?.phase == .focus)
        #expect(c.pomodoro?.plannedSeconds == c.settings.pomodoroFocusMinutes * 60)
        #expect(c.pomodoro?.taskID == a)
    }

    @Test
    func endBreakWithoutTimerClosesCard() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        c.tick(now: at(300))
        c.startBreak(nextStep: nil, now: at(300))
        c.tick(now: at(600))
        c.endBreakWithoutTimer(now: at(601))
        #expect(c.card == nil)
        #expect(c.pomodoro == nil)
    }

    @Test
    func extendActiveBreakAddsTime() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        c.tick(now: at(300))
        c.startBreak(nextStep: nil, now: at(300))
        c.extendBreak(minutes: 5, now: at(310))
        #expect(c.pomodoro?.plannedSeconds == c.settings.pomodoroBreakMinutes * 60 + 300)
    }

    @Test
    func breakSuppressesNudgeNextActionAndStalled() throws {
        let h = try make()
        let c = h.coordinator
        c.settings.stalledReminderMinutes = 5
        let a = try task(h, "A")
        c.sessionsDidChange([session("s1", .completed, at: at(0)), session("s2", .completed, at: at(0))], now: at(0))
        c.bind(sessionID: "s1", taskID: a, now: at(0))
        c.bind(sessionID: "s2", taskID: a, now: at(0))
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        c.tick(now: at(300))
        c.startBreak(nextStep: nil, minutes: 5, now: at(300))
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Terminal", url: nil, at: at(300)))
        c.sessionsDidChange([
            session("s1", .running, at: at(301), prompt: "q1"),
            session("s2", .running, at: at(301), prompt: "q2"),
            session("wait", .waitingForApproval, at: at(-1200)),
        ], now: at(301))
        c.tick(now: at(320))
        #expect(c.card == nil)
        c.sessionsDidChange([
            session("s1", .completed, at: at(400), prompt: "q1"),
            session("s2", .running, at: at(400), prompt: "q2"),
            session("wait", .waitingForApproval, at: at(-1200)),
        ], now: at(400))
        let url = URL(string: "https://youtube.com")
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Safari", url: url, at: at(402)))
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Safari", url: url, at: at(440)))
        #expect(c.card != .nudge)
        #expect(c.distractionTarget == nil)
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Terminal", url: nil, at: at(450)))
        c.tick(now: at(460))
        if case .nextAction = c.card { Issue.record("nextAction must not show during the break") }
        c.tick(now: at(600))
        guard case .breakEnd = c.card else {
            Issue.record("expected breakEnd, got \(String(describing: c.card))")
            return
        }
        c.endBreakWithoutTimer(now: at(601))
        c.tick(now: at(602))
        c.tick(now: at(640))
        if case .nextAction = c.card {
            Issue.record("nextAction must not fire after the break")
        }
    }

    @Test
    func breakStartEndsOpenDistraction() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.sessionsDidChange([session("run", .running, at: at(0))], now: at(0))
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        let url = URL(string: "https://youtube.com")
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Safari", url: url, at: at(250)))
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Safari", url: url, at: at(280)))
        #expect(c.card == .nudge)
        c.tick(now: at(300))
        c.perform(.dismiss, now: at(300))
        c.tick(now: at(301))
        guard case .pomodoroEnd = c.card else {
            Issue.record("expected pomodoroEnd after nudge, got \(String(describing: c.card))")
            return
        }
        c.startBreak(nextStep: nil, now: at(302))
        #expect(c.distractionTarget == nil)
        let episodes = try DistractionLog(store: h.store).episodes(since: at(0))
        #expect(episodes.count == 1)
    }

    @Test
    func pomodoroSummaryCollectsInterval() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.sessionsDidChange([session("s1", .running, at: at(0)), session("x", .running, at: at(0), cwd: "/tmp/x")], now: at(0))
        c.bind(sessionID: "s1", taskID: a, now: at(0))
        c.startTask(taskID: a, sessionIDs: ["s1"], focusMinutes: 5, now: at(0))
        let id = try #require(c.pomodoro?.id)
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Terminal", url: nil, at: at(0)))
        c.sessionsDidChange([session("s1", .completed, at: at(120)), session("x", .completed, at: at(120), cwd: "/tmp/x")], now: at(120))
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Finder", url: nil, at: at(200)))
        try DistractionLog(store: h.store).save(DistractionEpisode(startedAt: at(210), endedAt: at(240), appBundleID: "com.apple.Safari", domain: "youtube.com", nudged: true, returnedWithinSec: 5))
        c.tick(now: at(300))
        let summary = try #require(c.pomodoroSummary(pomodoroID: id))
        #expect(summary.taskTitle == "A")
        #expect(summary.plannedMinutes == 5)
        #expect(summary.cycleIndex == 1)
        #expect(summary.youInTaskSeconds == 200)
        #expect(summary.claudeSeconds == 120)
        #expect(summary.distractionSeconds == 30)
        #expect(summary.distractionCount == 1)
        #expect(summary.returnedCount == 1)
        #expect(summary.finishedSessionTitles == ["title-s1"])
        #expect(summary.checkedCriteria.isEmpty)
    }

    @Test
    func breakSummaryListsSessionsFinishedDuringBreak() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.sessionsDidChange([session("s1", .running, at: at(0))], now: at(0))
        c.bind(sessionID: "s1", taskID: a, now: at(0))
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        c.tick(now: at(300))
        c.startBreak(nextStep: "дальше", now: at(300))
        let breakID = try #require(c.pomodoro?.id)
        c.sessionsDidChange([session("s1", .completed, at: at(400))], now: at(400))
        c.tick(now: at(600))
        let summary = try #require(c.breakSummary(pomodoroID: breakID))
        #expect(summary.finishedSessionTitles == ["title-s1"])
        #expect(summary.note == "дальше")
    }

    @Test
    func restoreOnStartPresentsRecoveredEndCard() throws {
        let store = try FocusStore.inMemory()
        let taskModel = try BoardService(store: store).createTask(title: "A", column: .inProgress)
        let started = try PomodoroStore(store: store).start(taskID: taskModel.id, phase: .focus, plannedSeconds: 300, now: t0.addingTimeInterval(-1000))
        let h = try make(store: store)
        #expect(h.coordinator.card == .pomodoroEnd(pomodoroID: started.id))
        #expect(h.coordinator.pomodoro == nil)
        #expect(h.coordinator.pomodoroCountToday == 1)
    }

    @Test
    func restoreOnStartKeepsRunningPomodoro() throws {
        let store = try FocusStore.inMemory()
        let taskModel = try BoardService(store: store).createTask(title: "A", column: .inProgress)
        let started = try PomodoroStore(store: store).start(taskID: taskModel.id, phase: .focus, plannedSeconds: 600, now: t0.addingTimeInterval(-100))
        let h = try make(store: store)
        #expect(h.coordinator.card == nil)
        #expect(h.coordinator.pomodoro?.id == started.id)
        #expect(h.coordinator.pomodoro?.remainingSeconds == 500)
    }

    @Test
    func recoveredEndCardWaitsForOnboarding() throws {
        let store = try FocusStore.inMemory()
        let taskModel = try BoardService(store: store).createTask(title: "A", column: .inProgress)
        let started = try PomodoroStore(store: store).start(taskID: taskModel.id, phase: .focus, plannedSeconds: 300, now: t0.addingTimeInterval(-1000))
        let h = try make(start: false, store: store)
        h.coordinator.setHooksInstalled(false, now: t0)
        h.coordinator.start(initialSessions: [], now: t0)
        #expect(h.coordinator.card == .onboarding)
        h.coordinator.dismissOnboarding(now: at(1))
        h.coordinator.tick(now: at(2))
        #expect(h.coordinator.card == .pomodoroEnd(pomodoroID: started.id))
    }

    @Test
    func deleteTaskStopsPomodoroState() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.startPomodoro(taskID: a, minutes: 25, now: at(0))
        c.deleteTask(id: a)
        #expect(c.pomodoro == nil)
        c.tick(now: at(3000))
        #expect(c.card == nil)
    }

    @Test
    func deleteTaskClosesItsEndCard() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        c.tick(now: at(300))
        guard case .pomodoroEnd = c.card else {
            Issue.record("expected pomodoroEnd")
            return
        }
        c.deleteTask(id: a)
        #expect(c.card == nil)
    }

    @Test
    func pickTaskOptionsOrderAndOpen() throws {
        let h = try make()
        let c = h.coordinator
        let first = try task(h, "First", projectPath: "/tmp/none")
        let second = try task(h, "Second", projectPath: "/tmp/proj")
        let doing = try task(h, "Doing", column: .inProgress, projectPath: "/tmp/proj")
        c.sessionsDidChange([session("s1", .running, at: at(0)), session("s2", .completed, at: at(0), cwd: "/tmp/proj/a")], now: at(0))
        c.bind(sessionID: "s1", taskID: doing, now: at(0))
        let options = c.pickTaskOptions(now: at(0))
        #expect(options.todo.map(\.id) == c.board.tasks(in: .todo).map(\.id))
        #expect(Set(options.todo.map(\.id)) == [first, second])
        #expect(options.todo.allSatisfy { $0.liveSessionCount == 0 })
        #expect(options.inProgress.map(\.id) == [doing])
        #expect(options.inProgress.first?.liveSessionCount == 1)
        #expect(c.openPickTask(now: at(1)) == .presented)
        #expect(c.card == .pickTask)
    }

    @Test
    func openPickTaskWithEmptyTodoOpensBoard() throws {
        let h = try make()
        let c = h.coordinator
        var posted: [AnyHashable: Any]?
        let token = NotificationCenter.default.addObserver(forName: .focusOpenBoard, object: nil, queue: nil) { posted = $0.userInfo }
        defer { NotificationCenter.default.removeObserver(token) }
        #expect(c.openPickTask(now: at(0)) == .openedBoard)
        #expect(c.card == nil)
        #expect(posted?["tab"] as? String == "board")
    }

    @Test
    func pickTaskStartFromCardClosesIt() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.openPickTask(now: at(0))
        c.startTask(taskID: a, sessionIDs: [], focusMinutes: 25, now: at(1))
        #expect(c.card == nil)
    }

    @Test
    func overlayCloseKeepsPomodoroEndCard() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        let id = try #require(c.pomodoro?.id)
        c.tick(now: at(300))
        let presented = h.box.presented
        c.overlayDidClose(now: at(301))
        #expect(c.card == .pomodoroEnd(pomodoroID: id))
        c.tick(now: at(302))
        c.tick(now: at(303))
        #expect(h.box.presented == presented)
        #expect(c.card == .pomodoroEnd(pomodoroID: id))
    }

    @Test
    func movingTaskToDoneStopsItsPomodoro() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        let b = try task(h, "B", column: .inProgress)
        c.startPomodoro(taskID: a, minutes: 25, now: at(0))
        c.moveTask(id: b, to: .done, before: nil, now: at(30))
        #expect(c.pomodoro?.taskID == a)
        c.markDone(taskID: a, now: at(60))
        #expect(c.pomodoro == nil)
        #expect(c.pomodoroCount(day: at(0)) == 0)
        c.tick(now: at(25 * 60 + 5))
        #expect(c.card == nil)
    }

    func keptEndCard(_ h: Harness, taskID: String) throws -> String {
        let c = h.coordinator
        c.startPomodoro(taskID: taskID, minutes: 5, now: at(0))
        let id = try #require(c.pomodoro?.id)
        c.tick(now: at(300))
        c.overlayDidClose(now: at(301))
        #expect(c.card == .pomodoroEnd(pomodoroID: id))
        return id
    }

    @Test
    func keptEndCardQueuesReturnedUntilActedOn() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        c.sessionsDidChange([session("s", .running, at: at(0))], now: at(0))
        c.bind(sessionID: "s", taskID: a, now: at(0))
        let id = try keptEndCard(h, taskID: a)
        c.sessionsDidChange([session("s", .completed, at: at(310))], now: at(310))
        #expect(c.card == .pomodoroEnd(pomodoroID: id))
        c.endForToday(nextStep: nil, now: at(320))
        #expect(c.card == .returned(sessionID: "s"))
    }

    @Test
    func keptEndCardQueuesOverloadUntilActedOn() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        let id = try keptEndCard(h, taskID: a)
        let four = (1...4).map { session("s\($0)", .running, at: at(310)) }
        c.sessionsDidChange(four, now: at(310))
        #expect(c.card == .pomodoroEnd(pomodoroID: id))
        c.tick(now: at(311))
        #expect(c.card == .pomodoroEnd(pomodoroID: id))
        c.endForToday(nextStep: nil, now: at(320))
        c.tick(now: at(321))
        #expect(c.card == .overload(newSessionID: "s4"))
    }

    @Test
    func keptEndCardDropsQueuedOverloadOnceResolved() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        _ = try keptEndCard(h, taskID: a)
        let four = (1...4).map { session("s\($0)", .running, at: at(310)) }
        c.sessionsDidChange(four, now: at(310))
        c.sessionsDidChange(Array(four.prefix(2)), now: at(315))
        c.endForToday(nextStep: nil, now: at(320))
        c.tick(now: at(321))
        #expect(c.card == nil)
    }

    @Test
    func keptEndCardQueuesDayStartUntilActedOn() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        let id = try keptEndCard(h, taskID: a)
        c.openDayStart(now: at(310))
        #expect(c.card == .pomodoroEnd(pomodoroID: id))
        c.startBreak(nextStep: nil, now: at(320))
        c.tick(now: at(321))
        #expect(c.card == .dayStart)
        #expect(c.isOnBreak)
    }

    @Test
    func endCardDisplacedByNudgeIsShownAgain() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.sessionsDidChange([session("run", .running, at: at(0))], now: at(0))
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        let id = try #require(c.pomodoro?.id)
        c.tick(now: at(300))
        #expect(c.card == .pomodoroEnd(pomodoroID: id))
        let url = URL(string: "https://youtube.com")
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Safari", url: url, at: at(310)))
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Safari", url: url, at: at(340)))
        #expect(c.card == .nudge)
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Terminal", url: nil, at: at(350)))
        c.tick(now: at(351))
        #expect(c.card == .pomodoroEnd(pomodoroID: id))
    }

    @Test
    func startedTaskSurvivesAgentActivityAndPromptsOfOtherTask() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        let b = try task(h, "B", column: .inProgress)
        c.sessionsDidChange([session("o", .running, at: at(0), prompt: "first")], now: at(0))
        c.bind(sessionID: "o", taskID: b, now: at(0))
        c.startTask(taskID: a, sessionIDs: [], focusMinutes: nil, now: at(10))
        #expect(c.currentTask?.id == a)
        c.sessionsDidChange([session("o", .running, at: at(20), prompt: "first")], now: at(20))
        c.sessionsDidChange([session("o", .waitingForApproval, at: at(30), prompt: "first")], now: at(30))
        c.sessionsDidChange([session("o", .running, at: at(40), prompt: "first")], now: at(40))
        c.sessionsDidChange([session("o", .completed, at: at(50), prompt: "first")], now: at(50))
        #expect(c.currentTask?.id == a)
        c.sessionsDidChange([session("o", .running, at: at(60), prompt: "second")], now: at(60))
        #expect(c.currentTask?.id == a)
    }

    @Test
    func startedTaskOverrideSurvivesJumpAndBindButEndsOnColumnChange() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        let b = try task(h, "B", column: .inProgress)
        c.sessionsDidChange([session("o", .completed, at: at(0)), session("free", .completed, at: at(0))], now: at(0))
        c.bind(sessionID: "o", taskID: b, now: at(0))
        c.startTask(taskID: a, sessionIDs: [], focusMinutes: nil, now: at(10))
        #expect(c.currentTask?.id == a)
        c.requestJump(sessionID: "o", now: at(20))
        #expect(h.box.jumps.last == "o")
        #expect(c.currentTask?.id == a)

        c.bind(sessionID: "free", taskID: b, now: at(40))
        #expect(c.currentTask?.id == a)

        c.startTask(taskID: a, sessionIDs: [], focusMinutes: nil, now: at(50))
        #expect(c.currentTask?.id == a)
        c.moveTask(id: a, to: .todo, before: nil)
        #expect(c.currentTask?.id == b)
    }

    @Test
    func startTaskWithoutTimerEndsOtherTasksPomodoro() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        let b = try task(h, "B")
        c.startPomodoro(taskID: a, minutes: 25, now: at(0))
        #expect(c.currentTask?.id == a)
        c.startTask(taskID: b, sessionIDs: [], focusMinutes: nil, now: at(60))
        #expect(c.currentTask?.id == b)
        #expect(c.pomodoro == nil)
        #expect(c.pomodoroCount(day: at(60)) == 0)
        c.tick(now: at(25 * 60 + 5))
        #expect(c.card == nil)
    }

    @Test
    func startTaskWithTimerReplacesOtherTasksPomodoro() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        let b = try task(h, "B")
        c.startPomodoro(taskID: a, minutes: 25, now: at(0))
        c.startTask(taskID: b, sessionIDs: [], focusMinutes: 50, now: at(60))
        #expect(c.currentTask?.id == b)
        #expect(c.pomodoro?.taskID == b)
        #expect(c.pomodoro?.plannedSeconds == 50 * 60)
        #expect(c.pomodoroCount(day: at(60)) == 0)
    }

    @Test
    func startTaskWithoutTimerEndsOtherTasksBreak() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        let b = try task(h, "B")
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        c.tick(now: at(300))
        c.startBreak(nextStep: nil, now: at(301))
        #expect(c.isOnBreak)
        c.startTask(taskID: b, sessionIDs: [], focusMinutes: nil, now: at(320))
        #expect(!c.isOnBreak)
        #expect(c.currentTask?.id == b)
    }

    @Test
    func startTaskWithoutTimerKeepsSameTasksPomodoro() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        c.startPomodoro(taskID: a, minutes: 25, now: at(0))
        let id = try #require(c.pomodoro?.id)
        c.startTask(taskID: a, sessionIDs: [], focusMinutes: nil, now: at(60))
        #expect(c.pomodoro?.id == id)
        #expect(c.currentTask?.id == a)
    }

    @Test
    func pomodoroTaskWinsOverNewerActivity() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        let b = try task(h, "B", column: .inProgress)
        c.sessionsDidChange([session("o", .completed, at: at(0))], now: at(0))
        c.bind(sessionID: "o", taskID: b, now: at(0))
        c.startPomodoro(taskID: a, minutes: 25, now: at(10))
        c.sessionsDidChange([session("o", .running, at: at(20), prompt: "new")], now: at(20))
        #expect(c.currentTask?.id == a)
    }

    @Test
    func restoreSkipsStaleEndCards() throws {
        let store = try FocusStore.inMemory()
        let taskModel = try BoardService(store: store).createTask(title: "A", column: .inProgress)
        try PomodoroStore(store: store).start(taskID: taskModel.id, phase: .focus, plannedSeconds: 300, now: t0.addingTimeInterval(-3 * 3600))
        let h = try make(store: store)
        #expect(h.coordinator.card == nil)
        #expect(h.coordinator.pomodoroCountToday == 1)
    }

    @Test
    func restoreSkipsEndCardFromYesterday() throws {
        let store = try FocusStore.inMemory()
        let taskModel = try BoardService(store: store).createTask(title: "A", column: .inProgress)
        let late = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 0, minute: 30))!
        try PomodoroStore(store: store).start(taskID: taskModel.id, phase: .focus, plannedSeconds: 3600, now: late.addingTimeInterval(-3600 * 2))
        let defaults = UserDefaults(suiteName: "focus-pomodoro-\(UUID().uuidString)")!
        let c = FocusCoordinator(store: store, defaults: defaults, launcher: RecordingLauncher(), gitDiff: StubGitDiff(files: []), clipboard: { _ in }, runBackfill: false)
        c.settings.dayStartEnabled = false
        c.start(initialSessions: [], now: late)
        #expect(c.card == nil)
    }

    @Test
    func openPickTaskBlockedByHigherCard() throws {
        let h = try make()
        let c = h.coordinator
        _ = try task(h, "A")
        c.setHooksInstalled(false, now: at(0))
        #expect(c.card == .onboarding)
        #expect(c.openPickTask(now: at(1)) == .blocked)
        #expect(c.card == .onboarding)
    }

    @Test
    func nextFocusMinutesMatchesContinueFocus() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.startPomodoro(taskID: a, minutes: 50, now: at(0))
        let id = try #require(c.pomodoro?.id)
        c.tick(now: at(3000))
        let summary = try #require(c.pomodoroSummary(pomodoroID: id))
        #expect(summary.plannedMinutes == 50)
        #expect(summary.nextFocusMinutes == 50)
        c.continueFocus(nextStep: nil, now: at(3001))
        #expect(c.pomodoro?.plannedSeconds == summary.nextFocusMinutes * 60)
    }

    @Test
    func summaryListsCriteriaCheckedDuringPomodoro() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.perform(.addCriterion(taskID: a, text: "до"), now: at(-100))
        c.perform(.addCriterion(taskID: a, text: "во время"), now: at(-100))
        c.perform(.addCriterion(taskID: a, text: "снято"), now: at(-100))
        let ids = c.criteria(taskID: a).map(\.id)
        c.perform(.toggleCriterion(id: ids[0]), now: at(-50))
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        let id = try #require(c.pomodoro?.id)
        c.perform(.toggleCriterion(id: ids[1]), now: at(100))
        c.perform(.toggleCriterion(id: ids[2]), now: at(110))
        c.perform(.toggleCriterion(id: ids[2]), now: at(120))
        c.tick(now: at(300))
        #expect(c.pomodoroSummary(pomodoroID: id)?.checkedCriteria == ["во время"])
    }

    @Test
    func saveNextStepDraftKeepsEndCard() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        let id = try #require(c.pomodoro?.id)
        c.tick(now: at(301))
        c.saveNextStepDraft("  черновик ", pomodoroID: id, now: at(310))
        #expect(c.board.task(id: a)?.note == "черновик")
        #expect(c.card == .pomodoroEnd(pomodoroID: id))
        c.saveNextStepDraft("  ", pomodoroID: id, now: at(311))
        #expect(c.board.task(id: a)?.note == "черновик")
        c.saveNextStepDraft("x", pomodoroID: "missing", now: at(312))
        #expect(c.board.task(id: a)?.note == "черновик")
    }

    @Test
    func closePickTaskOnlyClosesPickTaskCard() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        #expect(c.openPickTask(now: at(0)) == .presented)
        #expect(c.card == .pickTask)
        c.closePickTask(now: at(1))
        #expect(c.card == nil)
        c.startPomodoro(taskID: a, minutes: 5, now: at(2))
        let id = try #require(c.pomodoro?.id)
        c.tick(now: at(303))
        c.closePickTask(now: at(304))
        #expect(c.card == .pomodoroEnd(pomodoroID: id))
    }

    @Test
    func pomodoroCountIsDayScoped() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        c.tick(now: at(301))
        #expect(c.pomodoroCount(day: at(0)) == 1)
        #expect(c.pomodoroCount(day: at(-86_400)) == 0)
    }

    @Test
    func breakAndNextFocusLengthsCanBeChosenOnEndCard() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        c.tick(now: at(5 * 60 + 1))
        c.startBreak(nextStep: nil, minutes: 15, now: at(5 * 60 + 2))
        #expect(c.pomodoro?.phase == .break)
        #expect(c.pomodoro?.plannedSeconds == 15 * 60)
        c.tick(now: at(20 * 60 + 3))
        c.resumeAfterBreak(minutes: 90, now: at(20 * 60 + 4))
        #expect(c.pomodoro?.phase == .focus)
        #expect(c.pomodoro?.plannedSeconds == 90 * 60)
        c.tick(now: at(110 * 60 + 5))
        c.continueFocus(nextStep: nil, minutes: 25, now: at(110 * 60 + 6))
        #expect(c.pomodoro?.plannedSeconds == 25 * 60)
    }

    @Test
    func breakLengthIsClamped() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        c.tick(now: at(5 * 60 + 1))
        c.startBreak(nextStep: nil, minutes: 99, now: at(5 * 60 + 2))
        #expect(c.pomodoro?.plannedSeconds == FocusSettings.pomodoroBreakRange.upperBound * 60)
    }
}
