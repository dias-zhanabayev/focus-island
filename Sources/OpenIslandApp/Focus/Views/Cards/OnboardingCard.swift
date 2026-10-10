import AppKit
import FocusCore
import SwiftUI

struct OnboardingCard: View {
    @Bindable var focus: FocusCoordinator
    let installHooks: () -> Void
    @State private var taskText = ""

    static let automationSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"

    init(focus: FocusCoordinator, installHooks: @escaping () -> Void) {
        self.focus = focus
        self.installHooks = installHooks
    }

    private var allDone: Bool {
        Self.allDone(automationOpened: focus.onboardingAutomationOpened, taskAdded: focus.onboardingTaskAdded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Focus Island").font(FocusStyle.titleFont)
                Text("Держит в голове сессии Claude и задачи, чтобы ты не держал. Три шага — и можно работать.")
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            step(number: 1, done: focus.hooksInstalled == true, doneText: "Claude Code подключён") {
                stepText("Подключить Claude Code", "Добавит хуки в ~/.claude/settings.json. Убрать можно в настройках.")
                Button("Подключить", action: installHooks)
                    .buttonStyle(FocusButtonStyle(kind: .primary))
            }
            step(number: 2, done: focus.onboardingAutomationOpened, doneText: "Настройки автоматизации открыты") {
                stepText("Разрешить автоматизацию", "Чтобы переходить в нужный терминал и замечать сайты-отвлекалки")
                Button("Открыть настройки") { openAutomationSettings() }
                    .buttonStyle(FocusButtonStyle(kind: .secondary))
            }
            step(number: 3, done: focus.onboardingTaskAdded, doneText: "Первая задача добавлена") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Над чем работаешь на этой неделе?")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        TextField("Название задачи", text: $taskText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: FocusStyle.buttonRadius).fill(FocusStyle.surface))
                            .overlay(RoundedRectangle(cornerRadius: FocusStyle.buttonRadius).stroke(FocusStyle.hairline, lineWidth: 1))
                            .onSubmit(addTask)
                        Button("Добавить", action: addTask)
                            .buttonStyle(FocusButtonStyle(kind: .secondary))
                            .disabled(!Self.canAddTask(text: taskText))
                    }
                    Text("Задачи попадут в Todo. Потом к ним привяжутся сессии.")
                        .font(.system(size: 11))
                        .foregroundStyle(FocusStyle.captionText)
                        .lineLimit(2)
                }
            }
            HStack(spacing: 8) {
                Label("Всё хранится только на этом Mac", systemImage: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(FocusStyle.captionText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("Доска — \(focus.settings.boardHotKey.title)")
                    .font(.system(size: 11))
                    .foregroundStyle(FocusStyle.captionText)
                    .lineLimit(1)
                Button(allDone ? "Готово" : "Позже") { focus.dismissOnboarding() }
                    .buttonStyle(FocusButtonStyle(kind: allDone ? .primary : .quiet, height: 26))
            }
        }
    }

    private func step<Content: View>(number: Int, done: Bool, doneText: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().fill(done ? FocusStyle.working.opacity(0.2) : FocusStyle.accent.opacity(0.25))
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(FocusStyle.working)
                } else {
                    Text("\(number)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(FocusStyle.link)
                }
            }
            .frame(width: 26, height: 26)
            .accessibilityHidden(true)
            if done {
                Text(doneText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Шаг \(number) выполнен: \(doneText)")
            } else {
                content()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: FocusStyle.cardRadius).fill(FocusStyle.surface))
    }

    private func stepText(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(detail)
                .font(FocusStyle.secondaryFont)
                .foregroundStyle(FocusStyle.secondaryText)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openAutomationSettings() {
        if let url = URL(string: Self.automationSettingsURL) {
            NSWorkspace.shared.open(url)
        }
        focus.markOnboardingAutomationOpened()
    }

    private func addTask() {
        let title = taskText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        focus.createTask(title: title, column: .todo, projectPath: nil)
        focus.markOnboardingTaskAdded()
        taskText = ""
    }

    nonisolated static func allDone(automationOpened: Bool, taskAdded: Bool) -> Bool {
        automationOpened && taskAdded
    }

    nonisolated static func canAddTask(text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
