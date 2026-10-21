import FocusCore
import Foundation
import OpenIslandCore
import Testing
@testable import OpenIslandApp

final class RecordingLauncher: TerminalLaunching, @unchecked Sendable {
    var commands: [String] = []
    func run(command: String, in terminal: ResumeTerminal) throws {
        commands.append(command)
    }
}

final class ThrowingLauncher: TerminalLaunching, @unchecked Sendable {
    let error: Error

    init(error: Error) {
        self.error = error
    }

    func run(command: String, in terminal: ResumeTerminal) throws {
        throw error
    }
}

struct AppleScriptTerminalLauncherTests {
    @Test
    func terminalScriptQuotesCommand() {
        let script = AppleScriptTerminalLauncher.script(for: .terminal, command: "cd '/tmp/a \"b\"' && claude")
        #expect(script == "tell application \"Terminal\"\nactivate\ndo script \"cd '/tmp/a \\\"b\\\"' && claude\"\nend tell")
    }

    @Test
    func iTermScriptWritesTextIntoNewWindow() {
        let script = AppleScriptTerminalLauncher.script(for: .iTerm, command: "claude")
        #expect(script == "tell application \"iTerm\"\nactivate\nset newWindow to (create window with default profile)\ntell current session of newWindow to write text \"claude\"\nend tell")
    }

    @Test
    func ghosttyHasNoAppleScript() {
        #expect(AppleScriptTerminalLauncher.script(for: .ghostty, command: "claude") == nil)
    }
}

@MainActor
struct FocusCoordinatorTests {
    let t0 = Date(timeIntervalSince1970: 70_000)

    @Test
    func settingsChangeInvokesHookOnce() throws {
        let (coordinator, _, _) = try makeCoordinator()
        var received: [BoardHotKey] = []
        coordinator.onSettingsChanged = { received.append($0.boardHotKey) }
        coordinator.settings.boardHotKey = .controlOptionB
        #expect(received == [.controlOptionB])
    }

    @Test
    func startNewSessionForTaskUsesProjectPathOrHome() throws {
        let (coordinator, store, launcher) = try makeCoordinator()
        let service = BoardService(store: store)
        let withProject = try service.createTask(title: "A", column: .todo, projectPath: "/tmp/proj")
        let withoutProject = try service.createTask(title: "B", column: .todo)
        coordinator.start(initialSessions: [], now: t0)
        coordinator.startNewSession(forTaskID: withProject.id)
        coordinator.startNewSession(forTaskID: withoutProject.id)
        coordinator.startNewSession(forTaskID: "missing")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(launcher.commands == [ResumeCommand.newSession(cwd: "/tmp/proj"), ResumeCommand.newSession(cwd: home)])
    }

    @Test
    func deleteTaskRemovesItFromBoard() throws {
        let (coordinator, store, _) = try makeCoordinator()
        let task = try BoardService(store: store).createTask(title: "A", column: .todo)
        coordinator.start(initialSessions: [], now: t0)
        #expect(coordinator.board.task(id: task.id) != nil)
        coordinator.deleteTask(id: task.id)
        #expect(coordinator.board.task(id: task.id) == nil)
    }

    @Test
    func deleteTaskKeepsSessionsSpansPromptsAndDropsCriteria() throws {
        let (coordinator, store, _) = try makeCoordinator()
        let task = try BoardService(store: store).createTask(title: "A", column: .todo)
        let record = SessionRecord(id: "s1", cwd: nil, projectName: nil, title: "s1", firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, startedAt: t0, lastActivityAt: t0, endedAt: t0, status: .ended, taskId: task.id, transcriptPath: nil)
        try store.dbQueue.write { db in try record.insert(db) }
        let log = ActivityLog(store: store)
        let spanID = try log.open(kind: .claude, sessionID: "s1", taskID: task.id, at: t0)
        try log.close(id: spanID, at: t0.addingTimeInterval(60))
        try PromptQueue(store: store).enqueue(sessionID: "s1", taskID: task.id, text: "дальше", now: t0)
        try TaskCriteriaService(store: store).add(taskID: task.id, text: "c", now: t0)
        coordinator.start(initialSessions: [], now: t0)
        coordinator.deleteTask(id: task.id)
        #expect(try SessionHistory(store: store).session(id: "s1")?.taskId == nil)
        let spans = try log.spans(from: t0.addingTimeInterval(-10), to: t0.addingTimeInterval(120))
        #expect(spans.count == 1)
        #expect(spans.first?.taskId == nil)
        #expect(try PromptQueue(store: store).pending(sessionID: "s1")?.taskId == nil)
        #expect(try PromptQueue(store: store).pending(sessionID: "s1")?.text == "дальше")
        #expect(try TaskCriteriaService(store: store).criteria(taskID: task.id).isEmpty)
    }

