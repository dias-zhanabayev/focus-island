import Foundation
import Testing
@testable import OpenIslandCore

struct ClaudeTurnEndProbeTests {
    private func line(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    @Test
    func turnEndedWhenLastTurnRecordIsStopSummary() {
        let tail = [
            line(["type": "assistant", "message": ["role": "assistant"]]),
            line(["type": "attachment"]),
            line(["type": "system", "subtype": "stop_hook_summary"]),
            line(["type": "last-prompt"]),
            line(["type": "cost-state"]),
        ].joined(separator: "\n")
        #expect(ClaudeTurnEndProbe.turnHasEnded(tail: tail))
    }

    @Test
    func turnNotEndedWhileToolIsRunning() {
        let tail = [
            line(["type": "system", "subtype": "stop_hook_summary"]),
            line(["type": "user", "message": ["role": "user"]]),
            line(["type": "assistant", "message": ["role": "assistant"]]),
        ].joined(separator: "\n")
        #expect(!ClaudeTurnEndProbe.turnHasEnded(tail: tail))
    }

    @Test
    func turnNotEndedOnOtherSystemRecords() {
        let tail = line(["type": "system", "subtype": "compact_boundary"])
        #expect(!ClaudeTurnEndProbe.turnHasEnded(tail: tail))
    }

    @Test
    func brokenFirstLineOfTailIsIgnored() {
        let tail = "e\":\"half a record\"}\n" + line(["type": "system", "subtype": "turn_duration"])
        #expect(ClaudeTurnEndProbe.turnHasEnded(tail: tail))
    }

    @Test
    func quietlyEndedNeedsTranscriptToBeQuiet() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("turn-end-\(UUID().uuidString).jsonl")
        try (line(["type": "system", "subtype": "stop_hook_summary"]) + "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let now = Date()
        #expect(!ClaudeTurnEndProbe.quietlyEnded(transcriptPath: url.path, now: now))

        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-120)], ofItemAtPath: url.path)
        #expect(ClaudeTurnEndProbe.quietlyEnded(transcriptPath: url.path, now: now))
        #expect(!ClaudeTurnEndProbe.quietlyEnded(transcriptPath: "/nonexistent/\(UUID().uuidString).jsonl", now: now))
    }

    @Test
    func onlyQuietRunningClaudeSessionsAreSettled() {
        let now = Date()
        func session(_ id: String, phase: SessionPhase, age: TimeInterval) -> AgentSession {
            AgentSession(
                id: id,
                title: id,
                tool: .claudeCode,
                phase: phase,
                summary: "",
                updatedAt: now.addingTimeInterval(-age),
                claudeMetadata: ClaudeSessionMetadata(transcriptPath: "/tmp/\(id).jsonl")
            )
        }
        let sessions = [
            session("stuck", phase: .running, age: 600),
            session("fresh", phase: .running, age: 10),
            session("done", phase: .completed, age: 600),
            session("busy", phase: .running, age: 600),
        ]
        let result = ClaudeTurnEndProbe.sessionsToSettle(sessions, now: now) { path in
            !path.contains("busy")
        }
        #expect(result == ["stuck"])
    }

    @Test
    func quietSettleCompletesRunningSessionAndNextActivityClearsFlag() {
        var state = SessionState(sessions: [
            AgentSession(id: "s", title: "s", tool: .claudeCode, phase: .running, summary: "", updatedAt: .now),
        ])
        let firstSettle = state.settleQuietly(sessionIDs: ["s"])
        #expect(firstSettle)
        #expect(state.session(id: "s")?.phase == .completed)
        #expect(state.session(id: "s")?.isQuietlySettled == true)
        let secondSettle = state.settleQuietly(sessionIDs: ["s"])
        #expect(!secondSettle)

        state.apply(.activityUpdated(SessionActivityUpdated(sessionID: "s", summary: "go", phase: .running, timestamp: .now)))
        #expect(state.session(id: "s")?.phase == .running)
        #expect(state.session(id: "s")?.isQuietlySettled == false)
    }
}
