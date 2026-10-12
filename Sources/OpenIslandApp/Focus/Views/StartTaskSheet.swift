import FocusCore
import SwiftUI

enum PomodoroFormat {
    nonisolated static let focusChoices = [25, 50, 90]
    nonisolated static let breakChoices = [5, 10, 15, 20]

    nonisolated static func choiceTitle(_ minutes: Int, defaultMinutes: Int) -> String {
        minutes == defaultMinutes ? "\(minutes) мин · по умолчанию" : "\(minutes) мин"
    }

    nonisolated static func startFocusTitle(minutes: Int) -> String {
        "▶ Начать фокус · \(minutes) мин"
    }

    nonisolated static func breakButtonTitle(minutes: Int) -> String {
        "Перерыв \(minutes) мин"
    }

    nonisolated static func clampFocus(_ minutes: Int) -> Int {
        min(FocusSettings.pomodoroFocusRange.upperBound, max(FocusSettings.pomodoroFocusRange.lowerBound, minutes))
    }

    nonisolated static func timerText(remainingSeconds: Int) -> String {
        let total = max(0, remainingSeconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    nonisolated static func remainingCaption(plannedSeconds: Int) -> String {
        "осталось из \(plannedSeconds / 60) мин"
    }

    nonisolated static func cycleCaption(index: Int, cycle: Int) -> String {
        "Помодоро \(index) из \(cycle)"
    }

    nonisolated static func todayCaption(seconds: TimeInterval) -> String? {
        guard seconds > 0 else { return nil }
        return "сегодня по задаче \(FocusText.roundedUpMinutes(seconds)) мин"
    }

    nonisolated static func breakCaption(minutes: Int) -> String {
        "потом перерыв \(minutes) мин"
    }

    nonisolated static func startButtonTitle(minutes: Int?) -> String {
        guard let minutes else { return "Начать" }
        return "Начать · \(minutes) мин"
    }

    nonisolated static func quickStartTitle(minutes: Int) -> String {
        "Начать \(minutes) мин"
    }

    nonisolated static func pauseTitle(isPaused: Bool) -> String {
        isPaused ? "Продолжить" : "Пауза"
    }

    nonisolated static func sessionTag(_ session: BindableSession) -> String? {
        session.boundTaskTitle.map { "у задачи «\($0)»" }
    }

    nonisolated static func activeElsewhereCaption(taskTitle: String?) -> String {
        guard let taskTitle else { return "Сейчас идёт помодоро" }
        return "Сейчас идёт помодоро «\(taskTitle)»"
    }

    nonisolated static let replaceButtonTitle = "Заменить"

    nonisolated static func replaceCaption(pomodoro: PomodoroSnapshot?, startingTaskID: String) -> String? {
        guard let pomodoro, pomodoro.taskID != startingTaskID else { return nil }
        return activeElsewhereCaption(taskTitle: pomodoro.taskTitle)
    }

    nonisolated static func shouldRequestStart(from old: BoardColumn?, to new: BoardColumn) -> Bool {
        guard let old else { return false }
        return new == .inProgress && old != .inProgress
    }
}

enum StartTimerChoice: CaseIterable, Hashable, Sendable {
    case none
    case m25
    case m50
    case m90
    case custom

    var title: String {
        switch self {
        case .none: "Без таймера"
        case .m25: "25 мин"
        case .m50: "50 мин"
        case .m90: "90 мин"
        case .custom: "Своё…"
        }
    }

    nonisolated static func initial(defaultMinutes: Int) -> StartTimerChoice {
        switch defaultMinutes {
        case 25: .m25
        case 50: .m50
        case 90: .m90
        default: .custom
        }
    }

    nonisolated func minutes(custom: Int) -> Int? {
        switch self {
        case .none: nil
        case .m25: 25
        case .m50: 50
        case .m90: 90
        case .custom: PomodoroFormat.clampFocus(custom)
        }
    }
}

struct StartTaskItem: Identifiable, Equatable {
    let id: String
}

struct StartTaskSheet: View {
    @Bindable var focus: FocusCoordinator
    let taskID: String
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [BindableSession] = []
    @State private var selected: Set<String> = []
    @State private var choice: StartTimerChoice = .m50
    @State private var customMinutes = 25
    @State private var pendingStart: PendingStart?

    private enum PendingStart: Identifiable {
        case start

        var id: Self { self }
    }

    var body: some View {
        let task = focus.board.task(id: taskID)
        let minutes = choice.minutes(custom: customMinutes)
        VStack(alignment: .leading, spacing: 16) {
            header(task)
            sessionsSection
            timerSection(minutes: minutes)
            if let caption = replaceCaption {
                replaceWarning(caption)
            }
            buttons(minutes: minutes)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(width: 520)
        .background(FocusStyle.cardFill)
        .preferredColorScheme(.dark)
        .onAppear(perform: load)
        .confirmationDialog(
            replaceCaption ?? "",
            isPresented: Binding(get: { pendingStart != nil }, set: { if !$0 { pendingStart = nil } }),
            presenting: pendingStart
        ) { action in
            Button(PomodoroFormat.replaceButtonTitle, role: .destructive) {
                finish(action, minutes: minutes)
            }
            Button("Отмена", role: .cancel) {}
        } message: { _ in
            Text("Текущее помодоро будет остановлено, фокусной станет эта задача.")
        }
    }

    private var replaceCaption: String? {
        PomodoroFormat.replaceCaption(pomodoro: focus.pomodoro, startingTaskID: taskID)
    }

    private func replaceWarning(_ caption: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "timer")
                .font(.system(size: 12))
            Text("\(caption) — «Начать» его остановит")
                .font(FocusStyle.secondaryFont)
                .lineLimit(2)
        }
        .foregroundStyle(FocusStyle.waitingText)
    }

    private func request(_ action: PendingStart, minutes: Int?) {
        if replaceCaption != nil {
            pendingStart = action
        } else {
            finish(action, minutes: minutes)
        }
    }

    private func finish(_ action: PendingStart, minutes: Int?) {
        pendingStart = nil
        begin(minutes: minutes)
        dismiss()
    }

    private func header(_ task: FocusTask?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FocusSectionCaption("Задача в работе", color: FocusStyle.working)
            Text(task?.title ?? "")
                .font(FocusStyle.titleFont)
                .foregroundStyle(FocusStyle.primaryText)
                .lineLimit(3)
            if let path = task?.projectPath {
                HStack(spacing: 8) {
                    ProjectTag(URL(fileURLWithPath: path).lastPathComponent)
                    Text(path)
                        .font(FocusStyle.monoFont)
                        .foregroundStyle(FocusStyle.captionText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            FocusSectionCaption("Привязать открытые сессии")
            if sessions.isEmpty {
                Text("Открытых сессий нет")
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(sessions) { session in
                            sessionRow(session)
                        }
                    }
                }
                .frame(maxHeight: 190)
            }
        }
    }

    private func sessionRow(_ session: BindableSession) -> some View {
        let isOn = selected.contains(session.id)
        return Button {
            if isOn {
                selected.remove(session.id)
            } else {
                selected.insert(session.id)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(isOn ? FocusStyle.link : FocusStyle.captionText)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title)
                        .font(.system(size: 13))
                        .foregroundStyle(FocusStyle.primaryText)
                        .lineLimit(1)
                    Text(session.detail)
                        .font(FocusStyle.secondaryFont)
                        .foregroundStyle(FocusStyle.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let name = session.projectName {
                    ProjectTag(name)
                }
                if let tag = PomodoroFormat.sessionTag(session) {
                    Text(tag)
                        .font(.system(size: 11))
                        .foregroundStyle(FocusStyle.waitingText)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.04)))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "выбрано" : "не выбрано")
    }

