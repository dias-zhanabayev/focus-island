import Foundation
import GRDB

public enum PomodoroPhase: String, Codable, Sendable {
    case focus
    case `break`
}

public struct Pomodoro: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "pomodoros"

    public var id: String
    public var taskId: String?
    public var phase: PomodoroPhase
    public var plannedSeconds: Int
    public var startedAt: Date
    public var endedAt: Date?
    public var pausedSeconds: Double
    public var pausedAt: Date?
    public var completed: Bool

    public init(
        id: String,
        taskId: String?,
        phase: PomodoroPhase,
        plannedSeconds: Int,
        startedAt: Date,
        endedAt: Date? = nil,
        pausedSeconds: Double = 0,
        pausedAt: Date? = nil,
        completed: Bool = false
    ) {
        self.id = id
        self.taskId = taskId
        self.phase = phase
        self.plannedSeconds = plannedSeconds
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.pausedSeconds = pausedSeconds
        self.pausedAt = pausedAt
        self.completed = completed
    }
}

public enum PomodoroClock {
    public static func elapsed(_ pomodoro: Pomodoro, now: Date) -> TimeInterval {
        let ongoingPause = pomodoro.pausedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
        return max(0, now.timeIntervalSince(pomodoro.startedAt) - pomodoro.pausedSeconds - ongoingPause)
    }

    public static func remaining(_ pomodoro: Pomodoro, now: Date) -> TimeInterval {
        max(0, TimeInterval(pomodoro.plannedSeconds) - elapsed(pomodoro, now: now))
    }

    public static func progress(_ pomodoro: Pomodoro, now: Date) -> Double {
        guard pomodoro.plannedSeconds > 0 else { return 1 }
        return min(1, max(0, elapsed(pomodoro, now: now) / TimeInterval(pomodoro.plannedSeconds)))
    }

    public static func expiryDate(_ pomodoro: Pomodoro) -> Date {
        pomodoro.startedAt.addingTimeInterval(TimeInterval(pomodoro.plannedSeconds) + pomodoro.pausedSeconds)
    }

    public static func isExpired(_ pomodoro: Pomodoro, now: Date) -> Bool {
        guard pomodoro.pausedAt == nil else { return false }
        return now >= expiryDate(pomodoro)
    }

    public static func cycleIndex(completedToday: Int, cycle: Int) -> Int {
        guard cycle > 0 else { return 1 }
        return max(0, completedToday) % cycle + 1
    }
}

public final class PomodoroStore: Sendable {
    private let store: FocusStore

    public init(store: FocusStore) {
        self.store = store
    }

    @discardableResult
    public func start(taskID: String?, phase: PomodoroPhase, plannedSeconds: Int, now: Date = .now) throws -> Pomodoro {
        try store.dbQueue.write { db in
            try Self.finishActive(completed: false, taskID: nil, at: { _ in now }, db: db)
            let pomodoro = Pomodoro(id: UUID().uuidString, taskId: taskID, phase: phase, plannedSeconds: plannedSeconds, startedAt: now)
            try pomodoro.insert(db)
            return pomodoro
        }
    }

    @discardableResult
    public func pause(now: Date = .now) throws -> Pomodoro? {
        try store.dbQueue.write { db in
            guard var pomodoro = try Self.fetchActive(db), pomodoro.pausedAt == nil else {
                return try Self.fetchActive(db)
            }
            pomodoro.pausedAt = now
            try pomodoro.update(db)
            return pomodoro
        }
    }

    @discardableResult
    public func resume(now: Date = .now) throws -> Pomodoro? {
        try store.dbQueue.write { db in
            guard var pomodoro = try Self.fetchActive(db), let pausedAt = pomodoro.pausedAt else {
                return try Self.fetchActive(db)
            }
            pomodoro.pausedSeconds += max(0, now.timeIntervalSince(pausedAt))
            pomodoro.pausedAt = nil
            try pomodoro.update(db)
            return pomodoro
        }
    }

    @discardableResult
    public func finish(completed: Bool, now: Date = .now) throws -> Pomodoro? {
        try store.dbQueue.write { db in
            try Self.finishActive(completed: completed, taskID: nil, at: { _ in now }, db: db).first
        }
    }

