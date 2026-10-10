import Foundation

public enum PresenceEvent: Sendable {
    case screenLocked
    case screenUnlocked
    case screensSlept
    case screensWoke
    case sessionResigned
    case sessionActivated
}

public enum PresenceTransition: Equatable, Sendable {
    case away
    case back
}

public struct PresenceTracker: Sendable {
    private enum Reason: Hashable, Sendable {
        case locked
        case displaysAsleep
        case sessionInactive
    }

    private var reasons: Set<Reason> = []

    public init() {}

    public var isAway: Bool { !reasons.isEmpty }

    public mutating func handle(_ event: PresenceEvent) -> PresenceTransition? {
        let wasAway = isAway
        switch event {
        case .screenLocked: reasons.insert(.locked)
        case .screenUnlocked: reasons.remove(.locked)
        case .screensSlept: reasons.insert(.displaysAsleep)
        case .screensWoke: reasons.remove(.displaysAsleep)
        case .sessionResigned: reasons.insert(.sessionInactive)
        case .sessionActivated: reasons.remove(.sessionInactive)
        }
        if wasAway == isAway { return nil }
        return isAway ? .away : .back
    }
}
