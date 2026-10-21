import Foundation
import OpenIslandCore

public struct TurnTracker: Sendable {
    private struct Turn: Sendable {
        var startedAt: Date
        var lastPrompt: String?
        var fired: Bool
        var running: Bool
    }

    public var delay: TimeInterval
    private var turns: [String: Turn] = [:]
    private var snoozedUntil: [String: Date] = [:]

    public init(delay: TimeInterval = 15) {
        self.delay = delay
    }

    public mutating func observe(sessionID: String, phase: SessionPhase, lastUserPrompt: String?, at now: Date) {
        guard phase == .running else {
            turns[sessionID]?.running = false
            return
        }
        if var turn = turns[sessionID], turn.running {
            if let previous = turn.lastPrompt, let lastUserPrompt, previous != lastUserPrompt {
                turns[sessionID] = Turn(startedAt: now, lastPrompt: lastUserPrompt, fired: false, running: true)
            } else {
                turn.lastPrompt = turn.lastPrompt ?? lastUserPrompt
                turns[sessionID] = turn
            }
            return
        }
        turns[sessionID] = Turn(startedAt: now, lastPrompt: lastUserPrompt, fired: false, running: true)
    }

    public mutating func forget(sessionID: String) {
        turns[sessionID] = nil
        snoozedUntil[sessionID] = nil
    }

    public mutating func snooze(sessionID: String, until: Date) {
        snoozedUntil[sessionID] = until
    }

    public mutating func peekDue(now: Date) -> [String] {
        var due: [String] = []
        for (id, turn) in turns where turn.running && !turn.fired && now.timeIntervalSince(turn.startedAt) >= delay {
            if let until = snoozedUntil[id], until > now {
                turns[id]?.fired = true
                continue
            }
            due.append(id)
        }
        return due.sorted()
    }

    public mutating func markFired(sessionID: String) {
        turns[sessionID]?.fired = true
    }

    public mutating func takeDueSessions(now: Date) -> [String] {
        let due = peekDue(now: now)
        for id in due {
            markFired(sessionID: id)
        }
        return due
    }
}
