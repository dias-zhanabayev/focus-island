import FocusCore
import Foundation
import OpenIslandCore
import Testing
@testable import OpenIslandApp

final class RecordingPromptSender: PromptSending, @unchecked Sendable {
    let result: PromptSendResult
    private let lock = NSLock()
    private var storage: [(text: String, sessionID: String)] = []

    init(result: PromptSendResult) {
        self.result = result
    }

    var sent: [(text: String, sessionID: String)] {
        lock.withLock { storage }
    }

    func send(_ text: String, to session: AgentSession) async -> PromptSendResult {
        lock.withLock { storage.append((text, session.id)) }
        return result
    }
}

final class StubGitDiff: GitDiffProviding, @unchecked Sendable {
    let files: [ChangedFile]
    private let lock = NSLock()
    private var cwds: [String] = []

    init(files: [ChangedFile]) {
        self.files = files
    }

    var calls: [String] {
        lock.withLock { cwds }
    }

    func changedFiles(cwd: String) async -> [ChangedFile] {
        lock.withLock { cwds.append(cwd) }
        return files
    }
}

final class GatedPromptSender: PromptSending, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let gate: AsyncStream<Void>
    private let opener: AsyncStream<Void>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        gate = stream
        opener = continuation
    }

    var calls: Int {
        lock.withLock { count }
    }

    func release() {
        opener.finish()
    }

    func send(_ text: String, to session: AgentSession) async -> PromptSendResult {
        lock.withLock { count += 1 }
        for await _ in gate {}
        return .sent
    }
}

final class ClipboardBox {
    var items: [String] = []
}

@MainActor
struct FocusCoordinatorCardTests {
    let t0 = Date(timeIntervalSince1970: 80_000)

    struct Harness {
        let coordinator: FocusCoordinator
        let store: FocusStore
        let sender: RecordingPromptSender
        let diff: StubGitDiff
        let clipboard: ClipboardBox
        let jumps: JumpBox
    }

    final class JumpBox {
        var ids: [String] = []
    }

    func make(sendResult: PromptSendResult = .sent, files: [ChangedFile] = []) throws -> Harness {
        let store = try FocusStore.inMemory()
        let defaults = UserDefaults(suiteName: "focus-card-\(UUID().uuidString)")!
        let sender = RecordingPromptSender(result: sendResult)
        let diff = StubGitDiff(files: files)
        let clipboard = ClipboardBox()
        let coordinator = FocusCoordinator(
            store: store,
            defaults: defaults,
            launcher: RecordingLauncher(),
            promptSender: sender,
            gitDiff: diff,
            clipboard: { clipboard.items.append($0) },
            runBackfill: false
        )
        let jumps = JumpBox()
        coordinator.jumpToSession = { jumps.ids.append($0) }
        coordinator.start(initialSessions: [], now: t0)
        return Harness(coordinator: coordinator, store: store, sender: sender, diff: diff, clipboard: clipboard, jumps: jumps)
    }

