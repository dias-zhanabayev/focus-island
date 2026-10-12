import Foundation
import FocusCore
import Testing
@testable import OpenIslandApp

struct V6ClosedPillTests {
    @Test
    @MainActor
    func reportsRenderedWidthForPanelMorphing() {
        let macbookPill = V6ClosedPill(
            mode: .idle,
            label: nil,
            rightSlot: nil,
            layout: .macbook,
            height: 32,
            physicalNotchWidth: 224
        )
        let externalPill = V6ClosedPill(
            mode: .idle,
            label: nil,
            rightSlot: nil,
            layout: .external,
            height: 32
        )

        #expect(macbookPill.resolvedWidth == 312)
        #expect(externalPill.resolvedWidth == 70)
    }

    @Test
    @MainActor
    func macbookEarsWidenSymmetricallyForTextSlot() {
        let pill = V6ClosedPill(
            mode: .idle,
            label: nil,
            rightSlot: .text("Task title here"),
            layout: .macbook,
            height: 32,
            physicalNotchWidth: 224
        )
        let ear = V6ClosedPill.macbookEarWidth(for: .text("Task title here"))
        #expect(ear == min(140, CGFloat(15) * 6.5) + 16)
        #expect(pill.resolvedWidth == 224 + ear * 2)
        #expect(V6ClosedPill.macbookEarWidth(for: .count(3)) == 44)
        #expect(V6ClosedPill.macbookEarWidth(for: nil) == 44)
    }

    @Test
    func earWidthForFocusSummaryAndAlertIsSymmetric() {
        let summary = IslandLeftSlotContent.focusSummary(running: 2, waiting: 1, done: 1)
        let alert = IslandRightSlotContent.alert("Webhook retries ждёт 15м")
        let left = V6LeftSlotView.intrinsicWidth(of: summary)
        let right = V6RightSlotView.intrinsicWidth(of: alert)
        #expect(right == min(170, CGFloat(24) * 6.5))
        let ear = V6ClosedPill.macbookEarWidth(for: alert, leftSlot: summary)
        #expect(ear == max(44, max(left + 30, right) + 16))
        #expect(ear > 44)
        #expect(V6ClosedPill.macbookEarWidth(for: nil, leftSlot: summary) > 44)
        #expect(V6ClosedPill.macbookEarWidth(for: alert) == max(44, right + 16))
        #expect(V6ClosedPill.macbookEarWidth(for: .count(3), leftSlot: nil) == 44)
    }

    @Test
    @MainActor
    func pillWidthUsesWiderEarOnBothSides() {
        let summary = IslandLeftSlotContent.focusSummary(running: 2, waiting: 1, done: 0)
        let pill = V6ClosedPill(
            mode: .idle,
            label: nil,
            rightSlot: .alert("Task ждёт 12м"),
            leftSlot: summary,
            layout: .macbook,
            height: 32,
            physicalNotchWidth: 200
        )
        let ear = V6ClosedPill.macbookEarWidth(for: .alert("Task ждёт 12м"), leftSlot: summary)
        #expect(pill.resolvedWidth == 200 + ear * 2)
    }

    @Test
    func leftSlotSummaryForTwoOrMoreLive() {
        let rows = [
            hubRow("a", .running),
            hubRow("b", .waiting),
            hubRow("c", .review),
            hubRow("d", .parked),
        ]
        #expect(FocusEars.leftSlot(rows: rows) == .focusSummary(running: 1, waiting: 1, done: 1))
    }

    @Test
    func leftSlotProgressForSingleLive() {
        let progress = PlanProgress(completed: 2, total: 7, currentTitle: "x")
        let rows = [hubRow("a", .running, progress: progress), hubRow("p", .parked)]
        #expect(FocusEars.leftSlot(rows: rows) == .progress("шаг 3/7"))
        let finished = PlanProgress(completed: 7, total: 7, currentTitle: nil)
        #expect(FocusEars.leftSlot(rows: [hubRow("a", .running, progress: finished)]) == .progress("шаг 7/7"))
    }

    @Test
    func leftSlotNilWithoutPlanOrSessions() {
        #expect(FocusEars.leftSlot(rows: []) == nil)
        #expect(FocusEars.leftSlot(rows: [hubRow("a", .running)]) == nil)
        #expect(FocusEars.leftSlot(rows: [hubRow("a", .parked), hubRow("b", .parked)]) == nil)
    }

