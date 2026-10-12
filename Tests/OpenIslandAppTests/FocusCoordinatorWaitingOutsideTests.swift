import FocusCore
import Foundation
import OpenIslandCore
import Testing
@testable import OpenIslandApp

@MainActor
struct FocusCoordinatorWaitingOutsideTests {
    let t0 = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 9))!

    final class Box {
        var jumps: [String] = []
        var presented = 0
    }

    struct Harness {
        let coordinator: FocusCoordinator
        let box: Box
        let store: FocusStore
    }

    func make() throws -> Harness {
        let store = try FocusStore.inMemory()
        let defaults = UserDefaults(suiteName: "focus-waiting-\(UUID().uuidString)")!
        let coordinator = FocusCoordinator(store: store, defaults: defaults, launcher: RecordingLauncher(), promptSender: RecordingPromptSender(result: .unsupported), gitDiff: StubGitDiff(files: []), clipboard: { _ in }, runBackfill: false)
        coordinator.settings.dayStartEnabled = false
        coordinator.settings.nextActionEnabled = false
        let box = Box()
        coordinator.jumpToSession = { box.jumps.append($0) }
        coordinator.presentCard = { box.presented += 1 }
        coordinator.start(initialSessions: [], now: t0)
        return Harness(coordinator: coordinator, box: box, store: store)
    }

    func session(_ id: String, _ phase: SessionPhase, at date: Date, cwd: String = "/tmp/proj") -> AgentSession {
        var session = AgentSession(
            id: id, title: "title-\(id)", tool: .claudeCode, origin: .live, attachmentState: .attached, phase: phase, summary: "", updatedAt: date, firstSeenAt: date.addingTimeInterval(-3600),
            jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "proj", paneTitle: "", workingDirectory: cwd),
            claudeMetadata: ClaudeSessionMetadata(initialUserPrompt: "p", lastUserPrompt: "p", startupSource: .startup)
        )
        session.isHookManaged = true
        return session
    }

    func task(_ h: Harness, _ title: String, column: BoardColumn = .inProgress) throws -> String {
        h.coordinator.createTask(title: title, column: column, projectPath: "/tmp/proj")
        return try #require(h.coordinator.board.tasks.first { $0.title == title }?.id)
    }

    func at(_ minutes: Double) -> Date {
        t0.addingTimeInterval(minutes * 60)
    }

    @Test
    func waitingOutsideListsOnlyOtherTasksPastThreshold() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        let b = try task(h, "B")
        c.sessionsDidChange([
            session("mine", .waitingForAnswer, at: at(0)),
            session("other", .waitingForAnswer, at: at(0)),
            session("fresh", .waitingForAnswer, at: at(10)),
        ], now: at(10))
        c.bind(sessionID: "mine", taskID: a, now: at(10))
        c.bind(sessionID: "other", taskID: b, now: at(10))
        c.bind(sessionID: "fresh", taskID: b, now: at(10))
        c.takeTask(taskID: a, now: at(10))
        c.tick(now: at(16))
        #expect(c.waitingOutside.map(\.id) == ["other"])
        #expect(c.card == nil)
    }

    @Test
    func noFocusTaskMeansNoWaitingOutside() throws {
        let h = try make()
        let c = h.coordinator
        c.offerTaskChoiceOnLaunch(now: at(0))
        c.sessionsDidChange([session("s", .waitingForAnswer, at: at(0))], now: at(0))
        c.tick(now: at(60))
        #expect(c.currentTask == nil)
        #expect(c.waitingOutside.isEmpty)
    }

    @Test
    func waitingSessionsNeverOpenIslandByThemselves() throws {
        let h = try make()
        let c = h.coordinator
        c.sessionsDidChange([session("s1", .waitingForApproval, at: at(0)), session("s2", .completed, at: at(0))], now: at(0))
        let before = h.box.presented
        for minute in stride(from: 1.0, through: 240.0, by: 15.0) {
            c.tick(now: at(minute))
        }
        #expect(c.card == nil)
        #expect(h.box.presented == before)
    }

    @Test
    func expandAndCollapseWaitingOutside() throws {
        let h = try make()
        let c = h.coordinator
        #expect(!c.waitingOutsideExpanded)
        c.showWaitingOutside()
        #expect(c.waitingOutsideExpanded)
        c.toggleWaitingOutside()
        #expect(!c.waitingOutsideExpanded)
    }

    @Test
    func deferWaitingOutsideParksSessions() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.sessionsDidChange([session("o1", .waitingForAnswer, at: at(0)), session("o2", .waitingForAnswer, at: at(0))], now: at(0))
        c.takeTask(taskID: a, now: at(1))
        c.tick(now: at(20))
        #expect(c.waitingOutside.count == 2)
        let cardBefore = c.card
        c.deferWaitingOutside(sessionIDs: ["o1", "o2"], now: at(21))
        #expect(c.waitingOutside.isEmpty)
        #expect(c.hubRows.allSatisfy { $0.group == .parked })
        #expect(try SessionHistory(store: h.store).session(id: "o1")?.parkedAt != nil)
        #expect(c.card == cardBefore)
    }

    @Test
    func addingWaitingSessionToFocusTaskRemovesItFromList() throws {
        let h = try make()
        let c = h.coordinator
        let a = try task(h, "A")
        c.sessionsDidChange([session("o", .waitingForAnswer, at: at(0))], now: at(0))
        c.takeTask(taskID: a, now: at(1))
        c.tick(now: at(20))
        #expect(c.waitingOutside.map(\.id) == ["o"])
        c.bind(sessionID: "o", taskID: a, now: at(21))
        #expect(c.waitingOutside.isEmpty)
        #expect(c.focusTaskSessions.map(\.id) == ["o"])
    }
}
