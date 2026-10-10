import Foundation
import Testing
import OpenIslandCore
@testable import FocusCore

struct SessionHubTests {
    let t0 = Date(timeIntervalSince1970: 100_000)

    func now(_ minutes: Int) -> Date { t0.addingTimeInterval(TimeInterval(minutes * 60)) }

    func session(_ id: String, _ phase: SessionPhase, updatedMinutes: Int = 0, cwd: String? = "/tmp/proj", prompt: String? = nil, tasks: [ClaudeTaskInfo] = [], origin: SessionOrigin = .live) -> AgentSession {
        var session = AgentSession(
            id: id, title: id, tool: .claudeCode, origin: origin, attachmentState: .attached, phase: phase, summary: "",
            updatedAt: now(updatedMinutes),
            jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "w", paneTitle: "", workingDirectory: cwd),
            claudeMetadata: ClaudeSessionMetadata(initialUserPrompt: prompt, activeTasks: tasks)
        )
        session.isHookManaged = true
        return session
    }

    func record(_ id: String, taskId: String? = nil, parked: Bool = false, projectName: String? = "proj") -> SessionRecord {
        SessionRecord(id: id, cwd: "/tmp/proj", projectName: projectName, title: id, firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, startedAt: t0, lastActivityAt: t0, endedAt: nil, status: .live, taskId: taskId, transcriptPath: nil, parkedAt: parked ? t0 : nil)
    }

    func task(_ id: String, _ title: String = "Задача") -> FocusTask {
        FocusTask(id: id, title: title, details: nil, boardColumn: .inProgress, position: 1, projectPath: nil, note: nil, createdAt: t0, updatedAt: t0, doneAt: nil)
    }

    func rows(_ sessions: [AgentSession], records: [SessionRecord] = [], tasks: [FocusTask] = [], unseen: Set<String> = [], at minutes: Int = 0) -> [HubRow] {
        SessionHub.rows(sessions: sessions, records: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }), board: BoardSnapshot(tasks: tasks), unseenCompleted: unseen, now: now(minutes))
    }

    @Test
    func progressIsNilForEmptyPlan() {
        #expect(PlanProgress.from([]) == nil)
    }

    @Test
    func progressCountsAndPrefersActiveForm() throws {
        let progress = try #require(PlanProgress.from([
            ClaudeTaskInfo(id: "1", title: "A", status: .completed),
            ClaudeTaskInfo(id: "2", title: "Правит B", status: .inProgress, activeForm: "правит хендлеры"),
            ClaudeTaskInfo(id: "3", title: "C", status: .pending),
            ClaudeTaskInfo(id: "4", title: "D", status: .pending),
        ]))
        #expect(progress.completed == 1)
        #expect(progress.total == 4)
        #expect(progress.currentTitle == "правит хендлеры")
        #expect(progress.fraction == 0.25)
    }

    @Test
    func progressFallsBackToTitleAndHasNoCurrentWhenNoneInProgress() throws {
        let titled = try #require(PlanProgress.from([ClaudeTaskInfo(id: "1", title: "A", status: .inProgress)]))
        #expect(titled.currentTitle == "A")
        let none = try #require(PlanProgress.from([ClaudeTaskInfo(id: "1", title: "A", status: .pending)]))
        #expect(none.currentTitle == nil)
    }

    @Test
    func remainingEstimate() {
        let none = PlanProgress(completed: 0, total: 4, currentTitle: nil)
        #expect(none.remaining(planStartedAt: t0, now: now(10)) == nil)
        let some = PlanProgress(completed: 2, total: 5, currentTitle: nil)
        #expect(some.remaining(planStartedAt: t0, now: now(10)) == 900)
    }

    @Test
    func groupsAndSortOrder() {
        let sessions = [
            session("run", .running, updatedMinutes: -5),
            session("wait-new", .waitingForApproval, updatedMinutes: -2),
            session("wait-old", .waitingForAnswer, updatedMinutes: -9),
            session("done", .completed, updatedMinutes: -12),
            session("idle", .completed, updatedMinutes: -40),
            session("park", .running, updatedMinutes: -1),
        ]
        let result = rows(sessions, records: [record("park", parked: true)], unseen: ["done"])
        #expect(result.map(\.id) == ["wait-old", "wait-new", "done", "run", "idle", "park"])
        #expect(result.map(\.group) == [.waiting, .waiting, .review, .running, .unbound, .parked])
    }

    @Test
    func seenCompletedBoundGoesToIdle() {
        let sessions = [session("seen", .completed, updatedMinutes: -5), session("bound", .completed, updatedMinutes: -90)]
        let result = rows(sessions, records: [record("bound", taskId: "t1")], tasks: [task("t1")])
        #expect(Set(result.map(\.id)) == ["seen", "bound"])
        #expect(result.allSatisfy { $0.group == .idle })
        #expect(result.first { $0.id == "seen" }?.detail == "Claude закончил 5 мин назад · твой ход")
    }

    @Test
    func idleSitsBetweenRunningAndUnbound() {
        let sessions = [session("u", .completed, updatedMinutes: -40), session("i", .completed, updatedMinutes: -10, ), session("r", .running)]
        let result = rows(sessions, records: [record("i", taskId: "t1")], tasks: [task("t1")])
        #expect(result.map(\.group) == [.running, .idle, .unbound])
    }

    @Test
    func promptWhitespaceIsCollapsed() {
        let result = rows([session("a", .running, prompt: "  fix\n\n  the   bug\tnow ")], records: [record("a")])
        #expect(result.first?.title == "proj · «fix the bug now»")
    }

    @Test
    func emptyProjectNameFallsBack() {
        let withCwd = rows([session("a", .running, cwd: "/nonexistent/zzz/scratch")], records: [record("a", projectName: "")])
        #expect(withCwd.first?.projectName == "scratch")
        var orphan = record("b", projectName: "")
        orphan.cwd = nil
        let none = rows([session("b", .running, cwd: nil, prompt: "hi")], records: [orphan])
        #expect(none.first?.title == "без проекта · «hi»")
    }

    @Test
    func unboundBoundaryIsThirtyMinutes() {
        let result = rows([session("a", .completed, updatedMinutes: -29), session("b", .completed, updatedMinutes: -30)])
        let byID = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
        #expect(byID["a"]?.group == .idle)
        #expect(byID["b"]?.group == .unbound)
        #expect(byID["b"]?.detail == "Нет активности 30 мин")
    }

    @Test
    func runningSessionIsNeverUnbound() {
        let result = rows([session("a", .running, updatedMinutes: -200)])
        #expect(result.first?.group == .running)
    }

    @Test
    func syntheticDemoEndedAndInvisibleAreExcluded() {
        var ended = session("ended", .running)
        ended.isSessionEnded = true
        let sessions = [session("claude-process:1", .running), session("demo", .running, origin: .demo), ended, session("ok", .running)]
        #expect(rows(sessions).map(\.id) == ["ok"])
    }

    @Test
    func titleForBoundTaskAndUnbound() {
        let bound = rows([session("a", .running)], records: [record("a", taskId: "t1")], tasks: [task("t1", "Рефакторинг auth")])
        #expect(bound.first?.title == "Рефакторинг auth")
        #expect(bound.first?.taskID == "t1")
        let long = String(repeating: "я", count: 60)
        let unbound = rows([session("b", .running, prompt: long)], records: [record("b")])
        #expect(unbound.first?.title == "proj · «\(String(repeating: "я", count: 40))»")
        let noPrompt = rows([session("c", .running)], records: [record("c")])
        #expect(noPrompt.first?.title == "proj")
        let noProject = rows([session("d", .running, cwd: nil, prompt: "hi")])
        #expect(noProject.first?.title == "без проекта · «hi»")
    }

    @Test
    func projectNameFallsBackToCwdLastComponent() {
        let result = rows([session("a", .running, cwd: "/nonexistent/zzz/scratch")])
        #expect(result.first?.projectName == "scratch")
    }

    @Test
    func detailStrings() {
        var approval = session("a", .waitingForApproval, updatedMinutes: -3)
        approval.permissionRequest = PermissionRequest(title: "t", summary: "Bash(npm test)", affectedPath: "")
        var question = session("q", .waitingForAnswer, updatedMinutes: -7)
        question.questionPrompt = QuestionPrompt(title: "Какой вариант?", options: [])
        let plan = [
            ClaudeTaskInfo(id: "1", title: "A", status: .completed),
            ClaudeTaskInfo(id: "2", title: "B", status: .inProgress, activeForm: "обновляет хендлеры"),
            ClaudeTaskInfo(id: "3", title: "C", status: .pending),
        ]
        let sessions = [approval, question, session("d", .completed, updatedMinutes: -12), session("r", .running, updatedMinutes: -4, tasks: plan), session("p", .running, updatedMinutes: -2), session("x", .running, updatedMinutes: -1)]
        let byID = Dictionary(uniqueKeysWithValues: rows(sessions, records: [record("x", parked: true)], unseen: ["d"]).map { ($0.id, $0) })
        #expect(byID["a"]?.detail == "Разрешение Bash(npm test) · ждёт 3 мин")
        #expect(byID["q"]?.detail == "Какой вариант? · ждёт 7 мин")
        #expect(byID["d"]?.detail == "Claude закончил 12 мин назад")
        #expect(byID["r"]?.detail == "Шаг 2 из 3 · обновляет хендлеры · 4 мин")
        #expect(byID["r"]?.progress?.total == 3)
        #expect(byID["p"]?.detail == "Работает · 2 мин")
        #expect(byID["a"]?.since == now(-3))
    }

    @Test
    func futureUpdatedAtClampsToZeroMinutes() {
        let result = rows([session("a", .completed, updatedMinutes: 5)], unseen: ["a"])
        #expect(result.first?.detail == "Claude закончил 0 мин назад")
    }
}