    @Test
    func rightSlotPrefersToastThenStalledThenTask() {
        let stalled = StalledBadge(title: "Webhook retries", minutes: 15)
        #expect(FocusEars.rightSlot(toast: "Промпт в буфере", stalled: stalled, taskTitle: "T", elapsedMinutes: 4) == .alert("Промпт в буфере"))
        #expect(FocusEars.rightSlot(toast: nil, stalled: stalled, taskTitle: "T", elapsedMinutes: 4) == .alert("Webhook retries ждёт 15м"))
        #expect(FocusEars.rightSlot(toast: nil, stalled: nil, taskTitle: "T", elapsedMinutes: 4) == .text("T · 4м"))
        #expect(FocusEars.rightSlot(toast: nil, stalled: nil, taskTitle: "T", elapsedMinutes: 0) == .text("T"))
        #expect(FocusEars.rightSlot(toast: nil, stalled: nil, taskTitle: "T", elapsedMinutes: nil) == .text("T"))
        #expect(FocusEars.rightSlot(toast: nil, stalled: nil, taskTitle: nil, elapsedMinutes: 4) == nil)
    }

    @Test
    func alertOverridesCountAndAgentsButNotNone() {
        let stalled = StalledBadge(title: "W", minutes: 12)
        for pref in [IslandRightSlot.currentTask, .count, .agents] {
            #expect(FocusEars.alertOverride(preference: pref, toast: nil, stalled: stalled) == .alert("W ждёт 12м"))
            #expect(FocusEars.alertOverride(preference: pref, toast: "T", stalled: stalled) == .alert("T"))
            #expect(FocusEars.alertOverride(preference: pref, toast: nil, stalled: nil) == nil)
        }
        #expect(FocusEars.alertOverride(preference: .none, toast: "T", stalled: stalled) == nil)
    }

    @Test
    func keptPomodoroCardShowsAlertAfterToast() {
        let stalled = StalledBadge(title: "W", minutes: 12)
        let end = FocusCard.pomodoroEnd(pomodoroID: "p")
        let breakEnd = FocusCard.breakEnd(pomodoroID: "p")
        for pref in [IslandRightSlot.currentTask, .count, .agents] {
            #expect(FocusEars.alertOverride(preference: pref, toast: nil, stalled: stalled, card: end) == .alert("☕ Перерыв 10"))
            #expect(FocusEars.alertOverride(preference: pref, toast: nil, stalled: stalled, card: end, breakCountdown: 4) == .alert("☕ Перерыв через 4"))
            #expect(FocusEars.alertOverride(preference: pref, toast: nil, stalled: nil, card: end, breakMinutes: 15) == .alert("☕ Перерыв 15"))
            #expect(FocusEars.alertOverride(preference: pref, toast: nil, stalled: nil, card: breakEnd, focusMinutes: 50) == .startFocus(50))
            #expect(FocusEars.alertOverride(preference: pref, toast: "T", stalled: nil, card: end) == .alert("T"))
            #expect(FocusEars.alertOverride(preference: pref, toast: nil, stalled: stalled, card: .dayStart) == .alert("W ждёт 12м"))
            #expect(FocusEars.alertOverride(preference: pref, toast: nil, stalled: nil, card: .dayStart) == nil)
        }
        #expect(FocusEars.alertOverride(preference: .none, toast: nil, stalled: nil, card: end) == nil)
        #expect(!FocusEars.clickOpensPickTask(rightSlot: FocusEars.alertOverride(preference: .currentTask, toast: nil, stalled: nil, card: end)))
        #expect(FocusEars.clickStartsFocus(rightSlot: FocusEars.alertOverride(preference: .currentTask, toast: nil, stalled: nil, card: breakEnd, focusMinutes: 50)) == 50)
    }

