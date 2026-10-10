import Foundation
import GRDB

public final class ActivityLog: Sendable {
    private let store: FocusStore

    public init(store: FocusStore) {
        self.store = store
    }

    @discardableResult
    public func open(kind: ActivityKind, sessionID: String?, taskID: String?, at date: Date) throws -> Int64 {
        try store.dbQueue.write { db in
            var span = ActivitySpan(kind: kind, sessionId: sessionID, taskId: taskID, startedAt: date)
            try span.insert(db)
            return span.id ?? 0
        }
    }

    public func close(id: Int64, at date: Date) throws {
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE activity_spans SET endedAt = MAX(startedAt, ?) WHERE id = ? AND endedAt IS NULL", arguments: [date, id])
        }
    }

    public func reassign(id: Int64, taskID: String?) throws {
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE activity_spans SET taskId = ? WHERE id = ? AND endedAt IS NULL", arguments: [taskID, id])
        }
    }

    public func closeAllOpen(at date: Date) throws {
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE activity_spans SET endedAt = MAX(startedAt, ?) WHERE endedAt IS NULL", arguments: [date])
        }
    }

    public func closeAllOpenAtStart() throws {
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE activity_spans SET endedAt = startedAt WHERE endedAt IS NULL")
        }
    }

    public func spans(taskID: String, to: Date) throws -> [ActivitySpan] {
        try store.dbQueue.read { db in
            let rows = try ActivitySpan
                .filter(Column("taskId") == taskID && Column("startedAt") < to)
                .order(Column("startedAt"), Column("id"))
                .fetchAll(db)
            return rows.map { span in
                var copy = span
                if copy.endedAt == nil { copy.endedAt = to }
                return copy
            }
        }
    }

    public func spans(from: Date, to: Date) throws -> [ActivitySpan] {
        try store.dbQueue.read { db in
            let rows = try ActivitySpan
                .filter(Column("startedAt") < to && (Column("endedAt") == nil || Column("endedAt") > from))
                .order(Column("startedAt"), Column("id"))
                .fetchAll(db)
            return rows.map { span in
                var copy = span
                if copy.endedAt == nil { copy.endedAt = to }
                return copy
            }
        }
    }
}

public struct LaneSegment: Equatable, Sendable {
    public let kind: ActivityKind
    public let start: Date
    public let end: Date

    public init(kind: ActivityKind, start: Date, end: Date) {
        self.kind = kind
        self.start = start
        self.end = end
    }
}

public struct TaskLane: Equatable, Sendable, Identifiable {
    public let id: String
    public let taskID: String?
    public let title: String
    public let segments: [LaneSegment]

    public init(id: String, taskID: String?, title: String, segments: [LaneSegment]) {
        self.id = id
        self.taskID = taskID
        self.title = title
        self.segments = segments
    }
}

public struct DayReport: Equatable, Sendable {
    public let youSeconds: TimeInterval
    public let claudeSeconds: TimeInterval
    public let waitingSeconds: TimeInterval
    public let distractionSeconds: TimeInterval
    public let distractionCount: Int
    public let returnedCount: Int
    public let maxParallel: Int
    public let firstAt: Date?
    public let lastAt: Date?
    public let lanes: [TaskLane]
    public let distractionLane: [LaneSegment]
    public let activeTaskIDs: Set<String>

    public init(youSeconds: TimeInterval, claudeSeconds: TimeInterval, waitingSeconds: TimeInterval, distractionSeconds: TimeInterval, distractionCount: Int, returnedCount: Int, maxParallel: Int, firstAt: Date?, lastAt: Date?, lanes: [TaskLane], distractionLane: [LaneSegment], activeTaskIDs: Set<String> = []) {
        self.youSeconds = youSeconds
        self.claudeSeconds = claudeSeconds
        self.waitingSeconds = waitingSeconds
        self.distractionSeconds = distractionSeconds
        self.distractionCount = distractionCount
        self.returnedCount = returnedCount
        self.maxParallel = maxParallel
        self.firstAt = firstAt
        self.lastAt = lastAt
        self.lanes = lanes
        self.distractionLane = distractionLane
        self.activeTaskIDs = activeTaskIDs
    }
}

public struct DayBar: Equatable, Sendable {
    public let day: Date
    public let youSeconds: TimeInterval
    public let waitingSeconds: TimeInterval
    public let distractionSeconds: TimeInterval

    public init(day: Date, youSeconds: TimeInterval, waitingSeconds: TimeInterval, distractionSeconds: TimeInterval) {
        self.day = day
        self.youSeconds = youSeconds
        self.waitingSeconds = waitingSeconds
        self.distractionSeconds = distractionSeconds
    }
}