    public func pomodoro(id: String) throws -> Pomodoro? {
        try store.dbQueue.read { db in try Pomodoro.fetchOne(db, key: id) }
    }

    @discardableResult
    public func extendActive(bySeconds seconds: Int) throws -> Pomodoro? {
        try store.dbQueue.write { db in
            guard var pomodoro = try Self.fetchActive(db) else { return nil }
            pomodoro.plannedSeconds = max(0, pomodoro.plannedSeconds + seconds)
            try pomodoro.update(db)
            return pomodoro
        }
    }

    public func active() throws -> Pomodoro? {
        try store.dbQueue.read { db in try Self.fetchActive(db) }
    }

    public func completedFocusCount(taskID: String, day: Date, startedBefore: Date = .distantFuture, calendar: Calendar = .current) throws -> Int {
        try countCompletedFocus(taskID: taskID, day: day, startedBefore: startedBefore, calendar: calendar)
    }

    public func completedFocusCount(day: Date, calendar: Calendar = .current) throws -> Int {
        try countCompletedFocus(taskID: nil, day: day, startedBefore: .distantFuture, calendar: calendar)
    }

    private func countCompletedFocus(taskID: String?, day: Date, startedBefore: Date, calendar: Calendar) throws -> Int {
        let range = Self.dayRange(day, calendar: calendar)
        return try store.dbQueue.read { db in
            var request = Pomodoro
                .filter(Column("phase") == PomodoroPhase.focus.rawValue && Column("completed") == true)
                .filter(Column("startedAt") >= range.lowerBound && Column("startedAt") < min(range.upperBound, startedBefore))
            if let taskID {
                request = request.filter(Column("taskId") == taskID)
            }
            return try request.fetchCount(db)
        }
    }

    public func focusSeconds(taskID: String, day: Date, calendar: Calendar = .current) throws -> TimeInterval {
        let range = Self.dayRange(day, calendar: calendar)
        let rows = try store.dbQueue.read { db in
            try Pomodoro
                .filter(Column("taskId") == taskID && Column("phase") == PomodoroPhase.focus.rawValue && Column("endedAt") != nil)
                .filter(Column("startedAt") >= range.lowerBound && Column("startedAt") < range.upperBound)
                .fetchAll(db)
        }
        return rows.reduce(0) { total, row in
            guard let endedAt = row.endedAt else { return total }
            return total + max(0, endedAt.timeIntervalSince(row.startedAt) - row.pausedSeconds)
        }
    }

    @discardableResult
    public func recoverExpired(now: Date = .now) throws -> Pomodoro? {
        try store.dbQueue.write { db in
            guard let pomodoro = try Self.fetchActive(db), PomodoroClock.isExpired(pomodoro, now: now) else { return nil }
            return try Self.finishActive(completed: true, taskID: nil, at: PomodoroClock.expiryDate, db: db).first
        }
    }

    static func stopForDeletedTask(taskID: String, now: Date, db: Database) throws {
        try finishActive(completed: false, taskID: taskID, at: { _ in now }, db: db)
        try db.execute(sql: "UPDATE pomodoros SET taskId = NULL WHERE taskId = ?", arguments: [taskID])
    }

    private static func fetchActive(_ db: Database) throws -> Pomodoro? {
        try Pomodoro.filter(Column("endedAt") == nil).order(Column("startedAt").desc).fetchOne(db)
    }

    @discardableResult
    private static func finishActive(completed: Bool, taskID: String?, at endDate: (Pomodoro) -> Date, db: Database) throws -> [Pomodoro] {
        var request = Pomodoro.filter(Column("endedAt") == nil)
        if let taskID {
            request = request.filter(Column("taskId") == taskID)
        }
        var finished: [Pomodoro] = []
        for var pomodoro in try request.fetchAll(db) {
            let end = endDate(pomodoro)
            if let pausedAt = pomodoro.pausedAt {
                pomodoro.pausedSeconds += max(0, end.timeIntervalSince(pausedAt))
                pomodoro.pausedAt = nil
            }
            pomodoro.endedAt = end
            pomodoro.completed = completed
            try pomodoro.update(db)
            finished.append(pomodoro)
        }
        return finished
    }

    private static func dayRange(_ day: Date, calendar: Calendar) -> Range<Date> {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return start..<end
    }
}
