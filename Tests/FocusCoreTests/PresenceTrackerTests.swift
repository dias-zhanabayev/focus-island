import Foundation
import Testing
@testable import FocusCore

struct PresenceTrackerTests {
    @Test
    func lockMakesAwayAndUnlockReturns() {
        var tracker = PresenceTracker()
        #expect(!tracker.isAway)
        #expect(tracker.handle(.screenLocked) == .away)
        #expect(tracker.isAway)
        #expect(tracker.handle(.screenLocked) == nil)
        #expect(tracker.handle(.screenUnlocked) == .back)
        #expect(!tracker.isAway)
        #expect(tracker.handle(.screenUnlocked) == nil)
    }

    @Test
    func awayUntilEveryReasonClears() {
        var tracker = PresenceTracker()
        #expect(tracker.handle(.screensSlept) == .away)
        #expect(tracker.handle(.screenLocked) == nil)
        #expect(tracker.handle(.screensWoke) == nil)
        #expect(tracker.isAway)
        #expect(tracker.handle(.sessionResigned) == nil)
        #expect(tracker.handle(.screenUnlocked) == nil)
        #expect(tracker.handle(.sessionActivated) == .back)
    }

    @Test
    func wakeWithoutSleepIsIgnored() {
        var tracker = PresenceTracker()
        #expect(tracker.handle(.screensWoke) == nil)
        #expect(tracker.handle(.sessionActivated) == nil)
        #expect(!tracker.isAway)
    }
}
