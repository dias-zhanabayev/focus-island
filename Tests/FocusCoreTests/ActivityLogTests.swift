import Foundation
import Testing
@testable import FocusCore

struct ActivityLogTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ minutes: Double) -> Date {
        base.addingTimeInterval(minutes * 60)
    }

    private func span(_ kind: ActivityKind, _ from: Double, _ to: Double?, task: String? = "t1", session: String? = "s1") -> ActivitySpan {
        ActivitySpan(kind: kind, sessionId: session, taskId: task, startedAt: at(from), endedAt: to.map { at($0) })
    }

    private func task(_ id: String, column: BoardColumn = .inProgress, doneAt: Date? = nil, path: String? = nil) -> FocusTask {
        FocusTask(id: id, title: "Задача \(id)", details: nil, boardColumn: column, position: 1, projectPath: path, note: nil, createdAt: base, updatedAt: base, doneAt: doneAt)
    }

    private func session(_ id: String, task: String?, startedAt: Date) -> SessionRecord {
        SessionRecord(id: id, cwd: nil, projectName: nil, title: id, firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, startedAt: startedAt, lastActivityAt: startedAt, endedAt: nil, status: .live, taskId: task, transcriptPath: nil)
    }

    @Test
    func openCloseRoundTrip() throws {
        let store = try FocusStore.inMemory()
        let log = ActivityLog(store: store)
        let id = try log.open(kind: .claude, sessionID: "s1", taskID: "t1", at: at(0))
        let openSpans = try log.spans(from: at(-10), to: at(30))
        #expect(openSpans.count == 1)
        #expect(openSpans[0].id == id)
        #expect(openSpans[0].endedAt == at(30))
        try log.close(id: id, at: at(10))
        let closed = try log.spans(from: at(-10), to: at(30))
        #expect(closed[0].endedAt == at(10))
        #expect(closed[0].kind == .claude)
        #expect(closed[0].sessionId == "s1")
        #expect(closed[0].taskId == "t1")
        #expect(try log.spans(from: at(11), to: at(20)).isEmpty)
    }

    @Test
    func closeAllOpenOnStart() throws {
        let store = try FocusStore.inMemory()
        let log = ActivityLog(store: store)
        let closedID = try log.open(kind: .you, sessionID: nil, taskID: "t1", at: at(0))
        try log.close(id: closedID, at: at(5))
        try log.open(kind: .claude, sessionID: "s1", taskID: "t1", at: at(6))
        try log.open(kind: .waiting, sessionID: "s2", taskID: nil, at: at(7))
        try log.closeAllOpen(at: at(20))
        let spans = try log.spans(from: at(-10), to: at(500))
        #expect(spans.count == 3)
        #expect(spans.map(\.endedAt) == [at(5), at(20), at(20)])
    }

    @Test
    func closeAllOpenAtStartLeavesZeroLength() throws {
        let store = try FocusStore.inMemory()
        let log = ActivityLog(store: store)
        let closedID = try log.open(kind: .you, sessionID: nil, taskID: "t1", at: at(0))
        try log.close(id: closedID, at: at(5))
        try log.open(kind: .claude, sessionID: "s1", taskID: "t1", at: at(6))
        try log.open(kind: .waiting, sessionID: "s2", taskID: nil, at: at(7))
        try log.closeAllOpenAtStart()
        let spans = try log.spans(from: at(-10), to: at(500))
        #expect(spans.map(\.endedAt) == [at(5), at(6), at(7)])
    }

    @Test
    func dayUnionsOverlaps() {
        let spans = [
            span(.you, 0, 30),
            span(.you, 20, 50, session: "s2"),
            span(.claude, 10, 20),
            span(.claude, 15, 40, session: "s2"),
            span(.waiting, 0, 10),
            span(.distraction, 0, 100)
        ]
        let episodes = [
            DistractionEpisode(startedAt: at(60), endedAt: at(65), appBundleID: "a", domain: nil, returnedWithinSec: 20),
            DistractionEpisode(startedAt: at(62), endedAt: at(70), appBundleID: "b", domain: nil)
        ]
        let report = ReportBuilder.day(spans: spans, episodes: episodes, tasks: [task("t1")], dayStart: at(0), dayEnd: at(120))
        #expect(report.youSeconds == 50 * 60)
        #expect(report.claudeSeconds == 30 * 60)
        #expect(report.waitingSeconds == 10 * 60)
        #expect(report.distractionSeconds == 10 * 60)
        #expect(report.distractionCount == 2)
        #expect(report.returnedCount == 1)
        #expect(report.distractionLane.count == 2)
        #expect(report.firstAt == at(0))
        #expect(report.lastAt == at(70))
    }

    @Test
    func dayMaxParallel() {
        let spans = [
            span(.claude, 0, 10, session: "a"),
            span(.claude, 5, 20, session: "b"),
            span(.claude, 8, 12, session: "c"),
            span(.claude, 20, 30, session: "d"),
            span(.waiting, 0, 30, session: "e")
        ]
        let report = ReportBuilder.day(spans: spans, episodes: [], tasks: [], dayStart: at(0), dayEnd: at(60))
        #expect(report.maxParallel == 3)
        let none = ReportBuilder.day(spans: [], episodes: [], tasks: [], dayStart: at(0), dayEnd: at(60))
        #expect(none.maxParallel == 0)
        #expect(none.firstAt == nil)
        #expect(none.lastAt == nil)
        #expect(none.lanes.isEmpty)
    }

    @Test
    func dayLanesCapAtSixPlusOther() {
        var spans: [ActivitySpan] = []
        var tasks: [FocusTask] = []
        for index in 1...8 {
            tasks.append(task("t\(index)"))
            spans.append(span(.claude, Double(index * 10), Double(index * 10 + index), task: "t\(index)"))
        }
        spans.append(span(.you, 100, 101, task: nil))
        let report = ReportBuilder.day(spans: spans, episodes: [], tasks: tasks, dayStart: at(0), dayEnd: at(200))
        #expect(report.lanes.count == 7)
        #expect(report.lanes.map(\.taskID) == ["t8", "t7", "t6", "t5", "t4", "t3", nil])
        #expect(report.lanes[0].title == "Задача t8")
        let other = report.lanes[6]
        #expect(other.id == "other")
        #expect(other.title == "Другие")
        #expect(other.segments.count == 3)
        #expect(other.segments.map(\.start) == [at(10), at(20), at(100)])
    }

    @Test
    func dayNoTaskLaneCountsTowardCap() {
        var spans: [ActivitySpan] = [span(.you, 0, 50, task: nil)]
        var tasks: [FocusTask] = []
        for index in 1...6 {
            tasks.append(task("t\(index)"))
            spans.append(span(.claude, Double(index * 60), Double(index * 60 + 10), task: "t\(index)"))
        }
        let report = ReportBuilder.day(spans: spans, episodes: [], tasks: tasks, dayStart: at(0), dayEnd: at(600))
        #expect(report.lanes.count == 7)
        #expect(report.lanes[0].title == "Без задачи")
        #expect(report.lanes[0].taskID == nil)
        #expect(report.lanes[6].title == "Другие")
        #expect(report.lanes[6].segments.count == 1)
    }

    @Test
    func dayClipsSpansToRange() {
        let spans = [
            span(.claude, -30, 10),
            span(.you, 50, nil),
            span(.waiting, 200, 300),
            span(.claude, -50, -40)
        ]
        let report = ReportBuilder.day(spans: spans, episodes: [], tasks: [task("t1")], dayStart: at(0), dayEnd: at(60))
        #expect(report.claudeSeconds == 10 * 60)
        #expect(report.youSeconds == 10 * 60)
        #expect(report.waitingSeconds == 0)
        #expect(report.firstAt == at(0))
        #expect(report.lastAt == at(60))
        let segments = report.lanes[0].segments
        #expect(segments.map(\.start) == [at(0), at(50)])
        #expect(segments.map(\.end) == [at(10), at(60)])
    }

    @Test
    func weekSevenBarsAndRowsOrder() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let weekStart = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let day = { (offset: Int, hour: Double) in calendar.date(byAdding: .day, value: offset, to: weekStart)!.addingTimeInterval(hour * 3600) }
        let spans = [
            ActivitySpan(kind: .claude, sessionId: "s1", taskId: "a", startedAt: day(0, 1), endedAt: day(0, 2)),
            ActivitySpan(kind: .you, sessionId: nil, taskId: "a", startedAt: day(0, 1.5), endedAt: day(0, 3)),
            ActivitySpan(kind: .claude, sessionId: "s2", taskId: "b", startedAt: day(3, 1), endedAt: day(3, 5)),
            ActivitySpan(kind: .waiting, sessionId: "s2", taskId: "b", startedAt: day(3, 5), endedAt: day(3, 5.5)),
            ActivitySpan(kind: .waiting, sessionId: "s1", taskId: "a", startedAt: day(6, 1), endedAt: day(6, 1.25)),
            ActivitySpan(kind: .claude, sessionId: "s9", taskId: "a", startedAt: day(7, 1), endedAt: day(7, 2)),
            ActivitySpan(kind: .you, sessionId: nil, taskId: nil, startedAt: day(2, 1), endedAt: day(2, 1.1))
        ]
        let episodes = [
            DistractionEpisode(startedAt: day(1, 4), endedAt: day(1, 4.5), appBundleID: "x", domain: nil),
            DistractionEpisode(startedAt: day(7, 4), endedAt: day(7, 4.5), appBundleID: "x", domain: nil)
        ]
        let tasks = [
            task("a", column: .done, doneAt: day(2, 0), path: "/Users/me/proj"),
            task("b"),
            task("c", column: .done, doneAt: day(-1, 0))
        ]
        let sessions = [
            session("s1", task: "a", startedAt: day(0, 1)),
            session("s2", task: "b", startedAt: day(3, 1)),
            session("s3", task: nil, startedAt: day(4, 1)),
            session("s0", task: "a", startedAt: day(-1, 1))
        ]
        let report = ReportBuilder.week(spans: spans, episodes: episodes, tasks: tasks, sessions: sessions, weekStart: weekStart, calendar: calendar)
        #expect(report.days.count == 7)
        #expect(report.days.map(\.day) == (0..<7).map { calendar.date(byAdding: .day, value: $0, to: weekStart)! })
        #expect(report.days[0].youSeconds == 1.5 * 3600)
        #expect(report.days[1].distractionSeconds == 1800)
        #expect(report.days[3].waitingSeconds == 1800)
        #expect(report.tasksDone == 1)
        #expect(report.sessions == 3)
        #expect(report.boundShare == 2.0 / 3.0)
        #expect(report.waitingSeconds == 1800 + 900)
        #expect(report.averageWaitSeconds == 1350.0)
        #expect(report.distractionSeconds == 1800)
        #expect(report.rows.map(\.id) == ["b", "a", "none"])
        #expect(report.rows[0].seconds == 4 * 3600)
        #expect(report.rows[1].seconds == 2 * 3600)
        #expect(report.rows[1].isDone)
        #expect(report.rows[1].projectName == "proj")
        #expect(report.rows[1].sessions == 1)
        #expect(report.rows[2].taskID == nil)
        #expect(report.rows[2].title == "Без задачи")
        #expect(report.rows[2].sessions == 1)
    }

    @Test
    func weekNoTaskRowLast() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let weekStart = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let spans = [
            ActivitySpan(kind: .you, sessionId: nil, taskId: nil, startedAt: weekStart.addingTimeInterval(3600 * 10), endedAt: weekStart.addingTimeInterval(3600 * 20)),
            ActivitySpan(kind: .claude, sessionId: "s1", taskId: "a", startedAt: weekStart.addingTimeInterval(3600), endedAt: weekStart.addingTimeInterval(3660))
        ]
        let report = ReportBuilder.week(spans: spans, episodes: [], tasks: [task("a")], sessions: [], weekStart: weekStart, calendar: calendar)
        #expect(report.rows.map(\.id) == ["a", "none"])
        #expect(report.boundShare == nil)
        #expect(report.averageWaitSeconds == nil)
        let empty = ReportBuilder.week(spans: [], episodes: [], tasks: [], sessions: [], weekStart: weekStart, calendar: calendar)
        #expect(empty.rows.isEmpty)
        #expect(empty.days.count == 7)
    }

    @Test
    func spansForTaskAreScopedAndClosedAtBound() throws {
        let store = try FocusStore.inMemory()
        let log = ActivityLog(store: store)
        let a = try log.open(kind: .claude, sessionID: "s1", taskID: "t1", at: at(0))
        try log.close(id: a, at: at(10))
        try log.open(kind: .you, sessionID: nil, taskID: "t1", at: at(20))
        try log.open(kind: .claude, sessionID: "s2", taskID: "t2", at: at(5))
        try log.open(kind: .claude, sessionID: "s3", taskID: "t1", at: at(90))
        let spans = try log.spans(taskID: "t1", to: at(30))
        #expect(spans.map(\.kind) == [.claude, .you])
        #expect(spans.allSatisfy { $0.taskId == "t1" })
        #expect(spans.last?.endedAt == at(30))
    }
}
