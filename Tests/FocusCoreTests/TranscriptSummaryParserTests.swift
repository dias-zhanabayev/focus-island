import Foundation
import Testing
@testable import FocusCore

struct TranscriptSummaryParserTests {
    func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
    }

    @Test
    func parsesPromptsAssistantTitleAndTimes() throws {
        let summary = try #require(TranscriptSummaryParser.parse(fileURL: try fixture("basic")))
        #expect(summary.sessionID == "abc-123")
        #expect(summary.cwd == "/tmp/proj")
        #expect(summary.firstPrompt == "Сделай канбан доску")
        #expect(summary.lastPrompt == "Добавь drag and drop")
        #expect(summary.lastAssistantMessage == "Готово.")
        #expect(summary.title == "kanban-board")
        #expect(summary.startedAt == ISO8601DateFormatter.focusFractional.date(from: "2026-10-08T20:09:00.000Z"))
        #expect(summary.lastActivityAt == ISO8601DateFormatter.focusFractional.date(from: "2026-10-08T20:10:30.000Z"))
    }

    @Test
    func skipsMetaAndCommandMessages() throws {
        let summary = try #require(TranscriptSummaryParser.parse(fileURL: try fixture("meta")))
        #expect(summary.firstPrompt == "Настоящий промпт")
        #expect(summary.lastPrompt == "Последний из last-prompt")
        #expect(summary.title == "Мой заголовок")
    }

    @Test
    func toleratesTruncatedLastLine() throws {
        let summary = try #require(TranscriptSummaryParser.parse(fileURL: try fixture("truncated")))
        #expect(summary.firstPrompt == "Целый промпт")
        #expect(summary.lastAssistantMessage == nil)
    }

    @Test
    func titleFallsBackToFirstPromptPrefix() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("s-9.jsonl")
        let prompt = String(repeating: "a", count: 200)
        try Data("{\"type\":\"user\",\"sessionId\":\"s-9\",\"timestamp\":\"2026-10-08T11:00:00.000Z\",\"message\":{\"content\":\"\(prompt)\"}}\n".utf8).write(to: file)
        let summary = try #require(TranscriptSummaryParser.parse(fileURL: file))
        #expect(summary.title.count == 80)
    }

    @Test
    func firstPromptSkipsSystemReminderBlocks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("s-10.jsonl")
        let line = #"{"type":"user","sessionId":"s-10","timestamp":"2026-10-08T11:00:00.000Z","message":{"content":[{"type":"text","text":"<system-reminder>ctx</system-reminder>"},{"type":"text","text":"Почини воронку"}]}}"#
        try Data((line + "\n").utf8).write(to: file)
        let summary = try #require(TranscriptSummaryParser.parse(fileURL: file))
        #expect(summary.firstPrompt == "Почини воронку")
    }

    @Test
    func returnsNilForFileWithoutSessionData() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("empty.jsonl")
        try Data("garbage\n".utf8).write(to: file)
        #expect(TranscriptSummaryParser.parse(fileURL: file) == nil)
    }
}
