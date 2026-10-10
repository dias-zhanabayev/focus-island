import FocusCore
import SwiftUI

struct WeekSummaryView: View {
    @Bindable var focus: FocusCoordinator
    @State private var report: WeekReport?
    @State private var previous: WeekReport?
    @State private var reactionSeconds: Double?
    @State private var weekStart: Date?
    @State private var today = Calendar.current.startOfDay(for: .now)

    static let chartHeight: CGFloat = 240
    static let shareWidth: CGFloat = 90

    nonisolated static func barHeights(days: [DayBar], maxHeight: CGFloat) -> [CGFloat] {
        let totals = days.map { $0.youSeconds + $0.waitingSeconds + $0.distractionSeconds }
        guard let peak = totals.max(), peak > 0 else { return totals.map { _ in 0 } }
        return totals.map { CGFloat($0 / peak) * maxHeight }
    }

    nonisolated static func segmentHeights(day: DayBar, barHeight: CGFloat) -> (you: CGFloat, waiting: CGFloat, distraction: CGFloat) {
        let total = day.youSeconds + day.waitingSeconds + day.distractionSeconds
        guard total > 0 else { return (0, 0, 0) }
        return (
            CGFloat(day.youSeconds / total) * barHeight,
            CGFloat(day.waitingSeconds / total) * barHeight,
            CGFloat(day.distractionSeconds / total) * barHeight
        )
    }

    nonisolated static func previousCount(_ value: Int?) -> String {
        "прошлая неделя \(value.map(String.init) ?? "—")"
    }

    nonisolated static func previousDuration(_ seconds: TimeInterval?) -> String {
        "прошлая неделя \(seconds.map(DaySummaryFormatter.duration) ?? "—")"
    }