    @Test
    func newSessionWithoutTaskShowsQuietHint() {
        #expect(FocusEars.taskSlot(taskTitle: nil, elapsedMinutes: nil, todoCount: 3, isOnBreak: false, runningCount: 0, newSessionPending: true) == .hint("✦ Новая сессия · задача?"))
        #expect(FocusEars.taskSlot(taskTitle: nil, elapsedMinutes: nil, todoCount: 3, isOnBreak: false, runningCount: 0) == .hint("Выбрать задачу · Todo 3"))
        #expect(FocusEars.taskSlot(taskTitle: "A", elapsedMinutes: 5, todoCount: 0, isOnBreak: false, runningCount: 0, focusMinutes: 50, newSessionPending: true) == .startFocus(50))
    }

    @Test
    func noneSuppressesLeftEar() {
        let rows = [hubRow("a", .running), hubRow("b", .waiting)]
        #expect(FocusEars.leftSlot(preference: .none, rows: rows) == nil)
        #expect(FocusEars.leftSlot(preference: .count, rows: rows) == .focusSummary(running: 1, waiting: 1, done: 0))
        #expect(FocusEars.leftSlot(preference: .currentTask, rows: rows) == FocusEars.leftSlot(rows: rows))
    }

    @Test
    func leftSlotPrefixesPomodoroTimerBeforeSummary() {
        let rows = [hubRow("a", .running), hubRow("b", .waiting)]
        let snap = snapshot(.focus, remaining: 1122, progress: 0.25)
        let ear = PomodoroEar(phase: .focus, remainingSeconds: 1122, progress: 0.25, isPaused: false)
        #expect(FocusEars.leftSlot(preference: .currentTask, rows: rows, pomodoro: snap) == .pomodoro(ear, base: .focusSummary(running: 1, waiting: 1, done: 0)))
        #expect(FocusEars.leftSlot(preference: .count, rows: [], pomodoro: snap) == .pomodoro(ear, base: nil))
        #expect(FocusEars.leftSlot(preference: .none, rows: rows, pomodoro: snap) == nil)
        #expect(FocusEars.leftSlot(preference: .currentTask, rows: rows, pomodoro: nil) == .focusSummary(running: 1, waiting: 1, done: 0))
    }

    @Test
    func pomodoroEarTextForFocusAndBreak() {
        #expect(FocusEars.pomodoroText(PomodoroEar(phase: .focus, remainingSeconds: 1122, progress: 0.25, isPaused: false)) == "18:42")
        #expect(FocusEars.pomodoroText(PomodoroEar(phase: .focus, remainingSeconds: 478, progress: 0.7, isPaused: true)) == "07:58")
        #expect(FocusEars.pomodoroText(PomodoroEar(phase: .break, remainingSeconds: 192, progress: 0.3, isPaused: false)) == "Перерыв 3:12")
    }

    @Test
    func taskEarShowsHintWithoutTaskAndClaudeWorkingOnBreak() {
        #expect(FocusEars.taskSlot(taskTitle: nil, elapsedMinutes: nil, todoCount: 3, isOnBreak: false, runningCount: 0) == .hint("Выбрать задачу · Todo 3"))
        #expect(FocusEars.taskSlot(taskTitle: nil, elapsedMinutes: nil, todoCount: 0, isOnBreak: false, runningCount: 2) == .hint("Доска пуста"))
        #expect(FocusEars.taskSlot(taskTitle: "T", elapsedMinutes: 4, todoCount: 3, isOnBreak: false, runningCount: 1) == .text("T · 4м"))
        #expect(FocusEars.taskSlot(taskTitle: "T", elapsedMinutes: 4, todoCount: 3, isOnBreak: true, runningCount: 1) == .status("Claude работает · 1"))
        #expect(FocusEars.taskSlot(taskTitle: "T", elapsedMinutes: nil, todoCount: 3, isOnBreak: true, runningCount: 0) == .text("T"))
        #expect(FocusEars.taskSlot(taskTitle: nil, elapsedMinutes: nil, todoCount: 2, isOnBreak: true, runningCount: 2) == .status("Claude работает · 2"))
    }

