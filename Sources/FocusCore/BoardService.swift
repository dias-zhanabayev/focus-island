import Foundation
import GRDB

public enum BoardError: Error, Equatable {
    case emptyTitle
    case unknownTask
    case unknownSession
}

public struct BoardSnapshot: Equatable, Sendable {
    public var tasks: [FocusTask]

    public init(tasks: [FocusTask]) {
        self.tasks = tasks
    }

    public func tasks(in column: BoardColumn) -> [FocusTask] {
        tasks.filter { $0.boardColumn == column }.sorted { $0.position < $1.position }
    }

    public func task(id: String?) -> FocusTask? {
        guard let id else { return nil }
        return tasks.first { $0.id == id }
    }

    public func currentTask(liveSessions: [SessionRecord]) -> FocusTask? {
        let bound = liveSessions
            .filter { $0.status == .live && $0.taskId != nil }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
        for session in bound {
            if let task = task(id: session.taskId), task.boardColumn != .done {
                return task
            }
        }
        return tasks(in: .inProgress).first
    }
}

public final class BoardService: Sendable {
    public static let maxSessionTitleLength = 80

    private let store: FocusStore

    public init(store: FocusStore) {
        self.store = store
    }

    public func snapshot() throws -> BoardSnapshot {
        try store.dbQueue.read { db in
            BoardSnapshot(tasks: try FocusTask.order(Column("position")).fetchAll(db))
        }
    }

    @discardableResult
    public func createTask(title: String, column: BoardColumn, projectPath: String? = nil, details: String? = nil, now: Date = .now) throws -> FocusTask {
        return try store.dbQueue.write { db in
            try Self.insertTask(title: title, column: column, projectPath: projectPath, details: details, now: now, db: db)
        }
    }

    public func updateTask(_ task: FocusTask, now: Date = .now) throws {
        let trimmed = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BoardError.emptyTitle }
        try store.dbQueue.write { db in
            guard var stored = try FocusTask.fetchOne(db, key: task.id) else { throw BoardError.unknownTask }
            stored.title = trimmed
            stored.details = task.details
            stored.projectPath = task.projectPath
            stored.note = task.note
            stored.updatedAt = now
            try stored.update(db)
        }
    }

    public func moveTask(id: String, to column: BoardColumn, beforeTaskID: String?, now: Date = .now) throws {
        try store.dbQueue.write { db in
            try Self.move(id: id, to: column, beforeTaskID: beforeTaskID, now: now, db: db)
        }
    }

    public func deleteTask(id: String) throws {
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE sessions SET taskId = NULL WHERE taskId = ?", arguments: [id])
            try db.execute(sql: "UPDATE queued_prompts SET taskId = NULL WHERE taskId = ?", arguments: [id])
            try db.execute(sql: "UPDATE activity_spans SET taskId = NULL WHERE taskId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM task_criteria WHERE taskId = ?", arguments: [id])
            _ = try FocusTask.deleteOne(db, key: id)
        }
    }

    public func bindSession(sessionID: String, toTaskID taskID: String?, now: Date = .now) throws {
        try store.dbQueue.write { db in
            guard var record = try SessionRecord.fetchOne(db, key: sessionID) else { throw BoardError.unknownSession }
            if let taskID {
                guard let task = try FocusTask.fetchOne(db, key: taskID) else { throw BoardError.unknownTask }
                if task.boardColumn == .backlog || task.boardColumn == .todo {
                    try Self.move(id: taskID, to: .inProgress, beforeTaskID: nil, now: now, db: db)
                }
            }
            record.taskId = taskID
            try record.update(db)
        }
    }

    @discardableResult
    public func createTaskForSession(sessionID: String, title: String, projectPath: String?, now: Date = .now) throws -> FocusTask {
        return try store.dbQueue.write { db in
            guard var record = try SessionRecord.fetchOne(db, key: sessionID) else { throw BoardError.unknownSession }
            let truncated = String(title.prefix(Self.maxSessionTitleLength))
            let task = try Self.insertTask(title: truncated, column: .inProgress, projectPath: projectPath, details: nil, now: now, db: db)
            record.taskId = task.id
            try record.update(db)
            return task
        }
    }

    public func doneTasks(since: Date) throws -> [FocusTask] {
        try store.dbQueue.read { db in
            try FocusTask
                .filter(Column("boardColumn") == BoardColumn.done.rawValue && Column("doneAt") >= since)
                .order(Column("doneAt").desc)
                .fetchAll(db)
        }
    }

    private static func insertTask(title: String, column: BoardColumn, projectPath: String?, details: String?, now: Date, db: Database) throws -> FocusTask {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BoardError.emptyTitle }
        let task = FocusTask(
            id: UUID().uuidString,
            title: trimmed,
            details: details,
            boardColumn: column,
            position: try Self.endPosition(in: column, db: db),
            projectPath: projectPath,
            note: nil,
            createdAt: now,
            updatedAt: now,
            doneAt: column == .done ? now : nil
        )
        try task.insert(db)
        return task
    }

    private static func endPosition(in column: BoardColumn, db: Database) throws -> Double {
        let maxPosition = try Double.fetchOne(db, sql: "SELECT MAX(position) FROM tasks WHERE boardColumn = ?", arguments: [column.rawValue])
        return (maxPosition ?? 0) + 1
    }

    private static func move(id: String, to column: BoardColumn, beforeTaskID: String?, now: Date, db: Database) throws {
        guard var task = try FocusTask.fetchOne(db, key: id) else { throw BoardError.unknownTask }
        let siblings = try FocusTask
            .filter(Column("boardColumn") == column.rawValue && Column("id") != id)
            .order(Column("position"))
            .fetchAll(db)
        if let beforeTaskID, let index = siblings.firstIndex(where: { $0.id == beforeTaskID }) {
            let next = siblings[index].position
            let previous = index > 0 ? siblings[index - 1].position : next - 2
            task.position = (previous + next) / 2
        } else {
            task.position = (siblings.last?.position ?? 0) + 1
        }
        if column == .done && task.boardColumn != .done {
            task.doneAt = now
        } else if column != .done {
            task.doneAt = nil
        }
        task.boardColumn = column
        task.updatedAt = now
        try task.update(db)
    }
}
