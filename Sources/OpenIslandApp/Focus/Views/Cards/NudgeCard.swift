import FocusCore
import SwiftUI

struct NudgeCard: View {
    @Bindable var focus: FocusCoordinator
    let sessionID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                header(now: context.date)
            }
            suggestionBox
            HStack(spacing: 8) {
                Button("Вернуться в терминал") { focus.perform(.returnToWork) }
                    .buttonStyle(FocusButtonStyle(kind: .primary, height: 32))
                    .keyboardShortcut(.defaultAction)
                Button("Отложить 5 мин") { focus.perform(.snoozeDistraction) }
                    .buttonStyle(FocusButtonStyle(kind: .secondary, height: 32))
                Spacer(minLength: 0)
                Button("Мне это нужно") { focus.perform(.allowDistraction) }
                    .buttonStyle(FocusButtonStyle(kind: .quiet, height: 32))
            }
        }
    }

    private func header(now: Date) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(FocusStyle.waitingText)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 10).fill(FocusStyle.waiting.opacity(0.2)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(target: focus.distractionTarget, seconds: seconds(now: now)))
                    .font(FocusStyle.titleFont)
                    .lineLimit(2)
                Text(subtitle(now: now))
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func seconds(now: Date) -> Int {
        guard let startedAt = focus.distractionStartedAt else { return 0 }
        return max(0, Int(now.timeIntervalSince(startedAt)))
    }

    private func subtitle(now: Date) -> String {
        let project = focus.hubRows.first { $0.id == sessionID }?.projectName
        let task = focus.board.task(id: focus.taskID(forSession: sessionID))?.title
        return Self.subtitle(project: project, task: task, elapsed: focus.turnElapsed(sessionID: sessionID, now: now))
    }

    @ViewBuilder
    private var suggestionBox: some View {
        if let suggestion = focus.nudgeSuggestionState {
            VStack(alignment: .leading, spacing: 2) {
                Text("Пока ждёшь, можно")
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                Text(suggestionTitle(suggestion))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: FocusStyle.rowRadius).fill(FocusStyle.surface))
        }
    }

    private func suggestionTitle(_ suggestion: NextAlternative) -> String {
        switch suggestion {
        case let .attend(id, reason, _):
            StayInTaskCard.attendTitle(name: focus.hubRows.first { $0.id == id }?.projectName ?? focus.sessionTitle(id), reason: reason)
        case let .review(id):
            "Просмотреть результат: \(focus.hubRows.first { $0.id == id }?.projectName ?? focus.sessionTitle(id))"
        case let .startTask(taskID, _):
            focus.board.task(id: taskID)?.title ?? ""
        }
    }

    nonisolated static func title(target: String?, seconds: Int) -> String {
        guard let target, !target.isEmpty else { return "Claude работает — ты отвлёкся" }
        let preposition = target.contains(".") ? "на" : "в"
        return "Claude работает — ты \(preposition) \(target) уже \(duration(seconds))"
    }

    nonisolated static func duration(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        guard seconds >= 60 else { return "\(seconds) с" }
        let minutes = seconds / 60
        let rest = seconds % 60
        return rest == 0 ? "\(minutes) мин" : "\(minutes) мин \(rest) с"
    }

    nonisolated static func subtitle(project: String?, task: String?, elapsed: TimeInterval?) -> String {
        var parts = [project.map { "Сессия \($0)" } ?? "Сессия"]
        if let task, !task.isEmpty { parts.append("«\(task)»") }
        if let elapsed { parts.append(FocusText.clock(elapsed)) }
        return parts.joined(separator: " · ")
    }
}