    @Test
    func pillClickOpensPickTaskOnlyForHint() {
        #expect(FocusEars.clickOpensPickTask(rightSlot: .hint("Выбрать задачу · Todo 3")))
        #expect(FocusEars.clickOpensPickTask(rightSlot: .hint("Доска пуста")))
        #expect(!FocusEars.clickOpensPickTask(rightSlot: .text("T")))
        #expect(!FocusEars.clickOpensPickTask(rightSlot: .status("Claude работает · 1")))
        #expect(!FocusEars.clickOpensPickTask(rightSlot: nil))
        #expect(FocusEars.opensIsland(after: .presented))
        #expect(FocusEars.opensIsland(after: .blocked))
        #expect(!FocusEars.opensIsland(after: .openedBoard))
    }

    @Test
    func earWidthsFitHintStatusAndTimer() {
        let hint = IslandRightSlotContent.hint("Выбрать задачу · Todo 3")
        #expect(V6RightSlotView.intrinsicWidth(of: hint) == CGFloat(23) * 6.5)
        #expect(V6ClosedPill.macbookEarWidth(for: hint) == CGFloat(23) * 6.5 + 16)
        let status = IslandRightSlotContent.status("Claude работает · 1")
        #expect(V6RightSlotView.intrinsicWidth(of: status) == 12 + CGFloat(19) * 6.5)
        #expect(V6ClosedPill.macbookEarWidth(for: status) > 44)
        let summary = IslandLeftSlotContent.focusSummary(running: 1, waiting: 1, done: 0)
        let focusEar = PomodoroEar(phase: .focus, remainingSeconds: 1122, progress: 0.25, isPaused: false)
        let timerOnly = V6LeftSlotView.intrinsicWidth(of: .pomodoro(focusEar, base: nil))
        #expect(timerOnly == 18 + CGFloat(5) * 7)
        let combined = V6LeftSlotView.intrinsicWidth(of: .pomodoro(focusEar, base: summary))
        #expect(combined == timerOnly + 8 + V6LeftSlotView.intrinsicWidth(of: summary))
        let breakEar = PomodoroEar(phase: .break, remainingSeconds: 192, progress: 0.3, isPaused: false)
        #expect(V6LeftSlotView.intrinsicWidth(of: .pomodoro(breakEar, base: nil)) == CGFloat(12) * 7)
        #expect(V6ClosedPill.macbookEarWidth(for: nil, leftSlot: .pomodoro(focusEar, base: summary)) == combined + 30 + 16)
    }

    @Test
    func leftSlotAnimationKeyIgnoresRemainingSeconds() {
        let summary = IslandLeftSlotContent.focusSummary(running: 1, waiting: 1, done: 0)
        let a = IslandLeftSlotContent.pomodoro(PomodoroEar(phase: .focus, remainingSeconds: 1122, progress: 0.25, isPaused: false), base: summary)
        let b = IslandLeftSlotContent.pomodoro(PomodoroEar(phase: .focus, remainingSeconds: 1121, progress: 0.26, isPaused: false), base: summary)
        let onBreak = IslandLeftSlotContent.pomodoro(PomodoroEar(phase: .break, remainingSeconds: 1121, progress: 0.26, isPaused: false), base: summary)
        let paused = IslandLeftSlotContent.pomodoro(PomodoroEar(phase: .focus, remainingSeconds: 1121, progress: 0.26, isPaused: true), base: summary)
        let noBase = IslandLeftSlotContent.pomodoro(PomodoroEar(phase: .focus, remainingSeconds: 1121, progress: 0.26, isPaused: false), base: nil)
        #expect(FocusEars.animationKey(a) == FocusEars.animationKey(b))
        #expect(FocusEars.animationKey(a) != FocusEars.animationKey(onBreak))
        #expect(FocusEars.animationKey(a) != FocusEars.animationKey(paused))
        #expect(FocusEars.animationKey(a) != FocusEars.animationKey(noBase))
        #expect(FocusEars.animationKey(a) != FocusEars.animationKey(summary))
        #expect(FocusEars.animationKey(nil) != FocusEars.animationKey(summary))
        #expect(FocusEars.animationKey(summary) != FocusEars.animationKey(.focusSummary(running: 2, waiting: 1, done: 0)))
    }

