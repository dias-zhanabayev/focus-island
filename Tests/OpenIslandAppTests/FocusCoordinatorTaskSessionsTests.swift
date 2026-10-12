import FocusCore
import Foundation
import OpenIslandCore
import Testing
@testable import OpenIslandApp

@MainActor
struct FocusCoordinatorTaskSessionsTests {
    let t0 = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 9))!

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
        let defaults = UserDefaults(suiteName: "focus-task-sessions-\(UUID().uuidString)")!
        let coordinator = FocusCoordinator(store: store, defaults: defaults, launcher: RecordingLauncher(), promptSender: RecordingPromptSender(result: .unsupported), gitDiff: StubGitDiff(files: []), clipboard: { _ in }, runBackfill: false)
        coordinator.settings.dayStartEnabled = false
        let box = Box()
        coordinator.jumpToSession = { box.jumps.append($0) }
        coordinator.presentCard = { box.presented += 1 }
        coordinator.start(initialSessions: [], now: t0)
        return Harness(coordinator: coordinator, box: box)
    }

    func session(_ id: String, _ phase: SessionPhase, at date: Date, cwd: String = "/tmp/proj") -> AgentSession {
        var session = AgentSession(
            id: id, title: "title-\(id)", tool: .claudeCode, origin: .live, attachmentState: .attached, phase: phase, summary: "", updatedAt: date, firstSeenAt: date.addingTimeInterval(-3600),
            jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "proj", paneTitle: "", workingDirectory: cwd),
            claudeMetadata: ClaudeSessionMetadata(initialUserPrompt: "p", lastUserPrompt: "p", startupSource: .startup)
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
    func choicesListBoundFirstThenSameProjectThenOthers() throws {
        let h = try make()
        let c = h.coordinator
        let target = try task(h, "Target", column: .inProgress)
        let other = try task(h, "Other", column: .inProgress, projectPath: "/tmp/other")
        c.sessionsDidChange([
            session("far", .running, at: at(5), cwd: "/tmp/other"),
            session("own", .running, at: at(4)),
            session("taken", .running, at: at(3)),
            session("mine", .running, at: at(2)),
        ], now: at(5))
        c.bind(sessionID: "taken", taskID: other, now: at(6))
        c.bind(sessionID: "mine", taskID: target, now: at(6))
        let choices = c.taskSessionChoices(forTaskID: target)
        #expect(choices.map(\.id) == ["mine", "own", "taken", "far"])
        #expect(choices.map(\.isBound) == [true, false, false, false])
        #expect(choices.map(\.isSameProject) == [true, true, true, false])
        #expect(FocusCoordinator.defaultTaskSessionSelection(choices) == ["mine", "own"])
    }

    @Test
    func sessionChangesSplitAdditionsAndRemovals() {
        let choices = [
            BindableSession(id: "b1", title: "", detail: "", projectName: nil, boundTaskTitle: nil, isSameProject: true, defaultSelected: true, isBound: true),
            BindableSession(id: "b2", title: "", detail: "", projectName: nil, boundTaskTitle: nil, isSameProject: true, defaultSelected: true, isBound: true),
            BindableSession(id: "n1", title: "", detail: "", projectName: nil, boundTaskTitle: nil, isSameProject: true, defaultSelected: true),
            BindableSession(id: "n2", title: "", detail: "", projectName: nil, boundTaskTitle: nil, isSameProject: false, defaultSelected: false),
        ]
        let changes = FocusCoordinator.taskSessionChanges(choices, selected: ["b1", "n2", "n1", "gone"])
        #expect(changes.add == ["n1", "n2"])
        #expect(changes.remove == ["b2"])
    }

    @Test
    func applyBindsAndUnbindsWithoutJumpingAndClosesCard() throws {
        let h = try make()
        let c = h.coordinator
        let target = try task(h, "Target", column: .inProgress)
        let other = try task(h, "Other", column: .inProgress)
        c.sessionsDidChange([
            session("keep", .completed, at: at(0)),
            session("drop", .completed, at: at(0)),
            session("add", .running, at: at(0)),
            session("steal", .running, at: at(0)),
        ], now: at(0))
        c.bind(sessionID: "keep", taskID: target, now: at(1))
        c.bind(sessionID: "drop", taskID: target, now: at(1))
        c.bind(sessionID: "steal", taskID: other, now: at(1))
        c.takeTask(taskID: target, now: at(2))
        #expect(c.openTaskSessions(taskID: target, now: at(3)))
        #expect(c.card == .bindToTask(taskID: target))
        c.applyTaskSessions(taskID: target, selected: ["keep", "add", "steal"], now: at(4))
        #expect(c.taskID(forSession: "keep") == target)
        #expect(c.taskID(forSession: "add") == target)
        #expect(c.taskID(forSession: "steal") == target)
        #expect(c.taskID(forSession: "drop") == nil)
        #expect(c.card == nil)
        #expect(h.box.jumps.isEmpty)
        #expect(c.currentTask?.id == target)
        #expect(Set(c.focusTaskSessions.map(\.id)) == ["keep", "add", "steal"])
    }

    @Test
    func takeTaskWithoutSessionsOpensSessionsScreenAndApplyReturnsToHub() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.sessionsDidChange([session("free", .completed, at: at(0))], now: at(0))
        #expect(c.takeTask(taskID: a, now: at(1)) == .needsBinding)
        #expect(c.card == .bindToTask(taskID: a))
        c.applyTaskSessions(taskID: a, selected: ["free"], now: at(2))
        #expect(c.card == nil)
        #expect(h.box.jumps.isEmpty)
        #expect(c.focusTaskSessions.map(\.id) == ["free"])
    }

    @Test
    func openTaskSessionsIsBlockedByPomodoroCard() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        c.takeTask(taskID: a, now: at(0))
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        c.tick(now: at(5 * 60 + 1))
        #expect(c.card?.pomodoroID != nil)
        #expect(!c.openTaskSessions(taskID: a, now: at(5 * 60 + 2)))
        #expect(c.card?.pomodoroID != nil)
    }

    @Test
    func unbindKeepsExplicitFocus() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        c.sessionsDidChange([session("s", .completed, at: at(0))], now: at(0))
        c.bind(sessionID: "s", taskID: a, now: at(1))
        c.takeTask(taskID: a, now: at(2))
        c.bind(sessionID: "s", taskID: nil, now: at(3))
        #expect(c.taskID(forSession: "s") == nil)
        #expect(c.currentTask?.id == a)
        #expect(c.focusTaskSessions.isEmpty)
        #expect(c.pendingBindingSessionIDs.isEmpty)
    }

    @Test
    func closeTaskMovesToDoneClearsFocusKeepsSessionsAndShowsPicker() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        let b = try task(h, "B", column: .inProgress)
        c.sessionsDidChange([session("s", .completed, at: at(0))], now: at(0))
        c.bind(sessionID: "s", taskID: a, now: at(1))
        c.takeTask(taskID: a, now: at(2))
        c.startPomodoro(taskID: a, minutes: 25, now: at(3))
        c.closeTask(taskID: a, showPicker: true, now: at(10))
        #expect(c.board.task(id: a)?.boardColumn == .done)
        #expect(c.taskID(forSession: "s") == a)
        #expect(c.pomodoro == nil)
        #expect(c.focusTaskOverrideID == nil)
        #expect(c.currentTask == nil)
        #expect(c.focusTaskSessions.isEmpty)
        #expect(c.closedTask == ClosedTaskNotice(taskID: a, title: "A"))
        #expect(c.card == .pickTask)
        _ = b
    }

    @Test
    func closedFocusStaysEmptyUntilExplicitChoice() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        let b = try task(h, "B", column: .inProgress)
        c.sessionsDidChange([session("sb", .running, at: at(0))], now: at(0))
        c.bind(sessionID: "sb", taskID: b, now: at(0))
        c.takeTask(taskID: a, now: at(1))
        c.closeTask(taskID: a, showPicker: false, now: at(2))
        #expect(c.currentTask == nil)
        c.sessionsDidChange([session("sb", .running, at: at(30))], now: at(30))
        #expect(c.currentTask == nil)
        c.takeTask(taskID: b, now: at(40))
        #expect(c.currentTask?.id == b)
    }

    @Test
    func closingUnfocusedTaskKeepsFocus() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        let b = try task(h, "B", column: .inProgress)
        c.takeTask(taskID: a, now: at(0))
        c.closeTask(taskID: b, showPicker: false, now: at(1))
        #expect(c.currentTask?.id == a)
        c.reopenClosedTask(now: at(2))
        #expect(c.board.task(id: b)?.boardColumn == .inProgress)
        #expect(c.currentTask?.id == a)
    }

    @Test
    func pickingAnotherTaskDropsCloseUndo() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        let b = try task(h, "B", column: .inProgress)
        c.takeTask(taskID: a, now: at(0))
        c.closeTask(taskID: a, showPicker: true, now: at(1))
        c.takeTask(taskID: b, now: at(2))
        #expect(c.closedTask == nil)
        c.reopenClosedTask(now: at(3))
        #expect(c.board.task(id: a)?.boardColumn == .done)
        #expect(c.currentTask?.id == b)
    }

    @Test
    func closeTaskWithExpiredPomodoroLeavesNoEndCard() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        _ = try task(h, "B", column: .inProgress)
        c.takeTask(taskID: a, now: at(0))
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        c.closeTask(taskID: a, showPicker: false, now: at(5 * 60 + 1))
        c.tick(now: at(5 * 60 + 2))
        #expect(c.pomodoro == nil)
        #expect(c.card?.pomodoroID == nil)
    }

    @Test
    func closeTaskFromBoardClosesItsPomodoroEndCard() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        c.takeTask(taskID: a, now: at(0))
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        c.tick(now: at(5 * 60 + 1))
        #expect(c.card?.pomodoroID != nil)
        c.closeTask(taskID: a, showPicker: false, now: at(5 * 60 + 2))
        #expect(c.card == nil)
    }

    @Test
    func closeTaskFromBoardDoesNotOpenPicker() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        _ = try task(h, "B", column: .inProgress)
        c.closeTask(taskID: a, showPicker: false, now: at(0))
        #expect(c.board.task(id: a)?.boardColumn == .done)
        #expect(c.card == nil)
        #expect(c.closedTask?.taskID == a)
    }

    @Test
    func closeLastTaskDoesNotOpenBoard() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        c.closeTask(taskID: a, showPicker: true, now: at(0))
        #expect(c.card == nil)
        #expect(c.closedTask?.taskID == a)
    }

    @Test
    func reopenClosedTaskReturnsToInProgressAndFocus() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        _ = try task(h, "B", column: .inProgress)
        c.takeTask(taskID: a, now: at(0))
        c.closeTask(taskID: a, showPicker: true, now: at(1))
        c.reopenClosedTask(now: at(2))
        #expect(c.board.task(id: a)?.boardColumn == .inProgress)
        #expect(c.board.tasks(in: .inProgress).first?.id == a)
        #expect(c.currentTask?.id == a)
        #expect(c.closedTask == nil)
        #expect(c.card == nil)
    }

    @Test
    func closedTaskNoticeExpires() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A", column: .inProgress)
        c.closeTask(taskID: a, showPicker: false, now: at(0))
        c.tick(now: at(FocusCoordinator.closedTaskLifetime - 1))
        #expect(c.closedTask != nil)
        c.tick(now: at(FocusCoordinator.closedTaskLifetime))
        #expect(c.closedTask == nil)
    }

    @Test
    func closeTaskClosesItsSessionsCard() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.takeTask(taskID: a, now: at(0))
        #expect(c.card == .bindToTask(taskID: a))
        c.closeTask(taskID: a, showPicker: false, now: at(1))
        #expect(c.card == nil)
    }
}