public struct TaskTimeRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let taskID: String?
    public let title: String
    public let projectName: String?
    public let seconds: TimeInterval
    public let sessions: Int
    public let isDone: Bool

    public init(id: String, taskID: String?, title: String, projectName: String?, seconds: TimeInterval, sessions: Int, isDone: Bool) {
        self.id = id
        self.taskID = taskID
        self.title = title
        self.projectName = projectName
        self.seconds = seconds
        self.sessions = sessions
        self.isDone = isDone
    }
}

public struct WeekReport: Equatable, Sendable {
    public let days: [DayBar]
    public let tasksDone: Int
    public let sessions: Int
    public let boundShare: Double?
    public let waitingSeconds: TimeInterval
    public let averageWaitSeconds: TimeInterval?
    public let distractionSeconds: TimeInterval
    public let rows: [TaskTimeRow]

    public init(days: [DayBar], tasksDone: Int, sessions: Int, boundShare: Double?, waitingSeconds: TimeInterval, averageWaitSeconds: TimeInterval?, distractionSeconds: TimeInterval, rows: [TaskTimeRow]) {
        self.days = days
        self.tasksDone = tasksDone
        self.sessions = sessions
        self.boundShare = boundShare
        self.waitingSeconds = waitingSeconds
        self.averageWaitSeconds = averageWaitSeconds
        self.distractionSeconds = distractionSeconds
        self.rows = rows
    }
}

public enum ReportBuilder {
    private static let laneCap = 6
    private static let noTaskTitle = "Без задачи"
    private static let noTaskID = "none"

    private struct Clipped {
        let kind: ActivityKind
        let taskID: String?
        let start: Date
        let end: Date
    }

    private static func clip(_ spans: [ActivitySpan], from: Date, to: Date) -> [Clipped] {
        spans.compactMap { span in
            guard span.kind != .distraction else { return nil }
            let start = max(span.startedAt, from)
            let end = min(span.endedAt ?? to, to)
            guard end > start else { return nil }
            return Clipped(kind: span.kind, taskID: span.taskId, start: start, end: end)
        }
    }

    private static func clip(_ episodes: [DistractionEpisode], from: Date, to: Date) -> [(episode: DistractionEpisode, start: Date, end: Date)] {
        episodes.compactMap { episode in
            let start = max(episode.startedAt, from)
            let end = min(episode.endedAt ?? to, to)
            guard end > start else { return nil }
            return (episode, start, end)
        }
    }

    private static func unionSeconds(_ intervals: [(Date, Date)]) -> TimeInterval {
        let sorted = intervals.sorted { $0.0 < $1.0 }
        var total: TimeInterval = 0
        var currentStart: Date?
        var currentEnd: Date?
        for (start, end) in sorted {
            if let cs = currentStart, let ce = currentEnd {
                if start <= ce {
                    currentEnd = max(ce, end)
                } else {
                    total += ce.timeIntervalSince(cs)
                    currentStart = start
                    currentEnd = end
                }
            } else {
                currentStart = start
                currentEnd = end
            }
        }
        if let cs = currentStart, let ce = currentEnd {
            total += ce.timeIntervalSince(cs)
        }
        return total
    }

    private static func maxOverlap(_ intervals: [(Date, Date)]) -> Int {
        var events: [(Date, Int)] = []
        for (start, end) in intervals {
            events.append((start, 1))
            events.append((end, -1))
        }
        events.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        var current = 0
        var best = 0
        for (_, delta) in events {
            current += delta
            best = max(best, current)
        }
        return best
    }

