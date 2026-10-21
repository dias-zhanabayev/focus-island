import FocusCore
import Foundation
import OpenIslandCore
import Testing
@testable import OpenIslandApp

@MainActor
struct FocusCoordinatorAutoBreakTests {
    let t0 = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 9))!

    final class Box {
        var presented = 0
        var sounds: [String] = []
    }

    struct Harness {
        let coordinator: FocusCoordinator
        let box: Box
    }

    func make() throws -> Harness {
        let store = try FocusStore.inMemory()
        let defaults = UserDefaults(suiteName: "focus-autobreak-\(UUID().uuidString)")!
        let coordinator = FocusCoordinator(store: store, defaults: defaults, launcher: RecordingLauncher(), promptSender: RecordingPromptSender(result: .unsupported), gitDiff: StubGitDiff(files: []), clipboard: { _ in }, runBackfill: false)
        coordinator.settings.dayStartEnabled = false
        coordinator.settings.nextActionEnabled = false
        let box = Box()
        coordinator.presentCard = { box.presented += 1 }
        coordinator.playSound = { box.sounds.append($0) }
        coordinator.start(initialSessions: [], now: t0)
        return Harness(coordinator: coordinator, box: box)
    }

    func session(_ id: String, _ phase: SessionPhase, at date: Date) -> AgentSession {
        var session = AgentSession(
            id: id, title: "title-\(id)", tool: .claudeCode, origin: .live, attachmentState: .attached, phase: phase, summary: "", updatedAt: date, firstSeenAt: date,
            jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "proj", paneTitle: "", workingDirectory: "/tmp/proj"),
            claudeMetadata: ClaudeSessionMetadata(initialUserPrompt: "p", lastUserPrompt: "p", startupSource: .startup)
        )
        session.isHookManaged = true
        return session
    }

    func task(_ h: Harness, _ title: String, column: BoardColumn = .inProgress) throws -> String {
        h.coordinator.createTask(title: title, column: column, projectPath: "/tmp/proj")
        return try #require(h.coordinator.board.tasks.first { $0.title == title }?.id)
    }

    func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    @Test
    func focusEndStartsCountdownWithSoundThenBreakStartsByItself() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        c.tick(now: at(300))
        guard case .pomodoroEnd = c.card else {
            Issue.record("expected pomodoroEnd, got \(String(describing: c.card))")
            return
        }
        #expect(c.breakCountdownEndsAt == at(300 + FocusCoordinator.breakCountdownSeconds))
        #expect(c.breakCountdownRemaining(now: at(301)) == 4)
        #expect(h.box.sounds == [FocusCoordinator.breakSoundName])
        c.tick(now: at(304))
        #expect(c.pomodoro?.phase == .focus || c.pomodoro == nil)
        #expect(c.card?.pomodoroID != nil)
        c.tick(now: at(305))
        #expect(c.pomodoro?.phase == .break)
        #expect(c.pomodoro?.plannedSeconds == c.settings.pomodoroBreakMinutes * 60)
        #expect(c.card == nil)
        #expect(c.breakCountdownEndsAt == nil)
    }

    @Test
    func chosenBreakLengthIsUsedByAutoStart() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        c.tick(now: at(300))
        c.chooseBreakMinutes(15)
        c.tick(now: at(306))
        #expect(c.pomodoro?.plannedSeconds == 15 * 60)
    }

    @Test
    func cancelStopsCountdownAndKeepsCard() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        c.tick(now: at(300))
        c.cancelBreakCountdown()
        #expect(c.breakCountdownEndsAt == nil)
        c.tick(now: at(400))
        #expect(c.pomodoro == nil)
        guard case .pomodoroEnd = c.card else {
            Issue.record("expected pomodoroEnd to stay")
            return
        }
    }

    @Test
    func countdownLeftFollowsTicksForThePill() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        c.tick(now: at(300))
        #expect(c.breakCountdownLeft == 5)
        c.tick(now: at(302))
        #expect(c.breakCountdownLeft == 3)
        c.cancelBreakCountdown()
        #expect(c.breakCountdownLeft == nil)
        c.tick(now: at(303))
        #expect(c.breakCountdownLeft == nil)
    }

    @Test
    func autoBreakOffMeansNoCountdownAndNoSound() throws {
        let h = try make()
        let c = h.coordinator
        c.settings.autoBreakEnabled = false
        let a = try task(h, "A")
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        c.tick(now: at(300))
        #expect(c.breakCountdownEndsAt == nil)
        #expect(h.box.sounds.isEmpty)
        c.tick(now: at(400))
        #expect(c.pomodoro == nil)
    }

    @Test
    func soundOffKeepsCountdownSilent() throws {
        let h = try make()
        let c = h.coordinator
        c.settings.breakSoundEnabled = false
        let a = try task(h, "A")
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        c.tick(now: at(300))
        #expect(c.breakCountdownEndsAt != nil)
        #expect(h.box.sounds.isEmpty)
    }

    @Test
    func manualActionsClearCountdown() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        c.tick(now: at(300))
        c.continueFocus(nextStep: nil, minutes: 25, now: at(301))
        #expect(c.breakCountdownEndsAt == nil)
        c.tick(now: at(310))
        #expect(c.pomodoro?.phase == .focus)
    }

    @Test
    func finishBreakEarlyShowsBreakEndCard() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.startPomodoro(taskID: a, minutes: 5, now: at(0))
        c.tick(now: at(300))
        c.startBreak(nextStep: nil, minutes: 10, now: at(301))
        c.finishBreakEarly(now: at(400))
        #expect(c.pomodoro == nil)
        guard case .breakEnd = c.card else {
            Issue.record("expected breakEnd, got \(String(describing: c.card))")
            return
        }
    }

    @Test
    func launchOpensIslandWithoutCard() throws {
        let h = try make()
        let c = h.coordinator
        _ = try task(h, "A")
        let before = h.box.presented
        c.offerTaskChoiceOnLaunch(now: at(0))
        #expect(c.card == nil)
        #expect(h.box.presented == before + 1)
        #expect(c.currentTask == nil)
    }

    @Test
    func bindingNewSessionWithoutFocusTakesTheTask() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.offerTaskChoiceOnLaunch(now: at(0))
        c.sessionsDidChange([session("new", .running, at: at(1))], now: at(1))
        #expect(c.pendingBindingSessionIDs == ["new"])
        c.bindNewSession(sessionID: "new", taskID: a, now: at(2))
        #expect(c.taskID(forSession: "new") == a)
        #expect(c.currentTask?.id == a)
        #expect(c.pendingBindingSessionIDs.isEmpty)
    }

    @Test
    func bindingNewSessionInFocusKeepsFocus() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        let b = try task(h, "B")
        c.takeTask(taskID: a, now: at(0))
        c.sessionsDidChange([session("new", .running, at: at(1))], now: at(1))
        c.bindNewSession(sessionID: "new", taskID: b, now: at(2))
        #expect(c.currentTask?.id == a)
    }

    @Test
    func completionOpensIslandOnlyForFocusTaskSessions() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.offerTaskChoiceOnLaunch(now: at(0))
        c.sessionsDidChange([session("mine", .running, at: at(0)), session("other", .running, at: at(0))], now: at(0))
        c.bind(sessionID: "mine", taskID: a, now: at(1))
        #expect(!c.opensIslandOnCompletion(sessionID: "mine"))
        c.takeTask(taskID: a, now: at(2))
        #expect(c.opensIslandOnCompletion(sessionID: "mine"))
        #expect(!c.opensIslandOnCompletion(sessionID: "other"))
    }
}
