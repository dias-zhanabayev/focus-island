import FocusCore
import SwiftUI

struct BreakEndCard: View {
    @Bindable var focus: FocusCoordinator
    let pomodoroID: String
    @State private var summary: BreakSummary?
    @State private var loaded = false
    @State private var chosenMinutes: Int?

    static let extendMinutes = 5

    private var selectedMinutes: Int {
        PomodoroFormat.clampFocus(chosenMinutes ?? focus.settings.pomodoroFocusMinutes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                FocusSectionCaption("Перерыв окончен", color: FocusStyle.link)
                Text(Self.title(taskTitle: summary?.taskTitle ?? focus.currentTask?.title ?? ""))
                    .font(FocusStyle.titleFont)
                    .lineLimit(2)
            }
            focusCard
            if let line = Self.restedLine(finishedSessionTitles: summary?.finishedSessionTitles ?? []) {
                Text(line)
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Button("Без таймера") { focus.endBreakWithoutTimer() }
                    .buttonStyle(FocusButtonStyle(kind: .secondary))
                Spacer(minLength: 0)
                Button(Self.extendTitle(minutes: Self.extendMinutes)) { focus.extendBreak(minutes: Self.extendMinutes) }
                    .buttonStyle(FocusButtonStyle(kind: .quiet, horizontalPadding: 6))
            }
            .padding(.top, 14)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            }
        }
        .onAppear(perform: load)
    }

    private var focusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button(PomodoroFormat.startFocusTitle(minutes: selectedMinutes)) {
                    focus.resumeAfterBreak(minutes: selectedMinutes)
                }
                .buttonStyle(FocusButtonStyle(kind: .primary, height: 38, horizontalPadding: 18))
                .font(.system(size: 15, weight: .semibold))
                .keyboardShortcut(.defaultAction)
                MinutesSegments(choices: PomodoroFormat.focusChoices, selected: selectedMinutes, customRange: FocusSettings.pomodoroFocusRange) {
                    chosenMinutes = $0
                }
                Spacer(minLength: 0)
            }
            if let note = Self.noteText(summary?.note) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Следующий шаг")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FocusStyle.link)
                    Text("· " + note)
                        .font(.system(size: 13))
                        .foregroundStyle(FocusStyle.primaryText)
                        .lineLimit(3)
                }
            }
            Text("Перейду в сессию задачи, где Claude ждёт тебя")
                .font(FocusStyle.secondaryFont)
                .foregroundStyle(FocusStyle.secondaryText)
                .lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(colors: [Color(focusHex: 0x0A84FF).opacity(0.16), Color(focusHex: 0x0A84FF).opacity(0.06)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(focusHex: 0x0A84FF).opacity(0.35), lineWidth: 1))
        )
        .accessibilityElement(children: .contain)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        summary = focus.breakSummary(pomodoroID: pomodoroID)
    }

    nonisolated static func title(taskTitle: String) -> String {
        taskTitle.isEmpty ? "Вернуться к задаче" : "Вернуться к «\(taskTitle)»"
    }

    nonisolated static func noteText(_ note: String?) -> String? {
        guard let text = note?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    nonisolated static func restedLine(finishedSessionTitles: [String]) -> String? {
        guard !finishedSessionTitles.isEmpty else { return nil }
        return "Пока отдыхал: Claude закончил " + finishedSessionTitles.map { "«\($0)»" }.joined(separator: ", ")
    }

    nonisolated static func extendTitle(minutes: Int) -> String {
        "Ещё \(minutes) мин отдыха"
    }
}