    @Test
    func taskAggregateTracksCriteriaPromptAndSessions() throws {
        let (coordinator, store, _) = try makeCoordinator()
        let task = try BoardService(store: store).createTask(title: "A", column: .inProgress)
        coordinator.start(initialSessions: [], now: t0)
        let record = SessionRecord(id: "s1", cwd: nil, projectName: nil, title: "s1", firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, startedAt: t0, lastActivityAt: t0, endedAt: nil, status: .live, taskId: task.id, transcriptPath: nil)
        try store.dbQueue.write { db in try record.insert(db) }
        #expect(coordinator.aggregate(taskID: task.id).criteria == nil)
        coordinator.perform(.addCriterion(taskID: task.id, text: "x"), now: t0)
        #expect(coordinator.aggregate(taskID: task.id).records.map(\.id) == ["s1"])
        #expect(coordinator.aggregate(taskID: task.id).criteria == CriteriaProgress(done: 0, total: 1))
        #expect(!coordinator.aggregate(taskID: task.id).sessionIDsWithQueuedPrompt.contains("s1"))
        coordinator.perform(.queuePrompt(sessionID: "s1", text: "дальше"), now: t0)
        #expect(coordinator.aggregate(taskID: task.id).sessionIDsWithQueuedPrompt.contains("s1"))
        coordinator.deleteTask(id: task.id)
        #expect(coordinator.aggregate(taskID: task.id).records.isEmpty)
    }

    func makeCoordinator() throws -> (FocusCoordinator, FocusStore, RecordingLauncher) {
        let store = try FocusStore.inMemory()
        let launcher = RecordingLauncher()
        let defaults = UserDefaults(suiteName: "focus-coord-\(UUID().uuidString)")!
        let coordinator = FocusCoordinator(store: store, defaults: defaults, launcher: launcher, gitDiff: StubGitDiff(files: []), clipboard: { _ in }, runBackfill: false)
        return (coordinator, store, launcher)
    }

