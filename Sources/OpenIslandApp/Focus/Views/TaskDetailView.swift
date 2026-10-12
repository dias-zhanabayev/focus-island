import FocusCore
import SwiftUI

struct TaskTimeTotals: Equatable, Sendable {
    var totalSeconds: TimeInterval
    var claudeSeconds: TimeInterval
}

struct TaskDetailView: View {
    @Bindable var focus: FocusCoordinator
    @State var task: FocusTask
    var onRequestStart: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDelete = false
    @State private var totals = TaskTimeTotals(totalSeconds: 0, claudeSeconds: 0)
    @State private var queued: QueuedPrompt?
    @State private var records: [SessionRecord] = []
    @State private var todaySeconds: TimeInterval = 0
    @State private var showsSessionsPicker = false
    @State private var projectPaths: [String] = []
    @State private var resumable: Set<String> = []

    var body: some View {
        let now = Date.now
        let allRows = focus.hubRows.filter { $0.taskID == task.id }
        let rows = allRows.filter { $0.group != .done }
        let aggregate = focus.aggregate(taskID: task.id)
        let active = records.filter { $0.doneAt == nil }
        let unrowed = Self.unrowedLive(records: active, rows: allRows, live: focus.liveSessionIDs)
        let past = active.filter { !focus.liveSessionIDs.contains($0.id) }
        let done = records.filter { $0.doneAt != nil }
        VStack(alignment: .leading, spacing: 16) {
            header
            TaskPomodoroSection(
                focus: focus,
                taskID: task.id,
                column: focus.board.task(id: task.id)?.boardColumn,
                todaySeconds: todaySeconds,
                onMinute: reloadSpans
            )
            HStack(alignment: .top, spacing: 18) {
                leftColumn(aggregate: aggregate)
                rightColumn(rows: rows, unrowed: unrowed, past: past, done: done, now: now)
            }
            footer
        }
        .onAppear {
            projectPaths = focus.knownProjectPaths()
            reloadDerived()
        }
        .onChange(of: focus.workRevision) { reloadDerived() }
        .onChange(of: focus.aggregate(taskID: task.id)) { reloadDerived() }
        .onChange(of: focus.hubRows) { reloadDerived() }
        .onChange(of: focus.board.task(id: task.id)?.boardColumn) { _, column in
            if !Self.showsCloseTask(column: column) {
                showsSessionsPicker = false
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(width: 820)
        .background(FocusStyle.cardFill)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsSessionsPicker) {
            TaskSessionsPicker(
                focus: focus,
                taskID: task.id,
                listMaxHeight: 420,
                showsBack: false,
                onCancel: { showsSessionsPicker = false },
                onApplied: { showsSessionsPicker = false }
            )
            .padding(22)
            .frame(width: 620)
            .background(FocusStyle.cardFill)
            .preferredColorScheme(.dark)
        }
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
                ForEach(projectPaths, id: \.self) { path in
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

    private func rightColumn(rows: [HubRow], unrowed: [SessionRecord], past: [SessionRecord], done: [SessionRecord], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice = focus.doneSessionNotice, records.contains(where: { $0.id == notice.sessionID }) {
                DoneSessionNoticeBanner(notice: notice) { focus.reopenDoneSession(sessionID: notice.sessionID) }
            }
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
            DoneSessionsSection(
                items: done.map { DoneSessionItem(id: $0.id, title: focus.sessionLabel($0.id) ?? $0.title, detail: Self.doneDetail(record: $0)) },
                onReopen: { focus.reopenDoneSession(sessionID: $0) },
                onOpen: { id in
                    if focus.liveSessionIDs.contains(id) {
                        focus.requestJump(sessionID: id)
                    } else if let record = done.first(where: { $0.id == id }) {
                        focus.resume(record: record)
                    }
                }
            )
            if Self.showsCloseTask(column: focus.board.task(id: task.id)?.boardColumn) {
                Button("+ Добавить сессию") { showsSessionsPicker = true }
                    .buttonStyle(FocusButtonStyle(kind: rows.isEmpty && unrowed.isEmpty ? .primary : .secondary))
                    .padding(.top, 4)
            }
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
            enabled: true,
            showsDone: SessionDoneFormat.showsDoneButton(group: row.group),
            sessionID: row.id
        ) {
            focus.requestJump(sessionID: row.id)
        }
    }

    private func unrowedRow(_ record: SessionRecord) -> some View {
        sessionRow(
            dot: AnyView(StatusDot(color: FocusStyle.working)),
            title: focus.sessionLabel(record.id) ?? record.title,
            subtitle: "сейчас",
            progress: nil,
            actionTitle: "Перейти",
            enabled: true,
            sessionID: record.id
        ) {
            focus.resume(record: record)
        }
    }

    private func pastRow(_ record: SessionRecord, now: Date) -> some View {
        sessionRow(
            dot: AnyView(StatusDot(color: FocusStyle.parkedDot)),
            title: focus.sessionLabel(record.id) ?? record.title,
            subtitle: Self.pastSubtitle(record: record, now: now, calendar: .current),
            progress: nil,
            actionTitle: "Продолжить",
            enabled: resumable.contains(record.id),
            showsDone: true,
            sessionID: record.id
        ) {
            focus.resume(record: record)
        }
    }

    private func sessionRow(dot: AnyView, title: String, subtitle: String, progress: PlanProgress?, actionTitle: String, enabled: Bool, showsDone: Bool = false, sessionID: String, action: @escaping () -> Void) -> some View {
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
            if showsDone {
                SessionDoneButton { focus.markSessionDone(sessionID: sessionID) }
            }
            Button(actionTitle, action: action)
                .buttonStyle(FocusButtonStyle(kind: .secondary))
                .disabled(!enabled)
            SessionMoreMenu(focus: focus, sessionID: sessionID, taskID: task.id)
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
            if Self.showsCloseTask(column: focus.board.task(id: task.id)?.boardColumn) {
                Button {
                    closeTask()
                } label: {
                    Label("Закрыть задачу", systemImage: "checkmark")
                }
                .buttonStyle(FocusButtonStyle(kind: .done))
            }
            Button("Отмена") { dismiss() }
                .buttonStyle(FocusButtonStyle(kind: .secondary))
            Button("Сохранить") {
                let previous = focus.board.task(id: task.id)?.boardColumn
                if previous != task.boardColumn {
                    focus.moveTask(id: task.id, to: task.boardColumn, before: nil)
                }
                focus.updateTask(task)
                if PomodoroFormat.shouldRequestStart(from: previous, to: task.boardColumn) {
                    onRequestStart(task.id)
                }
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

    private func closeTask() {
        guard let stored = focus.board.task(id: task.id) else { return }
        var edited = task
        edited.boardColumn = stored.boardColumn
        if edited != stored, !edited.title.trimmingCharacters(in: .whitespaces).isEmpty {
            focus.updateTask(edited)
        }
        focus.closeTask(taskID: task.id, showPicker: false)
        dismiss()
    }

    nonisolated static func showsCloseTask(column: BoardColumn?) -> Bool {
        guard let column else { return false }
        return column != .done
    }

    private func reloadDerived() {
        reloadSpans()
        records = focus.sessions(forTaskID: task.id)
        resumable = Self.resumableIDs(records: records, live: focus.liveSessionIDs)
        queued = records.lazy.compactMap { focus.queuedPrompt(sessionID: $0.id) }.first
    }

    private func reloadSpans() {
        let now = Date.now
        let spans = focus.taskSpans(taskID: task.id, now: now)
        totals = Self.timeTotals(spans: spans, now: now)
        todaySeconds = Self.todaySeconds(spans: spans, now: now, calendar: .current)
    }

    nonisolated static func resumableIDs(records: [SessionRecord], live: Set<String>) -> Set<String> {
        Set(records.filter { record in
            live.contains(record.id) || record.cwd.map { FileManager.default.fileExists(atPath: $0) } == true
        }.map(\.id))
    }

    nonisolated static func todaySeconds(spans: [ActivitySpan], now: Date, calendar: Calendar) -> TimeInterval {
        let start = calendar.startOfDay(for: now)
        let clipped = spans.compactMap { span -> ActivitySpan? in
            let end = span.endedAt ?? now
            guard end > start else { return nil }
            var copy = span
            copy.startedAt = max(span.startedAt, start)
            copy.endedAt = end
            return copy
        }
        return timeTotals(spans: clipped, now: now).totalSeconds
    }

    nonisolated static func doneDetail(record: SessionRecord) -> String? {
        let end = record.doneAt ?? record.lastActivityAt
        let minutes = max(0, Int(end.timeIntervalSince(record.startedAt) / 60))
        guard minutes > 0 else { return nil }
        return minutes >= 60 ? "\(minutes / 60) ч \(minutes % 60) мин" : "\(minutes) мин"
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

struct TaskPomodoroSection: View {
    @Bindable var focus: FocusCoordinator
    let taskID: String
    let column: BoardColumn?
    let todaySeconds: TimeInterval
    let onMinute: () -> Void
    @State private var quickMinutes = 25
    @State private var confirmsReplace = false

    var body: some View {
        content
            .onAppear { quickMinutes = focus.settings.pomodoroFocusMinutes }
            .onChange(of: focus.pomodoro?.remainingSeconds) { _, remaining in
                if let remaining, remaining % 60 == 0 { onMinute() }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = focus.pomodoro, snapshot.taskID == taskID {
            PomodoroBlock(focus: focus, snapshot: snapshot, todaySeconds: todaySeconds)
        } else if Self.showsQuickStart(column: column) {
            focusTimerRow
        }
    }

    nonisolated static func showsQuickStart(column: BoardColumn?) -> Bool {
        column == .inProgress
    }

    private var focusTimerRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "timer")
                .font(.system(size: 14))
                .foregroundStyle(FocusStyle.captionText)
            Text("Фокус-таймер")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FocusStyle.primaryText)
            if let active = focus.pomodoro {
                Text(PomodoroFormat.activeElsewhereCaption(taskTitle: active.taskTitle))
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.waitingText)
                    .lineLimit(1)
            } else if let caption = PomodoroFormat.todayCaption(seconds: todaySeconds) {
                Text(caption)
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
            }
            Spacer()
            Menu {
                ForEach([15, 25, 30, 45, 50, 60, 90], id: \.self) { minutes in
                    Button("\(minutes) мин") { quickMinutes = minutes }
                }
            } label: {
                Text("\(quickMinutes) мин")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button(PomodoroFormat.quickStartTitle(minutes: quickMinutes)) {
                if focus.pomodoro != nil {
                    confirmsReplace = true
                } else {
                    focus.startPomodoro(taskID: taskID, minutes: quickMinutes)
                }
            }
            .buttonStyle(FocusButtonStyle(kind: .primary))
        }
        .confirmationDialog("Заменить текущее помодоро?", isPresented: $confirmsReplace) {
            Button("Заменить и начать \(quickMinutes) мин") {
                focus.startPomodoro(taskID: taskID, minutes: quickMinutes)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: FocusStyle.cardRadius).fill(FocusStyle.surface))
    }
}

struct PomodoroBlock: View {
    @Bindable var focus: FocusCoordinator
    let snapshot: PomodoroSnapshot
    let todaySeconds: TimeInterval

    var body: some View {
        let isBreak = snapshot.phase == .break
        let tint = isBreak ? FocusStyle.working : FocusStyle.link
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: min(1, max(0, snapshot.progress)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(PomodoroFormat.timerText(remainingSeconds: snapshot.remainingSeconds))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(FocusStyle.primaryText)
                    Text(PomodoroFormat.remainingCaption(plannedSeconds: snapshot.plannedSeconds))
                        .font(FocusStyle.secondaryFont)
                        .foregroundStyle(FocusStyle.secondaryText)
                }
                Text(isBreak ? "Перерыв" : PomodoroFormat.cycleCaption(index: snapshot.cycleIndex, cycle: snapshot.cycle))
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                if let caption = PomodoroFormat.todayCaption(seconds: todaySeconds) {
                    Text(caption)
                        .font(FocusStyle.secondaryFont)
                        .foregroundStyle(FocusStyle.captionText)
                }
            }
            Spacer()
            Button(PomodoroFormat.pauseTitle(isPaused: snapshot.isPaused)) {
                if snapshot.isPaused {
                    focus.resumePomodoro()
                } else {
                    focus.pausePomodoro()
                }
            }
            .buttonStyle(FocusButtonStyle(kind: .secondary))
            Button("Остановить") { focus.stopPomodoro() }
                .buttonStyle(FocusButtonStyle(kind: .secondary))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: FocusStyle.cardRadius).fill(tint.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: FocusStyle.cardRadius).stroke(tint.opacity(0.35), lineWidth: 1))
    }
}
