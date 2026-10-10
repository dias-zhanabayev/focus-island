import FocusCore
import SwiftUI

struct TaskTimeTotals: Equatable, Sendable {
    var totalSeconds: TimeInterval
    var claudeSeconds: TimeInterval
}

struct TaskDetailView: View {
    @Bindable var focus: FocusCoordinator
    @State var task: FocusTask
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDelete = false
    @State private var totals = TaskTimeTotals(totalSeconds: 0, claudeSeconds: 0)
    @State private var queued: QueuedPrompt?
    @State private var records: [SessionRecord] = []

    var body: some View {
        let now = Date.now
        let rows = focus.hubRows.filter { $0.taskID == task.id }
        let aggregate = focus.aggregate(taskID: task.id)
        let unrowed = Self.unrowedLive(records: records, rows: rows, live: focus.liveSessionIDs)
        let past = records.filter { !focus.liveSessionIDs.contains($0.id) }
        VStack(alignment: .leading, spacing: 16) {
            header
            HStack(alignment: .top, spacing: 18) {
                leftColumn(aggregate: aggregate)
                rightColumn(rows: rows, unrowed: unrowed, past: past, now: now)
            }
            footer
        }
        .onAppear(perform: reloadDerived)
        .onChange(of: focus.workRevision) { reloadDerived() }
        .onChange(of: focus.aggregate(taskID: task.id)) { reloadDerived() }
        .onChange(of: focus.hubRows) { reloadDerived() }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(width: 820)
        .background(FocusStyle.cardFill)
        .preferredColorScheme(.dark)
        .confirmationDialog("Удалить задачу? Сессии останутся в истории.", isPresented: $confirmsDelete) {
            Button("Удалить", role: .destructive) {
                focus.deleteTask(id: task.id)
                dismiss()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            TextField("Заголовок", text: $task.title)
                .textFieldStyle(.plain)
                .font(FocusStyle.titleFont)
                .foregroundStyle(FocusStyle.primaryText)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: FocusStyle.buttonRadius).fill(FocusStyle.fieldFill))
                .overlay(RoundedRectangle(cornerRadius: FocusStyle.buttonRadius).stroke(FocusStyle.fieldBorder, lineWidth: 1))
            Picker("Колонка", selection: $task.boardColumn) {
                ForEach(BoardColumn.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Picker("Проект", selection: $task.projectPath) {
                Text("Без проекта").tag(String?.none)
                ForEach(focus.knownProjectPaths(), id: \.self) { path in
                    Text(URL(fileURLWithPath: path).lastPathComponent).tag(String?.some(path))
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private func leftColumn(aggregate: TaskAggregate) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            field("Описание", text: detailsBinding, height: 72)
            VStack(alignment: .leading, spacing: 6) {
                FocusSectionCaption(Self.criteriaCaption(aggregate.criteria))
                CriteriaChecklist(focus: focus, taskID: task.id)
            }
            field("Где остановился", text: noteBinding, height: 52)
            if let prompt = queued {
                VStack(alignment: .leading, spacing: 3) {
                    FocusSectionCaption("Промпт в очереди", color: FocusStyle.link)
                    Text(prompt.text)
                        .font(.system(size: 13))
                        .foregroundStyle(FocusStyle.primaryText)
                        .lineLimit(4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: FocusStyle.smallRadius).fill(Color(focusHex: 0x0A84FF, opacity: 0.08)))
                .overlay(RoundedRectangle(cornerRadius: FocusStyle.smallRadius).stroke(FocusStyle.link.opacity(0.35), lineWidth: 1))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func rightColumn(rows: [HubRow], unrowed: [SessionRecord], past: [SessionRecord], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                FocusSectionCaption(Self.sessionsCaption(count: rows.count + unrowed.count + past.count))
                Spacer(minLength: 8)
                if let summary = Self.timeSummary(totals) {
                    Text(summary)
                        .font(FocusStyle.secondaryFont)
                        .foregroundStyle(FocusStyle.secondaryText)
                        .lineLimit(1)
                }
            }
            ForEach(rows) { row in
                liveRow(row)
            }
            ForEach(unrowed) { record in
                unrowedRow(record)
            }
            ForEach(past) { record in
                pastRow(record, now: now)
            }
            Button("Новая сессия по задаче") {
                focus.startNewSession(forTaskID: task.id)
            }
            .buttonStyle(FocusButtonStyle(kind: .secondary))
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func liveRow(_ row: HubRow) -> some View {
        sessionRow(
            dot: AnyView(StatusDot(color: TaskCardView.dotColor(row.group))),
            title: focus.sessionTitle(row.id),
            subtitle: Self.liveSubtitle(progress: row.progress, group: row.group),
            progress: row.group == .running ? row.progress : nil,
            actionTitle: "Перейти",
            enabled: true
        ) {
            focus.requestJump(sessionID: row.id)
        }
    }

    private func unrowedRow(_ record: SessionRecord) -> some View {
        sessionRow(
            dot: AnyView(StatusDot(color: FocusStyle.working)),
            title: record.title,
            subtitle: "сейчас",
            progress: nil,
            actionTitle: "Перейти",
            enabled: true
        ) {
            focus.resume(record: record)
        }
    }

    private func pastRow(_ record: SessionRecord, now: Date) -> some View {
        sessionRow(
            dot: AnyView(StatusDot(color: FocusStyle.parkedDot)),
            title: record.title,
            subtitle: Self.pastSubtitle(record: record, now: now, calendar: .current),
            progress: nil,
            actionTitle: "Продолжить",
            enabled: focus.canResume(record)
        ) {
            focus.resume(record: record)
        }
    }

    private func sessionRow(dot: AnyView, title: String, subtitle: String, progress: PlanProgress?, actionTitle: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            dot
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13)).foregroundStyle(FocusStyle.primaryText).lineLimit(1)
                Text(subtitle).font(FocusStyle.secondaryFont).foregroundStyle(FocusStyle.secondaryText).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let progress {
                PlanProgressBar(progress: progress, width: 70)
            }
            Button(actionTitle, action: action)
                .buttonStyle(FocusButtonStyle(kind: .secondary))
                .disabled(!enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.04)))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Удалить задачу") { confirmsDelete = true }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FocusStyle.removed)
            Spacer()
            Button("Отмена") { dismiss() }
                .buttonStyle(FocusButtonStyle(kind: .secondary))
            Button("Сохранить") {
                if focus.board.task(id: task.id)?.boardColumn != task.boardColumn {
                    focus.moveTask(id: task.id, to: task.boardColumn, before: nil)
                }
                focus.updateTask(task)
                dismiss()
            }
            .buttonStyle(FocusButtonStyle(kind: .primary))
            .keyboardShortcut(.defaultAction)
            .disabled(task.title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.top, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
    }

    private func field(_ caption: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FocusSectionCaption(caption)
            TextEditor(text: text)
                .font(.system(size: 13))
                .foregroundStyle(FocusStyle.primaryText)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: FocusStyle.buttonRadius).fill(FocusStyle.fieldFill))
                .overlay(RoundedRectangle(cornerRadius: FocusStyle.buttonRadius).stroke(FocusStyle.fieldBorder, lineWidth: 1))
        }
    }