    nonisolated static func boundShareDetail(_ share: Double?) -> String {
        "с задачей \(share.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")"
    }

    nonisolated static func averageWaitDetail(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "нет данных" }
        return "в среднем \(FocusText.roundedUpMinutes(seconds)) мин на ответ"
    }

    nonisolated static func reactionValue(_ seconds: Double?) -> String {
        seconds.map { "\(Int($0.rounded())) с" } ?? "—"
    }

    nonisolated static func hoursLabel(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "0" }
        return String(format: "%.1f", seconds / 3600)
    }

    nonisolated static func shareWidths(rows: [TaskTimeRow], maxWidth: CGFloat) -> [CGFloat] {
        guard let peak = rows.map(\.seconds).max(), peak > 0 else { return rows.map { _ in 0 } }
        return rows.map { CGFloat($0.seconds / peak) * maxWidth }
    }

    nonisolated static func status(_ row: TaskTimeRow) -> String {
        if row.isDone { return "сделано" }
        return row.taskID == nil ? "—" : "в работе"
    }

    nonisolated static func rangeTitle(start: Date, calendar: Calendar = .current) -> String {
        let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let sameMonth = calendar.component(.month, from: start) == calendar.component(.month, from: end)
        formatter.dateFormat = "d MMMM"
        let endText = formatter.string(from: end)
        if sameMonth {
            return "\(calendar.component(.day, from: start)) – \(endText)"
        }
        return "\(formatter.string(from: start)) – \(endText)"
    }

    nonisolated static func dayLabel(_ day: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEEEE"
        return formatter.string(from: day).lowercased()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                kpiRow
                HStack(alignment: .top, spacing: 12) {
                    chartCard
                    tableCard
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .task {
            while !Task.isCancelled {
                load()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func load() {
        let now = Date.now
        let calendar = Calendar.current
        let lastDay = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -6, to: lastDay) ?? lastDay
        weekStart = start
        today = lastDay
        let current = focus.weekReport(endingAt: now, now: now)
        let before = calendar.date(byAdding: .day, value: -7, to: now).flatMap { focus.weekReport(endingAt: $0, now: now) }
        report = current
        previous = before
        reactionSeconds = focus.stats(since: start)?.medianReactionSec
    }

    private var header: some View {
        HStack {
            Text("Неделя").font(.system(size: 22, weight: .bold))
            if let weekStart {
                Text(Self.rangeTitle(start: weekStart)).font(FocusStyle.secondaryFont).foregroundStyle(FocusStyle.secondaryText)
            }
            Spacer(minLength: 0)
        }
    }

    private var kpiRow: some View {
        HStack(alignment: .top, spacing: 12) {
            kpi("Задач закрыто", report.map { "\($0.tasksDone)" } ?? "—", detail: Self.previousCount(previous?.tasksDone))
            kpi("Сессий", report.map { "\($0.sessions)" } ?? "—", detail: Self.boundShareDetail(report?.boundShare))
            kpi(
                "Ждали тебя",
                report.map { DaySummaryFormatter.duration($0.waitingSeconds) } ?? "—",
                color: FocusStyle.waitingText,
                detail: Self.averageWaitDetail(report?.averageWaitSeconds)
            )
            kpi(
                "Отвлечения",
                report.map { DaySummaryFormatter.duration($0.distractionSeconds) } ?? "—",
                color: FocusStyle.distractionText,
                detail: Self.previousDuration(previous?.distractionSeconds)
            )
            kpi("Реакция на «Что дальше?»", Self.reactionValue(reactionSeconds), detail: "медиана")
        }
    }

    private func kpi(_ label: String, _ value: String, color: Color = FocusStyle.primaryText, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(FocusStyle.secondaryFont).foregroundStyle(FocusStyle.secondaryText).lineLimit(1)
            Text(value)
                .font(.system(size: 26, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(detail).font(FocusStyle.secondaryFont).foregroundStyle(FocusStyle.secondaryText).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: FocusStyle.rowRadius).fill(FocusStyle.barBackground))
        .accessibilityElement(children: .combine)
    }

    private var chartCard: some View {
        let days = report?.days ?? []
        let heights = Self.barHeights(days: days, maxHeight: Self.chartHeight)
        return FocusBox(fill: FocusStyle.barBackground, spacing: 12) {
            HStack(spacing: 14) {
                Text("По дням, часы").font(.system(size: 14, weight: .bold)).frame(maxWidth: .infinity, alignment: .leading)
                legend("в задаче", FocusStyle.accent)
                legend("ждали", FocusStyle.waiting)
                legend("отвлечения", FocusStyle.distraction)
            }
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    let isToday = Calendar.current.isDate(day.day, inSameDayAs: today)
                    VStack(spacing: 6) {
                        Spacer(minLength: 0)
                        Text(Self.hoursLabel(day.youSeconds + day.waitingSeconds + day.distractionSeconds))
                            .font(FocusStyle.secondaryFont)
                            .foregroundStyle(isToday ? FocusStyle.primaryText : FocusStyle.secondaryText)
                        stack(day: day, height: heights[index], highlighted: isToday)
                        Text(Self.dayLabel(day.day))
                            .font(FocusStyle.secondaryFont)
                            .foregroundStyle(isToday ? FocusStyle.primaryText : FocusStyle.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: Self.chartHeight + 50)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Часы по дням: в задаче, ожидание и отвлечения")
        }
        .frame(maxWidth: .infinity)
    }

    private func stack(day: DayBar, height: CGFloat, highlighted: Bool) -> some View {
        let parts = Self.segmentHeights(day: day, barHeight: height)
        return VStack(spacing: 0) {
            Rectangle().fill(FocusStyle.distraction).frame(height: parts.distraction)
            Rectangle().fill(FocusStyle.waiting).frame(height: parts.waiting)
            Rectangle().fill(FocusStyle.accent).frame(height: parts.you)
        }
        .frame(width: 34, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay {
            if highlighted && height > 0 {
                RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.5), lineWidth: 2).padding(-2)
            }
        }
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 14, height: 10)
            Text(text).font(FocusStyle.secondaryFont).foregroundStyle(FocusStyle.tagText)
        }
    }

    private var tableCard: some View {
        let rows = report?.rows ?? []
        let widths = Self.shareWidths(rows: rows, maxWidth: Self.shareWidth)
        return FocusBox(fill: FocusStyle.barBackground, spacing: 0) {
            Text("Куда ушло время").font(.system(size: 14, weight: .bold)).padding(.bottom, 12)
            HStack(spacing: 8) {
                FocusSectionCaption("Задача").frame(maxWidth: .infinity, alignment: .leading)
                FocusSectionCaption("Время").frame(width: 170, alignment: .leading)
                FocusSectionCaption("Сессии").frame(width: 60, alignment: .leading)
                FocusSectionCaption("Статус").frame(width: 70, alignment: .leading)
            }
            .padding(.vertical, 6)
            Divider().overlay(FocusStyle.hairline)
            if rows.isEmpty {
                Text("Нет данных за неделю")
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                    .padding(.vertical, 12)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(.system(size: 13))
                            .foregroundStyle(row.taskID == nil ? FocusStyle.secondaryText : FocusStyle.primaryText)
                            .lineLimit(1)
                        if let project = row.projectName { ProjectTag(project) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        Capsule()
                            .fill(row.taskID == nil ? Color(focusHex: 0x636366) : Color(focusHex: 0x0A84FF))
                            .frame(width: max(widths[index], 2), height: 6)
                        Text(DaySummaryFormatter.duration(row.seconds)).monospacedDigit()
                    }
                    .frame(width: 170, alignment: .leading)
                    Text("\(row.sessions)").monospacedDigit().frame(width: 60, alignment: .leading)
                    Text(Self.status(row)).foregroundStyle(FocusStyle.secondaryText).frame(width: 70, alignment: .leading)
                }
                .font(.system(size: 13))
                .padding(.vertical, 8)
                Divider().overlay(Color.white.opacity(0.05))
            }
        }
        .frame(maxWidth: .infinity)
    }
}
