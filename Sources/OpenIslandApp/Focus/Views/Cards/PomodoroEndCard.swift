import FocusCore
import SwiftUI

struct PomodoroEndCard: View {
    @Bindable var focus: FocusCoordinator
    let pomodoroID: String
    @State private var summary: PomodoroSummary?
    @State private var nextStep = ""
    @State private var savedNote = ""
    @State private var loaded = false

    struct Item: Equatable {
        let text: String
        let isCriterion: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                breakCard(remaining: focus.breakCountdownRemaining(now: context.date))
            }
            kpiRow
            whileRunning
            footer
        }
        .onAppear(perform: load)
        .onDisappear(perform: saveDraft)
    }

    private var breakMinutes: Int {
        Self.breakMinutes(focus.breakMinutesChoice ?? focus.settings.pomodoroBreakMinutes)
    }

    private var nextFocusMinutes: Int {
        summary?.nextFocusMinutes ?? focus.nextFocusMinutes(after: nil)
    }

    private func breakCard(remaining: Int?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                countdownRing(remaining: remaining)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.breakHeadline(minutes: breakMinutes, secondsLeft: remaining))
                        .font(.system(size: 15, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(FocusStyle.primaryText)
                        .lineLimit(1)
                    Text("Отдохни — подсказки и отвлечения на перерыве молчат")
                        .font(FocusStyle.secondaryFont)
                        .foregroundStyle(FocusStyle.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if remaining != nil {
                    Button("Начать сейчас") { focus.startBreak(nextStep: nextStep, minutes: breakMinutes) }
                        .buttonStyle(FocusButtonStyle(kind: .rest, height: 32))
                        .keyboardShortcut(.defaultAction)
                    Button("Отменить") { focus.cancelBreakCountdown() }
                        .buttonStyle(FocusButtonStyle(kind: .quiet, height: 32, horizontalPadding: 6))
                } else {
                    Button(Self.breakTitle(minutes: breakMinutes)) { focus.startBreak(nextStep: nextStep, minutes: breakMinutes) }
                        .buttonStyle(FocusButtonStyle(kind: .rest, height: 32))
                        .keyboardShortcut(.defaultAction)
                }
            }
            HStack(spacing: 10) {
                Text("Длительность")
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                MinutesSegments(choices: PomodoroFormat.breakChoices, selected: breakMinutes) {
                    focus.chooseBreakMinutes($0)
                }
                Text(Self.afterBreakCaption(focusMinutes: nextFocusMinutes))
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(1)
            }
            nextStepField
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(colors: [FocusStyle.working.opacity(0.16), FocusStyle.working.opacity(0.06)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(FocusStyle.working.opacity(0.35), lineWidth: 1))
        )
        .accessibilityElement(children: .contain)
    }

    private func countdownRing(remaining: Int?) -> some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 4)
            if let remaining {
                Circle()
                    .trim(from: 0, to: Self.countdownProgress(secondsLeft: remaining))
                    .stroke(FocusStyle.working, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: remaining)
                Text("\(remaining)")
                    .font(.system(size: 17, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(FocusStyle.working)
            } else {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FocusStyle.working)
            }
        }
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(FocusStyle.working, lineWidth: 4)
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(FocusStyle.working)
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                FocusSectionCaption(
                    Self.headline(cycleIndex: summary?.cycleIndex ?? 1, cycle: summary?.cycle ?? focus.settings.pomodoroCycle),
                    color: FocusStyle.working
                )
                Text(Self.title(minutes: summary?.plannedMinutes ?? focus.settings.pomodoroFocusMinutes, taskTitle: summary?.taskTitle ?? ""))
                    .font(FocusStyle.titleFont)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var kpiRow: some View {
        HStack(alignment: .top, spacing: 10) {
            kpi("Ты в задаче", Self.minutesValue(summary?.youInTaskSeconds ?? 0))
            kpi("Claude работал", Self.minutesValue(summary?.claudeSeconds ?? 0))
            kpi(
                "Отвлечения",
                Self.minutesValue(summary?.distractionSeconds ?? 0),
                detail: summary.flatMap { Self.distractionDetail(count: $0.distractionCount, returned: $0.returnedCount) }
            )
        }
    }

    private func kpi(_ label: String, _ value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(FocusStyle.secondaryFont).foregroundStyle(FocusStyle.secondaryText)
            Text(value).font(.system(size: 18, weight: .bold)).monospacedDigit()
            if let detail {
                Text(detail).font(FocusStyle.secondaryFont).foregroundStyle(FocusStyle.secondaryText).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: FocusStyle.smallRadius).fill(Color.white.opacity(0.05)))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var whileRunning: some View {
        let items = Self.whileRunningItems(
            finishedSessionTitles: summary?.finishedSessionTitles ?? [],
            checkedCriteria: summary?.checkedCriteria ?? []
        )
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                FocusSectionCaption("Пока шёл таймер")
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 10) {
                        StatusDot(color: item.isCriterion ? FocusStyle.working : FocusStyle.done)
                        Text(item.text)
                            .font(.system(size: 13))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: FocusStyle.smallRadius).fill(Color.white.opacity(0.04)))
                }
            }
        }
    }

    private var nextStepField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Следующий шаг — чтобы вернуться без раскачки", text: $nextStep)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: FocusStyle.buttonRadius).fill(FocusStyle.fieldFill))
                .overlay(RoundedRectangle(cornerRadius: FocusStyle.buttonRadius).stroke(FocusStyle.fieldBorder, lineWidth: 1))
                .accessibilityLabel("Следующий шаг")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Закончить на сегодня") { focus.endForToday(nextStep: nextStep) }
                .buttonStyle(FocusButtonStyle(kind: .quiet, horizontalPadding: 6))
            Spacer(minLength: 0)
            Button(Self.continueTitle(minutes: nextFocusMinutes)) {
                focus.continueFocus(nextStep: nextStep, minutes: nextFocusMinutes)
            }
            .buttonStyle(FocusButtonStyle(kind: .secondary))
        }
        .padding(.top, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let loadedSummary = focus.pomodoroSummary(pomodoroID: pomodoroID)
        summary = loadedSummary
        nextStep = Self.prefill(note: focus.board.task(id: loadedSummary?.taskID ?? focus.currentTask?.id)?.note)
        savedNote = nextStep
    }

    private func saveDraft() {
        guard loaded, let draft = Self.draftToSave(text: nextStep, saved: savedNote) else { return }
        focus.saveNextStepDraft(draft, pomodoroID: pomodoroID)
        savedNote = draft
    }

    nonisolated static func draftToSave(text: String, saved: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != saved.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return trimmed
    }

    nonisolated static func headline(cycleIndex: Int, cycle: Int) -> String {
        "Фокус \(cycleIndex) из \(cycle) готов"
    }

    nonisolated static func title(minutes: Int, taskTitle: String) -> String {
        let value = "\(minutes) \(minutesWord(minutes))"
        guard !taskTitle.isEmpty else { return "\(value) фокуса" }
        return "\(value) в «\(taskTitle)»"
    }

    nonisolated static func minutesValue(_ seconds: TimeInterval) -> String {
        "\(max(0, Int((seconds / 60).rounded()))) мин"
    }

    nonisolated static func distractionDetail(count: Int, returned: Int) -> String? {
        guard count > 0 else { return nil }
        let mod10 = count % 10
        let mod100 = count % 100
        let word = (2...4).contains(mod10) && !(12...14).contains(mod100) ? "раза" : "раз"
        let base = "\(count) \(word)"
        if returned <= 0 { return base }
        if returned >= count { return "\(base), вернулся" }
        return "\(base), вернулся \(returned)"
    }

    nonisolated static func whileRunningItems(finishedSessionTitles: [String], checkedCriteria: [String]) -> [Item] {
        finishedSessionTitles.map { Item(text: "«\($0)» — Claude закончил", isCriterion: false) }
            + checkedCriteria.map { Item(text: "Критерий «\($0)» отмечен", isCriterion: true) }
    }

    nonisolated static func continueTitle(minutes: Int) -> String {
        "Без перерыва — ещё \(minutes) мин"
    }

    nonisolated static func breakTitle(minutes: Int) -> String {
        "☕ Начать перерыв · \(minutes) мин"
    }

    nonisolated static func breakHeadline(minutes: Int, secondsLeft: Int?) -> String {
        guard let secondsLeft else { return "Перерыв \(minutes) мин" }
        return "Перерыв \(minutes) мин начнётся через \(secondsLeft) с"
    }

    nonisolated static func afterBreakCaption(focusMinutes: Int) -> String {
        "потом фокус \(focusMinutes) мин"
    }

    nonisolated static func countdownProgress(secondsLeft: Int) -> CGFloat {
        let total = FocusCoordinator.breakCountdownSeconds
        return CGFloat(max(0, min(total, TimeInterval(secondsLeft))) / total)
    }

    nonisolated static func breakMinutes(_ setting: Int) -> Int {
        min(FocusSettings.pomodoroBreakRange.upperBound, max(FocusSettings.pomodoroBreakRange.lowerBound, setting))
    }

    nonisolated static func prefill(note: String?) -> String {
        note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    nonisolated private static func minutesWord(_ count: Int) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        if mod10 == 1 && mod100 != 11 { return "минута" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "минуты" }
        return "минут"
    }
}
