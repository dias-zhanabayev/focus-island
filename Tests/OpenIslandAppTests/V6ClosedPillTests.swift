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
    func noneSuppressesLeftEar() {
        let rows = [hubRow("a", .running), hubRow("b", .waiting)]
        #expect(FocusEars.leftSlot(preference: .none, rows: rows) == nil)
        #expect(FocusEars.leftSlot(preference: .count, rows: rows) == .focusSummary(running: 1, waiting: 1, done: 0))
        #expect(FocusEars.leftSlot(preference: .currentTask, rows: rows) == FocusEars.leftSlot(rows: rows))
    }

    private func hubRow(_ id: String, _ group: HubGroup, progress: PlanProgress? = nil) -> HubRow {
        HubRow(id: id, group: group, taskID: nil, title: id, projectName: nil, detail: "", since: Date(timeIntervalSince1970: 0), progress: progress)
    }
}
