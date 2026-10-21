import AppKit
import FocusCore
import SwiftUI

struct OnboardingCard: View {
    enum Stage: Equatable {
        case connect
        case firstTask
        case started
    }

    @Bindable var focus: FocusCoordinator
    let installHooks: () -> Void
    @State private var taskText = ""
    @State private var criterionText = ""
    @State private var selected: Set<String> = []
    @State private var anchorID: String?

    init(focus: FocusCoordinator, installHooks: @escaping () -> Void) {
        self.focus = focus
        self.installHooks = installHooks
    }

    private var stage: Stage {
        Self.stage(hooksInstalled: focus.hooksInstalled, taskAdded: focus.onboardingTaskAdded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch stage {
            case .connect: connectStage
            case .firstTask: firstTaskStage
            case .started: startedStage
            }
        }
    }

    private var connectStage: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepDots(current: 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Focus Island").font(FocusStyle.titleFont)
                Text("Держит в голове сессии Claude и задачи, чтобы ты не держал. Подключись — и заведём первую задачу.")
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Подключить Claude Code").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("Добавит хуки в ~/.claude/settings.json. Убрать можно в настройках.")
                        .font(FocusStyle.secondaryFont)
                        .foregroundStyle(FocusStyle.secondaryText)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Подключить", action: installHooks)
                    .buttonStyle(FocusButtonStyle(kind: .primary))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: FocusStyle.cardRadius).fill(FocusStyle.surface))
            footer(caption: "Всё хранится только на этом Mac", buttonTitle: "Позже")
        }
    }

    private var firstTaskStage: some View {
        let candidates = focus.firstTaskCandidates()
        let typing = Self.canAddTask(text: taskText)
        return VStack(alignment: .leading, spacing: 12) {
            StepDots(current: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text("Над чем работаешь сейчас?").font(FocusStyle.titleFont)
                Text("Одна задача в фокусе. Остров будет держать её сессии и время, а ты — только код.")
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(2)
            }
            TextField("Например: перевести auth на токены", text: $taskText)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 10).fill(FocusStyle.surface))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(typing ? FocusStyle.link : FocusStyle.hairline, lineWidth: 1))
                .onSubmit { start(candidates: candidates) }
                .accessibilityLabel("Название задачи")
                .onChange(of: typing) { _, isTyping in
                    if isTyping, anchorID == nil {
                        selected = OnboardingCard.preselection(candidates: candidates, anchorID: nil)
                    }
                }
            if typing {
                if !candidates.isEmpty {
                    FocusSectionCaption("Сессии в эту задачу")
                    ForEach(candidates) { candidate in
                        candidateToggle(candidate)
                    }
                }
                HStack(spacing: 8) {
                    Text("Готово, когда")
                        .font(FocusStyle.secondaryFont)
                        .foregroundStyle(FocusStyle.secondaryText)
                        .fixedSize()
                    TextField("необязательно", text: $criterionText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onSubmit { start(candidates: candidates) }
                        .accessibilityLabel("Готово, когда")
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(FocusStyle.surface))
                HStack(spacing: 8) {
                    Button("Пропустить") { focus.dismissOnboarding() }
                        .buttonStyle(FocusButtonStyle(kind: .quiet, height: 28, horizontalPadding: 6))
                    Spacer(minLength: 0)
                    Button("Начать задачу") { start(candidates: candidates) }
                        .buttonStyle(FocusButtonStyle(kind: .primary, height: 34, horizontalPadding: 18))
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                if !candidates.isEmpty {
                    FocusSectionCaption("Или продолжи то, что уже идёт")
                    ForEach(candidates.prefix(FocusCoordinator.firstTaskSuggestionLimit)) { candidate in
                        suggestionRow(candidate, candidates: candidates)
                    }
                }
                footer(caption: "Автоматизацию macOS спросит сам, когда впервые перейдёшь в сессию", buttonTitle: "Пропустить")
            }
        }
    }

    private var startedStage: some View {
        let task = focus.currentTask
        let rows = focus.focusTaskSessions
        let minutes = PomodoroFormat.clampFocus(focus.settings.pomodoroFocusMinutes)
        return VStack(alignment: .leading, spacing: 12) {
            StepDots(current: 3)
            if !rows.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(FocusStyle.working)
                        .accessibilityHidden(true)
                    Text(Self.startedToast(sessionCount: rows.count))
                        .font(FocusStyle.secondaryFont)
                        .foregroundStyle(FocusStyle.tagText)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: FocusStyle.smallRadius).fill(FocusStyle.working.opacity(0.12)))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("В фокусе")
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                Text(task?.title ?? "Задача")
                    .font(FocusStyle.titleFont)
                    .lineLimit(2)
            }
            if rows.isEmpty {
                waitingForSession(projectPath: task?.projectPath)
            } else {
                ForEach(rows) { row in
                    startedRow(row)
                }
            }
            VStack(spacing: 6) {
                Button {
                    if let task {
                        focus.startPomodoro(taskID: task.id, minutes: minutes)
                    }
                    focus.dismissOnboarding()
                } label: {
                    Text("▶ Фокус \(minutes) минут")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(FocusButtonStyle(kind: .primary, height: 38))
                .font(.system(size: 15, weight: .semibold))
                .keyboardShortcut(.defaultAction)
                Text(rows.isEmpty ? "Можно начать фокус и сейчас — сессии подтянутся по ходу" : "Пока идёт фокус, Claude зовёт только по делу. Потом перерыв \(focus.settings.pomodoroBreakMinutes) минут.")
                    .font(.system(size: 11))
                    .foregroundStyle(FocusStyle.captionText)
                    .lineLimit(2)
            }
            footer(caption: "Доска со всеми задачами — \(focus.settings.boardHotKey.title)", buttonTitle: "Без таймера")
        }
    }

    private func suggestionRow(_ candidate: FirstTaskCandidate, candidates: [FirstTaskCandidate]) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FocusStyle.primaryText)
                    .lineLimit(1)
                Text(Self.candidateDetail(cwd: candidate.cwd, appName: candidate.appName))
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let status = SessionStatusKind.of(candidate.group) {
                SessionStatusBadge(kind: status)
            }
            Button("Взять") {
                anchorID = candidate.id
                selected = Self.preselection(candidates: candidates, anchorID: candidate.id)
                taskText = candidate.title
            }
            .buttonStyle(FocusButtonStyle(kind: .secondary, height: 28))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: FocusStyle.rowRadius).fill(FocusStyle.surface))
    }

    private func candidateToggle(_ candidate: FirstTaskCandidate) -> some View {
        let isOn = selected.contains(candidate.id)
        return Button {
            if isOn { selected.remove(candidate.id) } else { selected.insert(candidate.id) }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isOn ? FocusStyle.accent : Color.clear)
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isOn ? FocusStyle.accent : Color.white.opacity(0.3), lineWidth: 1.5)
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isOn ? FocusStyle.primaryText : FocusStyle.secondaryText)
                        .lineLimit(1)
                    Text(Self.candidateDetail(cwd: candidate.cwd, appName: candidate.appName))
                        .font(.system(size: 11))
                        .foregroundStyle(FocusStyle.captionText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let status = SessionStatusKind.of(candidate.group) {
                    SessionStatusBadge(kind: status)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate.title)
        .accessibilityValue(isOn ? "в задаче" : "не в задаче")
    }

    private func startedRow(_ row: HubRow) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(focus.sessionLabel(row.id) ?? focus.sessionTitle(row.id))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(row.detail)
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let status = SessionStatusKind.of(row.group) {
                SessionStatusBadge(kind: status)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.05)))
    }

    private func waitingForSession(projectPath: String?) -> some View {
        let command = Self.launchCommand(projectPath: projectPath)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(FocusStyle.link)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(FocusStyle.link.opacity(0.25), lineWidth: 5))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Жду первую сессию Claude")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Запусти claude в терминале, IDE или Claude.app — сессия сама попадёт в эту задачу.")
                        .font(FocusStyle.secondaryFont)
                        .foregroundStyle(FocusStyle.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .stroke(FocusStyle.link.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            HStack(spacing: 10) {
                Text("$ " + command)
                    .font(FocusStyle.monoFont)
                    .foregroundStyle(FocusStyle.tagText)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Скопировать") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .buttonStyle(FocusButtonStyle(kind: .secondary, height: 24, horizontalPadding: 10))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.35)))
        }
    }

    private func footer(caption: String, buttonTitle: String) -> some View {
        HStack(spacing: 8) {
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(FocusStyle.captionText)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(buttonTitle) { focus.dismissOnboarding() }
                .buttonStyle(FocusButtonStyle(kind: .quiet, height: 26))
        }
    }

    private func start(candidates: [FirstTaskCandidate]) {
        guard Self.canAddTask(text: taskText) else { return }
        let ids = candidates.map(\.id).filter { selected.contains($0) }
        focus.startFirstTask(title: taskText, sessionIDs: ids, criterion: criterionText)
        taskText = ""
        criterionText = ""
    }

    nonisolated static func stage(hooksInstalled: Bool?, taskAdded: Bool) -> Stage {
        if taskAdded { return .started }
        return hooksInstalled == true ? .firstTask : .connect
    }

    nonisolated static func canAddTask(text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated static func preselection(candidates: [FirstTaskCandidate], anchorID: String?) -> Set<String> {
        FocusCoordinator.firstTaskPreselection(candidates: candidates, anchorID: anchorID)
    }

    nonisolated static func startedToast(sessionCount: Int) -> String {
        "Задача в работе · \(FocusCoordinator.sessionCountText(sessionCount)) внутри"
    }

    nonisolated static func candidateDetail(cwd: String?, appName: String?) -> String {
        var parts: [String] = []
        if let cwd, !cwd.isEmpty {
            parts.append(Self.shortPath(cwd))
        }
        if let appName, !appName.isEmpty {
            parts.append(appName)
        }
        return parts.isEmpty ? "сессия Claude" : parts.joined(separator: " · ")
    }

    nonisolated static func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    nonisolated static func launchCommand(projectPath: String?) -> String {
        guard let projectPath, !projectPath.isEmpty else { return "claude" }
        let target = projectPath.contains(" ") ? "\"\(projectPath)\"" : shortPath(projectPath)
        return "cd \(target) && claude"
    }
}

private struct StepDots: View {
    let current: Int
    let total = 3

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...total, id: \.self) { index in
                Capsule()
                    .fill(index < current ? FocusStyle.working : index == current ? FocusStyle.link : Color.white.opacity(0.18))
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
            Text("Шаг \(current) из \(total)")
                .font(.system(size: 11))
                .foregroundStyle(FocusStyle.captionText)
                .padding(.leading, 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Шаг \(current) из \(total)")
    }
}
