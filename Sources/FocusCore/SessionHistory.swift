import Foundation
import GRDB
import OpenIslandCore

public struct SessionObservation: Equatable, Sendable {
    public var sessionID: String
    public var cwd: String?
    public var title: String
    public var firstPrompt: String?
    public var lastPrompt: String?
    public var lastAssistantMessage: String?
    public var transcriptPath: String?
    public var observedAt: Date
    public var isEnded: Bool

    public init(sessionID: String, cwd: String?, title: String, firstPrompt: String?, lastPrompt: String?, lastAssistantMessage: String?, transcriptPath: String?, observedAt: Date, isEnded: Bool) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.title = title
        self.firstPrompt = firstPrompt
        self.lastPrompt = lastPrompt
        self.lastAssistantMessage = lastAssistantMessage
        self.transcriptPath = transcriptPath
        self.observedAt = observedAt
        self.isEnded = isEnded
    }

    public init(session: AgentSession) {
        self.init(
            sessionID: session.id,
            cwd: session.jumpTarget?.workingDirectory,
            title: session.title,
            firstPrompt: session.claudeMetadata?.initialUserPrompt,
            lastPrompt: session.claudeMetadata?.lastUserPrompt,
            lastAssistantMessage: session.claudeMetadata?.lastAssistantMessage.map { String($0.prefix(SessionHistory.maxAssistantMessageLength)) },
            transcriptPath: session.claudeMetadata?.transcriptPath,
            observedAt: session.updatedAt,
            isEnded: session.isSessionEnded
        )
    }
}

public final class SessionHistory: Sendable {
    public static let maxAssistantMessageLength = 500

    let store: FocusStore

    public init(store: FocusStore) {
        self.store = store
    }

    public func record(_ observation: SessionObservation) throws {
        try store.dbQueue.write { db in
            if var existing = try SessionRecord.fetchOne(db, key: observation.sessionID) {
                if let cwd = observation.cwd {
                    existing.cwd = cwd
                    existing.projectName = Self.projectName(for: cwd)
                }
                existing.title = observation.title
                existing.firstPrompt = existing.firstPrompt ?? observation.firstPrompt
                if let newPrompt = observation.lastPrompt, newPrompt != existing.lastPrompt {
                    existing.parkedAt = nil
                    existing.doneAt = nil
                }
                existing.lastPrompt = observation.lastPrompt ?? existing.lastPrompt
                existing.lastAssistantMessage = observation.lastAssistantMessage ?? existing.lastAssistantMessage
                existing.transcriptPath = observation.transcriptPath ?? existing.transcriptPath
                existing.lastActivityAt = max(existing.lastActivityAt, observation.observedAt)
                if observation.isEnded {
                    existing.status = .ended
                    existing.endedAt = existing.endedAt ?? observation.observedAt
                } else {
                    existing.status = .live
                    existing.endedAt = nil
                }
                try existing.update(db)
            } else {
                try SessionRecord(
                    id: observation.sessionID,
                    cwd: observation.cwd,
                    projectName: Self.projectName(for: observation.cwd),
                    title: observation.title,
                    firstPrompt: observation.firstPrompt,
                    lastPrompt: observation.lastPrompt,
                    lastAssistantMessage: observation.lastAssistantMessage,
                    startedAt: observation.observedAt,
                    lastActivityAt: observation.observedAt,
                    endedAt: observation.isEnded ? observation.observedAt : nil,
                    status: observation.isEnded ? .ended : .live,
                    taskId: nil,
                    transcriptPath: observation.transcriptPath
                ).insert(db)
            }
        }
    }

