import AppKit
import FocusCore
import Foundation
import SwiftUI

enum DaySummaryFormatter {
    nonisolated static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        guard minutes >= 60 else { return "\(minutes) м" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) ч" : "\(minutes / 60) ч \(rest) м"
    }

    nonisolated static func title(_ day: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE, d MMMM"
        let text = formatter.string(from: day)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    nonisolated static func range(first: Date?, last: Date?, calendar: Calendar = .current) -> String? {
        guard let first, let last else { return nil }
        func clock(_ date: Date) -> String {
            String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
        }
        return "\(clock(first)) – \(clock(last))"
    }

    nonisolated static func distractionDetail(count: Int, returned: Int) -> String? {
        guard count > 0 else { return nil }
        let mod10 = count % 10
        let mod100 = count % 100
        let word = (2...4).contains(mod10) && !(12...14).contains(mod100) ? "раза" : "раз"
        return "\(count) \(word), вернулся \(returned)"
    }

    nonisolated static func done(tasks: [FocusTask], dayStart: Date, dayEnd: Date) -> [FocusTask] {
        tasks.filter { task in
            guard let doneAt = task.doneAt else { return false }
            return doneAt >= dayStart && doneAt < dayEnd
        }
    }

    nonisolated static func open(tasks: [FocusTask], report: DayReport?, dayStart: Date, dayEnd: Date) -> [FocusTask] {
        let active = report?.activeTaskIDs ?? []
        return tasks.filter { task in
            task.boardColumn == .inProgress
                && (active.contains(task.id) || (task.updatedAt >= dayStart && task.updatedAt < dayEnd))
        }
    }

    nonisolated static func openSubtitle(progress: CriteriaProgress?, hasQueuedPrompt: Bool) -> String? {
        var parts: [String] = []
        if let progress, progress.total > 0 { parts.append("критерий \(progress.done) из \(progress.total)") }
        if hasQueuedPrompt { parts.append("промпт в очереди") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    nonisolated static func rolledOver(from loaded: Date, to now: Date, calendar: Calendar = .current) -> Bool {
        !calendar.isDate(loaded, inSameDayAs: now)
    }

    nonisolated static func listItem(_ title: String) -> String {
        var text = title.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        if text.hasPrefix("#") { text = "\\" + text }
        return "- \(text)"
    }

    nonisolated static func markdown(report: DayReport, done: [FocusTask], open: [FocusTask], tomorrow: String?, day: Date, pomodoroCount: Int = 0, calendar: Calendar = .current) -> String {
        var distraction = "- Отвлечения: \(duration(report.distractionSeconds))"
        if let detail = distractionDetail(count: report.distractionCount, returned: report.returnedCount) {
            distraction += " (\(detail))"
        }
        var lines = [
            "- Ты в работе: \(duration(report.youSeconds))",
            "- Claude работал: \(duration(report.claudeSeconds))",
            "- Сессии ждали тебя: \(duration(report.waitingSeconds))",
            distraction
        ]
        if pomodoroCount > 0 { lines.append("- Помодоро: \(pomodoroCount)") }
        lines.append("- Макс. параллельно: \(report.maxParallel)")
        let kpis = lines.joined(separator: "\n")
        var blocks = ["# \(title(day, calendar: calendar))", kpis]
        if !done.isEmpty {
            blocks.append((["## Сделано"] + done.map { listItem($0.title) }).joined(separator: "\n"))
        }
        if !open.isEmpty {
            blocks.append((["## Осталось открытым"] + open.map { listItem($0.title) }).joined(separator: "\n"))
        }
        if let note = tomorrow?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            blocks.append("## Завтра начать с\n\(note)")
        }
        return blocks.joined(separator: "\n\n")
    }
}

extension FocusStyle {
    static let distractionText = Color(focusHex: 0xFF6961)
    static let tomorrowBorder = Color(focusHex: 0xBF5AF2, opacity: 0.35)
}

struct DaySummaryView: View {
    @Bindable var focus: FocusCoordinator
    @State private var report: DayReport?
    @State private var pomodoroCount = 0
    @State private var doneTasks: [FocusTask] = []
    @State private var openTasks: [FocusTask] = []
    @State private var subtitles: [String: String] = [:]
    @State private var note = ""
    @State private var savedNote = ""
    @State private var noteLoaded = false
    @State private var reportDay = Date.now
    @State private var noteDay = Date.now
    @State private var copied = false
    @FocusState private var noteFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                kpiRow
                if let report {
                    DayTimelineView(report: report)
                }
                HStack(alignment: .top, spacing: 12) {
                    doneCard
                    openCard
                    tomorrowCard
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .task {
            while !Task.isCancelled {
                reload()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onChange(of: focus.workRevision) { _, _ in reload() }
        .onChange(of: focus.board) { _, _ in reload() }
        .onChange(of: focus.pomodoroCountToday) { _, _ in reload() }
        .onChange(of: noteFocused) { _, focused in
            if !focused { saveNote() }
        }
        .onDisappear { saveNote() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(DaySummaryFormatter.title(reportDay))
                .font(.system(size: 22, weight: .bold))
            if let range = DaySummaryFormatter.range(first: report?.firstAt, last: report?.lastAt) {
                Text(range).font(.system(size: 12)).foregroundStyle(FocusStyle.secondaryText)
            }
            Spacer(minLength: 0)
            Button(copied ? "Скопировано" : "Скопировать в заметку", action: copy)
                .buttonStyle(FocusButtonStyle(kind: .secondary, height: 28, horizontalPadding: 12))
                .disabled(report == nil)
        }
    }

    private var kpiRow: some View {
        let value = report
        return HStack(alignment: .top, spacing: 12) {
            kpi("Ты в работе", value.map { DaySummaryFormatter.duration($0.youSeconds) } ?? "—")
            kpi("Claude работал", value.map { DaySummaryFormatter.duration($0.claudeSeconds) } ?? "—")
            kpi("Сессии ждали тебя", value.map { DaySummaryFormatter.duration($0.waitingSeconds) } ?? "—", color: FocusStyle.waitingText)
            kpi(
                "Отвлечения",
                value.map { DaySummaryFormatter.duration($0.distractionSeconds) } ?? "—",
                color: FocusStyle.distractionText,
                detail: value.flatMap { DaySummaryFormatter.distractionDetail(count: $0.distractionCount, returned: $0.returnedCount) }
            )
            kpi("Помодоро", value == nil ? "—" : "\(pomodoroCount)")
            kpi("Макс. параллельно", value.map { "\($0.maxParallel)" } ?? "—", detail: "комфортно до \(focus.settings.maxParallelSessions)")
        }
    }

    private func kpi(_ label: String, _ value: String, color: Color = FocusStyle.primaryText, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(FocusStyle.secondaryFont).foregroundStyle(FocusStyle.secondaryText)
            Text(value)
                .font(.system(size: 26, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(color)
            if let detail {
                Text(detail).font(FocusStyle.secondaryFont).foregroundStyle(FocusStyle.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: FocusStyle.rowRadius).fill(FocusStyle.barBackground))
        .accessibilityElement(children: .combine)
    }

    private var doneCard: some View {
        FocusBox(fill: FocusStyle.barBackground, spacing: 4) {
            Text("Сделано · \(doneTasks.count)").font(.system(size: 14, weight: .bold))
            if doneTasks.isEmpty {
                emptyLine("Пока ничего не закрыто")
            }
            ForEach(doneTasks) { task in
                HStack(spacing: 10) {
                    Text("✓").foregroundStyle(FocusStyle.working)
                    Text(task.title).frame(maxWidth: .infinity, alignment: .leading)
                    if let project = task.projectPath.map({ URL(fileURLWithPath: $0).lastPathComponent }) {
                        ProjectTag(project)
                    }
                }
                .font(.system(size: 13))
                .padding(.vertical, 4)
            }
        }
    }

    private var openCard: some View {
        FocusBox(fill: FocusStyle.barBackground, spacing: 4) {
            Text("Осталось открытым · \(openTasks.count)").font(.system(size: 14, weight: .bold))
            if openTasks.isEmpty {
                emptyLine("Открытых задач нет")
            }
            ForEach(openTasks) { task in
                HStack(spacing: 10) {
                    StatusDot(color: FocusStyle.working)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(task.title).font(.system(size: 13))
                        if let subtitle = subtitles[task.id] {
                            Text(subtitle).font(FocusStyle.secondaryFont).foregroundStyle(FocusStyle.secondaryText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var tomorrowCard: some View {
        FocusBox(fill: FocusStyle.barBackground, border: FocusStyle.tomorrowBorder, spacing: 8) {
            Text("Завтра начать с").font(.system(size: 14, weight: .bold))
            Text("Утром island покажет это первым").font(FocusStyle.secondaryFont).foregroundStyle(FocusStyle.secondaryText)
            TextEditor(text: $note)
                .focused($noteFocused)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(height: 64)
                .background(RoundedRectangle(cornerRadius: FocusStyle.buttonRadius).fill(FocusStyle.fieldFill))
                .overlay(RoundedRectangle(cornerRadius: FocusStyle.buttonRadius).stroke(FocusStyle.fieldBorder, lineWidth: 1))
                .accessibilityLabel("Завтра начать с")
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(FocusStyle.secondaryText).padding(.vertical, 4)
    }

    private func bounds(now: Date) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        return (start, calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
    }

    private func reload(now: Date = .now) {
        if noteLoaded, DaySummaryFormatter.rolledOver(from: noteDay, to: now) {
            saveNote()
            noteLoaded = false
        }
        loadNote(now: now)
        reportDay = now
        let range = bounds(now: now)
        let loaded = focus.dayReport(day: now, now: now)
        let tasks = focus.board.tasks
        let open = DaySummaryFormatter.open(tasks: tasks, report: loaded, dayStart: range.start, dayEnd: range.end)
        var texts: [String: String] = [:]
        for task in open {
            let queued = focus.aggregate(taskID: task.id).records.contains { focus.queuedPrompt(sessionID: $0.id) != nil }
            if let text = DaySummaryFormatter.openSubtitle(progress: focus.criteriaProgress(taskID: task.id), hasQueuedPrompt: queued) {
                texts[task.id] = text
            }
        }
        report = loaded
        pomodoroCount = focus.pomodoroCount(day: now)
        doneTasks = DaySummaryFormatter.done(tasks: tasks, dayStart: range.start, dayEnd: range.end)
        openTasks = open
        subtitles = texts
    }

    private func loadNote(now: Date = .now) {
        guard !noteLoaded else { return }
        noteLoaded = true
        noteDay = now
        let stored = focus.dayPlan(day: now)?.tomorrowNote ?? ""
        note = stored
        savedNote = stored
    }

    private func saveNote() {
        guard noteLoaded else { return }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != savedNote else { return }
        focus.setTomorrowNote(trimmed, day: noteDay)
        savedNote = trimmed
    }

    private func copy() {
        reload()
        guard let report else { return }
        let text = DaySummaryFormatter.markdown(report: report, done: doneTasks, open: openTasks, tomorrow: note, day: reportDay, pomodoroCount: pomodoroCount)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