    private func timerSection(minutes: Int?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FocusSectionCaption("Фокус-таймер · необязательно")
            HStack(spacing: 0) {
                ForEach(StartTimerChoice.allCases, id: \.self) { item in
                    Button {
                        choice = item
                    } label: {
                        Text(item.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(choice == item ? Color.white : FocusStyle.segmentText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(choice == item ? FocusStyle.segmentSelected : .clear))
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(choice == item ? .isSelected : [])
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8).fill(FocusStyle.segmentFill))
            if choice == .custom {
                Stepper(value: $customMinutes, in: FocusSettings.pomodoroFocusRange, step: 5) {
                    Text("\(customMinutes) мин")
                        .font(.system(size: 13))
                        .foregroundStyle(FocusStyle.primaryText)
                        .monospacedDigit()
                }
            }
            if minutes != nil {
                Text(PomodoroFormat.breakCaption(minutes: focus.settings.pomodoroBreakMinutes))
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
            }
        }
    }

    private func buttons(minutes: Int?) -> some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Позже") { dismiss() }
                .buttonStyle(FocusButtonStyle(kind: .secondary))
            Button(PomodoroFormat.startButtonTitle(minutes: minutes)) {
                request(.start, minutes: minutes)
            }
            .buttonStyle(FocusButtonStyle(kind: .primary))
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 6)
    }

    private func begin(minutes: Int?) {
        let ids = sessions.map(\.id).filter { selected.contains($0) }
        focus.startTask(taskID: taskID, sessionIDs: ids, focusMinutes: minutes)
    }

    private func load() {
        sessions = focus.bindableSessions(forTaskID: taskID)
        selected = Self.initialSelection(sessions)
        let defaultMinutes = focus.settings.pomodoroFocusMinutes
        choice = StartTimerChoice.initial(defaultMinutes: defaultMinutes)
        customMinutes = min(FocusSettings.pomodoroFocusRange.upperBound, max(FocusSettings.pomodoroFocusRange.lowerBound, defaultMinutes))
    }

    nonisolated static func initialSelection(_ sessions: [BindableSession]) -> Set<String> {
        Set(sessions.filter(\.defaultSelected).map(\.id))
    }
}