    public func park(sessionID: String, at date: Date) throws {
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE sessions SET parkedAt = ? WHERE id = ?", arguments: [date, sessionID])
        }
    }

    public func unpark(sessionID: String) throws {
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE sessions SET parkedAt = NULL WHERE id = ?", arguments: [sessionID])
        }
    }

    public func markDone(sessionID: String, at date: Date) throws {
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE sessions SET doneAt = ?, parkedAt = NULL WHERE id = ?", arguments: [date, sessionID])
        }
    }

    public func unmarkDone(sessionID: String) throws {
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE sessions SET doneAt = NULL WHERE id = ?", arguments: [sessionID])
        }
    }

    public func markSeen(sessionID: String, at date: Date) throws {
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE sessions SET lastSeenAt = ? WHERE id = ?", arguments: [date, sessionID])
        }
    }

    public func parkedSessionIDs() throws -> Set<String> {
        try store.dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT id FROM sessions WHERE parkedAt IS NOT NULL"))
        }
    }

    public func markEnded(sessionID: String, at date: Date) throws {
        try store.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET status = 'ended', endedAt = COALESCE(endedAt, ?) WHERE id = ?",
                arguments: [date, sessionID]
            )
        }
    }

    public func markAllLiveEnded(except keep: Set<String>, at date: Date) throws {
        try store.dbQueue.write { db in
            let live = try SessionRecord.filter(Column("status") == SessionRecordStatus.live.rawValue).fetchAll(db)
            for var record in live where !keep.contains(record.id) {
                record.status = .ended
                record.endedAt = record.endedAt ?? date
                try record.update(db)
            }
        }
    }

    public func mergeTranscript(_ summary: TranscriptSummary) throws {
        try store.dbQueue.write { db in
            if var existing = try SessionRecord.fetchOne(db, key: summary.sessionID) {
                existing.cwd = existing.cwd ?? summary.cwd
                existing.projectName = existing.projectName ?? Self.projectName(for: summary.cwd)
                existing.firstPrompt = existing.firstPrompt ?? summary.firstPrompt
                existing.transcriptPath = existing.transcriptPath ?? summary.transcriptPath
                existing.startedAt = min(existing.startedAt, summary.startedAt)
                if existing.status == .ended {
                    existing.title = summary.title
                    existing.lastPrompt = summary.lastPrompt ?? existing.lastPrompt
                    existing.lastAssistantMessage = summary.lastAssistantMessage ?? existing.lastAssistantMessage
                    existing.lastActivityAt = max(existing.lastActivityAt, summary.lastActivityAt)
                    existing.endedAt = existing.lastActivityAt
                }
                try existing.update(db)
            } else {
                try SessionRecord(
                    id: summary.sessionID,
                    cwd: summary.cwd,
                    projectName: Self.projectName(for: summary.cwd),
                    title: summary.title,
                    firstPrompt: summary.firstPrompt,
                    lastPrompt: summary.lastPrompt,
                    lastAssistantMessage: summary.lastAssistantMessage,
                    startedAt: summary.startedAt,
                    lastActivityAt: summary.lastActivityAt,
                    endedAt: summary.lastActivityAt,
                    status: .ended,
                    taskId: nil,
                    transcriptPath: summary.transcriptPath
                ).insert(db)
            }
        }
    }

    public func session(id: String) throws -> SessionRecord? {
        try store.dbQueue.read { db in try SessionRecord.fetchOne(db, key: id) }
    }

    public func recent(limit: Int) throws -> [SessionRecord] {
        try search(text: nil, projectPath: nil, limit: limit)
    }

    public func search(text: String?, projectPath: String?, limit: Int) throws -> [SessionRecord] {
        try store.dbQueue.read { db in
            var request = SessionRecord.all()
            if let projectPath {
                request = request.filter(Column("cwd") == projectPath)
            }
            var records = try request.order(Column("lastActivityAt").desc).fetchAll(db)
            if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                records = records.filter { record in
                    [record.title, record.firstPrompt, record.lastPrompt, record.projectName]
                        .compactMap { $0 }
                        .contains { $0.localizedCaseInsensitiveContains(text) }
                }
            }
            return Array(records.prefix(limit))
        }
    }

    public func boundSessions(doneSince: Date) throws -> [SessionRecord] {
        try store.dbQueue.read { db in
            try SessionRecord.fetchAll(
                db,
                sql: """
                SELECT sessions.* FROM sessions
                LEFT JOIN tasks ON tasks.id = sessions.taskId
                WHERE sessions.taskId IS NOT NULL
                  AND (sessions.status = ? OR tasks.id IS NULL OR tasks.boardColumn != ? OR tasks.doneAt >= ?)
                ORDER BY sessions.lastActivityAt DESC
                """,
                arguments: [SessionRecordStatus.live.rawValue, BoardColumn.done.rawValue, doneSince]
            )
        }
    }

    public func sessions(startedFrom start: Date, to end: Date) throws -> [SessionRecord] {
        try store.dbQueue.read { db in
            try SessionRecord
                .filter(Column("startedAt") >= start && Column("startedAt") < end)
                .order(Column("startedAt"))
                .fetchAll(db)
        }
    }

    public func sessions(forTaskID taskID: String) throws -> [SessionRecord] {
        try store.dbQueue.read { db in
            try SessionRecord.filter(Column("taskId") == taskID).order(Column("lastActivityAt").desc).fetchAll(db)
        }
    }

    public func liveSessions() throws -> [SessionRecord] {
        try store.dbQueue.read { db in
            try SessionRecord.filter(Column("status") == SessionRecordStatus.live.rawValue).fetchAll(db)
        }
    }

    public func knownProjectPaths() throws -> [String] {
        try store.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT cwd FROM sessions WHERE cwd IS NOT NULL GROUP BY cwd ORDER BY MAX(lastActivityAt) DESC")
        }
    }

    public static func projectName(for cwd: String?, fileManager: FileManager = .default) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        var url = URL(fileURLWithPath: cwd)
        while url.path != "/" {
            if fileManager.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url.lastPathComponent
            }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
}
