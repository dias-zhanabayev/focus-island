import FocusCore
import Foundation
import OpenIslandCore
import Testing
@testable import OpenIslandApp

@MainActor
struct FocusFirstTaskTests {
    let t0 = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 9))!

    func make() throws -> FocusCoordinator {
        let store = try FocusStore.inMemory()
        let defaults = UserDefaults(suiteName: "focus-first-task-\(UUID().uuidString)")!
        let coordinator = FocusCoordinator(store: store, defaults: defaults, launcher: RecordingLauncher(), promptSender: RecordingPromptSender(result: .unsupported), gitDiff: StubGitDiff(files: []), clipboard: { _ in }, runBackfill: false)
        coordinator.settings.autoBindNewSessions = false
        coordinator.settings.dayStartEnabled = false
        coordinator.start(initialSessions: [], now: t0)
        return coordinator
    }

    func session(_ id: String, _ phase: SessionPhase, at date: Date, cwd: String = "/tmp/api", prompt: String = "p") -> AgentSession {
        var session = AgentSession(
            id: id, title: id, tool: .claudeCode, origin: .live, attachmentState: .attached, phase: phase, summary: "", updatedAt: date, firstSeenAt: date,
            jumpTarget: JumpTarget(terminalApp: "Ghostty", workspaceName: "api", paneTitle: "", workingDirectory: cwd),
            claudeMetadata: ClaudeSessionMetadata(initialUserPrompt: prompt, lastUserPrompt: prompt, startupSource: .startup)
        )
        session.isHookManaged = true
        return session
    }

    func candidate(_ id: String, cwd: String?) -> FirstTaskCandidate {
        FirstTaskCandidate(id: id, title: id, cwd: cwd, appName: nil, group: .running)
    }

    @Test
    func titleComesFromLabelThenPromptThenProject() {
        #expect(FocusCoordinator.firstTaskTitle(label: " Тесты на токен ", prompt: "x", projectName: "api") == "Тесты на токен")
        #expect(FocusCoordinator.firstTaskTitle(label: nil, prompt: "перепиши   middleware\nподробности", projectName: "api") == "перепиши middleware")
        let long = String(repeating: "а", count: 80)
        #expect(FocusCoordinator.firstTaskTitle(label: nil, prompt: long, projectName: nil) == String(repeating: "а", count: 60) + "…")
        #expect(FocusCoordinator.firstTaskTitle(label: "", prompt: "  ", projectName: "api") == "api")
        #expect(FocusCoordinator.firstTaskTitle(label: nil, prompt: nil, projectName: nil) == "Сессия Claude")
    }

    @Test
    func preselectionTakesSessionsFromTheAnchorFolder() {
        let candidates = [candidate("a", cwd: "/tmp/api"), candidate("b", cwd: "/tmp/billing"), candidate("c", cwd: "/tmp/api"), candidate("d", cwd: nil)]
        #expect(FocusCoordinator.firstTaskPreselection(candidates: candidates, anchorID: nil) == ["a", "c"])
        #expect(FocusCoordinator.firstTaskPreselection(candidates: candidates, anchorID: "b") == ["b"])
        #expect(FocusCoordinator.firstTaskPreselection(candidates: candidates, anchorID: "d") == ["d"])
        #expect(FocusCoordinator.firstTaskPreselection(candidates: [], anchorID: nil).isEmpty)
    }

    @Test
    func candidatesAreUnboundLiveSessionsFreshestFirst() throws {
        let c = try make()
        c.sessionsDidChange([
            session("old", .completed, at: t0, prompt: "старый промпт"),
            session("new", .running, at: t0.addingTimeInterval(60), prompt: "новый промпт"),
            session("bound", .running, at: t0.addingTimeInterval(30)),
        ], now: t0.addingTimeInterval(60))
        c.createTask(title: "Другая", column: .todo, projectPath: nil)
        let other = try #require(c.board.tasks.first?.id)
        c.bind(sessionID: "bound", taskID: other)
        let candidates = c.firstTaskCandidates()
        #expect(candidates.map(\.id) == ["new", "old"])
        #expect(candidates.first?.title == "новый промпт")
        #expect(candidates.first?.cwd == "/tmp/api")
        #expect(candidates.first?.appName == "Ghostty")
    }

    @Test
    func startFirstTaskPutsItInProgressWithSessionsAndCriterion() throws {
        let c = try make()
        c.sessionsDidChange([session("a", .running, at: t0), session("b", .completed, at: t0)], now: t0)
        let taskID = try #require(c.startFirstTask(title: "  Перевести auth  ", sessionIDs: ["a", "b"], criterion: "старые токены не принимаются", now: t0))
        let task = try #require(c.board.task(id: taskID))
        #expect(task.title == "Перевести auth")
        #expect(task.boardColumn == .inProgress)
        #expect(task.projectPath == "/tmp/api")
        #expect(c.currentTask?.id == taskID)
        #expect(c.taskID(forSession: "a") == taskID)
        #expect(c.taskID(forSession: "b") == taskID)
        #expect(c.criteria(taskID: taskID).map(\.text) == ["старые токены не принимаются"])
        #expect(c.onboardingTaskAdded)
        #expect(c.firstTaskWaitingID == nil)
        #expect(c.startFirstTask(title: "   ", sessionIDs: [], criterion: nil, now: t0) == nil)
    }

    @Test
    func firstNewSessionJoinsTheWaitingTaskByItself() throws {
        let c = try make()
        let taskID = try #require(c.startFirstTask(title: "Перевести auth", sessionIDs: [], criterion: " ", now: t0))
        #expect(c.firstTaskWaitingID == taskID)
        #expect(c.criteria(taskID: taskID).isEmpty)
        #expect(c.board.task(id: taskID)?.projectPath == nil)

        let first = session("first", .running, at: t0.addingTimeInterval(10), cwd: "/tmp/new-api")
        c.sessionsDidChange([first], now: t0.addingTimeInterval(10))
        #expect(c.taskID(forSession: "first") == taskID)
        #expect(c.pendingBindingSessionIDs.isEmpty)
        #expect(c.firstTaskWaitingID == nil)
        #expect(c.board.task(id: taskID)?.projectPath == "/tmp/new-api")
        #expect(c.boundSessionNotice?.sessionID == "first")

        let second = session("second", .running, at: t0.addingTimeInterval(20))
        c.sessionsDidChange([first, second], now: t0.addingTimeInterval(20))
        #expect(c.taskID(forSession: "second") == nil)
        #expect(c.pendingBindingSessionIDs == ["second"])

        c.unbindAutoBoundSession()
        #expect(c.taskID(forSession: "first") == nil)
        #expect(c.boundSessionNotice == nil)
    }

    @Test
    func newSessionsJoinTheFocusedTaskWhenAutoBindIsOn() throws {
        let c = try make()
        #expect(FocusSettings().autoBindNewSessions)
        c.settings.autoBindNewSessions = true
        c.createTask(title: "Фокус", column: .inProgress, projectPath: nil)
        let taskID = try #require(c.board.tasks.first?.id)
        c.startTask(taskID: taskID, sessionIDs: [], focusMinutes: nil, now: t0)

        let first = session("first", .running, at: t0.addingTimeInterval(10), cwd: "/tmp/new-api")
        c.sessionsDidChange([first], now: t0.addingTimeInterval(10))
        let second = session("second", .running, at: t0.addingTimeInterval(20))
        c.sessionsDidChange([first, second], now: t0.addingTimeInterval(20))

        #expect(c.taskID(forSession: "first") == taskID)
        #expect(c.taskID(forSession: "second") == taskID)
        #expect(c.pendingBindingSessionIDs.isEmpty)
        #expect(c.boundSessionNotice?.sessionID == "second")
        #expect(c.board.task(id: taskID)?.projectPath == "/tmp/new-api")

        c.unbindAutoBoundSession()
        #expect(c.taskID(forSession: "second") == nil)
    }

    @Test
    func newSessionWithoutTaskJustJoinsTheList() throws {
        let c = try make()
        c.settings.autoBindNewSessions = true
        c.sessionsDidChange([session("s", .running, at: t0, cwd: "/tmp/proj")], now: t0)
        #expect(c.currentTask == nil)
        #expect(c.board.tasks.isEmpty)
        #expect(c.taskID(forSession: "s") == nil)
        #expect(c.pendingBindingSessionIDs.isEmpty)
        #expect(c.hubRows.map(\.id) == ["s"])
    }

    @Test
    func newSessionWithoutTaskAsksWhenAutoBindIsOff() throws {
        let c = try make()
        c.sessionsDidChange([session("s", .running, at: t0)], now: t0)
        #expect(c.taskID(forSession: "s") == nil)
        #expect(c.currentTask == nil)
        #expect(c.pendingBindingSessionIDs == ["s"])
        #expect(c.newSessionIDs == ["s"])
        #expect(c.listRows.isEmpty)
    }

    @Test
    func addingNewSessionPutsItIntoTheList() throws {
        let c = try make()
        c.sessionsDidChange([session("s", .running, at: t0)], now: t0)
        c.addNewSessions(["s"], now: t0)
        #expect(c.newSessionIDs.isEmpty)
        #expect(c.listRows.map(\.id) == ["s"])
        #expect(c.hiddenRows.isEmpty)
    }

    @Test
    func addingNewSessionWithTaskInFocusJoinsTheTask() throws {
        let c = try make()
        _ = c.startFirstTask(title: "Задача", sessionIDs: [], criterion: nil, now: t0)
        let first = session("first", .running, at: t0.addingTimeInterval(2))
        c.sessionsDidChange([first], now: t0.addingTimeInterval(2))
        c.sessionsDidChange([first, session("s", .running, at: t0.addingTimeInterval(5))], now: t0.addingTimeInterval(5))
        #expect(c.newSessionIDs == ["s"])
        c.addNewSessions(["s"], now: t0.addingTimeInterval(6))
        #expect(c.taskID(forSession: "s") == c.currentTask?.id)
    }

    @Test
    func skippedNewSessionGoesToHidden() throws {
        let c = try make()
        c.sessionsDidChange([session("s", .running, at: t0)], now: t0)
        c.skipBinding(sessionID: "s", now: t0)
        #expect(c.listRows.isEmpty)
        #expect(c.hiddenRows.map(\.id) == ["s"])
        c.restoreHiddenSession(sessionID: "s", now: t0)
        #expect(c.listRows.map(\.id) == ["s"])
    }

    @Test
    func clearingListHidesOpenSessionsButNotWaitingOnes() throws {
        let c = try make()
        c.settings.autoBindNewSessions = true
        c.sessionsDidChange([session("a", .running, at: t0), session("b", .waitingForApproval, at: t0)], now: t0)
        #expect(c.sessionListChoiceCount == 2)
        c.clearSessionList(now: t0)
        #expect(c.sessionListChoiceCount == 0)
        #expect(c.listRows.map(\.id) == ["b"])
        #expect(c.hiddenRows.map(\.id) == ["a"])
        c.sessionsDidChange([session("a", .waitingForAnswer, at: t0.addingTimeInterval(5)), session("b", .waitingForApproval, at: t0)], now: t0.addingTimeInterval(5))
        #expect(Set(c.listRows.map(\.id)) == ["a", "b"])
    }

    @Test
    func keepingAllSessionsAsksOnlyOnce() throws {
        let c = try make()
        c.settings.autoBindNewSessions = true
        c.sessionsDidChange([session("a", .running, at: t0)], now: t0)
        #expect(c.sessionListChoiceCount == 1)
        c.keepAllSessionsInList()
        #expect(c.sessionListChoiceCount == 0)
        #expect(c.listRows.map(\.id) == ["a"])
    }

    @Test
    func boundNoticeExpires() throws {
        let c = try make()
        _ = c.startFirstTask(title: "Задача", sessionIDs: [], criterion: nil, now: t0)
        c.sessionsDidChange([session("first", .running, at: t0.addingTimeInterval(10))], now: t0.addingTimeInterval(10))
        #expect(c.boundSessionNotice != nil)
        c.tick(now: t0.addingTimeInterval(10 + FocusCoordinator.closedTaskLifetime))
        #expect(c.boundSessionNotice == nil)
    }
}
