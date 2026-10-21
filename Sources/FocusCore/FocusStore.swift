import Foundation
import GRDB

public enum FocusStoreOpenOutcome: Equatable, Sendable {
    case normal
    case recovered(backupURL: URL)
    case inMemoryFallback
}

public struct FocusStoreOpenResult: Sendable {
    public let store: FocusStore
    public let outcome: FocusStoreOpenOutcome

    public init(store: FocusStore, outcome: FocusStoreOpenOutcome) {
        self.store = store
        self.outcome = outcome
    }
}

public enum FocusStoreOpenError: Error {
    case migrationFailed(Error)
}

public final class FocusStore: Sendable {
    public let dbQueue: DatabaseQueue

    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FocusIsland", isDirectory: true)
            .appendingPathComponent("focus.sqlite")
    }

    public convenience init(fileURL: URL) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        let queue = try DatabaseQueue(path: fileURL.path, configuration: configuration)
        do {
            try self.init(queue: queue)
        } catch {
            throw FocusStoreOpenError.migrationFailed(error)
        }
    }

    public static func inMemory() throws -> FocusStore {
        try FocusStore(queue: DatabaseQueue())
    }

    public static func openWithRecovery(fileURL: URL, now: Date = .now) -> FocusStoreOpenResult {
        let firstError: Error
        do {
            return FocusStoreOpenResult(store: try FocusStore(fileURL: fileURL), outcome: .normal)
        } catch {
            firstError = error
        }
        guard isCorruption(firstError) else {
            if let store = try? FocusStore(fileURL: fileURL) {
                return FocusStoreOpenResult(store: store, outcome: .normal)
            }
            return FocusStoreOpenResult(store: try! FocusStore.inMemory(), outcome: .inMemoryFallback)
        }
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).bak-\(Int(now.timeIntervalSince1970))")
        guard (try? FileManager.default.moveItem(at: fileURL, to: backup)) != nil else {
            return FocusStoreOpenResult(store: try! FocusStore.inMemory(), outcome: .inMemoryFallback)
        }
        if let store = try? FocusStore(fileURL: fileURL) {
            return FocusStoreOpenResult(store: store, outcome: .recovered(backupURL: backup))
        }
        return FocusStoreOpenResult(store: try! FocusStore.inMemory(), outcome: .inMemoryFallback)
    }

    static func isCorruption(_ error: Error) -> Bool {
        if let databaseError = error as? DatabaseError {
            return databaseError.resultCode == .SQLITE_CORRUPT || databaseError.resultCode == .SQLITE_NOTADB
        }
        guard case let FocusStoreOpenError.migrationFailed(underlying) = error else { return false }
        guard let databaseError = underlying as? DatabaseError else { return true }
        return !transientResultCodes.contains(databaseError.resultCode)
    }

    private static let transientResultCodes: [ResultCode] = [
        .SQLITE_BUSY, .SQLITE_LOCKED, .SQLITE_CANTOPEN, .SQLITE_PERM, .SQLITE_READONLY,
        .SQLITE_IOERR, .SQLITE_FULL, .SQLITE_NOMEM, .SQLITE_AUTH, .SQLITE_INTERRUPT,
    ]

    private init(queue: DatabaseQueue) throws {
        dbQueue = queue
        try Self.migrator(upTo: nil).migrate(dbQueue)
    }

    static func migrator(upTo identifier: String?) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "tasks") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("details", .text)
                t.column("boardColumn", .text).notNull().indexed()
                t.column("position", .double).notNull()
                t.column("projectPath", .text)
                t.column("note", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("doneAt", .datetime)
            }
            try db.create(table: "sessions") { t in
                t.primaryKey("id", .text)
                t.column("cwd", .text)
                t.column("projectName", .text)
                t.column("title", .text).notNull()
                t.column("firstPrompt", .text)
                t.column("lastPrompt", .text)
                t.column("lastAssistantMessage", .text)
                t.column("startedAt", .datetime).notNull()
                t.column("lastActivityAt", .datetime).notNull().indexed()
                t.column("endedAt", .datetime)
                t.column("status", .text).notNull()
                t.column("taskId", .text).indexed()
                t.column("transcriptPath", .text)
            }
            try db.create(table: "distraction_episodes") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("startedAt", .datetime).notNull().indexed()
                t.column("endedAt", .datetime)
                t.column("appBundleID", .text).notNull()
                t.column("domain", .text)
                t.column("nudged", .boolean).notNull()
                t.column("returnedWithinSec", .double)
            }
            try db.create(table: "next_action_events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("shownAt", .datetime).notNull().indexed()
                t.column("reactedAt", .datetime)
                t.column("kind", .text).notNull()
            }
            try db.create(table: "backfill_files") { t in
                t.primaryKey("path", .text)
                t.column("modifiedAt", .datetime).notNull()
            }
        }
        if identifier == "v1" { return migrator }
        migrator.registerMigration("v2") { db in
            try db.alter(table: "sessions") { t in
                t.add(column: "parkedAt", .datetime)
                t.add(column: "lastSeenAt", .datetime)
            }
            try db.create(table: "task_criteria") { t in
                t.primaryKey("id", .text)
                t.column("taskId", .text).notNull().indexed()
                t.column("text", .text).notNull()
                t.column("done", .boolean).notNull()
                t.column("position", .double).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "queued_prompts") { t in
                t.primaryKey("id", .text)
                t.column("sessionId", .text).notNull().indexed()
                t.column("taskId", .text)
                t.column("text", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("sentAt", .datetime)
            }
            try db.create(table: "activity_spans") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("sessionId", .text)
                t.column("taskId", .text)
                t.column("startedAt", .datetime).notNull().indexed()
                t.column("endedAt", .datetime)
            }
            try db.create(table: "day_plans") { t in
                t.primaryKey("day", .text)
                t.column("focusTaskIds", .text).notNull().defaults(to: "[]")
                t.column("tomorrowNote", .text)
                t.column("dayStartShownAt", .datetime)
            }
        }
        if identifier == "v2" { return migrator }
        migrator.registerMigration("v3") { db in
            try db.create(table: "pomodoros") { t in
                t.primaryKey("id", .text)
                t.column("taskId", .text)
                t.column("phase", .text).notNull()
                t.column("plannedSeconds", .integer).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("pausedSeconds", .double).notNull().defaults(to: 0)
                t.column("pausedAt", .datetime)
                t.column("completed", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "pomodoros_on_taskId_startedAt", on: "pomodoros", columns: ["taskId", "startedAt"])
        }
        if identifier == "v3" { return migrator }
        migrator.registerMigration("v4") { db in
            try db.alter(table: "task_criteria") { t in
                t.add(column: "checkedAt", .datetime)
            }
        }
        if identifier == "v4" { return migrator }
        migrator.registerMigration("v5") { db in
            try db.alter(table: "sessions") { t in
                t.add(column: "doneAt", .datetime)
            }
        }
        return migrator
    }
}
