import FocusCore
import Foundation
import OpenIslandCore
import Testing
@testable import OpenIslandApp

@MainActor
struct FocusCoordinatorSessionDoneTests {
    let t0 = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 11))!

    func make() throws -> FocusCoordinator {
        let store = try FocusStore.inMemory()
        let defaults = UserDefaults(suiteName: "focus-done-\(UUID().uuidString)")!
        let c = FocusCoordinator(store: store, defaults: defaults, launcher: RecordingLauncher(), promptSender: RecordingPromptSender(result: .unsupported), gitDiff: StubGitDiff(files: []), clipboard: { _ in }, runBackfill: false)
        c.settings.dayStartEnabled = false
        c.settings.nextActionEnabled = false
        c.presentCard = {}
        c.start(initialSessions: [], now: t0)
        return c
    }

    func session(_ id: String, _ phase: SessionPhase, prompt: String = "p") -> AgentSession {
        var session = AgentSession(
            id: id, title: "title-\(id)", tool: .claudeCode, origin: .live, attachmentState: .attached, phase: phase, summary: "", updatedAt: t0, firstSeenAt: t0,
            jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "proj", paneTitle: "", workingDirectory: "/tmp/proj"),
            claudeMetadata: ClaudeSessionMetadata(initialUserPrompt: "p", lastUserPrompt: prompt, startupSource: .startup)
        )
        session.isHookManaged = true
        return session
    }

    func setUp() throws -> (FocusCoordinator, String) {
        let c = try make()
        c.createTask(title: "A", column: .inProgress, projectPath: "/tmp/proj")
        let a = try #require(c.board.tasks.first { $0.title == "A" }?.id)
        c.sessionsDidChange([session("s1", .completed), session("s2", .running)], now: t0)
        c.bind(sessionID: "s1", taskID: a, now: t0)
        c.bind(sessionID: "s2", taskID: a, now: t0)
        c.takeTask(taskID: a, now: t0)
        return (c, a)
    }

    @Test
    func doneSessionLeavesActiveListAndShowsNotice() throws {
        let (c, _) = try setUp()
        c.markSessionDone(sessionID: "s1", now: t0.addingTimeInterval(1))
        #expect(c.focusTaskSessions.map(\.id) == ["s2"])
        #expect(c.focusTaskDoneSessions.map(\.id) == ["s1"])
        #expect(c.doneSessionNotice?.sessionID == "s1")
        c.tick(now: t0.addingTimeInterval(1 + FocusCoordinator.closedTaskLifetime))
        #expect(c.doneSessionNotice == nil)
        #expect(c.focusTaskDoneSessions.map(\.id) == ["s1"])
    }

    @Test
    func reopenReturnsSessionAndNewPromptAlsoReturnsIt() throws {
        let (c, _) = try setUp()
        c.markSessionDone(sessionID: "s1", now: t0)
        c.reopenDoneSession(sessionID: "s1", now: t0.addingTimeInterval(1))
        #expect(c.doneSessionNotice == nil)
        #expect(Set(c.focusTaskSessions.map(\.id)) == ["s1", "s2"])
        c.markSessionDone(sessionID: "s1", now: t0.addingTimeInterval(2))
        c.sessionsDidChange([session("s1", .running, prompt: "продолжим"), session("s2", .running)], now: t0.addingTimeInterval(3))
        #expect(Set(c.focusTaskSessions.map(\.id)) == ["s1", "s2"])
    }

    @Test
    func allDoneSuggestsClosingUntilDismissed() throws {
        let (c, a) = try setUp()
        c.markSessionDone(sessionID: "s1", now: t0)
        #expect(!c.showsAllDoneSuggestion(taskID: a))
        c.markSessionDone(sessionID: "s2", now: t0)
        #expect(c.showsAllDoneSuggestion(taskID: a))
        c.dismissAllDoneSuggestion(taskID: a)
        #expect(!c.showsAllDoneSuggestion(taskID: a))
        #expect(FocusCoordinator.allDone(doneCount: 3, activeCount: 0, dismissedAt: 2))
        #expect(!FocusCoordinator.allDone(doneCount: 0, activeCount: 0, dismissedAt: nil))
    }

    @Test
    func moveTargetsExcludeCurrentTask() throws {
        let (c, a) = try setUp()
        c.createTask(title: "B", column: .todo, projectPath: nil)
        #expect(c.moveTargets(excludingTaskID: a).map(\.title) == ["B"])
    }

    @Test
    func doneCheckForActiveTaskSessions() {
        #expect(SessionDoneFormat.showsDoneCheck(group: .idle))
        #expect(SessionDoneFormat.showsDoneCheck(group: .review))
        #expect(SessionDoneFormat.showsDoneCheck(group: .running))
        #expect(SessionDoneFormat.showsDoneCheck(group: .waiting))
        #expect(!SessionDoneFormat.showsDoneCheck(group: .unbound))
        #expect(!SessionDoneFormat.showsDoneCheck(group: .parked))
        #expect(!SessionDoneFormat.showsDoneCheck(group: .done))
        #expect(SessionDoneFormat.confirmsDone(group: .running))
        #expect(SessionDoneFormat.confirmsDone(group: .waiting))
        #expect(!SessionDoneFormat.confirmsDone(group: .idle))
        #expect(SessionDoneFormat.sectionTitle(count: 2, expanded: false) == "Завершённые · 2 ▸")
        #expect(SessionDoneFormat.noticeText("Онбординг") == "«Онбординг» завершена")
        #expect(TaskDetailView.doneDetail(record: SessionRecord(id: "x", cwd: nil, projectName: nil, title: "x", firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, startedAt: t0, lastActivityAt: t0, endedAt: nil, status: .live, taskId: nil, transcriptPath: nil, doneAt: t0.addingTimeInterval(70 * 60))) == "1 ч 10 мин")
    }

    @Test
    func statusBadgeSaysWhatClaudeIsDoing() {
        #expect(SessionStatusKind.of(.running)?.title == "Работает")
        #expect(SessionStatusKind.of(.waiting)?.title == "Ждёт ответа")
        #expect(SessionStatusKind.of(.idle)?.title == "Твой ход")
        #expect(SessionStatusKind.of(.review)?.title == "Твой ход")
        #expect(SessionStatusKind.of(.done)?.title == "Завершена")
        #expect(SessionStatusKind.of(.parked)?.title == "На паузе")
        #expect(SessionStatusKind.of(.unbound) == nil)
        #expect(HubGroup.done.title == "Завершённые")
        #expect(FocusEars.yourTurnText(2) == "2 твой ход")
    }
}
