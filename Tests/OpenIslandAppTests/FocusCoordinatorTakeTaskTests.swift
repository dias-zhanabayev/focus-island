import FocusCore
import Foundation
import OpenIslandCore
import Testing
@testable import OpenIslandApp

@MainActor
struct FocusCoordinatorTakeTaskTests {
    let t0 = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 9))!

    final class Box {
        var jumps: [String] = []
        var presented = 0
    }

    struct Harness {
        let coordinator: FocusCoordinator
        let box: Box
    }

    func make() throws -> Harness {
        let store = try FocusStore.inMemory()
        let defaults = UserDefaults(suiteName: "focus-take-\(UUID().uuidString)")!
        let coordinator = FocusCoordinator(store: store, defaults: defaults, launcher: RecordingLauncher(), promptSender: RecordingPromptSender(result: .unsupported), gitDiff: StubGitDiff(files: []), clipboard: { _ in }, runBackfill: false)
        coordinator.settings.dayStartEnabled = false
        let box = Box()
        coordinator.jumpToSession = { box.jumps.append($0) }
        coordinator.presentCard = { box.presented += 1 }
        coordinator.start(initialSessions: [], now: t0)
        return Harness(coordinator: coordinator, box: box)
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
    func pickTaskOptionsSplitInProgressAndTodoInBoardOrder() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        let b = try task(h, "B", column: .inProgress, projectPath: "/tmp/other")
        let todo1 = try task(h, "T1")
        let todo2 = try task(h, "T2")
        c.sessionsDidChange([
            session("s1", .completed, at: at(0)),
            session("s2", .running, at: at(60))
        ], now: at(60))
        c.bind(sessionID: "s1", taskID: a, now: at(60))
        c.bind(sessionID: "s2", taskID: a, now: at(60))
        let options = c.pickTaskOptions(now: at(83 * 60))
        #expect(options.inProgress.map(\.taskID) == c.board.tasks(in: .inProgress).map(\.id))
        #expect(Set(options.inProgress.map(\.taskID)) == [a, b])
        #expect(options.todo.map(\.taskID) == c.board.tasks(in: .todo).map(\.id))
        #expect(Set(options.todo.map(\.taskID)) == [todo1, todo2])
        let optionA = try #require(options.inProgress.first { $0.taskID == a })
        #expect(optionA.title == "A")
        #expect(optionA.projectName == "proj")
        #expect(optionA.liveSessionCount == 2)
        #expect(optionA.hasLiveSessions)
        #expect(optionA.sessionStateText == "2 сессии · твой ход 83 мин")
        #expect(optionA.id == a)
        let optionB = try #require(options.inProgress.first { $0.taskID == b })
        #expect(optionB.liveSessionCount == 0)
        #expect(!optionB.hasLiveSessions)
        #expect(optionB.sessionStateText == "нет сессий — добавишь следующим шагом")
    }

    @Test
    func pickTaskStateTextPrefersWaitingThenYourTurnThenRunning() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        let b = try task(h, "B", column: .inProgress)
        let d = try task(h, "D", column: .inProgress)
        c.sessionsDidChange([
            session("run", .running, at: at(0)),
            session("wait", .waitingForApproval, at: at(120)),
            session("idle", .completed, at: at(60)),
            session("run2", .running, at: at(0)),
            session("idle2", .completed, at: at(180)),
            session("run3", .running, at: at(240))
        ], now: at(240))
        for id in ["run", "wait", "idle"] { c.bind(sessionID: id, taskID: a, now: at(240)) }
        for id in ["run2", "idle2"] { c.bind(sessionID: id, taskID: b, now: at(240)) }
        c.bind(sessionID: "run3", taskID: d, now: at(240))
        let options = c.pickTaskOptions(now: at(600))
        #expect(options.inProgress.first { $0.taskID == a }?.sessionStateText == "3 сессии · ждёт 8 мин")
        #expect(options.inProgress.first { $0.taskID == b }?.sessionStateText == "2 сессии · твой ход 7 мин")
        #expect(options.inProgress.first { $0.taskID == d }?.sessionStateText == "1 сессия · работает 6 мин")
    }

    @Test
    func takeTaskWithSessionsFocusesAndClosesPickTask() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        let b = try task(h, "B", column: .inProgress)
        c.sessionsDidChange([session("s1", .completed, at: at(0)), session("o", .running, at: at(10))], now: at(10))
        c.bind(sessionID: "s1", taskID: a, now: at(10))
        c.bind(sessionID: "o", taskID: b, now: at(10))
        #expect(c.openPickTask(now: at(20)) == .presented)
        #expect(c.takeTask(taskID: a, now: at(30)) == .focused)
        #expect(c.card == nil)
        #expect(c.currentTask?.id == a)
        #expect(c.focusTaskOverrideID == a)
        #expect(c.pomodoro == nil)
        #expect(c.pendingStartTaskID == nil)
    }

    @Test
    func takeTaskFromTodoWithoutSessionsNeedsBinding() throws {
        let h = try make()
        let c = h.coordinator
        _ = try task(h, "Doing", column: .inProgress)
        let a = try task(h, "A")
        c.sessionsDidChange([session("free", .completed, at: at(0))], now: at(0))
        c.openPickTask(now: at(10))
        #expect(c.takeTask(taskID: a, now: at(20)) == .needsBinding)
        #expect(c.board.task(id: a)?.boardColumn == .inProgress)
        #expect(c.board.tasks(in: .inProgress).first?.id == a)
        #expect(c.currentTask?.id == a)
        #expect(c.card == .bindToTask(taskID: a))
        #expect(FocusCard.bindToTask(taskID: a).priority == FocusCard.pickTask.priority)
        #expect(h.box.jumps.isEmpty)
    }

    @Test
    func takeTaskUnknownReturnsNil() throws {
        let h = try make()
        #expect(h.coordinator.takeTask(taskID: "missing", now: at(0)) == nil)
        #expect(h.coordinator.card == nil)
    }

    @Test
    func takeTaskEndsOtherTasksPomodoro() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        let b = try task(h, "B", column: .inProgress)
        c.startPomodoro(taskID: b, minutes: 25, now: at(0))
        c.takeTask(taskID: a, now: at(60))
        #expect(c.pomodoro == nil)
        #expect(c.currentTask?.id == a)
    }

    @Test
    func takeTaskKeepsSameTasksPomodoro() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        c.startPomodoro(taskID: a, minutes: 25, now: at(0))
        c.takeTask(taskID: a, now: at(60))
        #expect(c.pomodoro?.taskID == a)
    }

    @Test
    func focusTaskSessionsOtherRowsAndHere() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        let b = try task(h, "B", column: .inProgress)
        c.sessionsDidChange([
            session("a1", .running, at: at(0)),
            session("a2", .completed, at: at(0)),
            session("b1", .completed, at: at(0)),
            session("free", .running, at: at(0))
        ], now: at(0))
        c.bind(sessionID: "a1", taskID: a, now: at(0))
        c.bind(sessionID: "a2", taskID: a, now: at(0))
        c.bind(sessionID: "b1", taskID: b, now: at(0))
        c.takeTask(taskID: a, now: at(10))
        #expect(Set(c.focusTaskSessions.map(\.id)) == ["a1", "a2"])
        #expect(c.hereSessionID == nil)
        c.requestJump(sessionID: "a2", now: at(20))
        #expect(c.hereSessionID == "a2")
        c.requestJump(sessionID: "free", now: at(30))
        #expect(c.hereSessionID == nil)
        c.requestJump(sessionID: "a1", now: at(40))
        #expect(c.hereSessionID == "a1")
        c.sessionsDidChange([
            session("a2", .completed, at: at(0)),
            session("b1", .completed, at: at(0)),
            session("free", .running, at: at(0))
        ], now: at(50))
        #expect(c.hereSessionID == nil)
    }

    @Test
    func noFocusTaskMeansNoFocusSessions() throws {
        let h = try make()
        let c = h.coordinator
        c.sessionsDidChange([session("free", .running, at: at(0))], now: at(0))
        #expect(c.currentTask == nil)
        #expect(c.focusTaskSessions.isEmpty)
        #expect(c.hubRows.map(\.id) == ["free"])
    }

    @Test
    func explicitFocusSurvivesJumpPromptAndBindOfOtherTask() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        let b = try task(h, "B", column: .inProgress)
        c.sessionsDidChange([session("o", .completed, at: at(0), prompt: "first"), session("free", .completed, at: at(0))], now: at(0))
        c.bind(sessionID: "o", taskID: b, now: at(0))
        c.takeTask(taskID: a, now: at(10))
        #expect(c.currentTask?.id == a)
        c.requestJump(sessionID: "o", now: at(20))
        #expect(h.box.jumps.last == "o")
        #expect(c.currentTask?.id == a)
        c.sessionsDidChange([session("o", .running, at: at(30), prompt: "second"), session("free", .completed, at: at(0))], now: at(30))
        #expect(c.currentTask?.id == a)
        c.bind(sessionID: "free", taskID: b, now: at(40))
        #expect(c.currentTask?.id == a)
        c.takeTask(taskID: b, now: at(50))
        #expect(c.currentTask?.id == b)
    }

    @Test
    func explicitFocusEndsWhenTaskLeavesInProgress() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        let b = try task(h, "B", column: .inProgress)
        c.sessionsDidChange([session("o", .running, at: at(0))], now: at(0))
        c.bind(sessionID: "o", taskID: b, now: at(0))
        c.takeTask(taskID: a, now: at(10))
        #expect(c.currentTask?.id == a)
        c.moveTask(id: a, to: .todo, before: nil, now: at(20))
        #expect(c.focusTaskOverrideID == nil)
        #expect(c.currentTask?.id == b)
        c.moveTask(id: a, to: .inProgress, before: nil, now: at(30))
        #expect(c.currentTask?.id == b)
        c.takeTask(taskID: a, now: at(40))
        c.markDone(taskID: a, now: at(50))
        #expect(c.focusTaskOverrideID == nil)
        #expect(c.currentTask?.id == b)
    }

    @Test
    func jumpToOtherTaskStillShowsReEntryButKeepsFocus() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        let b = try task(h, "B", column: .inProgress)
        c.sessionsDidChange([session("o", .completed, at: at(0))], now: at(0))
        c.bind(sessionID: "o", taskID: b, now: at(0))
        c.takeTask(taskID: a, now: at(10))
        c.requestJump(sessionID: "o", now: at(1200))
        #expect(c.card == .reEntry(sessionID: "o"))
        c.perform(.confirmJump(sessionID: "o"), now: at(1210))
        #expect(h.box.jumps == ["o"])
        #expect(c.currentTask?.id == a)
    }

    @Test
    func afterLaunchOfferThereIsNoAutomaticFocus() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        let b = try task(h, "B", column: .inProgress)
        c.sessionsDidChange([session("sa", .running, at: at(0)), session("sb", .completed, at: at(0))], now: at(0))
        c.bind(sessionID: "sa", taskID: a, now: at(0))
        c.bind(sessionID: "sb", taskID: b, now: at(0))
        #expect(c.currentTask != nil)
        c.offerTaskChoiceOnLaunch(now: at(5))
        #expect(c.card == nil)
        c.sessionsDidChange([session("sa", .completed, at: at(10)), session("sb", .running, at: at(20), prompt: "new")], now: at(20))
        #expect(c.focusTaskOverrideID == nil)
        #expect(c.currentTask == nil)
        #expect(c.focusTaskSessions.isEmpty)
        c.takeTask(taskID: a, now: at(30))
        #expect(c.currentTask?.id == a)
    }

    @Test
    func launchOffersTaskChoiceWhenTasksExist() throws {
        let h = try make()
        let c = h.coordinator
        _ = try task(h, "A", column: .inProgress)
        c.offerTaskChoiceOnLaunch(now: at(0))
        #expect(c.card == nil)
        #expect(c.currentTask == nil)
    }

    @Test
    func launchDoesNotOfferChoiceWithoutTasksOrWithRunningPomodoro() throws {
        let h = try make()
        let c = h.coordinator
        c.offerTaskChoiceOnLaunch(now: at(0))
        #expect(c.card == nil)
        let a = try task(h, "A", column: .inProgress)
        c.startPomodoro(taskID: a, minutes: 50, now: at(1))
        c.offerTaskChoiceOnLaunch(now: at(2))
        #expect(c.card == nil)
        #expect(c.currentTask?.id == a)
    }

    @Test
    func openPickTaskPresentsWithOnlyInProgressTasks() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        c.takeTask(taskID: a, now: at(0))
        #expect(c.openPickTask(now: at(10)) == .presented)
        #expect(c.card == .pickTask)
    }

    @Test
    func deleteTaskClosesItsBindCard() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.takeTask(taskID: a, now: at(0))
        #expect(c.card == .bindToTask(taskID: a))
        c.deleteTask(id: a, now: at(10))
        #expect(c.card == nil)
        #expect(c.focusTaskOverrideID == nil)
    }

    @Test
    func bindRefreshesHubRowsImmediately() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        c.sessionsDidChange([session("s1", .completed, at: at(0))], now: at(0))
        c.bind(sessionID: "s1", taskID: a, now: at(1))
        #expect(c.hubRows.first { $0.id == "s1" }?.taskID == a)
    }

    @Test
    func updateTaskLeavingInProgressClearsFocusOverride() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        c.takeTask(taskID: a, now: at(10))
        #expect(c.focusTaskOverrideID == a)
        var edited = try #require(c.board.task(id: a))
        edited.boardColumn = .todo
        c.updateTask(edited)
        #expect(c.focusTaskOverrideID == nil)
    }

    @Test
    func updateTaskKeepingInProgressKeepsFocusOverride() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        c.takeTask(taskID: a, now: at(10))
        var edited = try #require(c.board.task(id: a))
        edited.title = "A2"
        c.updateTask(edited)
        #expect(c.focusTaskOverrideID == a)
    }

    @Test
    func applyTaskSessionsKeepsSessionsCardOfAnotherTask() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        let b = try task(h, "B")
        c.takeTask(taskID: a, now: at(10))
        #expect(c.card?.bindTaskID == a)
        c.applyTaskSessions(taskID: b, selected: [], now: at(20))
        #expect(c.card?.bindTaskID == a)
    }
}
