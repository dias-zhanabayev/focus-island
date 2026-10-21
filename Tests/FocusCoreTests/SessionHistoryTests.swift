import Foundation
import Testing
import OpenIslandCore
@testable import FocusCore

struct SessionHistoryTests {
    let t0 = Date(timeIntervalSince1970: 20_000)

    func makeSession(id: String = "s1", cwd: String? = "/tmp/proj", initialPrompt: String? = "first", lastPrompt: String? = "last", assistant: String? = "ok", updatedAt: Date, ended: Bool = false) -> AgentSession {
        var session = AgentSession(
            id: id,
            title: "Claude · proj",
            tool: .claudeCode,
            origin: .live,
            attachmentState: .attached,
            phase: .running,
            summary: "",
            updatedAt: updatedAt,
            jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "proj", paneTitle: "", workingDirectory: cwd),
            claudeMetadata: ClaudeSessionMetadata(transcriptPath: "/tmp/t.jsonl", initialUserPrompt: initialPrompt, lastUserPrompt: lastPrompt, lastAssistantMessage: assistant)
        )
        session.isSessionEnded = ended
        return session
    }

    @Test
    func recordCreatesLiveRecord() throws {
        let history = SessionHistory(store: try FocusStore.inMemory())
        try history.record(SessionObservation(session: makeSession(updatedAt: t0)))
        let record = try #require(try history.session(id: "s1"))
        #expect(record.status == .live)
        #expect(record.startedAt == t0)
        #expect(record.cwd == "/tmp/proj")
        #expect(record.projectName == "proj")
        #expect(record.firstPrompt == "first")
        #expect(record.transcriptPath == "/tmp/t.jsonl")
    }

    @Test
    func recordPreservesStartFirstPromptAndTaskOnUpdate() throws {
        let store = try FocusStore.inMemory()
        let history = SessionHistory(store: store)
        try history.record(SessionObservation(session: makeSession(updatedAt: t0)))
        try store.dbQueue.write { db in try db.execute(sql: "UPDATE sessions SET taskId = 'task-1'") }
        try history.record(SessionObservation(session: makeSession(initialPrompt: nil, lastPrompt: "newer", updatedAt: t0.addingTimeInterval(30))))
        let record = try #require(try history.session(id: "s1"))
        #expect(record.startedAt == t0)
        #expect(record.firstPrompt == "first")
        #expect(record.lastPrompt == "newer")
        #expect(record.taskId == "task-1")
        #expect(record.lastActivityAt == t0.addingTimeInterval(30))
    }

    @Test
    func endedObservationSetsEndedOnce() throws {
        let history = SessionHistory(store: try FocusStore.inMemory())
        try history.record(SessionObservation(session: makeSession(updatedAt: t0, ended: true)))
        try history.record(SessionObservation(session: makeSession(updatedAt: t0.addingTimeInterval(5), ended: true)))
        let record = try #require(try history.session(id: "s1"))
        #expect(record.status == .ended)
        #expect(record.endedAt == t0)
    }

    @Test
    func assistantMessageIsTruncated() throws {
        let history = SessionHistory(store: try FocusStore.inMemory())
        try history.record(SessionObservation(session: makeSession(assistant: String(repeating: "x", count: 900), updatedAt: t0)))
        #expect(try history.session(id: "s1")?.lastAssistantMessage?.count == 500)
    }

    @Test
    func markAllLiveEndedSkipsGivenIDs() throws {
        let history = SessionHistory(store: try FocusStore.inMemory())
        try history.record(SessionObservation(session: makeSession(id: "a", updatedAt: t0)))
        try history.record(SessionObservation(session: makeSession(id: "b", updatedAt: t0)))
        try history.markAllLiveEnded(except: ["b"], at: t0.addingTimeInterval(100))
        #expect(try history.session(id: "a")?.status == .ended)
        #expect(try history.session(id: "a")?.endedAt == t0.addingTimeInterval(100))
        #expect(try history.session(id: "b")?.status == .live)
    }

    @Test
    func searchMatchesTitleAndPromptsCaseInsensitively() throws {
        let history = SessionHistory(store: try FocusStore.inMemory())
        try history.record(SessionObservation(session: makeSession(id: "a", initialPrompt: "Почини ДОСКУ", updatedAt: t0)))
        try history.record(SessionObservation(session: makeSession(id: "b", cwd: "/tmp/other", initialPrompt: "другое", lastPrompt: "x", updatedAt: t0.addingTimeInterval(1))))
        #expect(try history.search(text: "доску", projectPath: nil, limit: 10).map(\.id) == ["a"])
        #expect(try history.search(text: nil, projectPath: "/tmp/other", limit: 10).map(\.id) == ["b"])
        #expect(try history.search(text: nil, projectPath: nil, limit: 10).map(\.id) == ["b", "a"])
    }

    @Test
    func projectNameUsesGitRootWhenPresent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repo-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        #expect(SessionHistory.projectName(for: nested.path) == root.lastPathComponent)
        #expect(SessionHistory.projectName(for: "/nonexistent/some/dir") == "dir")
        #expect(SessionHistory.projectName(for: nil) == nil)
    }

    @Test
    func knownProjectPathsAreDistinctAndRecentFirst() throws {
        let history = SessionHistory(store: try FocusStore.inMemory())
        try history.record(SessionObservation(session: makeSession(id: "a", cwd: "/p1", updatedAt: t0)))
        try history.record(SessionObservation(session: makeSession(id: "b", cwd: "/p2", updatedAt: t0.addingTimeInterval(10))))
        try history.record(SessionObservation(session: makeSession(id: "c", cwd: "/p1", updatedAt: t0.addingTimeInterval(20))))
        #expect(try history.knownProjectPaths() == ["/p1", "/p2"])
    }

    @Test
    func newPromptClearsPark() throws {
        let history = SessionHistory(store: try FocusStore.inMemory())
        try history.record(SessionObservation(session: makeSession(updatedAt: t0)))
        try history.park(sessionID: "s1", at: t0.addingTimeInterval(1))
        #expect(try history.parkedSessionIDs() == ["s1"])
        try history.record(SessionObservation(session: makeSession(updatedAt: t0.addingTimeInterval(2))))
        #expect(try history.session(id: "s1")?.parkedAt == t0.addingTimeInterval(1))
        try history.record(SessionObservation(session: makeSession(lastPrompt: "different", updatedAt: t0.addingTimeInterval(3))))
        #expect(try history.session(id: "s1")?.parkedAt == nil)
        #expect(try history.parkedSessionIDs().isEmpty)
    }

    @Test
    func unparkClearsParkedAt() throws {
        let history = SessionHistory(store: try FocusStore.inMemory())
        try history.record(SessionObservation(session: makeSession(updatedAt: t0)))
        try history.park(sessionID: "s1", at: t0)
        try history.unpark(sessionID: "s1")
        #expect(try history.session(id: "s1")?.parkedAt == nil)
    }

    @Test
    func markSeenSetsLastSeenAt() throws {
        let history = SessionHistory(store: try FocusStore.inMemory())
        try history.record(SessionObservation(session: makeSession(updatedAt: t0)))
        try history.markSeen(sessionID: "s1", at: t0.addingTimeInterval(9))
        #expect(try history.session(id: "s1")?.lastSeenAt == t0.addingTimeInterval(9))
    }

    @Test
    func boundSessionsReturnsOnlyTaskBoundNewestFirst() throws {
        let store = try FocusStore.inMemory()
        let history = SessionHistory(store: store)
        func record(_ id: String, task: String?, at: TimeInterval) -> SessionRecord {
            SessionRecord(id: id, cwd: nil, projectName: nil, title: id, firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, startedAt: Date(timeIntervalSince1970: at), lastActivityAt: Date(timeIntervalSince1970: at), endedAt: nil, status: .ended, taskId: task, transcriptPath: nil)
        }
        try store.dbQueue.write { db in
            try record("a", task: "t1", at: 10).insert(db)
            try record("b", task: nil, at: 20).insert(db)
            try record("c", task: "t2", at: 30).insert(db)
        }
        #expect(try history.boundSessions(doneSince: .distantPast).map(\.id) == ["c", "a"])
    }

    @Test
    func boundSessionsSkipsLongDoneTasksUnlessLive() throws {
        let store = try FocusStore.inMemory()
        let history = SessionHistory(store: store)
        func task(_ id: String, column: BoardColumn, doneAt: TimeInterval?) -> FocusTask {
            FocusTask(id: id, title: id, details: nil, boardColumn: column, position: 1, projectPath: nil, note: nil, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0), doneAt: doneAt.map { Date(timeIntervalSince1970: $0) })
        }
        func record(_ id: String, task: String, status: SessionRecordStatus, at: TimeInterval) -> SessionRecord {
            SessionRecord(id: id, cwd: nil, projectName: nil, title: id, firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, startedAt: Date(timeIntervalSince1970: at), lastActivityAt: Date(timeIntervalSince1970: at), endedAt: nil, status: status, taskId: task, transcriptPath: nil)
        }
        try store.dbQueue.write { db in
            try task("open", column: .inProgress, doneAt: nil).insert(db)
            try task("recent", column: .done, doneAt: 900).insert(db)
            try task("old", column: .done, doneAt: 100).insert(db)
            try record("a", task: "open", status: .ended, at: 10).insert(db)
            try record("b", task: "recent", status: .ended, at: 20).insert(db)
            try record("c", task: "old", status: .ended, at: 30).insert(db)
            try record("d", task: "old", status: .live, at: 40).insert(db)
        }
        #expect(try history.boundSessions(doneSince: Date(timeIntervalSince1970: 500)).map(\.id) == ["d", "b", "a"])
    }

    @Test
    func sessionsStartedInRange() throws {
        let store = try FocusStore.inMemory()
        let history = SessionHistory(store: store)
        func record(_ id: String, at: TimeInterval) -> SessionRecord {
            SessionRecord(id: id, cwd: nil, projectName: nil, title: id, firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, startedAt: Date(timeIntervalSince1970: at), lastActivityAt: Date(timeIntervalSince1970: at + 5), endedAt: nil, status: .ended, taskId: nil, transcriptPath: nil)
        }
        try store.dbQueue.write { db in
            for (id, at) in [("a", 10.0), ("b", 100.0), ("c", 199.0), ("d", 200.0)] {
                try record(id, at: at).insert(db)
            }
        }
        let ids = try history.sessions(startedFrom: Date(timeIntervalSince1970: 100), to: Date(timeIntervalSince1970: 200)).map(\.id)
        #expect(Set(ids) == ["b", "c"])
    }

    @Test
    func markDoneAndNewPromptReturnsSession() throws {
        let history = SessionHistory(store: try FocusStore.inMemory())
        try history.record(SessionObservation(session: makeSession(updatedAt: t0)))
        try history.park(sessionID: "s1", at: t0)
        try history.markDone(sessionID: "s1", at: t0.addingTimeInterval(1))
        #expect(try history.session(id: "s1")?.doneAt == t0.addingTimeInterval(1))
        #expect(try history.session(id: "s1")?.parkedAt == nil)
        try history.record(SessionObservation(session: makeSession(updatedAt: t0.addingTimeInterval(2))))
        #expect(try history.session(id: "s1")?.doneAt != nil)
        try history.record(SessionObservation(session: makeSession(lastPrompt: "ещё одно", updatedAt: t0.addingTimeInterval(3))))
        #expect(try history.session(id: "s1")?.doneAt == nil)
        try history.markDone(sessionID: "s1", at: t0)
        try history.unmarkDone(sessionID: "s1")
        #expect(try history.session(id: "s1")?.doneAt == nil)
    }
}
