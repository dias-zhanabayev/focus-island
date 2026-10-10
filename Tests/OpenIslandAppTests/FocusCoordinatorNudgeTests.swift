import FocusCore
import Foundation
import OpenIslandCore
import Testing
@testable import OpenIslandApp

final class FiredCounter: @unchecked Sendable {
    var count = 0
}

@MainActor
struct FocusCoordinatorNudgeTests {
    let t0 = Date(timeIntervalSince1970: 90_000)

    func make() throws -> FocusCoordinator {
        let coordinator = FocusCoordinator(
            store: try FocusStore.inMemory(),
            defaults: UserDefaults(suiteName: "focus-nudge-\(UUID().uuidString)")!,
            launcher: RecordingLauncher(),
            promptSender: RecordingPromptSender(result: .sent),
            gitDiff: StubGitDiff(files: []),
            clipboard: { _ in },
            runBackfill: false
        )
        coordinator.start(initialSessions: [], now: t0)
        return coordinator
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

    @Test
    func distractionTargetTracksBrowserDomainAndClears() throws {
        let c = try make()
        c.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        let url = URL(string: "https://www.youtube.com/watch?v=1")
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Safari", url: url, at: t0))
        #expect(c.distractionTarget == "youtube.com")
        #expect(c.distractionStartedAt == t0)
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Safari", url: url, at: t0.addingTimeInterval(25)))
        #expect(c.card == .nudge)
        #expect(c.distractionStartedAt == t0)
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Terminal", url: nil, at: t0.addingTimeInterval(30)))
        #expect(c.distractionTarget == nil)
        #expect(c.distractionStartedAt == nil)
    }

    @Test
    func distractionTargetFallsBackToBundleIDForUnknownApp() throws {
        let c = try make()
        let bundleID = "com.example.NotRunning.Distraction"
        c.settings.stopList = StopList(appBundleIDs: [bundleID], domains: [])
        c.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        c.frontmostDidChange(FrontmostSample(bundleID: bundleID, url: nil, at: t0))
        #expect(c.distractionTarget == bundleID)
        #expect(c.distractionStartedAt == t0)
        #expect(FocusCoordinator.distractionName(domain: nil, bundleID: bundleID) == bundleID)
        #expect(FocusCoordinator.distractionName(domain: "x.com", bundleID: bundleID) == "x.com")
    }

    @Test
    func nudgeStateCapturedWhenPresented() throws {
        let c = try make()
        c.sessionsDidChange([
            session("run", .running, at: t0),
            session("wait", .waitingForApproval, at: t0.addingTimeInterval(1)),
        ], now: t0.addingTimeInterval(1))
        let url = URL(string: "https://youtube.com")
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Safari", url: url, at: t0.addingTimeInterval(2)))
        c.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Safari", url: url, at: t0.addingTimeInterval(30)))
        #expect(c.card == .nudge)
        #expect(c.nudgeSessionIDState == "run")
        guard case let .attend(id, _, _) = c.nudgeSuggestionState else {
            Issue.record("expected attend suggestion")
            return
        }
        #expect(id == "wait")
    }

    @Test
    func turnDurationCoversWaitsAndRestartsOnNewPrompt() throws {
        let c = try make()
        func s(_ phase: SessionPhase, _ at: TimeInterval, prompt: String = "p") -> AgentSession {
            var session = self.session("s1", phase, at: t0.addingTimeInterval(at))
            session.claudeMetadata?.lastUserPrompt = prompt
            return session
        }
        c.sessionsDidChange([s(.running, 0)], now: t0)
        c.sessionsDidChange([s(.waitingForApproval, 480)], now: t0.addingTimeInterval(480))
        #expect(c.turnElapsed(sessionID: "s1", now: t0.addingTimeInterval(500)) == 500)
        c.sessionsDidChange([s(.running, 490)], now: t0.addingTimeInterval(490))
        c.sessionsDidChange([s(.completed, 600)], now: t0.addingTimeInterval(600))
        #expect(c.lastTurnDuration(sessionID: "s1") == 600)
        #expect(c.turnElapsed(sessionID: "s1", now: t0.addingTimeInterval(610)) == nil)

        c.sessionsDidChange([s(.running, 700, prompt: "a")], now: t0.addingTimeInterval(700))
        c.sessionsDidChange([s(.running, 760, prompt: "b")], now: t0.addingTimeInterval(760))
        #expect(c.turnElapsed(sessionID: "s1", now: t0.addingTimeInterval(770)) == 10)
    }

    @Test
    func nudgeSuggestionUsesMostRecentRunningSessionAndLimitsToOne() throws {
        let c = try make()
        c.createTask(title: "Миграция", column: .todo, projectPath: "/tmp/proj")
        c.createTask(title: "Другая", column: .todo, projectPath: nil)
        c.sessionsDidChange([
            session("old", .running, at: t0),
            session("new", .running, at: t0.addingTimeInterval(10)),
            session("wait", .waitingForApproval, at: t0.addingTimeInterval(5)),
        ], now: t0.addingTimeInterval(10))
        #expect(c.nudgeSessionID() == "new")
        guard case let .attend(sessionID, _, _) = c.nudgeSuggestion(now: t0.addingTimeInterval(11)) else {
            Issue.record("expected attend suggestion, got \(String(describing: c.nudgeSuggestion(now: t0)))")
            return
        }
        #expect(sessionID == "wait")
    }

    @Test
    func nudgeSuggestionNilWithoutRunningSession() throws {
        let c = try make()
        c.sessionsDidChange([session("s1", .completed, at: t0)], now: t0)
        #expect(c.nudgeSessionID() == nil)
        #expect(c.nudgeSuggestion(now: t0) == nil)
    }

    @Test
    func turnElapsedStartsWhenSessionBecomesRunning() throws {
        let c = try make()
        c.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        #expect(c.turnElapsed(sessionID: "s1", now: t0.addingTimeInterval(70)) == 70)
        c.sessionsDidChange([session("s1", .running, at: t0.addingTimeInterval(20))], now: t0.addingTimeInterval(20))
        #expect(c.turnElapsed(sessionID: "s1", now: t0.addingTimeInterval(70)) == 70)
        c.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(80))], now: t0.addingTimeInterval(80))
        #expect(c.turnElapsed(sessionID: "s1", now: t0.addingTimeInterval(90)) == nil)
        #expect(c.lastTurnDuration(sessionID: "s1") == 80)
        c.sessionsDidChange([session("s1", .running, at: t0.addingTimeInterval(100))], now: t0.addingTimeInterval(100))
        #expect(c.turnElapsed(sessionID: "s1", now: t0.addingTimeInterval(110)) == 10)
    }

    @Test
    func focusElapsedMinutesChangesOnlyAcrossMinuteBoundary() throws {
        let c = try make()
        c.createTask(title: "Фокус", column: .todo, projectPath: nil)
        c.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        let taskID = try #require(c.board.tasks.first { $0.title == "Фокус" }?.id)
        c.bind(sessionID: "s1", taskID: taskID)
        c.tick(now: t0.addingTimeInterval(61))
        #expect(c.focusElapsedMinutes == 1)

        let fired = FiredCounter()
        withObservationTracking {
            _ = c.focusElapsedMinutes
        } onChange: {
            fired.count += 1
        }
        c.tick(now: t0.addingTimeInterval(90))
        #expect(fired.count == 0)
        c.tick(now: t0.addingTimeInterval(121))
        #expect(fired.count == 1)
        #expect(c.focusElapsedMinutes == 2)
    }
}
