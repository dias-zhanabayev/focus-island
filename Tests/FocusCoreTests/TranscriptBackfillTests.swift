import Foundation
import Testing
@testable import FocusCore

struct TranscriptBackfillTests {
    func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("projects-\(UUID().uuidString)")
        let project = root.appendingPathComponent("-tmp-proj")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("abc-123/subagents"), withIntermediateDirectories: true)
        let source = try #require(Bundle.module.url(forResource: "basic", withExtension: "jsonl", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: source, to: project.appendingPathComponent("abc-123.jsonl"))
        try FileManager.default.copyItem(at: source, to: project.appendingPathComponent("abc-123/subagents/agent-1.jsonl"))
        return root
    }

    @Test
    func importsEndedSessionsAndSkipsSubagents() throws {
        let store = try FocusStore.inMemory()
        let backfill = TranscriptBackfill(store: store, rootURL: try makeRoot())
        #expect(try backfill.run() == 1)
        let record = try #require(try SessionHistory(store: store).session(id: "abc-123"))
        #expect(record.status == .ended)
        #expect(record.title == "kanban-board")
        #expect(record.endedAt == record.lastActivityAt)
    }

    @Test
    func secondRunSkipsUnchangedFiles() throws {
        let store = try FocusStore.inMemory()
        let backfill = TranscriptBackfill(store: store, rootURL: try makeRoot())
        _ = try backfill.run()
        #expect(try backfill.run() == 0)
    }

    @Test
    func doesNotDowngradeLiveSessionOrDropTask() throws {
        let store = try FocusStore.inMemory()
        let history = SessionHistory(store: store)
        try history.record(SessionObservation(sessionID: "abc-123", cwd: "/tmp/proj", title: "Live title", firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, transcriptPath: nil, observedAt: Date(timeIntervalSince1970: 1), isEnded: false))
        try store.dbQueue.write { db in try db.execute(sql: "UPDATE sessions SET taskId = 't1'") }
        _ = try TranscriptBackfill(store: store, rootURL: try makeRoot()).run()
        let record = try #require(try history.session(id: "abc-123"))
        #expect(record.status == .live)
        #expect(record.title == "Live title")
        #expect(record.taskId == "t1")
        #expect(record.firstPrompt == "Сделай канбан доску")
    }
}
