import Foundation
import GRDB

public final class DistractionLog: Sendable {
    private let store: FocusStore

    public init(store: FocusStore) {
        self.store = store
    }

    public func save(_ episode: DistractionEpisode) throws {
        try store.dbQueue.write { db in
            var copy = episode
            try copy.insert(db)
        }
    }

    public func episodes(since: Date) throws -> [DistractionEpisode] {
        try store.dbQueue.read { db in
            try DistractionEpisode.filter(Column("startedAt") >= since).order(Column("startedAt")).fetchAll(db)
        }
    }
}

public final class NextActionLog: Sendable {
    private let store: FocusStore

    public init(store: FocusStore) {
        self.store = store
    }

    public func shown(kind: String, at date: Date) throws -> Int64 {
        try store.dbQueue.write { db in
            var event = NextActionEvent(shownAt: date, kind: kind)
            try event.insert(db)
            return event.id ?? 0
        }
    }

    public func reacted(id: Int64, at date: Date) throws {
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE next_action_events SET reactedAt = ? WHERE id = ? AND reactedAt IS NULL", arguments: [date, id])
        }
    }
}

public struct FocusStats: Equatable, Sendable {
    public var tasksDone: Int
    public var sessionsStarted: Int
    public var boundShare: Double?
    public var distractionCount: Int
    public var distractionSeconds: Double
    public var medianReactionSec: Double?

    public init(tasksDone: Int, sessionsStarted: Int, boundShare: Double?, distractionCount: Int, distractionSeconds: Double, medianReactionSec: Double?) {
        self.tasksDone = tasksDone
        self.sessionsStarted = sessionsStarted
        self.boundShare = boundShare
        self.distractionCount = distractionCount
        self.distractionSeconds = distractionSeconds
        self.medianReactionSec = medianReactionSec
    }
}

public final class StatsService: Sendable {
    private let store: FocusStore

    public init(store: FocusStore) {
        self.store = store
    }

    public func stats(since: Date) throws -> FocusStats {
        try store.dbQueue.read { db in
            let tasksDone = try FocusTask.filter(Column("boardColumn") == BoardColumn.done.rawValue && Column("doneAt") >= since).fetchCount(db)
            let sessions = try SessionRecord.filter(Column("startedAt") >= since).fetchAll(db)
            let bound = sessions.filter { $0.taskId != nil }.count
            let episodes = try DistractionEpisode.filter(Column("startedAt") >= since).fetchAll(db)
            let seconds = episodes.reduce(0.0) { total, episode in
                total + (episode.endedAt.map { $0.timeIntervalSince(episode.startedAt) } ?? 0)
            }
            let reactions = try NextActionEvent
                .filter(Column("shownAt") >= since && Column("reactedAt") != nil)
                .fetchAll(db)
                .compactMap { event in event.reactedAt.map { $0.timeIntervalSince(event.shownAt) } }
                .sorted()
            let median: Double? = reactions.isEmpty ? nil : (reactions.count % 2 == 1
                ? reactions[reactions.count / 2]
                : (reactions[reactions.count / 2 - 1] + reactions[reactions.count / 2]) / 2)
            return FocusStats(
                tasksDone: tasksDone,
                sessionsStarted: sessions.count,
                boundShare: sessions.isEmpty ? nil : Double(bound) / Double(sessions.count),
                distractionCount: episodes.count,
                distractionSeconds: seconds,
                medianReactionSec: median
            )
        }
    }
}