    public static func day(spans: [ActivitySpan], episodes: [DistractionEpisode], tasks: [FocusTask], dayStart: Date, dayEnd: Date) -> DayReport {
        let clipped = clip(spans, from: dayStart, to: dayEnd)
        let clippedEpisodes = clip(episodes, from: dayStart, to: dayEnd)

        func intervals(_ kind: ActivityKind) -> [(Date, Date)] {
            clipped.filter { $0.kind == kind }.map { ($0.start, $0.end) }
        }

        let distractionIntervals = clippedEpisodes.map { ($0.start, $0.end) }
        let allStarts = clipped.map(\.start) + clippedEpisodes.map(\.start)
        let allEnds = clipped.map(\.end) + clippedEpisodes.map(\.end)

        var perTask: [String?: [LaneSegment]] = [:]
        for item in clipped {
            perTask[item.taskID, default: []].append(LaneSegment(kind: item.kind, start: item.start, end: item.end))
        }
        let titles = Dictionary(tasks.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let ranked = perTask.map { key, segments -> (key: String?, segments: [LaneSegment], seconds: TimeInterval, first: Date) in
            let sorted = segments.sorted { $0.start < $1.start }
            let seconds = sorted.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
            return (key, sorted, seconds, sorted[0].start)
        }.sorted { lhs, rhs in
            if lhs.seconds != rhs.seconds { return lhs.seconds > rhs.seconds }
            if lhs.first != rhs.first { return lhs.first < rhs.first }
            return (lhs.key ?? "") < (rhs.key ?? "")
        }

        var lanes: [TaskLane] = ranked.prefix(laneCap).map { entry in
            if let key = entry.key {
                return TaskLane(id: key, taskID: key, title: titles[key] ?? key, segments: entry.segments)
            }
            return TaskLane(id: noTaskID, taskID: nil, title: noTaskTitle, segments: entry.segments)
        }
        let rest = ranked.dropFirst(laneCap)
        if !rest.isEmpty {
            let merged = rest.flatMap(\.segments).sorted { $0.start < $1.start }
            lanes.append(TaskLane(id: "other", taskID: nil, title: "Другие", segments: merged))
        }

        return DayReport(
            youSeconds: unionSeconds(intervals(.you)),
            claudeSeconds: unionSeconds(intervals(.claude)),
            waitingSeconds: unionSeconds(intervals(.waiting)),
            distractionSeconds: unionSeconds(distractionIntervals),
            distractionCount: clippedEpisodes.count,
            returnedCount: clippedEpisodes.filter { $0.episode.returnedWithinSec != nil }.count,
            maxParallel: maxOverlap(intervals(.claude)),
            firstAt: allStarts.min(),
            lastAt: allEnds.max(),
            lanes: lanes,
            distractionLane: clippedEpisodes
                .sorted { $0.start < $1.start }
                .map { LaneSegment(kind: .distraction, start: $0.start, end: $0.end) },
            activeTaskIDs: Set(ranked.compactMap(\.key))
        )
    }

    public static func week(spans: [ActivitySpan], episodes: [DistractionEpisode], tasks: [FocusTask], sessions: [SessionRecord], weekStart: Date, calendar: Calendar) -> WeekReport {
        let starts = (0..<7).map { calendar.date(byAdding: .day, value: $0, to: weekStart) ?? weekStart.addingTimeInterval(Double($0) * 86_400) }
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart.addingTimeInterval(7 * 86_400)

        let days = starts.enumerated().map { index, start -> DayBar in
            let end = index + 1 < starts.count ? starts[index + 1] : weekEnd
            let report = day(spans: spans, episodes: episodes, tasks: tasks, dayStart: start, dayEnd: end)
            return DayBar(day: start, youSeconds: report.youSeconds, waitingSeconds: report.waitingSeconds, distractionSeconds: report.distractionSeconds)
        }

        let clipped = clip(spans, from: weekStart, to: weekEnd)
        let waits = clipped.filter { $0.kind == .waiting }.map { $0.end.timeIntervalSince($0.start) }
        let weekSessions = sessions.filter { $0.startedAt >= weekStart && $0.startedAt < weekEnd }
        let bound = weekSessions.filter { $0.taskId != nil }.count
        let tasksDone = tasks.filter { task in
            guard let doneAt = task.doneAt else { return false }
            return doneAt >= weekStart && doneAt < weekEnd
        }.count

        var work: [String?: [(Date, Date)]] = [:]
        for item in clipped where item.kind == .claude || item.kind == .you {
            work[item.taskID, default: []].append((item.start, item.end))
        }
        var sessionCounts: [String?: Int] = [:]
        for record in weekSessions {
            sessionCounts[record.taskId, default: 0] += 1
        }
        let taskByID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var taskRows: [TaskTimeRow] = []
        var noTaskRow: TaskTimeRow?
        for key in Set(work.keys).union(sessionCounts.keys) {
            let seconds = unionSeconds(work[key] ?? [])
            let count = sessionCounts[key] ?? 0
            guard seconds > 0 || count > 0 else { continue }
            if let id = key {
                let task = taskByID[id]
                taskRows.append(TaskTimeRow(
                    id: id,
                    taskID: id,
                    title: task?.title ?? id,
                    projectName: task?.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent },
                    seconds: seconds,
                    sessions: count,
                    isDone: task?.boardColumn == .done
                ))
            } else {
                noTaskRow = TaskTimeRow(id: noTaskID, taskID: nil, title: noTaskTitle, projectName: nil, seconds: seconds, sessions: count, isDone: false)
            }
        }
        taskRows.sort { lhs, rhs in
            lhs.seconds != rhs.seconds ? lhs.seconds > rhs.seconds : lhs.title < rhs.title
        }
        if let noTaskRow { taskRows.append(noTaskRow) }

        return WeekReport(
            days: days,
            tasksDone: tasksDone,
            sessions: weekSessions.count,
            boundShare: weekSessions.isEmpty ? nil : Double(bound) / Double(weekSessions.count),
            waitingSeconds: days.reduce(0) { $0 + $1.waitingSeconds },
            averageWaitSeconds: waits.isEmpty ? nil : waits.reduce(0, +) / Double(waits.count),
            distractionSeconds: days.reduce(0) { $0 + $1.distractionSeconds },
            rows: taskRows
        )
    }
}