    private var detailsBinding: Binding<String> {
        Binding(get: { task.details ?? "" }, set: { task.details = $0.isEmpty ? nil : $0 })
    }

    private var noteBinding: Binding<String> {
        Binding(get: { task.note ?? "" }, set: { task.note = $0.isEmpty ? nil : $0 })
    }

    private func reloadDerived() {
        totals = Self.timeTotals(spans: focus.taskSpans(taskID: task.id, now: .now), now: .now)
        records = focus.sessions(forTaskID: task.id)
        queued = records.lazy.compactMap { focus.queuedPrompt(sessionID: $0.id) }.first
    }

    nonisolated static func unrowedLive(records: [SessionRecord], rows: [HubRow], live: Set<String>) -> [SessionRecord] {
        let rowIDs = Set(rows.map(\.id))
        return records.filter { live.contains($0.id) && !rowIDs.contains($0.id) }
    }

    nonisolated static func criteriaCaption(_ progress: CriteriaProgress?) -> String {
        guard let progress else { return "Критерий готовности" }
        return "Критерий готовности · \(progress.done) из \(progress.total)"
    }

    nonisolated static func sessionsCaption(count: Int) -> String {
        "Сессии · \(count)"
    }

    nonisolated static func timeSummary(_ totals: TaskTimeTotals) -> String? {
        guard totals.totalSeconds > 0 else { return nil }
        return "всего \(BoardView.duration(totals.totalSeconds)) · Claude \(BoardView.duration(totals.claudeSeconds))"
    }

    nonisolated static func timeTotals(spans: [ActivitySpan], now: Date) -> TaskTimeTotals {
        func intervals(_ kinds: Set<ActivityKind>) -> [(Date, Date)] {
            spans
                .filter { kinds.contains($0.kind) }
                .map { ($0.startedAt, $0.endedAt ?? now) }
                .filter { $0.1 > $0.0 }
        }
        return TaskTimeTotals(
            totalSeconds: unionSeconds(intervals([.claude, .you])),
            claudeSeconds: unionSeconds(intervals([.claude]))
        )
    }

    nonisolated private static func unionSeconds(_ intervals: [(Date, Date)]) -> TimeInterval {
        var total: TimeInterval = 0
        var current: (Date, Date)?
        for interval in intervals.sorted(by: { $0.0 < $1.0 }) {
            if let existing = current {
                if interval.0 <= existing.1 {
                    current = (existing.0, max(existing.1, interval.1))
                } else {
                    total += existing.1.timeIntervalSince(existing.0)
                    current = interval
                }
            } else {
                current = interval
            }
        }
        if let current {
            total += current.1.timeIntervalSince(current.0)
        }
        return total
    }

    nonisolated static func liveSubtitle(progress: PlanProgress?, group: HubGroup) -> String {
        switch group {
        case .waiting:
            return "ждёт тебя"
        case .review:
            return "готово, не просмотрено"
        default:
            guard let progress else { return "сейчас" }
            return "сейчас · шаг \(min(progress.total, progress.completed + 1)) из \(progress.total)"
        }
    }

    nonisolated static func pastSubtitle(record: SessionRecord, now: Date, calendar: Calendar) -> String {
        let clock = calendar.dateComponents([.hour, .minute], from: record.startedAt)
        let time = String(format: "%02d:%02d", clock.hour ?? 0, clock.minute ?? 0)
        var parts = [
            "\(TaskCardView.dayLabel(record.startedAt, now: now, calendar: calendar)), \(time)",
            BoardView.duration(TaskCardView.sessionSeconds(record))
        ]
        if let message = record.lastAssistantMessage.map({ FocusText.truncated($0, limit: FocusText.rowMessageLimit) }), !message.isEmpty {
            parts.append(message)
        }
        return parts.joined(separator: " · ")
    }

    nonisolated static func newSessionCwd(projectPath: String?, home: String) -> String {
        guard let projectPath, !projectPath.isEmpty else { return home }
        return projectPath
    }
}
