import Foundation
import GRDB

public struct CriteriaProgress: Equatable, Sendable {
    public let done: Int
    public let total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }
}

public final class TaskCriteriaService: Sendable {
    private let store: FocusStore

    public init(store: FocusStore) {
        self.store = store
    }

    public func criteria(taskID: String) throws -> [TaskCriterion] {
        try store.dbQueue.read { db in
            try TaskCriterion.filter(Column("taskId") == taskID).order(Column("position")).fetchAll(db)
        }
    }

    @discardableResult
    public func add(taskID: String, text: String, now: Date = .now) throws -> TaskCriterion {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BoardError.emptyTitle }
        return try store.dbQueue.write { db in
            let maxPosition = try Double.fetchOne(db, sql: "SELECT MAX(position) FROM task_criteria WHERE taskId = ?", arguments: [taskID])
            let criterion = TaskCriterion(
                id: UUID().uuidString,
                taskId: taskID,
                text: trimmed,
                done: false,
                position: (maxPosition ?? 0) + 1,
                createdAt: now
            )
            try criterion.insert(db)
            return criterion
        }
    }

    public func toggle(id: String, now: Date = .now) throws {
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE task_criteria SET checkedAt = CASE WHEN done THEN NULL ELSE ? END, done = NOT done WHERE id = ?", arguments: [now, id])
        }
    }

    public func delete(id: String) throws {
        try store.dbQueue.write { db in
            _ = try TaskCriterion.deleteOne(db, key: id)
        }
    }

    public func allProgress() throws -> [String: CriteriaProgress] {
        try store.dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT taskId, COUNT(*) AS total, SUM(done) AS done FROM task_criteria GROUP BY taskId")
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                (row["taskId"] as String, CriteriaProgress(done: row["done"] as Int? ?? 0, total: row["total"] as Int))
            })
        }
    }

    public func progress(taskID: String) throws -> CriteriaProgress {
        try store.dbQueue.read { db in
            let total = try TaskCriterion.filter(Column("taskId") == taskID).fetchCount(db)
            let done = try TaskCriterion.filter(Column("taskId") == taskID && Column("done") == true).fetchCount(db)
            return CriteriaProgress(done: done, total: total)
        }
    }
}

public final class PromptQueue: Sendable {
    private let store: FocusStore

    public init(store: FocusStore) {
        self.store = store
    }

    public func pending(sessionID: String) throws -> QueuedPrompt? {
        try store.dbQueue.read { db in
            try QueuedPrompt
                .filter(Column("sessionId") == sessionID && Column("sentAt") == nil)
                .order(Column("createdAt").desc)
                .fetchOne(db)
        }
    }

    @discardableResult
    public func enqueue(sessionID: String, taskID: String?, text: String, now: Date = .now) throws -> QueuedPrompt {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = QueuedPrompt(id: UUID().uuidString, sessionId: sessionID, taskId: taskID, text: trimmed, createdAt: now)
        try store.dbQueue.write { db in
            try Self.deleteUnsent(sessionID: sessionID, db: db)
            if !trimmed.isEmpty {
                try prompt.insert(db)
            }
        }
        return prompt
    }

    public func markSent(id: String, at: Date) throws {
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE queued_prompts SET sentAt = ? WHERE id = ?", arguments: [at, id])
        }
    }

    public func markSent(sessionID: String, text: String, at: Date) throws {
        try store.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE queued_prompts SET sentAt = ? WHERE sessionId = ? AND sentAt IS NULL AND text = ?",
                arguments: [at, sessionID, text]
            )
        }
    }

    public func discardForEndedSessions() throws {
        try store.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM queued_prompts WHERE sentAt IS NULL AND sessionId IN (SELECT id FROM sessions WHERE status = ?)", arguments: [SessionRecordStatus.ended.rawValue])
        }
    }

    public func discard(sessionID: String) throws {
        try store.dbQueue.write { db in
            try Self.deleteUnsent(sessionID: sessionID, db: db)
        }
    }

    public func pendingSessionIDs() throws -> Set<String> {
        try store.dbQueue.read { db in
            Set(try String.fetchAll(
                db,
                sql: "SELECT DISTINCT sessionId FROM queued_prompts WHERE sentAt IS NULL AND sessionId NOT IN (SELECT id FROM sessions WHERE status = ?)",
                arguments: [SessionRecordStatus.ended.rawValue]
            ))
        }
    }

    private static func deleteUnsent(sessionID: String, db: Database) throws {
        try db.execute(sql: "DELETE FROM queued_prompts WHERE sessionId = ? AND sentAt IS NULL", arguments: [sessionID])
    }
}

public final class DayPlanStore: Sendable {
    private let store: FocusStore

    public init(store: FocusStore) {
        self.store = store
    }

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public func plan(day: String) throws -> DayPlan? {
        try store.dbQueue.read { db in try DayPlan.fetchOne(db, key: day) }
    }

    public func latestTomorrowNote(before day: String, notBefore earliest: String) throws -> String? {
        try store.dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT tomorrowNote FROM day_plans WHERE day < ? AND day >= ? AND tomorrowNote IS NOT NULL AND TRIM(tomorrowNote) != '' ORDER BY day DESC LIMIT 1",
                arguments: [day, earliest]
            )
        }
    }

    public func setFocusTasks(_ ids: [String], day: String) throws {
        try mutate(day: day) { $0.focusTaskIds = ids }
    }

    public func setTomorrowNote(_ text: String?, day: String) throws {
        try mutate(day: day) { $0.tomorrowNote = text }
    }

    public func markDayStartShown(day: String, at: Date) throws {
        try mutate(day: day) { $0.dayStartShownAt = at }
    }

    private func mutate(day: String, _ change: (inout DayPlan) -> Void) throws {
        try store.dbQueue.write { db in
            var plan = try DayPlan.fetchOne(db, key: day) ?? DayPlan(day: day)
            change(&plan)
            try plan.save(db)
        }
    }
}