    @Test
    func taskEarHidesHintWhileTasklessPomodoroRuns() {
        #expect(FocusEars.taskSlot(taskTitle: nil, elapsedMinutes: nil, todoCount: 3, isOnBreak: false, runningCount: 0, pomodoroActive: true) == nil)
        #expect(FocusEars.taskSlot(taskTitle: nil, elapsedMinutes: nil, todoCount: 3, isOnBreak: true, runningCount: 0, pomodoroActive: true) == nil)
        #expect(FocusEars.taskSlot(taskTitle: nil, elapsedMinutes: nil, todoCount: 3, isOnBreak: true, runningCount: 1, pomodoroActive: true) == .status("Claude работает · 1"))
        #expect(FocusEars.taskSlot(taskTitle: "T", elapsedMinutes: nil, todoCount: 3, isOnBreak: false, runningCount: 0, pomodoroActive: true) == .text("T"))
        #expect(FocusEars.taskSlot(taskTitle: nil, elapsedMinutes: nil, todoCount: 3, isOnBreak: false, runningCount: 0, pomodoroActive: false) == .hint("Выбрать задачу · Todo 3"))
    }

    private func snapshot(_ phase: PomodoroPhase, remaining: Int, progress: Double) -> PomodoroSnapshot {
        PomodoroSnapshot(id: "p", taskID: "t", taskTitle: "T", phase: phase, plannedSeconds: 1500, remainingSeconds: remaining, progress: progress, isPaused: false, cycleIndex: 1, cycle: 4)
    }

    private func hubRow(_ id: String, _ group: HubGroup, progress: PlanProgress? = nil) -> HubRow {
        HubRow(id: id, group: group, taskID: nil, title: id, projectName: nil, detail: "", since: Date(timeIntervalSince1970: 0), progress: progress)
    }

    @Test
    func taskWithoutTimerOffersFocusStartInEar() {
        #expect(FocusEars.taskSlot(taskTitle: "Воронка", elapsedMinutes: nil, todoCount: 0, isOnBreak: false, runningCount: 0, pomodoroActive: false, focusMinutes: 50) == .startFocus(50))
        #expect(FocusEars.taskSlot(taskTitle: "Воронка", elapsedMinutes: nil, todoCount: 0, isOnBreak: false, runningCount: 0, pomodoroActive: true, focusMinutes: 50) == .text("Воронка"))
        #expect(FocusEars.taskSlot(taskTitle: nil, elapsedMinutes: nil, todoCount: 0, isOnBreak: false, runningCount: 0, inProgressCount: 2) == .hint("Выбрать задачу"))
        #expect(FocusEars.taskSlot(taskTitle: nil, elapsedMinutes: nil, todoCount: 0, isOnBreak: false, runningCount: 0, inProgressCount: 0) == .hint("Доска пуста"))
        #expect(FocusEars.clickStartsFocus(rightSlot: .startFocus(50)) == 50)
        #expect(FocusEars.clickStartsFocus(rightSlot: .hint("Выбрать задачу")) == nil)
        #expect(!FocusEars.clickOpensPickTask(rightSlot: .startFocus(50)))
        #expect(FocusEars.startFocusText(50) == "▶ Фокус 50")
    }

    @Test
    func waitingOutsideCounterInLeftEar() {
        let rows: [HubRow] = []
        #expect(FocusEars.leftSlot(preference: .currentTask, rows: rows, pomodoro: nil, waitingOutside: 2) == .waitingOutside(2, quiet: false))
        let snap = PomodoroSnapshot(id: "p", taskID: "t", taskTitle: "T", phase: .focus, plannedSeconds: 3000, remainingSeconds: 1452, progress: 0.5, isPaused: false, cycleIndex: 1, cycle: 4)
        guard case let .pomodoro(_, base)? = FocusEars.leftSlot(preference: .currentTask, rows: rows, pomodoro: snap, waitingOutside: 2) else {
            Issue.record("expected pomodoro")
            return
        }
        #expect(base == .waitingOutside(2, quiet: true))
        #expect(FocusEars.leftSlot(preference: .currentTask, rows: rows, pomodoro: nil, waitingOutside: 0) == nil)
        #expect(FocusEars.waitingOutsideText(2, quiet: false) == "2 ждут")
        #expect(FocusEars.waitingOutsideText(2, quiet: true) == "2")
        #expect(FocusEars.clickShowsWaitingOutside(leftSlot: .waitingOutside(2, quiet: false)))
        #expect(!FocusEars.clickShowsWaitingOutside(leftSlot: nil))
    }
}
