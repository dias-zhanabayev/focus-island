import Foundation
import Testing
import OpenIslandCore
@testable import FocusCore

struct TurnTrackerTests {
    let t0 = Date(timeIntervalSince1970: 30_000)

    @Test
    func firesOnceAfterDelayWhileRunning() {
        var tracker = TurnTracker(delay: 15)
        tracker.observe(sessionID: "s", phase: .running, lastUserPrompt: "p1", at: t0)
        #expect(tracker.takeDueSessions(now: t0.addingTimeInterval(14)) == [])
        #expect(tracker.takeDueSessions(now: t0.addingTimeInterval(15)) == ["s"])
        #expect(tracker.takeDueSessions(now: t0.addingTimeInterval(60)) == [])
    }

    @Test
    func repeatedRunningUpdatesDoNotRestartTurn() {
        var tracker = TurnTracker(delay: 15)
        tracker.observe(sessionID: "s", phase: .running, lastUserPrompt: "p1", at: t0)
        tracker.observe(sessionID: "s", phase: .running, lastUserPrompt: "p1", at: t0.addingTimeInterval(10))
        #expect(tracker.takeDueSessions(now: t0.addingTimeInterval(15)) == ["s"])
    }

    @Test
    func promptAppearingLaterIsSameTurn() {
        var tracker = TurnTracker(delay: 15)
        tracker.observe(sessionID: "s", phase: .running, lastUserPrompt: nil, at: t0)
        tracker.observe(sessionID: "s", phase: .running, lastUserPrompt: "p1", at: t0.addingTimeInterval(5))
        #expect(tracker.takeDueSessions(now: t0.addingTimeInterval(15)) == ["s"])
    }

    @Test
    func stoppingBeforeDelayCancels() {
        var tracker = TurnTracker(delay: 15)
        tracker.observe(sessionID: "s", phase: .running, lastUserPrompt: "p1", at: t0)
        tracker.observe(sessionID: "s", phase: .completed, lastUserPrompt: "p1", at: t0.addingTimeInterval(5))
        #expect(tracker.takeDueSessions(now: t0.addingTimeInterval(20)) == [])
    }

    @Test
    func newTurnAfterCompletionFiresAgain() {
        var tracker = TurnTracker(delay: 15)
        tracker.observe(sessionID: "s", phase: .running, lastUserPrompt: "p1", at: t0)
        _ = tracker.takeDueSessions(now: t0.addingTimeInterval(15))
        tracker.observe(sessionID: "s", phase: .completed, lastUserPrompt: "p1", at: t0.addingTimeInterval(20))
        tracker.observe(sessionID: "s", phase: .running, lastUserPrompt: "p2", at: t0.addingTimeInterval(30))
        #expect(tracker.takeDueSessions(now: t0.addingTimeInterval(45)) == ["s"])
    }

    @Test
    func changedPromptWhileRunningStartsNewTurn() {
        var tracker = TurnTracker(delay: 15)
        tracker.observe(sessionID: "s", phase: .running, lastUserPrompt: "p1", at: t0)
        _ = tracker.takeDueSessions(now: t0.addingTimeInterval(15))
        tracker.observe(sessionID: "s", phase: .running, lastUserPrompt: "p2", at: t0.addingTimeInterval(20))
        #expect(tracker.takeDueSessions(now: t0.addingTimeInterval(35)) == ["s"])
    }

    @Test
    func waitingForApprovalPausesTurn() {
        var tracker = TurnTracker(delay: 15)
        tracker.observe(sessionID: "s", phase: .running, lastUserPrompt: "p1", at: t0)
        tracker.observe(sessionID: "s", phase: .waitingForApproval, lastUserPrompt: "p1", at: t0.addingTimeInterval(3))
        #expect(tracker.takeDueSessions(now: t0.addingTimeInterval(20)) == [])
        tracker.observe(sessionID: "s", phase: .running, lastUserPrompt: "p1", at: t0.addingTimeInterval(30))
        #expect(tracker.takeDueSessions(now: t0.addingTimeInterval(45)) == ["s"])
    }

    @Test
    func snoozeConsumesTurnSilently() {
        var tracker = TurnTracker(delay: 15)
        tracker.snooze(sessionID: "s", until: t0.addingTimeInterval(300))
        tracker.observe(sessionID: "s", phase: .running, lastUserPrompt: "p1", at: t0)
        #expect(tracker.takeDueSessions(now: t0.addingTimeInterval(20)) == [])
        tracker.observe(sessionID: "s", phase: .completed, lastUserPrompt: "p1", at: t0.addingTimeInterval(400))
        tracker.observe(sessionID: "s", phase: .running, lastUserPrompt: "p2", at: t0.addingTimeInterval(410))
        #expect(tracker.takeDueSessions(now: t0.addingTimeInterval(425)) == ["s"])
    }

    @Test
    func multipleDueSessionsAreSorted() {
        var tracker = TurnTracker(delay: 15)
        tracker.observe(sessionID: "b", phase: .running, lastUserPrompt: nil, at: t0)
        tracker.observe(sessionID: "a", phase: .running, lastUserPrompt: nil, at: t0)
        #expect(tracker.takeDueSessions(now: t0.addingTimeInterval(15)) == ["a", "b"])
    }

    @Test
    func peekDueKeepsTurnUntilMarkedFired() {
        var tracker = TurnTracker(delay: 15)
        tracker.observe(sessionID: "a", phase: .running, lastUserPrompt: "p1", at: t0)
        tracker.observe(sessionID: "b", phase: .running, lastUserPrompt: "p1", at: t0)
        #expect(tracker.peekDue(now: t0.addingTimeInterval(14)) == [])
        #expect(tracker.peekDue(now: t0.addingTimeInterval(15)) == ["a", "b"])
        #expect(tracker.peekDue(now: t0.addingTimeInterval(16)) == ["a", "b"])
        tracker.markFired(sessionID: "a")
        #expect(tracker.peekDue(now: t0.addingTimeInterval(17)) == ["b"])
        tracker.markFired(sessionID: "b")
        #expect(tracker.peekDue(now: t0.addingTimeInterval(18)) == [])
    }

    @Test
    func peekDueConsumesSnoozedTurnSilently() {
        var tracker = TurnTracker(delay: 15)
        tracker.snooze(sessionID: "s", until: t0.addingTimeInterval(30))
        tracker.observe(sessionID: "s", phase: .running, lastUserPrompt: "p1", at: t0)
        #expect(tracker.peekDue(now: t0.addingTimeInterval(20)) == [])
        #expect(tracker.peekDue(now: t0.addingTimeInterval(40)) == [])
    }
}
