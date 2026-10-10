import FocusCore
import Foundation
import SwiftUI

struct TimelineAxis: Equatable {
    let start: Date
    let end: Date
    let hours: [Date]

    func fraction(_ date: Date) -> Double {
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(start) / span))
    }
}

extension FocusStyle {
    static let you = Color(focusHex: 0x0A84FF)
}

struct DayTimelineView: View {
    let report: DayReport
    var calendar: Calendar = .current

    private static let laneHeight: CGFloat = 18
    private static let labelWidth: CGFloat = 190

    nonisolated static func axis(first: Date?, last: Date?, calendar: Calendar) -> TimelineAxis? {
        guard let first, let last else { return nil }
        guard let startInterval = calendar.dateInterval(of: .hour, for: first),
              let endInterval = calendar.dateInterval(of: .hour, for: last) else { return nil }
        let start = startInterval.start
        var end = last > endInterval.start ? endInterval.end : endInterval.start
        if let minimum = calendar.date(byAdding: .hour, value: 1, to: start), end < minimum {
            end = minimum
        }
        var hours: [Date] = []
        var cursor = start
        while cursor <= end {
            hours.append(cursor)
            guard let next = calendar.date(byAdding: .hour, value: 1, to: cursor) else { break }
            cursor = next
        }
        return TimelineAxis(start: start, end: end, hours: hours)
    }

    nonisolated static func accessibilitySummary(_ report: DayReport) -> String {
        guard !(report.lanes.isEmpty && report.distractionLane.isEmpty) else { return "Нет данных за день" }
        var parts: [String] = report.lanes.compactMap { lane in
            func total(_ kind: ActivityKind) -> TimeInterval {
                lane.segments.filter { $0.kind == kind }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
            }
            var pieces: [String] = []
            if total(.claude) > 0 { pieces.append("Claude \(DaySummaryFormatter.duration(total(.claude)))") }
            if total(.you) > 0 { pieces.append("ты \(DaySummaryFormatter.duration(total(.you)))") }
            if total(.waiting) > 0 { pieces.append("ждал \(DaySummaryFormatter.duration(total(.waiting)))") }
            return pieces.isEmpty ? nil : "\(lane.title): \(pieces.joined(separator: ", "))"
        }
        if report.distractionSeconds > 0 {
            parts.append("Отвлечения: \(DaySummaryFormatter.duration(report.distractionSeconds))")
        }
        return parts.isEmpty ? "Нет данных за день" : parts.joined(separator: ". ")
    }

    nonisolated static func hourLabel(_ date: Date, calendar: Calendar) -> String {
        String(format: "%02d", calendar.component(.hour, from: date))
    }

    private static func color(_ kind: ActivityKind) -> Color {
        switch kind {
        case .claude: FocusStyle.working
        case .you: FocusStyle.you
        case .waiting: FocusStyle.waiting
        case .distraction: FocusStyle.distraction
        }
    }

    var body: some View {
        let axis = Self.axis(first: report.firstAt, last: report.lastAt, calendar: calendar)
        FocusBox(fill: FocusStyle.barBackground, spacing: 10) {
            HStack(spacing: 16) {
                Text("Как прошёл день по задачам")
                    .font(.system(size: 14, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                legend
            }
            if let axis {
                hourRow(axis)
                ForEach(report.lanes) { lane in
                    laneRow(title: lane.title, segments: lane.segments, axis: axis, dim: false)
                }
                laneRow(title: "Отвлечения", segments: report.distractionLane, axis: axis, dim: true)
            } else {
                Text("Пока нет данных за этот день")
                    .font(.system(size: 13))
                    .foregroundStyle(FocusStyle.secondaryText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilitySummary(report))
        .accessibilityAddTraits(.isImage)
    }

    private var legend: some View {
        HStack(spacing: 16) {
            legendItem("Claude работает", kind: .claude)
            legendItem("ты в задаче", kind: .you)
            legendItem("ждёт тебя", kind: .waiting)
            legendItem("отвлечение", kind: .distraction)
        }
    }

    private func legendItem(_ text: String, kind: ActivityKind) -> some View {
        HStack(spacing: 6) {
            Canvas { context, size in
                Self.paint(&context, rect: CGRect(origin: .zero, size: size), kind: kind, radius: 2)
            }
            .frame(width: 14, height: 10)
            Text(text).font(FocusStyle.secondaryFont).foregroundStyle(FocusStyle.tagText)
        }
    }

    private func hourRow(_ axis: TimelineAxis) -> some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: Self.labelWidth, height: 14)
            GeometryReader { geo in
                ForEach(Array(axis.hours.enumerated()), id: \.offset) { _, hour in
                    Text(Self.hourLabel(hour, calendar: calendar))
                        .font(FocusStyle.secondaryFont)
                        .foregroundStyle(FocusStyle.secondaryText)
                        .fixedSize()
                        .position(x: geo.size.width * axis.fraction(hour), y: 7)
                }
            }
            .frame(height: 14)
        }
    }

    private func laneRow(title: String, segments: [LaneSegment], axis: TimelineAxis, dim: Bool) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(dim ? FocusStyle.secondaryText : FocusStyle.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Self.labelWidth, alignment: .leading)
            Canvas { context, size in
                context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4), with: .color(Color.white.opacity(0.04)))
                for segment in segments {
                    let x0 = size.width * axis.fraction(segment.start)
                    let x1 = size.width * axis.fraction(segment.end)
                    guard x1 > x0 else { continue }
                    let rect = CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: size.height)
                    Self.paint(&context, rect: rect, kind: segment.kind, radius: 4)
                }
            }
            .frame(height: Self.laneHeight)
        }
        .frame(height: 30)
    }

    private static func paint(_ context: inout GraphicsContext, rect: CGRect, kind: ActivityKind, radius: CGFloat) {
        let color = color(kind)
        let outline = Path(roundedRect: rect, cornerRadius: radius)
        switch kind {
        case .claude, .you:
            context.fill(outline, with: .color(color))
        case .waiting, .distraction:
            var layer = context
            layer.clip(to: outline)
            layer.fill(Path(rect), with: .color(color.opacity(0.45)))
            let step: CGFloat = kind == .waiting ? 8 : 6
            let width: CGFloat = kind == .waiting ? 4 : 3
            let slope = rect.height
            var x = rect.minX - slope
            while x < rect.maxX {
                var line = Path()
                if kind == .waiting {
                    line.move(to: CGPoint(x: x, y: rect.maxY))
                    line.addLine(to: CGPoint(x: x + slope, y: rect.minY))
                } else {
                    line.move(to: CGPoint(x: x, y: rect.minY))
                    line.addLine(to: CGPoint(x: x + slope, y: rect.maxY))
                }
                layer.stroke(line, with: .color(color), lineWidth: width)
                x += step
            }
        }
    }
}