    func session(_ id: String, _ phase: SessionPhase, at date: Date, firstSeen: Date? = nil, prompt: String? = "p", cwd: String = "/tmp/proj", source: ClaudeSessionStartSource = .startup) -> AgentSession {
        var session = AgentSession(
            id: id, title: id, tool: .claudeCode, origin: .live, attachmentState: .attached, phase: phase, summary: "", updatedAt: date, firstSeenAt: firstSeen ?? date,
            jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "proj", paneTitle: "", workingDirectory: cwd),
            claudeMetadata: ClaudeSessionMetadata(initialUserPrompt: prompt, lastUserPrompt: prompt, startupSource: source)
        )
        session.isHookManaged = true
        return session
    }

    @Test
    func newSessionIsRecordedAndAsksForBinding() throws {
        let (coordinator, store, _) = try makeCoordinator()
        coordinator.start(initialSessions: [], now: t0)
        coordinator.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        #expect(coordinator.pendingBindingSessionIDs == ["s1"])
        #expect(try SessionHistory(store: store).session(id: "s1")?.status == .live)
    }

    @Test
    func restoredSessionDoesNotAskForBinding() throws {
        let (coordinator, _, _) = try makeCoordinator()
        let restored = session("old", .completed, at: t0, firstSeen: t0.addingTimeInterval(-3600))
        coordinator.start(initialSessions: [restored], now: t0)
        coordinator.sessionsDidChange([restored], now: t0)
        #expect(coordinator.pendingBindingSessionIDs.isEmpty)
    }

    @Test
    func resumedSessionDoesNotAskForBinding() throws {
        let (coordinator, _, _) = try makeCoordinator()
        coordinator.start(initialSessions: [], now: t0)
        coordinator.sessionsDidChange([session("s1", .running, at: t0, source: .resume)], now: t0)
        #expect(coordinator.pendingBindingSessionIDs.isEmpty)
    }

    @Test
    func reconcilesStaleLiveRecordsOnStart() throws {
        let (coordinator, store, _) = try makeCoordinator()
        let history = SessionHistory(store: store)
        try history.record(SessionObservation(session: session("ghost", .running, at: t0.addingTimeInterval(-100))))
        try history.record(SessionObservation(session: session("alive", .running, at: t0.addingTimeInterval(-100))))
        coordinator.start(initialSessions: [session("alive", .running, at: t0)], now: t0)
        #expect(try history.session(id: "ghost")?.status == .ended)
        #expect(try history.session(id: "alive")?.status == .live)
    }

    @Test
    func identicalObservationsAreNotRewritten() throws {
        let (coordinator, store, _) = try makeCoordinator()
        coordinator.start(initialSessions: [], now: t0)
        let s = session("s1", .running, at: t0)
        coordinator.sessionsDidChange([s], now: t0)
        try store.dbQueue.write { db in try db.execute(sql: "UPDATE sessions SET title = 'sentinel'") }
        coordinator.sessionsDidChange([s], now: t0.addingTimeInterval(1))
        #expect(try SessionHistory(store: store).session(id: "s1")?.title == "sentinel")
    }

    @Test
    func removedSessionIsMarkedEnded() throws {
        let (coordinator, store, _) = try makeCoordinator()
        coordinator.start(initialSessions: [], now: t0)
        coordinator.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        coordinator.sessionsDidChange([], now: t0.addingTimeInterval(5))
        #expect(try SessionHistory(store: store).session(id: "s1")?.status == .ended)
    }

    @Test
    func tickPresentsNextActionAfterDelay() throws {
        let (coordinator, _, _) = try makeCoordinator()
        var presented = 0
        coordinator.presentCard = { presented += 1 }
        coordinator.start(initialSessions: [], now: t0)
        coordinator.createTask(title: "Следующее", column: .todo, projectPath: "/tmp/next")
        coordinator.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        coordinator.tick(now: t0.addingTimeInterval(10))
        #expect(coordinator.card == nil)
        coordinator.tick(now: t0.addingTimeInterval(15))
        guard case let .nextAction(triggering, eventID) = coordinator.card else {
            Issue.record("expected nextAction card, got \(String(describing: coordinator.card))")
            return
        }
        #expect(triggering == "s1")
        #expect(eventID != nil)
        guard case let .startTask(taskID, sameProject) = coordinator.alternatives.first else {
            Issue.record("expected startTask alternative, got \(coordinator.alternatives)")
            return
        }
        #expect(!sameProject)
        #expect(coordinator.board.task(id: taskID)?.title == "Следующее")
        #expect(presented == 1)
    }

    @Test
    func startTaskMovesToInProgressAndLaunchesInProjectPath() throws {
        let (coordinator, _, launcher) = try makeCoordinator()
        coordinator.start(initialSessions: [], now: t0)
        coordinator.createTask(title: "Следующее", column: .todo, projectPath: "/tmp/next")
        let taskID = try #require(coordinator.board.tasks(in: .todo).first?.id)
        coordinator.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        coordinator.tick(now: t0.addingTimeInterval(15))
        coordinator.perform(.startTask(taskID: taskID), now: t0.addingTimeInterval(20))
        #expect(coordinator.board.task(id: taskID)?.boardColumn == .inProgress)
        #expect(launcher.commands == ["cd '/tmp/next' && claude"])
        #expect(coordinator.card == nil)
    }

    @Test
    func startTaskLaunchFailureClosesCardWithoutReaction() throws {
        let store = try FocusStore.inMemory()
        let defaults = UserDefaults(suiteName: "focus-coord-\(UUID().uuidString)")!
        let thrower = ThrowingLauncher(error: TerminalLaunchError.scriptFailed("test error"))
        let coordinator = FocusCoordinator(store: store, defaults: defaults, launcher: thrower, gitDiff: StubGitDiff(files: []), clipboard: { _ in }, runBackfill: false)

        coordinator.start(initialSessions: [], now: t0)
        coordinator.createTask(title: "Следующее", column: .todo, projectPath: "/tmp/next")
        let taskID = try #require(coordinator.board.tasks(in: .todo).first?.id)
        coordinator.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        coordinator.tick(now: t0.addingTimeInterval(15))
        coordinator.perform(.startTask(taskID: taskID), now: t0.addingTimeInterval(20))

        #expect(coordinator.card == nil)
        #expect(coordinator.board.task(id: taskID)?.boardColumn == .inProgress)
        let stats = try #require(coordinator.stats(since: t0))
        #expect(stats.medianReactionSec == nil)
    }

    @Test
    func completedSessionStaysUnseenUntilJump() throws {
        let (coordinator, _, _) = try makeCoordinator()
        var jumped: [String] = []
        coordinator.jumpToSession = { jumped.append($0) }
        coordinator.start(initialSessions: [], now: t0)
        coordinator.sessionsDidChange([session("done", .running, at: t0), session("s1", .running, at: t0)], now: t0)
        coordinator.sessionsDidChange([session("done", .completed, at: t0.addingTimeInterval(1)), session("s1", .running, at: t0)], now: t0.addingTimeInterval(1))
        coordinator.tick(now: t0.addingTimeInterval(15))
        guard case let .nextAction(triggering, _) = coordinator.card else {
            Issue.record("expected nextAction card")
            return
        }
        #expect(triggering == "s1")
        #expect(coordinator.alternatives == [.review(sessionID: "done")])
        coordinator.perform(.jump(sessionID: "done"), now: t0.addingTimeInterval(16))
        #expect(jumped == ["done"])
        #expect(coordinator.card == nil)
    }

    @Test
    func distractionNudgeAppearsAndEpisodeIsLogged() throws {
        let (coordinator, store, _) = try makeCoordinator()
        coordinator.start(initialSessions: [], now: t0)
        coordinator.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        coordinator.frontmostDidChange(FrontmostSample(bundleID: "ru.keepcoder.Telegram", url: nil, at: t0))
        coordinator.frontmostDidChange(FrontmostSample(bundleID: "ru.keepcoder.Telegram", url: nil, at: t0.addingTimeInterval(20)))
        #expect(coordinator.card == .nudge)
        coordinator.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Terminal", url: nil, at: t0.addingTimeInterval(30)))
        #expect(coordinator.card == nil)
        #expect(try DistractionLog(store: store).episodes(since: t0).count == 1)
    }

    @Test
    func bindingFromChipMovesTaskAndClearsPrompt() throws {
        let (coordinator, _, _) = try makeCoordinator()
        coordinator.start(initialSessions: [], now: t0)
        coordinator.createTask(title: "A", column: .todo, projectPath: nil)
        let taskID = try #require(coordinator.board.tasks(in: .todo).first?.id)
        coordinator.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        coordinator.bind(sessionID: "s1", taskID: taskID)
        #expect(coordinator.pendingBindingSessionIDs.isEmpty)
        #expect(coordinator.board.task(id: taskID)?.boardColumn == .inProgress)
        #expect(coordinator.currentTask?.id == taskID)
    }

    @Test
    func restoredCompletedSessionIsNotUnseenAfterStart() throws {
        let (coordinator, _, _) = try makeCoordinator()
        let restored = session("old", .completed, at: t0.addingTimeInterval(-3600), firstSeen: t0.addingTimeInterval(-3600))
        coordinator.sessionsDidChange([restored], now: t0)
        coordinator.start(initialSessions: [restored], now: t0)
        coordinator.sessionsDidChange([restored, session("s1", .running, at: t0)], now: t0)
        coordinator.tick(now: t0.addingTimeInterval(15))
        guard case let .nextAction(triggering, _) = coordinator.card else {
            Issue.record("expected nextAction card, got \(String(describing: coordinator.card))")
            return
        }
        #expect(triggering == "s1")
        #expect(coordinator.alternatives.isEmpty)
    }

    @Test
    func overlayCloseClearsPendingCard() throws {
        let (coordinator, _, _) = try makeCoordinator()
        coordinator.start(initialSessions: [], now: t0)
        coordinator.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        coordinator.tick(now: t0.addingTimeInterval(15))
        #expect(coordinator.card != nil)
        coordinator.overlayDidClose(now: t0.addingTimeInterval(16))
        #expect(coordinator.card == nil)
    }

    @Test
    func pendingCardDoesNotConsumeTurns() throws {
        let (coordinator, _, _) = try makeCoordinator()
        coordinator.start(initialSessions: [], now: t0)
        coordinator.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        coordinator.tick(now: t0.addingTimeInterval(15))
        coordinator.sessionsDidChange([session("s1", .running, at: t0), session("s2", .running, at: t0.addingTimeInterval(16))], now: t0.addingTimeInterval(16))
        coordinator.tick(now: t0.addingTimeInterval(40))
        guard case let .nextAction(stillShown, _) = coordinator.card else {
            Issue.record("expected pending nextAction card")
            return
        }
        #expect(stillShown == "s1")
        coordinator.overlayDidClose(now: t0.addingTimeInterval(41))
        coordinator.tick(now: t0.addingTimeInterval(42))
        guard case let .nextAction(triggering, _) = coordinator.card else {
            Issue.record("expected card for s2, got \(String(describing: coordinator.card))")
            return
        }
        #expect(triggering == "s2")
    }

    @Test
    func nextActionCardExpiresWhenTriggeringSessionStops() throws {
        let (coordinator, _, _) = try makeCoordinator()
        coordinator.start(initialSessions: [], now: t0)
        coordinator.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        coordinator.tick(now: t0.addingTimeInterval(15))
        #expect(coordinator.card != nil)
        coordinator.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(20))], now: t0.addingTimeInterval(20))
        #expect(coordinator.card == nil)
    }

    @Test
    func nextActionCardExpiresAfterTenMinutes() throws {
        let (coordinator, _, _) = try makeCoordinator()
        coordinator.start(initialSessions: [], now: t0)
        coordinator.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        coordinator.tick(now: t0.addingTimeInterval(15))
        coordinator.tick(now: t0.addingTimeInterval(15 + 599))
        #expect(coordinator.card != nil)
        coordinator.tick(now: t0.addingTimeInterval(15 + 600))
        #expect(coordinator.card == nil)
    }

    @Test
    func nudgeReplacesPendingNextActionCard() throws {
        let (coordinator, _, _) = try makeCoordinator()
        var presented = 0
        coordinator.presentCard = { presented += 1 }
        coordinator.start(initialSessions: [], now: t0)
        coordinator.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        coordinator.tick(now: t0.addingTimeInterval(15))
        guard case .nextAction = coordinator.card else {
            Issue.record("expected nextAction card")
            return
        }
        coordinator.frontmostDidChange(FrontmostSample(bundleID: "ru.keepcoder.Telegram", url: nil, at: t0.addingTimeInterval(16)))
        coordinator.frontmostDidChange(FrontmostSample(bundleID: "ru.keepcoder.Telegram", url: nil, at: t0.addingTimeInterval(40)))
        #expect(coordinator.card == .nudge)
        #expect(presented == 2)
    }

    @Test
    func syntheticProcessSessionIsIgnored() throws {
        let (coordinator, store, _) = try makeCoordinator()
        coordinator.start(initialSessions: [], now: t0)
        let synthetic = session("claude-process:abc", .running, at: t0)
        #expect(synthetic.isSyntheticProcessSession)
        coordinator.sessionsDidChange([synthetic], now: t0)
        coordinator.sessionsDidChange([session("claude-process:abc", .completed, at: t0.addingTimeInterval(1))], now: t0.addingTimeInterval(1))
        coordinator.sessionsDidChange([session("claude-process:abc", .running, at: t0.addingTimeInterval(2), prompt: "p2"), session("s1", .running, at: t0.addingTimeInterval(2))], now: t0.addingTimeInterval(2))
        #expect(try SessionHistory(store: store).session(id: "claude-process:abc") == nil)
        #expect(coordinator.pendingBindingSessionIDs == ["s1"])
        #expect(!coordinator.liveSessionIDs.contains("claude-process:abc"))
        coordinator.tick(now: t0.addingTimeInterval(20))
        guard case let .nextAction(triggering, _) = coordinator.card else {
            Issue.record("expected nextAction card")
            return
        }
        #expect(triggering == "s1")
        #expect(coordinator.alternatives.isEmpty)
    }

    @Test
    func hasRunningSessionRequiresRunningPhase() throws {
        let (coordinator, _, _) = try makeCoordinator()
        coordinator.start(initialSessions: [], now: t0)
        coordinator.sessionsDidChange([session("s1", .completed, at: t0)], now: t0)
        #expect(!coordinator.hasRunningSession)
        coordinator.sessionsDidChange([session("s1", .running, at: t0.addingTimeInterval(1))], now: t0.addingTimeInterval(1))
        #expect(coordinator.hasRunningSession)
    }

    @Test
    func pickerTasksPreferSessionProject() throws {
        let (coordinator, _, _) = try makeCoordinator()
        coordinator.start(initialSessions: [], now: t0)
        coordinator.createTask(title: "A", column: .todo, projectPath: "/tmp/other")
        coordinator.createTask(title: "B", column: .todo, projectPath: "/tmp/proj")
        coordinator.createTask(title: "C", column: .todo, projectPath: "/tmp")
        coordinator.createTask(title: "D", column: .todo, projectPath: "/tmp/pro")
        coordinator.sessionsDidChange([session("s1", .running, at: t0, cwd: "/tmp/proj/sub")], now: t0)
        #expect(coordinator.sessionCWD("s1") == "/tmp/proj/sub")
        #expect(coordinator.pickerTasks(forSessionID: "s1").map(\.title) == ["B", "C", "A", "D"])
        #expect(coordinator.pickerTasks(forSessionID: "unknown").map(\.title) == ["A", "B", "C", "D"])
    }

    @Test
    func liveSessionIDsTrackRunningSessions() throws {
        let (coordinator, _, _) = try makeCoordinator()
        coordinator.start(initialSessions: [], now: t0)
        coordinator.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        #expect(coordinator.liveSessionIDs == ["s1"])
        coordinator.sessionsDidChange([], now: t0.addingTimeInterval(5))
        #expect(coordinator.liveSessionIDs.isEmpty)
    }
}

