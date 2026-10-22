import Foundation
import Testing
@testable import FocusCore

struct PolicyTests {
    let t0 = Date(timeIntervalSince1970: 200_000)

    func at(_ minutes: Int) -> Date { t0.addingTimeInterval(TimeInterval(minutes * 60)) }

    func row(_ id: String, _ group: HubGroup, sinceMinutes: Int, taskID: String? = "t") -> HubRow {
        HubRow(id: id, group: group, taskID: taskID, title: id, projectName: id, detail: "", since: at(sinceMinutes), progress: nil)
    }

    @Test
    func stalledAppliesThreeRules() {
        let rows = [
            row("w14", .waiting, sinceMinutes: -14),
            row("w15", .waiting, sinceMinutes: -15),
            row("r59", .review, sinceMinutes: -59),
            row("r60", .review, sinceMinutes: -60),
            row("u119", .unbound, sinceMinutes: -119),
            row("u120", .unbound, sinceMinutes: -120),
            row("run", .running, sinceMinutes: -500),
            row("park", .parked, sinceMinutes: -500),
        ]
        let result = StalledPolicy.stalled(rows: rows, reminderMinutes: 15, now: at(0))
        #expect(result.map(\.id) == ["u120", "r60", "w15"])
    }

    @Test
    func stalledRespectsReminderSetting() {
        let rows = [row("w", .waiting, sinceMinutes: -5)]
        #expect(StalledPolicy.stalled(rows: rows, reminderMinutes: 5, now: at(0)).count == 1)
        #expect(StalledPolicy.stalled(rows: rows, reminderMinutes: 6, now: at(0)).isEmpty)
    }

    @Test
    func overloadIsNilAtLimit() {
        let rows = [row("a", .running, sinceMinutes: -1), row("b", .waiting, sinceMinutes: -2), row("c", .review, sinceMinutes: -3)]
        #expect(OverloadPolicy.evaluate(rows: rows, limit: 3, taskID: "t") == nil)
    }

    @Test
    func overloadCountsIdleRows() throws {
        let rows = [row("a", .running, sinceMinutes: -1), row("i", .idle, sinceMinutes: -2)]
        #expect(OverloadPolicy.evaluate(rows: rows, limit: 2, taskID: "t") == nil)
        #expect(try #require(OverloadPolicy.evaluate(rows: rows, limit: 1, taskID: "t")).slots.count == 2)
    }

    @Test
    func overloadCountsOnlySessionsOfTheGivenTask() throws {
        let rows = [
            row("a", .running, sinceMinutes: -1),
            row("b", .waiting, sinceMinutes: -2),
            row("x", .running, sinceMinutes: -3, taskID: "other"),
            row("y", .running, sinceMinutes: -4, taskID: nil),
            row("z", .unbound, sinceMinutes: -5, taskID: nil),
        ]
        #expect(OverloadPolicy.evaluate(rows: rows, limit: 2, taskID: "t") == nil)
        let suggestion = try #require(OverloadPolicy.evaluate(rows: rows, limit: 1, taskID: "t"))
        #expect(suggestion.slots.map(\.id) == ["a", "b"])
        #expect(OverloadPolicy.evaluate(rows: rows, limit: 0, taskID: nil) == nil)
    }

    @Test
    func stalledIgnoresIdle() {
        #expect(StalledPolicy.stalled(rows: [row("i", .idle, sinceMinutes: -999)], reminderMinutes: 5, now: at(0)).isEmpty)
    }

    @Test
    func overloadPausedDoNotCount() {
        let rows = [row("a", .running, sinceMinutes: -1), row("b", .running, sinceMinutes: -2), row("p", .parked, sinceMinutes: -3)]
        #expect(OverloadPolicy.evaluate(rows: rows, limit: 2, taskID: "t") == nil)
    }

    @Test
    func overloadPicksOldestWaitingAndNewestRunning() throws {
        let rows = [
            row("w-new", .waiting, sinceMinutes: -2),
            row("w-old", .waiting, sinceMinutes: -20),
            row("r-old", .running, sinceMinutes: -30),
            row("r-new", .running, sinceMinutes: -1),
            row("p", .parked, sinceMinutes: -9),
        ]
        let suggestion = try #require(OverloadPolicy.evaluate(rows: rows, limit: 3, taskID: "t"))
        #expect(suggestion.attend?.id == "w-old")
        #expect(suggestion.park?.id == "r-new")
        #expect(suggestion.slots.count == 4)
        #expect(!suggestion.slots.contains { $0.id == "p" })
    }

    @Test
    func overloadWithoutWaitingOrRunning() throws {
        let rows = [row("a", .review, sinceMinutes: -1), row("b", .unbound, sinceMinutes: -2)]
        let suggestion = try #require(OverloadPolicy.evaluate(rows: rows, limit: 1, taskID: "t"))
        #expect(suggestion.attend == nil)
        #expect(suggestion.park == nil)
    }

    @Test
    func dayStartBoundaries() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10))!
        let early = day.addingTimeInterval(4 * 3600 + 59 * 60)
        let open = day.addingTimeInterval(5 * 3600)
        #expect(!DayStartPolicy.shouldShow(enabled: true, plan: nil, now: early, calendar: calendar))
        #expect(DayStartPolicy.shouldShow(enabled: true, plan: nil, now: open, calendar: calendar))
        #expect(DayStartPolicy.shouldShow(enabled: true, plan: DayPlan(day: "2026-10-10"), now: open, calendar: calendar))
        #expect(!DayStartPolicy.shouldShow(enabled: true, plan: DayPlan(day: "2026-10-10", dayStartShownAt: open), now: open, calendar: calendar))
        #expect(!DayStartPolicy.shouldShow(enabled: false, plan: nil, now: open, calendar: calendar))
    }
}