    func session(_ id: String, _ phase: SessionPhase, at date: Date, prompt: String? = "p", cwd: String = "/tmp/proj", tasks: [ClaudeTaskInfo] = []) -> AgentSession {
        var session = AgentSession(
            id: id, title: id, tool: .claudeCode, origin: .live, attachmentState: .attached, phase: phase, summary: "", updatedAt: date, firstSeenAt: date,
            jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "proj", paneTitle: "", workingDirectory: cwd),
            claudeMetadata: ClaudeSessionMetadata(initialUserPrompt: prompt, lastUserPrompt: prompt, startupSource: .startup, activeTasks: tasks)
        )
        session.isHookManaged = true
        return session
    }

    func boundTask(_ h: Harness, title: String, sessionID: String) throws -> String {
        h.coordinator.createTask(title: title, column: .todo, projectPath: nil)
        let id = try #require(h.coordinator.board.tasks.first { $0.title == title }?.id)
        h.coordinator.bind(sessionID: sessionID, taskID: id)
        return id
    }

    @Test
    func priorityOrder() throws {
        let ordered: [FocusCard] = [
            .onboarding, .nudge, .returned(sessionID: "a"), .reEntry(sessionID: "a"), .overload(newSessionID: "a"),
            .nextAction(triggeringSessionID: "a", eventID: nil), .dayStart,
        ]
        #expect(ordered.map(\.priority) == [10, 9, 7, 6, 5, 4, 2])
        for (index, card) in ordered.enumerated() {
            #expect(FocusCard.canReplace(nil, with: card))
            #expect(FocusCard.canReplace(card, with: card))
            for lower in ordered[(index + 1)...] {
                #expect(FocusCard.canReplace(lower, with: card))
                #expect(!FocusCard.canReplace(card, with: lower))
            }
        }

        let h = try make()
        let c = h.coordinator
        c.sessionsDidChange([session("s1", .running, at: t0), session("s2", .running, at: t0)], now: t0)
        _ = try boundTask(h, title: "Фокус", sessionID: "s1")
        c.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(5)), session("s2", .running, at: t0)], now: t0.addingTimeInterval(5))
        #expect(c.card == .returned(sessionID: "s1"))
        c.tick(now: t0.addingTimeInterval(20))
        #expect(c.card == .returned(sessionID: "s1"))
        c.frontmostDidChange(FrontmostSample(bundleID: "ru.keepcoder.Telegram", url: nil, at: t0.addingTimeInterval(21)))
        c.frontmostDidChange(FrontmostSample(bundleID: "ru.keepcoder.Telegram", url: nil, at: t0.addingTimeInterval(45)))
        #expect(c.card == .nudge)
        c.perform(.returnToWork, now: t0.addingTimeInterval(46))
        #expect(c.card == nil)
        c.tick(now: t0.addingTimeInterval(47))
        guard case let .nextAction(triggering, _) = c.card else {
            Issue.record("expected deferred nextAction, got \(String(describing: c.card))")
            return
        }
        #expect(triggering == "s2")
    }

    @Test
    func returnedOnCompletionWithQueuedPrompt() throws {
        let h = try make()
        let c = h.coordinator
        c.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        c.tick(now: t0.addingTimeInterval(15))
        c.perform(.queuePrompt(sessionID: "s1", text: "дальше тесты"), now: t0.addingTimeInterval(16))
        c.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(30))], now: t0.addingTimeInterval(30))
        #expect(c.card == .returned(sessionID: "s1"))
    }

    @Test
    func returnedForFocusTaskWithoutPrompt() throws {
        let h = try make()
        let c = h.coordinator
        c.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        let taskID = try boundTask(h, title: "Фокус", sessionID: "s1")
        #expect(c.currentTask?.id == taskID)
        var presented = 0
        c.presentCard = { presented += 1 }
        c.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(30))], now: t0.addingTimeInterval(30))
        #expect(c.card == .returned(sessionID: "s1"))
        #expect(presented == 1)
    }

    @Test
    func noReturnedForOtherTaskWithoutPrompt() throws {
        let h = try make()
        let c = h.coordinator
        c.sessionsDidChange([session("s1", .running, at: t0), session("s2", .running, at: t0.addingTimeInterval(10))], now: t0.addingTimeInterval(10))
        _ = try boundTask(h, title: "A", sessionID: "s1")
        let b = try boundTask(h, title: "B", sessionID: "s2")
        #expect(c.currentTask?.id == b)
        c.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(20)), session("s2", .running, at: t0.addingTimeInterval(10))], now: t0.addingTimeInterval(20))
        #expect(c.card == nil)
        c.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(20)), session("s3", .running, at: t0.addingTimeInterval(21))], now: t0.addingTimeInterval(21))
        c.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(20)), session("s3", .completed, at: t0.addingTimeInterval(22))], now: t0.addingTimeInterval(22))
        #expect(c.card == nil)
    }

    @Test
    func queuePromptReplaces() throws {
        let h = try make()
        let c = h.coordinator
        c.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        c.perform(.queuePrompt(sessionID: "s1", text: "первый"), now: t0.addingTimeInterval(1))
        c.perform(.queuePrompt(sessionID: "s1", text: "второй"), now: t0.addingTimeInterval(2))
        #expect(c.queuedPrompt(sessionID: "s1")?.text == "второй")
        let count = try h.store.dbQueue.read { db in try QueuedPrompt.fetchCount(db) }
        #expect(count == 1)
    }

    @Test
    func sendQueuedPromptMarksSentAndJumps() async throws {
        let h = try make(sendResult: .sent)
        let c = h.coordinator
        c.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        c.perform(.queuePrompt(sessionID: "s1", text: "дальше"), now: t0.addingTimeInterval(1))
        c.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(30))], now: t0.addingTimeInterval(30))
        #expect(c.card == .returned(sessionID: "s1"))
        await c.performAsync(.sendQueuedPrompt(sessionID: "s1"), now: t0.addingTimeInterval(40))
        #expect(h.sender.sent.map(\.text) == ["дальше"])
        #expect(h.sender.sent.map(\.sessionID) == ["s1"])
        #expect(c.queuedPrompt(sessionID: "s1") == nil)
        #expect(h.jumps.ids == ["s1"])
        #expect(c.card == nil)
        #expect(c.toast == nil)
        #expect(h.clipboard.items.isEmpty)
        #expect(c.record("s1")?.lastSeenAt == t0.addingTimeInterval(40))
    }

    @Test
    func unsupportedSendFallsBackToClipboard() async throws {
        let h = try make(sendResult: .unsupported)
        let c = h.coordinator
        c.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        c.perform(.queuePrompt(sessionID: "s1", text: "дальше"), now: t0.addingTimeInterval(1))
        c.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(30))], now: t0.addingTimeInterval(30))
        await c.performAsync(.sendQueuedPrompt(sessionID: "s1"), now: t0.addingTimeInterval(40))
        #expect(h.clipboard.items == ["дальше"])
        #expect(h.jumps.ids == ["s1"])
        #expect(c.toast == "Промпт в буфере — вставь ⌘V")
        #expect(c.queuedPrompt(sessionID: "s1")?.text == "дальше")
        #expect(c.card == nil)
        c.tick(now: t0.addingTimeInterval(43))
        #expect(c.toast != nil)
        c.tick(now: t0.addingTimeInterval(44))
        #expect(c.toast == nil)
    }

    @Test
    func reEntryWhenUnseenTenMinutesAndOtherTask() throws {
        let h = try make()
        let c = h.coordinator
        c.sessionsDidChange([session("s2", .completed, at: t0), session("s1", .running, at: t0.addingTimeInterval(60))], now: t0.addingTimeInterval(60))
        _ = try boundTask(h, title: "Другая", sessionID: "s2")
        let focus = try boundTask(h, title: "Фокус", sessionID: "s1")
        #expect(c.currentTask?.id == focus)
        c.requestJump(sessionID: "s2", now: t0.addingTimeInterval(11 * 60))
        #expect(c.card == .reEntry(sessionID: "s2"))
        #expect(h.jumps.ids.isEmpty)
    }

    @Test
    func directJumpWhenRecentlySeen() throws {
        let h = try make()
        let c = h.coordinator
        c.sessionsDidChange([session("s2", .completed, at: t0), session("s1", .running, at: t0.addingTimeInterval(60))], now: t0.addingTimeInterval(60))
        _ = try boundTask(h, title: "Другая", sessionID: "s2")
        _ = try boundTask(h, title: "Фокус", sessionID: "s1")
        c.markSessionSeen("s2", now: t0.addingTimeInterval(5 * 60))
        c.requestJump(sessionID: "s2", now: t0.addingTimeInterval(11 * 60))
        #expect(c.card == nil)
        #expect(h.jumps.ids == ["s2"])
        #expect(c.lastJumpProjectName == "proj")
    }

    @Test
    func confirmJumpUpdatesLastSeen() throws {
        let h = try make()
        let c = h.coordinator
        c.sessionsDidChange([session("s2", .completed, at: t0), session("s1", .running, at: t0.addingTimeInterval(60))], now: t0.addingTimeInterval(60))
        _ = try boundTask(h, title: "Другая", sessionID: "s2")
        _ = try boundTask(h, title: "Фокус", sessionID: "s1")
        let now = t0.addingTimeInterval(11 * 60)
        c.perform(.jump(sessionID: "s2"), now: now)
        #expect(c.card == .reEntry(sessionID: "s2"))
        c.perform(.confirmJump(sessionID: "s2"), now: now.addingTimeInterval(3))
        #expect(c.card == nil)
        #expect(h.jumps.ids == ["s2"])
        #expect(c.record("s2")?.lastSeenAt == now.addingTimeInterval(3))
        c.requestJump(sessionID: "s2", now: now.addingTimeInterval(60))
        #expect(h.jumps.ids == ["s2", "s2"])
    }

    @Test
    func jumpClosesCardAsReactedBeforeJumping() throws {
        let h = try make()
        let c = h.coordinator
        c.sessionsDidChange([session("s2", .waitingForApproval, at: t0), session("s1", .running, at: t0)], now: t0)
        c.tick(now: t0.addingTimeInterval(15))
        guard case .nextAction = c.card else {
            Issue.record("expected nextAction, got \(String(describing: c.card))")
            return
        }
        #expect(c.alternatives.first == .attend(sessionID: "s2", reason: .approval, since: t0))
        var cardAtJump: FocusCard? = .dayStart
        c.jumpToSession = { _ in cardAtJump = c.card }
        c.perform(.jump(sessionID: "s2"), now: t0.addingTimeInterval(20))
        #expect(cardAtJump == nil)
        #expect(c.alternatives.isEmpty)
        #expect(c.stats(since: t0)?.medianReactionSec == 5)
    }

    @Test
    func parkMovesRowToParked() throws {
        let h = try make()
        let c = h.coordinator
        c.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        #expect(c.hubRows.first { $0.id == "s1" }?.group == .running)
        c.perform(.park(sessionID: "s1"), now: t0.addingTimeInterval(1))
        #expect(c.hubRows.first { $0.id == "s1" }?.group == .parked)
        c.perform(.unpark(sessionID: "s1"), now: t0.addingTimeInterval(2))
        #expect(c.hubRows.first { $0.id == "s1" }?.group == .running)
        c.perform(.park(sessionID: "s1"), now: t0.addingTimeInterval(3))
        c.sessionsDidChange([session("s1", .running, at: t0.addingTimeInterval(4), prompt: "новый")], now: t0.addingTimeInterval(4))
        #expect(c.hubRows.first { $0.id == "s1" }?.group == .running)
    }

    @Test
    func criteriaActions() throws {
        let h = try make()
        let c = h.coordinator
        c.createTask(title: "A", column: .todo, projectPath: nil)
        let taskID = try #require(c.board.tasks.first?.id)
        #expect(c.criteriaProgress(taskID: taskID) == nil)
        c.perform(.addCriterion(taskID: taskID, text: "тесты зелёные"))
        c.perform(.addCriterion(taskID: taskID, text: "сборка"))
        let items = c.criteria(taskID: taskID)
        #expect(items.map(\.text) == ["тесты зелёные", "сборка"])
        c.perform(.toggleCriterion(id: items[0].id))
        #expect(c.criteriaProgress(taskID: taskID) == CriteriaProgress(done: 1, total: 2))
        c.perform(.deleteCriterion(id: items[1].id))
        #expect(c.criteria(taskID: taskID).map(\.text) == ["тесты зелёные"])
        c.perform(.markTaskDone(taskID: taskID))
        #expect(c.board.task(id: taskID)?.boardColumn == .done)
    }

    @Test
    func nextActionLoadsChangedFilesWithCache() async throws {
        let file = ChangedFile(id: "a.swift", path: "a.swift", added: 3, removed: 1)
        let h = try make(files: [file])
        let c = h.coordinator
        c.settings.nextActionDelay = 5
        c.sessionsDidChange([session("s1", .running, at: t0, cwd: "/tmp/repo")], now: t0)
        c.tick(now: t0.addingTimeInterval(5))
        await c.changedFilesTask?.value
        #expect(c.changedFiles["s1"] == [file])
        #expect(h.diff.calls == ["/tmp/repo"])
        c.perform(.dismiss, now: t0.addingTimeInterval(6))
        c.sessionsDidChange([session("s1", .running, at: t0.addingTimeInterval(7), prompt: "p2", cwd: "/tmp/repo")], now: t0.addingTimeInterval(7))
        c.tick(now: t0.addingTimeInterval(12))
        #expect(c.card != nil)
        await c.changedFilesTask?.value
        #expect(h.diff.calls == ["/tmp/repo"])
        c.perform(.dismiss, now: t0.addingTimeInterval(13))
        c.sessionsDidChange([session("s1", .running, at: t0.addingTimeInterval(14), prompt: "p3", cwd: "/tmp/repo")], now: t0.addingTimeInterval(14))
        c.tick(now: t0.addingTimeInterval(19))
        await c.changedFilesTask?.value
        #expect(h.diff.calls == ["/tmp/repo", "/tmp/repo"])
    }

    @Test
    func planProgressAndRemaining() throws {
        let h = try make()
        let c = h.coordinator
        let plan = [ClaudeTaskInfo(id: "1", title: "a", status: .inProgress), ClaudeTaskInfo(id: "2", title: "b")]
        c.sessionsDidChange([session("s1", .running, at: t0, tasks: plan)], now: t0)
        #expect(c.planProgress(sessionID: "s1") == PlanProgress(completed: 0, total: 2, currentTitle: "a"))
        #expect(c.planRemaining(sessionID: "s1", now: t0.addingTimeInterval(60)) == nil)
        let next = [ClaudeTaskInfo(id: "1", title: "a", status: .completed), ClaudeTaskInfo(id: "2", title: "b", status: .inProgress)]
        c.sessionsDidChange([session("s1", .running, at: t0.addingTimeInterval(120), tasks: next)], now: t0.addingTimeInterval(120))
        #expect(c.planRemaining(sessionID: "s1", now: t0.addingTimeInterval(120)) == 120)
    }

    @Test
    func snoozeDistractionSuppressesFiveMinutes() throws {
        let h = try make()
        let c = h.coordinator
        c.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        c.frontmostDidChange(FrontmostSample(bundleID: "ru.keepcoder.Telegram", url: nil, at: t0))
        c.frontmostDidChange(FrontmostSample(bundleID: "ru.keepcoder.Telegram", url: nil, at: t0.addingTimeInterval(25)))
        #expect(c.card == .nudge)
        c.perform(.snoozeDistraction, now: t0.addingTimeInterval(26))
        #expect(c.card == nil)
        c.frontmostDidChange(FrontmostSample(bundleID: "ru.keepcoder.Telegram", url: nil, at: t0.addingTimeInterval(200)))
        c.frontmostDidChange(FrontmostSample(bundleID: "ru.keepcoder.Telegram", url: nil, at: t0.addingTimeInterval(299)))
        #expect(c.card == nil)
        c.frontmostDidChange(FrontmostSample(bundleID: "ru.keepcoder.Telegram", url: nil, at: t0.addingTimeInterval(330)))
        c.frontmostDidChange(FrontmostSample(bundleID: "ru.keepcoder.Telegram", url: nil, at: t0.addingTimeInterval(360)))
        #expect(c.card == .nudge)
    }

    @Test
    func returnedSurvivesNudge() throws {
        let h = try make()
        let c = h.coordinator
        c.sessionsDidChange([session("s1", .running, at: t0), session("s2", .running, at: t0)], now: t0)
        _ = try boundTask(h, title: "Фокус", sessionID: "s1")
        c.frontmostDidChange(FrontmostSample(bundleID: "ru.keepcoder.Telegram", url: nil, at: t0.addingTimeInterval(1)))
        c.frontmostDidChange(FrontmostSample(bundleID: "ru.keepcoder.Telegram", url: nil, at: t0.addingTimeInterval(25)))
        #expect(c.card == .nudge)
        c.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(30)), session("s2", .running, at: t0)], now: t0.addingTimeInterval(30))
        #expect(c.card == .nudge)
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Terminal", url: nil, at: t0.addingTimeInterval(40)))
        #expect(c.card == .returned(sessionID: "s1"))
    }

    @Test
    func secondReturnedQueuedUntilFirstCloses() throws {
        let h = try make()
        let c = h.coordinator
        c.sessionsDidChange([session("s1", .running, at: t0), session("s2", .running, at: t0)], now: t0)
        c.perform(.queuePrompt(sessionID: "s1", text: "a"), now: t0.addingTimeInterval(1))
        c.perform(.queuePrompt(sessionID: "s2", text: "b"), now: t0.addingTimeInterval(1))
        c.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(5)), session("s2", .completed, at: t0.addingTimeInterval(5))], now: t0.addingTimeInterval(5))
        #expect(c.card == .returned(sessionID: "s1"))
        c.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(5)), session("s2", .completed, at: t0.addingTimeInterval(6), prompt: "p")], now: t0.addingTimeInterval(6))
        #expect(c.card == .returned(sessionID: "s1"))
        c.perform(.dismiss, now: t0.addingTimeInterval(7))
        #expect(c.card == .returned(sessionID: "s2"))
        c.perform(.dismiss, now: t0.addingTimeInterval(8))
        #expect(c.card == nil)
        c.tick(now: t0.addingTimeInterval(9))
        #expect(c.card == nil)
    }

    @Test
    func overlayCloseKeepsPendingReturnedWithoutReopening() throws {
        let h = try make()
        let c = h.coordinator
        c.sessionsDidChange([session("s1", .running, at: t0), session("s2", .running, at: t0)], now: t0)
        c.perform(.queuePrompt(sessionID: "s1", text: "a"), now: t0.addingTimeInterval(1))
        c.perform(.queuePrompt(sessionID: "s2", text: "b"), now: t0.addingTimeInterval(1))
        c.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(5)), session("s2", .completed, at: t0.addingTimeInterval(5))], now: t0.addingTimeInterval(5))
        #expect(c.card == .returned(sessionID: "s1"))
        var presented = 0
        c.presentCard = { presented += 1 }
        c.overlayDidClose(now: t0.addingTimeInterval(7))
        #expect(c.card == .returned(sessionID: "s2"))
        #expect(presented == 0)
        c.tick(now: t0.addingTimeInterval(8))
        #expect(c.card == .returned(sessionID: "s2"))
        #expect(presented == 0)
        c.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(5)), session("s2", .running, at: t0.addingTimeInterval(9), prompt: "p2")], now: t0.addingTimeInterval(9))
        #expect(c.card == nil)
        c.tick(now: t0.addingTimeInterval(10))
        #expect(c.card == nil)
        #expect(presented == 0)
    }

    @Test
    func returnedClosesWhenItsSessionIsResolved() throws {
        func shown() throws -> (Harness, FocusCoordinator) {
            let h = try make()
            let c = h.coordinator
            c.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
            c.perform(.queuePrompt(sessionID: "s1", text: "a"), now: t0.addingTimeInterval(1))
            c.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(5))], now: t0.addingTimeInterval(5))
            #expect(c.card == .returned(sessionID: "s1"))
            return (h, c)
        }
        let (_, running) = try shown()
        running.sessionsDidChange([session("s1", .running, at: t0.addingTimeInterval(10), prompt: "p2")], now: t0.addingTimeInterval(10))
        #expect(running.card == nil)

        let (_, seen) = try shown()
        seen.markSessionSeen("s1", now: t0.addingTimeInterval(10))
        #expect(seen.card == nil)

        let (_, parked) = try shown()
        parked.perform(.park(sessionID: "s1"), now: t0.addingTimeInterval(10))
        #expect(parked.card == nil)

        let (_, ended) = try shown()
        ended.sessionsDidChange([], now: t0.addingTimeInterval(10))
        #expect(ended.card == nil)
    }

    @Test
    func hiddenReturnedDoesNotBlockLowerCards() throws {
        let h = try make()
        let c = h.coordinator
        c.settings.dayStartEnabled = false
        c.sessionsDidChange([session("s1", .running, at: t0), session("s2", .running, at: t0), session("s3", .running, at: t0)], now: t0)
        c.perform(.queuePrompt(sessionID: "s1", text: "a"), now: t0.addingTimeInterval(1))
        c.perform(.queuePrompt(sessionID: "s2", text: "b"), now: t0.addingTimeInterval(1))
        c.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(5)), session("s2", .completed, at: t0.addingTimeInterval(5)), session("s3", .running, at: t0)], now: t0.addingTimeInterval(5))
        #expect(c.card == .returned(sessionID: "s1"))
        var presented = 0
        c.presentCard = { presented += 1 }
        c.overlayDidClose(now: t0.addingTimeInterval(6))
        #expect(c.card == .returned(sessionID: "s2"))
        c.tick(now: t0.addingTimeInterval(20))
        guard case let .nextAction(triggering, _) = c.card else {
            Issue.record("expected nextAction over hidden returned, got \(String(describing: c.card))")
            return
        }
        #expect(triggering == "s3")
        #expect(presented == 1)
        c.perform(.dismiss, now: t0.addingTimeInterval(21))
        #expect(c.card == .returned(sessionID: "s2"))
        #expect(presented == 1)
    }

    @Test
    func freshReturnedIsShownPastDeferredHead() throws {
        let h = try make()
        let c = h.coordinator
        c.settings.dayStartEnabled = false
        c.settings.distractionEnabled = false
        let running = ["s1", "s2", "s3", "s4"].map { session($0, .running, at: t0) }
        c.sessionsDidChange(running, now: t0)
        _ = try boundTask(h, title: "Фокус", sessionID: "s4")
        c.perform(.queuePrompt(sessionID: "s1", text: "a"), now: t0.addingTimeInterval(1))
        c.perform(.queuePrompt(sessionID: "s2", text: "b"), now: t0.addingTimeInterval(1))
        c.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(5)), session("s2", .completed, at: t0.addingTimeInterval(5)), running[2], running[3]], now: t0.addingTimeInterval(5))
        #expect(c.card == .returned(sessionID: "s1"))
        c.overlayDidClose(now: t0.addingTimeInterval(6))
        #expect(c.card == .returned(sessionID: "s2"))
        c.tick(now: t0.addingTimeInterval(20))
        guard case .nextAction = c.card else {
            Issue.record("expected nextAction, got \(String(describing: c.card))")
            return
        }
        var presented = 0
        c.presentCard = { presented += 1 }
        c.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(5)), session("s2", .completed, at: t0.addingTimeInterval(5)), running[2], session("s4", .completed, at: t0.addingTimeInterval(30))], now: t0.addingTimeInterval(30))
        #expect(c.card == .returned(sessionID: "s4"))
        #expect(presented == 1)
        c.perform(.dismiss, now: t0.addingTimeInterval(31))
        #expect(c.card == .returned(sessionID: "s2"))
        #expect(presented == 1)
    }

    @Test
    func returnedDisplacedByNudgeComesBack() throws {
        let h = try make()
        let c = h.coordinator
        c.settings.dayStartEnabled = false
        c.sessionsDidChange([session("s1", .running, at: t0), session("s2", .running, at: t0)], now: t0)
        _ = try boundTask(h, title: "Фокус", sessionID: "s1")
        c.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(5)), session("s2", .running, at: t0)], now: t0.addingTimeInterval(5))
        #expect(c.card == .returned(sessionID: "s1"))
        c.frontmostDidChange(FrontmostSample(bundleID: "ru.keepcoder.Telegram", url: nil, at: t0.addingTimeInterval(21)))
        c.frontmostDidChange(FrontmostSample(bundleID: "ru.keepcoder.Telegram", url: nil, at: t0.addingTimeInterval(45)))
        #expect(c.card == .nudge)
        c.perform(.snoozeDistraction, now: t0.addingTimeInterval(46))
        #expect(c.card == .returned(sessionID: "s1"))
    }

    @Test
    func requestJumpKeepsOnboardingCard() throws {
        let h = try make()
        let c = h.coordinator
        c.setHooksInstalled(false, now: t0)
        #expect(c.card == .onboarding)
        c.sessionsDidChange([session("s1", .completed, at: t0)], now: t0)
        c.requestJump(sessionID: "s1", now: t0.addingTimeInterval(1))
        #expect(c.card == .onboarding)
        #expect(h.jumps.ids == ["s1"])
    }

    @Test
    func dueTurnIsKeptUntilItsCardIsPresented() throws {
        let h = try make()
        let c = h.coordinator
        c.settings.dayStartEnabled = false
        c.settings.distractionEnabled = false
        c.sessionsDidChange([session("a", .running, at: t0), session("b", .running, at: t0)], now: t0)
        c.tick(now: t0.addingTimeInterval(16))
        guard case let .nextAction(first, _) = c.card else {
            Issue.record("expected first nextAction, got \(String(describing: c.card))")
            return
        }
        #expect(first == "a")
        c.perform(.dismiss, now: t0.addingTimeInterval(17))
        c.tick(now: t0.addingTimeInterval(18))
        guard case let .nextAction(second, _) = c.card else {
            Issue.record("expected second nextAction, got \(String(describing: c.card))")
            return
        }
        #expect(second == "b")
        c.perform(.dismiss, now: t0.addingTimeInterval(19))

        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.finder", url: nil, at: t0.addingTimeInterval(20)))
        c.sessionsDidChange([session("a", .running, at: t0.addingTimeInterval(30), prompt: "p2"), session("b", .running, at: t0)], now: t0.addingTimeInterval(30))
        c.tick(now: t0.addingTimeInterval(90))
        #expect(c.card == nil)
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Terminal", url: nil, at: t0.addingTimeInterval(91)))
        c.tick(now: t0.addingTimeInterval(92))
        guard case let .nextAction(third, _) = c.card else {
            Issue.record("expected deferred nextAction, got \(String(describing: c.card))")
            return
        }
        #expect(third == "a")
    }

    @Test
    func reEnqueuedSameTextDuringSendIsMarkedSent() async throws {
        let store = try FocusStore.inMemory()
        let defaults = UserDefaults(suiteName: "focus-card-\(UUID().uuidString)")!
        let sender = GatedPromptSender()
        let c = FocusCoordinator(store: store, defaults: defaults, launcher: RecordingLauncher(), promptSender: sender, gitDiff: StubGitDiff(files: []), clipboard: { _ in }, runBackfill: false)
        c.start(initialSessions: [], now: t0)
        c.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        c.perform(.queuePrompt(sessionID: "s1", text: "дальше"), now: t0.addingTimeInterval(1))
        c.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(5))], now: t0.addingTimeInterval(5))
        c.perform(.sendQueuedPrompt(sessionID: "s1"), now: t0.addingTimeInterval(6))
        while sender.calls == 0 {
            await Task.yield()
        }
        c.perform(.queuePrompt(sessionID: "s1", text: "дальше"), now: t0.addingTimeInterval(7))
        sender.release()
        await c.actionTask?.value
        #expect(c.queuedPrompt(sessionID: "s1") == nil)
    }

    @Test
    func queuedPromptOfEndedSessionIsDiscarded() throws {
        let h = try make()
        let c = h.coordinator
        c.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        c.perform(.queuePrompt(sessionID: "s1", text: "a"), now: t0.addingTimeInterval(1))
        #expect(c.queuedPrompt(sessionID: "s1") != nil)
        c.sessionsDidChange([], now: t0.addingTimeInterval(2))
        #expect(c.queuedPrompt(sessionID: "s1") == nil)
    }

    @Test
    func todaySummaryRefreshesOnStartAndAtMostEveryMinute() throws {
        let h = try make()
        let c = h.coordinator
        #expect(c.todaySummaryRefreshedAt == t0)
        #expect(c.todaySummary == TodaySummary(focusSeconds: 0, distractionSeconds: 0))
        c.tick(now: t0.addingTimeInterval(30))
        #expect(c.todaySummaryRefreshedAt == t0)
        c.tick(now: t0.addingTimeInterval(59))
        #expect(c.todaySummaryRefreshedAt == t0)
        c.tick(now: t0.addingTimeInterval(60))
        #expect(c.todaySummaryRefreshedAt == t0.addingTimeInterval(60))
        c.tick(now: t0.addingTimeInterval(90))
        #expect(c.todaySummaryRefreshedAt == t0.addingTimeInterval(60))
    }

    @Test
    func concurrentSendCallsSenderOnce() async throws {
        let store = try FocusStore.inMemory()
        let defaults = UserDefaults(suiteName: "focus-card-\(UUID().uuidString)")!
        let sender = GatedPromptSender()
        let c = FocusCoordinator(store: store, defaults: defaults, launcher: RecordingLauncher(), promptSender: sender, gitDiff: StubGitDiff(files: []), clipboard: { _ in }, runBackfill: false)
        c.start(initialSessions: [], now: t0)
        c.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        c.perform(.queuePrompt(sessionID: "s1", text: "дальше"), now: t0.addingTimeInterval(1))
        c.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(5))], now: t0.addingTimeInterval(5))
        c.perform(.sendQueuedPrompt(sessionID: "s1"), now: t0.addingTimeInterval(6))
        while sender.calls == 0 {
            await Task.yield()
        }
        await c.performAsync(.sendQueuedPrompt(sessionID: "s1"), now: t0.addingTimeInterval(7))
        c.perform(.sendQueuedPrompt(sessionID: "s1"), now: t0.addingTimeInterval(7))
        await c.actionTask?.value
        #expect(sender.calls == 1)
        sender.release()
        while c.queuedPrompt(sessionID: "s1") != nil {
            await Task.yield()
        }
        #expect(sender.calls == 1)
    }

    @Test
    func resumeLiveSessionGoesThroughReEntry() throws {
        let h = try make()
        let c = h.coordinator
        c.sessionsDidChange([session("s2", .completed, at: t0), session("s1", .running, at: t0.addingTimeInterval(60))], now: t0.addingTimeInterval(60))
        _ = try boundTask(h, title: "Другая", sessionID: "s2")
        _ = try boundTask(h, title: "Фокус", sessionID: "s1")
        let record = try #require(c.record("s2"))
        c.resume(record: record, now: t0.addingTimeInterval(11 * 60))
        #expect(c.card == .reEntry(sessionID: "s2"))
        #expect(h.jumps.ids.isEmpty)
    }

    @Test
    func unboundTargetJumpsDirectly() throws {
        let h = try make()
        let c = h.coordinator
        c.sessionsDidChange([session("s2", .completed, at: t0), session("s1", .running, at: t0.addingTimeInterval(60))], now: t0.addingTimeInterval(60))
        _ = try boundTask(h, title: "Фокус", sessionID: "s1")
        c.requestJump(sessionID: "s2", now: t0.addingTimeInterval(11 * 60))
        #expect(c.card == nil)
        #expect(h.jumps.ids == ["s2"])
    }

    @Test
    func returnToWorkJumpsAndMarksSeen() throws {
        let h = try make()
        let c = h.coordinator
        c.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        c.frontmostDidChange(FrontmostSample(bundleID: "ru.keepcoder.Telegram", url: nil, at: t0))
        c.frontmostDidChange(FrontmostSample(bundleID: "ru.keepcoder.Telegram", url: nil, at: t0.addingTimeInterval(25)))
        #expect(c.card == .nudge)
        c.perform(.returnToWork, now: t0.addingTimeInterval(26))
        #expect(c.card == nil)
        #expect(h.jumps.ids == ["s1"])
        #expect(c.record("s1")?.lastSeenAt == t0.addingTimeInterval(26))
        #expect(c.lastJumpProjectName == "proj")
    }

    @Test
    func lateChangedFilesForEndedSessionAreDropped() async throws {
        let file = ChangedFile(id: "a.swift", path: "a.swift", added: 1, removed: 0)
        let h = try make(files: [file])
        let c = h.coordinator
        c.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        c.tick(now: t0.addingTimeInterval(15))
        c.sessionsDidChange([], now: t0.addingTimeInterval(16))
        await c.changedFilesTask?.value
        #expect(c.changedFiles["s1"] == nil)
        #expect(c.alternatives.isEmpty)
    }

    func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test
    func returnedCardIsSkippedWhenTheSessionIsOnScreen() async throws {
        let h = try make()
        let c = h.coordinator
        var presented = 0
        c.presentCard = { presented += 1 }
        c.isSessionOnScreen = { _ in true }
        c.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        _ = try boundTask(h, title: "Фокус", sessionID: "s1")
        c.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(5))], now: t0.addingTimeInterval(5))
        #expect(c.card == nil)
        await waitUntil { c.hubRows.first?.group == .idle }
        #expect(c.hubRows.first?.group == .idle)
        #expect(c.card == nil)
        #expect(presented == 0)
    }

    @Test
    func returnedCardShowsAfterCheckWhenTheSessionIsElsewhere() async throws {
        let h = try make()
        let c = h.coordinator
        c.isSessionOnScreen = { _ in false }
        c.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        _ = try boundTask(h, title: "Фокус", sessionID: "s1")
        c.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(5))], now: t0.addingTimeInterval(5))
        await waitUntil { c.card != nil }
        #expect(c.card == .returned(sessionID: "s1"))
    }
}