struct FocusIslandSectionTests {
    @Test
    func boardButtonTitleFollowsHotKey() {
        #expect(FocusIslandSection.boardButtonTitle(.optionCommandB) == "Доска ⌥⌘B")
        #expect(FocusIslandSection.boardButtonTitle(.controlOptionB) == "Доска ⌃⌥B")
        #expect(FocusIslandSection.boardButtonTitle(.off) == "Доска")
    }
}

struct FrontmostAppMonitorTests {
    @Test
    func browserURLIsReadOnlyWhenDistractionEnabledAndSessionRunning() {
        #expect(FrontmostAppMonitor.browserURLSource(for: "com.apple.Safari", distractionEnabled: true, hasRunningSession: true) != nil)
        #expect(FrontmostAppMonitor.browserURLSource(for: "com.apple.Safari", distractionEnabled: false, hasRunningSession: true) == nil)
        #expect(FrontmostAppMonitor.browserURLSource(for: "com.apple.Safari", distractionEnabled: true, hasRunningSession: false) == nil)
        #expect(FrontmostAppMonitor.browserURLSource(for: "com.apple.Terminal", distractionEnabled: true, hasRunningSession: true) == nil)
    }

    @Test
    func browserScriptsCoverSupportedBrowsers() {
        #expect(FrontmostAppMonitor.browserURLScript(for: "com.apple.Safari") == "tell application id \"com.apple.Safari\" to if (count of documents) > 0 then return URL of front document")
        #expect(FrontmostAppMonitor.browserURLScript(for: "com.google.Chrome") == "tell application id \"com.google.Chrome\" to if (count of windows) > 0 then return URL of active tab of front window")
        #expect(FrontmostAppMonitor.browserURLScript(for: "company.thebrowser.Browser") == "tell application id \"company.thebrowser.Browser\" to if (count of windows) > 0 then return URL of active tab of front window")
        #expect(FrontmostAppMonitor.browserURLScript(for: "com.apple.Terminal") == nil)
    }

    @Test
    func readBrowserURLReturnsNilForFailingScript() async {
        let url = await FrontmostAppMonitor.readBrowserURL(script: "this is not applescript", timeout: 2)
        #expect(url == nil)
    }

    @Test
    func readBrowserURLReturnsWithinTimeout() async {
        let startTime = Date()
        let url = await FrontmostAppMonitor.readBrowserURL(script: "delay 5", timeout: 0.5)
        let elapsed = Date().timeIntervalSince(startTime)
        #expect(url == nil)
        #expect(elapsed < 2)
    }
}
