import FocusCore
import Foundation
import OpenIslandCore
import Testing
@testable import OpenIslandApp

@MainActor
struct FocusCoordinatorTriggerTests {
    let t0 = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 9))!

    final class JumpBox {
        var ids: [String] = []
    }

    struct Harness {
        let coordinator: FocusCoordinator
        let store: FocusStore
        let launcher: RecordingLauncher
        let jumps: JumpBox
        let defaults: UserDefaults
    }

    func make(initial: [AgentSession] = [], dayStart: Bool = false, defaults: UserDefaults? = nil) throws -> Harness {
        let store = try FocusStore.inMemory()
        let defaults = defaults ?? UserDefaults(suiteName: "focus-trigger-\(UUID().uuidString)")!
        let launcher = RecordingLauncher()
        let coordinator = FocusCoordinator(store: store, defaults: defaults, launcher: launcher, promptSender: RecordingPromptSender(result: .unsupported), gitDiff: StubGitDiff(files: []), clipboard: { _ in }, runBackfill: false)
        coordinator.settings.dayStartEnabled = dayStart
        let jumps = JumpBox()
        coordinator.jumpToSession = { jumps.ids.append($0) }
        coordinator.start(initialSessions: initial, now: t0)
        return Harness(coordinator: coordinator, store: store, launcher: launcher, jumps: jumps, defaults: defaults)
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

    func minutes(_ value: Double) -> TimeInterval { value * 60 }

    func focusTask(_ c: FocusCoordinator, _ title: String = "T") throws -> String {
        c.createTask(title: title, column: .inProgress, projectPath: "/tmp/proj")
        let id = try #require(c.board.tasks.first { $0.title == title }?.id)
        c.startTask(taskID: id, sessionIDs: [], focusMinutes: nil, now: t0)
        return id
    }

    func join(_ c: FocusCoordinator, _ sessions: [AgentSession], all: [AgentSession], taskID: String, now: Date) {
        c.sessionsDidChange(all, now: now)
        for session in sessions { c.bind(sessionID: session.id, taskID: taskID, now: now) }
    }

    @Test
    func overloadShownOncePerNewSession() throws {
        let h = try make()
        let c = h.coordinator
        let task = try focusTask(c)
        let three = (1...3).map { session("r\($0)", .running, at: t0) }
        join(c, three, all: three, taskID: task, now: t0)
        #expect(c.card == nil)

        let fourth = session("s4", .running, at: t0.addingTimeInterval(10))
        join(c, [fourth], all: three + [fourth], taskID: task, now: t0.addingTimeInterval(10))
        #expect(c.card == .overload(newSessionID: "s4"))
        c.perform(.dismiss, now: t0.addingTimeInterval(11))
        #expect(c.card == nil)

        let updated = three + [session("s4", .waitingForAnswer, at: t0.addingTimeInterval(12))]
        c.sessionsDidChange(updated, now: t0.addingTimeInterval(12))
        #expect(c.card == nil)

        let fifth = session("s5", .running, at: t0.addingTimeInterval(13))
        join(c, [fifth], all: updated + [fifth], taskID: task, now: t0.addingTimeInterval(13))
        #expect(c.card == .overload(newSessionID: "s5"))
    }

    @Test
    func overloadIgnoresSessionsOutsideTheFocusedTask() throws {
        let h = try make()
        let c = h.coordinator
        let task = try focusTask(c)
        let other = try focusTask(c, "Other")
        c.startTask(taskID: task, sessionIDs: [], focusMinutes: nil, now: t0)
        let own = session("own", .running, at: t0)
        let foreign = (1...3).map { session("f\($0)", .running, at: t0) }
        let unbound = (1...4).map { session("u\($0)", .running, at: t0) }
        join(c, [own], all: [own] + foreign + unbound, taskID: task, now: t0)
        for s in foreign { c.bind(sessionID: s.id, taskID: other, now: t0) }
        #expect(c.card == nil)
        #expect(c.overloadSuggestion == nil)
    }

    @Test
    func overloadNeedsAFocusedTask() throws {
        let h = try make()
        let c = h.coordinator
        c.sessionsDidChange((1...6).map { session("s\($0)", .running, at: t0) }, now: t0)
        #expect(c.card == nil)
        #expect(c.overloadSuggestion == nil)
    }

    @Test
    func overloadClosesWhenResolved() throws {
        let h = try make()
        let c = h.coordinator
        let task = try focusTask(c)
        let four = (1...4).map { session("s\($0)", .running, at: t0) }
        join(c, four, all: four, taskID: task, now: t0)
        #expect(c.card == .overload(newSessionID: "s4"))
        c.sessionsDidChange(Array(four.prefix(3)), now: t0.addingTimeInterval(1))
        #expect(c.card == nil)

        let fifth = session("s5", .running, at: t0.addingTimeInterval(2))
        join(c, [fifth], all: Array(four.prefix(3)) + [fifth], taskID: task, now: t0.addingTimeInterval(2))
        #expect(c.card == .overload(newSessionID: "s5"))
        c.perform(.park(sessionID: "s1"), now: t0.addingTimeInterval(3))
        #expect(c.card == nil)
    }

    @Test
    func nextActionShowsOnTickWithWaitingSessions() throws {
        let h = try make()
        let c = h.coordinator
        c.sessionsDidChange([session("s1", .running, at: t0), session("s2", .waitingForApproval, at: t0.addingTimeInterval(-minutes(20)))], now: t0)
        c.tick(now: t0.addingTimeInterval(1))
        #expect(c.card == nil)
        c.tick(now: t0.addingTimeInterval(15))
        guard case let .nextAction(triggering, _) = c.card else {
            Issue.record("expected nextAction, got \(String(describing: c.card))")
            return
        }
        #expect(triggering == "s1")
    }

    @Test
    func nextActionTurnKeptWhileHigherCardShown() throws {
        let h = try make()
        let c = h.coordinator
        c.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        c.setHooksInstalled(false, now: t0.addingTimeInterval(1))
        c.tick(now: t0.addingTimeInterval(15))
        #expect(c.card == .onboarding)
        c.dismissOnboarding(now: t0.addingTimeInterval(16))
        c.tick(now: t0.addingTimeInterval(17))
        guard case .nextAction = c.card else {
            Issue.record("expected nextAction, got \(String(describing: c.card))")
            return
        }
    }

    @Test
    func openDayStartReplacesCurrentCardExceptOnboarding() throws {
        let h = try make()
        let c = h.coordinator
        c.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        c.tick(now: t0.addingTimeInterval(15))
        guard case .nextAction = c.card else {
            Issue.record("expected nextAction, got \(String(describing: c.card))")
            return
        }
        c.openDayStart(now: t0.addingTimeInterval(16))
        #expect(c.card == .dayStart)
        c.setHooksInstalled(false, now: t0.addingTimeInterval(17))
        c.openDayStart(now: t0.addingTimeInterval(18))
        #expect(c.card == .onboarding)
    }

    @Test
    func slotToastDoesNotOverwriteToast() async throws {
        let h = try make()
        let c = h.coordinator
        let task = try focusTask(c)
        let four = (1...4).map { session("s\($0)", .running, at: t0) }
        join(c, four, all: four, taskID: task, now: t0)
        c.perform(.dismiss, now: t0)
        c.perform(.park(sessionID: "s4"), now: t0.addingTimeInterval(1))
        c.perform(.queuePrompt(sessionID: "s1", text: "дальше"), now: t0.addingTimeInterval(2))
        await c.performAsync(.sendQueuedPrompt(sessionID: "s1"), now: t0.addingTimeInterval(3))
        #expect(c.toast == FocusCoordinator.clipboardToast)
        c.sessionsDidChange([four[0], four[2], four[3]], now: t0.addingTimeInterval(4))
        #expect(c.toast == FocusCoordinator.clipboardToast)
        c.tick(now: t0.addingTimeInterval(8))
        #expect(c.toast == "Освободился слот — вернуть proj?")
    }

    @Test
    func overloadIgnoresSessionsWithinLimit() throws {
        let h = try make()
        let c = h.coordinator
        c.sessionsDidChange((1...3).map { session("s\($0)", .running, at: t0) }, now: t0)
        #expect(c.card == nil)
    }

    @Test
    func slotToastOnceWhenBelowLimitWithParked() throws {
        let h = try make()
        let c = h.coordinator
        let task = try focusTask(c)
        let four = (1...4).map { session("s\($0)", .running, at: t0) }
        join(c, four, all: four, taskID: task, now: t0)
        c.perform(.dismiss, now: t0)
        c.perform(.park(sessionID: "s4"), now: t0.addingTimeInterval(1))
        #expect(c.toast == nil)
        c.sessionsDidChange(Array(four.dropFirst()), now: t0.addingTimeInterval(2))
        #expect(c.toast == "Освободился слот — вернуть proj?")
        c.tick(now: t0.addingTimeInterval(10))
        #expect(c.toast == nil)
        c.sessionsDidChange(Array(four.dropFirst(2)), now: t0.addingTimeInterval(11))
        #expect(c.toast == nil)
    }

    @Test
    func dayStartOncePerDay() throws {
        let h = try make(dayStart: true)
        let c = h.coordinator
        let early = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 4))!
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Terminal", url: nil, at: early))
        #expect(c.card == nil)

        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Safari", url: nil, at: t0))
        #expect(c.card == .dayStart)
        #expect(c.dayPlan(day: t0)?.dayStartShownAt == t0)
        c.perform(.dismiss, now: t0.addingTimeInterval(5))
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Terminal", url: nil, at: t0.addingTimeInterval(60)))
        #expect(c.card == nil)

        let tomorrow = t0.addingTimeInterval(86_400)
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Safari", url: nil, at: tomorrow))
        #expect(c.card == .dayStart)
        c.perform(.dismiss, now: tomorrow)

        c.settings.dayStartEnabled = false
        let later = t0.addingTimeInterval(2 * 86_400)
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Terminal", url: nil, at: later))
        #expect(c.card == nil)
        c.openDayStart(now: later)
        #expect(c.card == .dayStart)
    }

    @Test
    func dayStartWaitsForHigherCard() throws {
        let h = try make(dayStart: true)
        let c = h.coordinator
        c.setHooksInstalled(false, now: t0)
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Terminal", url: nil, at: t0))
        #expect(c.card == .onboarding)
        #expect(c.dayPlan(day: t0)?.dayStartShownAt == nil)
        c.dismissOnboarding(now: t0.addingTimeInterval(1))
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Safari", url: nil, at: t0.addingTimeInterval(2)))
        #expect(c.card == .dayStart)
    }

    @Test
    func startDayMovesTasksAndLaunches() throws {
        let h = try make()
        let c = h.coordinator
        c.createTask(title: "A", column: .todo, projectPath: "/tmp/a")
        c.createTask(title: "B", column: .todo, projectPath: nil)
        let a = try #require(c.board.tasks.first { $0.title == "A" }?.id)
        let b = try #require(c.board.tasks.first { $0.title == "B" }?.id)
        c.openDayStart(now: t0)
        #expect(c.card == .dayStart)
        c.perform(.startDay(taskIDs: [a, b]), now: t0.addingTimeInterval(5))
        #expect(c.card == nil)
        #expect(c.board.task(id: a)?.boardColumn == .inProgress)
        #expect(c.board.task(id: b)?.boardColumn == .inProgress)
        #expect(h.launcher.commands == ["cd '/tmp/a' && claude"])
        #expect(c.dayPlan(day: t0)?.focusTaskIds == [a, b])
        #expect(h.jumps.ids.isEmpty)
    }

    @Test
    func startDayJumpsToLiveSessionOfFirstTask() throws {
        let h = try make()
        let c = h.coordinator
        c.sessionsDidChange([session("old", .completed, at: t0), session("new", .completed, at: t0.addingTimeInterval(30))], now: t0.addingTimeInterval(30))
        c.createTask(title: "A", column: .todo, projectPath: "/tmp/a")
        let a = try #require(c.board.tasks.first?.id)
        c.bind(sessionID: "old", taskID: a)
        c.bind(sessionID: "new", taskID: a)
        c.openDayStart(now: t0.addingTimeInterval(40))
        c.perform(.startDay(taskIDs: [a]), now: t0.addingTimeInterval(41))
        #expect(c.card == nil)
        #expect(h.jumps.ids == ["new"])
        #expect(h.launcher.commands.isEmpty)
        #expect(c.board.task(id: a)?.boardColumn == .inProgress)
    }

    @Test
    func onboardingFollowsHooksState() throws {
        let h = try make()
        let c = h.coordinator
        c.setHooksInstalled(false, now: t0)
        #expect(c.card == .onboarding)
        c.setHooksInstalled(true, now: t0.addingTimeInterval(1))
        #expect(c.card == .onboarding)
        #expect(c.hooksInstalled == true)

        #expect(!c.onboardingTaskAdded)
        c.markOnboardingTaskAdded()
        #expect(c.onboardingTaskAdded)
        #expect(h.defaults.bool(forKey: "focus.onboarding.taskAdded"))

        let reopened = try make(defaults: h.defaults)
        #expect(reopened.coordinator.onboardingTaskAdded)

        c.dismissOnboarding(now: t0.addingTimeInterval(2))
        #expect(c.card == nil)
        #expect(h.defaults.bool(forKey: "focus.onboarding.dismissed"))
        c.setHooksInstalled(false, now: t0.addingTimeInterval(3))
        #expect(c.card == nil)
        let again = try make(defaults: h.defaults)
        again.coordinator.setHooksInstalled(true, now: t0)
        again.coordinator.setHooksInstalled(false, now: t0.addingTimeInterval(1))
        #expect(again.coordinator.card == nil)
    }

    @Test
    func requestBindingMovesSessionToFront() throws {
        let h = try make()
        let c = h.coordinator
        c.requestBinding(sessionID: "a")
        c.requestBinding(sessionID: "b")
        c.requestBinding(sessionID: "a")
        #expect(c.pendingBindingSessionIDs == ["a", "b"])
        c.requestBinding(sessionID: "b")
        #expect(c.pendingBindingSessionIDs == ["b", "a"])
    }

    @Test
    func stalledBadgeAfterTenMinutes() throws {
        let h = try make()
        let c = h.coordinator
        c.sessionsDidChange([session("s1", .waitingForAnswer, at: t0), session("s2", .waitingForApproval, at: t0.addingTimeInterval(120))], now: t0.addingTimeInterval(120))
        c.createTask(title: "Фокус", column: .todo, projectPath: nil)
        let taskID = try #require(c.board.tasks.first?.id)
        c.bind(sessionID: "s1", taskID: taskID)
        c.tick(now: t0.addingTimeInterval(minutes(9)))
        #expect(c.stalledBadge == nil)
        c.tick(now: t0.addingTimeInterval(minutes(10)))
        #expect(c.stalledBadge == StalledBadge(title: "Фокус", minutes: 10))
        c.sessionsDidChange([session("s2", .waitingForApproval, at: t0.addingTimeInterval(120))], now: t0.addingTimeInterval(minutes(11)))
        #expect(c.stalledBadge == nil)
    }

    @Test
    func onboardingSurvivesOverlayCloseAndRelaunch() throws {
        let h = try make()
        let c = h.coordinator
        c.setHooksInstalled(false, now: t0)
        c.setHooksInstalled(true, now: t0.addingTimeInterval(1))
        c.overlayDidClose(now: t0.addingTimeInterval(2))
        #expect(c.card == .onboarding)

        let relaunched = try make(defaults: h.defaults)
        relaunched.coordinator.setHooksInstalled(true, now: t0)
        #expect(relaunched.coordinator.card == .onboarding)

        c.markOnboardingTaskAdded()
        c.overlayDidClose(now: t0.addingTimeInterval(3))
        #expect(c.card == nil)
        let finished = try make(defaults: h.defaults)
        finished.coordinator.setHooksInstalled(true, now: t0)
        #expect(finished.coordinator.card == nil)

        let fresh = try make()
        fresh.coordinator.setHooksInstalled(true, now: t0)
        #expect(fresh.coordinator.card == nil)
    }
}
