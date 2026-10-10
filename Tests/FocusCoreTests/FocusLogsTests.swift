import Foundation
import GRDB
import Testing
@testable import FocusCore

struct FocusLogsTests {
    let t0 = Date(timeIntervalSince1970: 60_000)

    @Test
    func statsAggregateSinceDate() throws {
        let store = try FocusStore.inMemory()
        let board = BoardService(store: store)
        let done = try board.createTask(title: "A", column: .inProgress, now: t0)
        try board.moveTask(id: done.id, to: .done, beforeTaskID: nil, now: t0.addingTimeInterval(10))
        let old = try board.createTask(title: "Old", column: .inProgress, now: t0)
        try board.moveTask(id: old.id, to: .done, beforeTaskID: nil, now: t0.addingTimeInterval(-10_000))

        try store.dbQueue.write { db in
            for (id, task) in [("s1", done.id), ("s2", nil)] as [(String, String?)] {
                try SessionRecord(id: id, cwd: nil, projectName: nil, title: id, firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, startedAt: t0, lastActivityAt: t0, endedAt: nil, status: .ended, taskId: task, transcriptPath: nil).insert(db)
            }
        }

        let distractions = DistractionLog(store: store)
        try distractions.save(DistractionEpisode(startedAt: t0, endedAt: t0.addingTimeInterval(40), appBundleID: "x", domain: nil, nudged: true, returnedWithinSec: 10))
        try distractions.save(DistractionEpisode(startedAt: t0.addingTimeInterval(100), endedAt: t0.addingTimeInterval(160), appBundleID: "x", domain: nil, nudged: true, returnedWithinSec: 5))

        let reactions = NextActionLog(store: store)
        for (shown, reacted) in [(0.0, 10.0), (100, 140), (200, 220)] {
            let id = try reactions.shown(kind: "startTask", at: t0.addingTimeInterval(shown))
            try reactions.reacted(id: id, at: t0.addingTimeInterval(reacted))
        }
        _ = try reactions.shown(kind: "reflect", at: t0.addingTimeInterval(300))

        let stats = try StatsService(store: store).stats(since: t0.addingTimeInterval(-1))
        #expect(stats == FocusStats(tasksDone: 1, sessionsStarted: 2, boundShare: 0.5, distractionCount: 2, distractionSeconds: 100, medianReactionSec: 20))
    }

    @Test
    func emptyStatsHaveNilRatios() throws {
        let stats = try StatsService(store: try FocusStore.inMemory()).stats(since: t0)
        #expect(stats == FocusStats(tasksDone: 0, sessionsStarted: 0, boundShare: nil, distractionCount: 0, distractionSeconds: 0, medianReactionSec: nil))
    }
}
