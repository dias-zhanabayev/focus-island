import Foundation
import GRDB

public enum BoardColumn: String, Codable, CaseIterable, Sendable, Identifiable {
    case backlog
    case todo
    case inProgress
    case done

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .backlog: "Backlog"
        case .todo: "Todo"
        case .inProgress: "In progress"
        case .done: "Done"
        }
    }
}

public struct FocusTask: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tasks"

    public var id: String
    public var title: String
    public var details: String?
    public var boardColumn: BoardColumn
    public var position: Double
    public var projectPath: String?
    public var note: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var doneAt: Date?

    public init(id: String, title: String, details: String?, boardColumn: BoardColumn, position: Double, projectPath: String?, note: String?, createdAt: Date, updatedAt: Date, doneAt: Date?) {
        self.id = id
        self.title = title
        self.details = details
        self.boardColumn = boardColumn
        self.position = position
        self.projectPath = projectPath
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.doneAt = doneAt
    }
}

public enum SessionRecordStatus: String, Codable, Sendable {
    case live
    case ended
}

public struct SessionRecord: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sessions"

    public var id: String
    public var cwd: String?
    public var projectName: String?
    public var title: String
    public var firstPrompt: String?
    public var lastPrompt: String?
    public var lastAssistantMessage: String?
    public var startedAt: Date
    public var lastActivityAt: Date
    public var endedAt: Date?
    public var status: SessionRecordStatus
    public var taskId: String?
    public var transcriptPath: String?
    public var parkedAt: Date?
    public var lastSeenAt: Date?

    public init(id: String, cwd: String?, projectName: String?, title: String, firstPrompt: String?, lastPrompt: String?, lastAssistantMessage: String?, startedAt: Date, lastActivityAt: Date, endedAt: Date?, status: SessionRecordStatus, taskId: String?, transcriptPath: String?, parkedAt: Date? = nil, lastSeenAt: Date? = nil) {
        self.id = id
        self.cwd = cwd
        self.projectName = projectName
        self.title = title
        self.firstPrompt = firstPrompt
        self.lastPrompt = lastPrompt
        self.lastAssistantMessage = lastAssistantMessage
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.endedAt = endedAt
        self.status = status
        self.taskId = taskId
        self.transcriptPath = transcriptPath
        self.parkedAt = parkedAt
        self.lastSeenAt = lastSeenAt
    }
}

public struct DistractionEpisode: Codable, Equatable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "distraction_episodes"

    public var id: Int64?
    public var startedAt: Date
    public var endedAt: Date?
    public var appBundleID: String
    public var domain: String?
    public var nudged: Bool
    public var returnedWithinSec: Double?

    public init(id: Int64? = nil, startedAt: Date, endedAt: Date? = nil, appBundleID: String, domain: String?, nudged: Bool = false, returnedWithinSec: Double? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.appBundleID = appBundleID
        self.domain = domain
        self.nudged = nudged
        self.returnedWithinSec = returnedWithinSec
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct NextActionEvent: Codable, Equatable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "next_action_events"

    public var id: Int64?
    public var shownAt: Date
    public var reactedAt: Date?
    public var kind: String

    public init(id: Int64? = nil, shownAt: Date, reactedAt: Date? = nil, kind: String) {
        self.id = id
        self.shownAt = shownAt
        self.reactedAt = reactedAt
        self.kind = kind
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct TaskCriterion: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "task_criteria"

    public var id: String
    public var taskId: String
    public var text: String
    public var done: Bool
    public var position: Double
    public var createdAt: Date

    public init(id: String, taskId: String, text: String, done: Bool, position: Double, createdAt: Date) {
        self.id = id
        self.taskId = taskId
        self.text = text
        self.done = done
        self.position = position
        self.createdAt = createdAt
    }
}

public struct QueuedPrompt: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "queued_prompts"

    public var id: String
    public var sessionId: String
    public var taskId: String?
    public var text: String
    public var createdAt: Date
    public var sentAt: Date?

    public init(id: String, sessionId: String, taskId: String?, text: String, createdAt: Date, sentAt: Date? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.taskId = taskId
        self.text = text
        self.createdAt = createdAt
        self.sentAt = sentAt
    }
}

public enum ActivityKind: String, Codable, Sendable, CaseIterable {
    case claude
    case waiting
    case you
    case distraction
}

public struct ActivitySpan: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "activity_spans"

    public var id: Int64?
    public var kind: ActivityKind
    public var sessionId: String?
    public var taskId: String?
    public var startedAt: Date
    public var endedAt: Date?

    public init(id: Int64? = nil, kind: ActivityKind, sessionId: String?, taskId: String?, startedAt: Date, endedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.sessionId = sessionId
        self.taskId = taskId
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct DayPlan: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "day_plans"

    public var day: String
    public var focusTaskIds: [String]
    public var tomorrowNote: String?
    public var dayStartShownAt: Date?

    public init(day: String, focusTaskIds: [String] = [], tomorrowNote: String? = nil, dayStartShownAt: Date? = nil) {
        self.day = day
        self.focusTaskIds = focusTaskIds
        self.tomorrowNote = tomorrowNote
        self.dayStartShownAt = dayStartShownAt
    }

    public init(row: Row) throws {
        day = row["day"]
        let json: String = row["focusTaskIds"]
        focusTaskIds = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
        tomorrowNote = row["tomorrowNote"]
        dayStartShownAt = row["dayStartShownAt"]
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["day"] = day
        container["focusTaskIds"] = String(decoding: try JSONEncoder().encode(focusTaskIds), as: UTF8.self)
        container["tomorrowNote"] = tomorrowNote
        container["dayStartShownAt"] = dayStartShownAt
    }
}
