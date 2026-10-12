import FocusCore
import SwiftUI

extension Notification.Name {
    static let focusOpenBoard = Notification.Name("focus.openBoard")
}

struct FocusSectionHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct FocusIslandSection: View {
    @Bindable var focus: FocusCoordinator
    var installHooks: (() -> Void)?
    var openSettings: (() -> Void)?
    var horizontalInset: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let toast = focus.toast {
                Text(toast).font(.caption).foregroundStyle(.secondary)
            }
            if let closed = focus.closedTask {
                ClosedTaskBanner(title: closed.title) { focus.reopenClosedTask() }
            }
            if let card = focus.card, Self.showsCardView(card) {
                cardView(card)
            }
            if focus.currentTask == nil, Self.showsBinding(card: focus.card), let sessionID = focus.pendingBindingSessionIDs.first {
                BindingCard(focus: focus, sessionID: sessionID).id(sessionID)
            }
            if !Self.showsCardView(focus.card) {
                SessionHubView(focus: focus, openSettings: openSettings)
            }
        }
        .padding(.horizontal, horizontalInset)
        .padding(.vertical, 8)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: FocusSectionHeightKey.self, value: geo.size.height)
            }
        )
    }

    static func showsCardView(_ card: FocusCard?) -> Bool {
        switch card {
        case nil, .returned: false
        default: true
        }
    }

    static func showsBinding(card: FocusCard?) -> Bool {
        switch card {
        case nil, .nextAction, .returned, .dayStart: true
        case .onboarding, .nudge, .reEntry, .overload, .pickTask, .bindToTask, .pomodoroEnd, .breakEnd: false
        }
    }

    @ViewBuilder
    private func cardView(_ card: FocusCard) -> some View {
        switch card {
        case let .nextAction(triggering, _):
            StayInTaskCard(focus: focus, sessionID: triggering).id(triggering)
        case .nudge:
            NudgeCard(focus: focus, sessionID: focus.nudgeSessionIDState ?? "").id(focus.nudgeSessionIDState ?? "")
        case let .returned(sessionID):
            ReturnCard(focus: focus, sessionID: sessionID).id(sessionID)
        case let .reEntry(sessionID):
            ReEntryCard(focus: focus, sessionID: sessionID).id(sessionID)
        case let .overload(newSessionID):
            OverloadCard(focus: focus, newSessionID: newSessionID).id(newSessionID)
        case .dayStart:
            DayStartCard(focus: focus).id("dayStart")
        case .onboarding:
            OnboardingCard(focus: focus, installHooks: { installHooks?() }).id("onboarding")
        case .pickTask:
            PickTaskCard(focus: focus).id("pickTask")
        case let .bindToTask(taskID):
            TaskSessionsPicker(focus: focus, taskID: taskID, onCancel: { focus.perform(.dismiss) }).id(taskID)
        case let .pomodoroEnd(pomodoroID):
            PomodoroEndCard(focus: focus, pomodoroID: pomodoroID).id(pomodoroID)
        case let .breakEnd(pomodoroID):
            BreakEndCard(focus: focus, pomodoroID: pomodoroID).id(pomodoroID)
        }
    }

    static func boardButtonTitle(_ hotKey: BoardHotKey) -> String {
        hotKey == .off ? "Доска" : "Доска " + hotKey.title
    }
}

struct ClosedTaskBanner: View {
    let title: String
    let onReopen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(FocusStyle.working)
                .accessibilityHidden(true)
            Text(Self.text(title))
                .font(FocusStyle.secondaryFont)
                .foregroundStyle(FocusStyle.tagText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Вернуть", action: onReopen)
                .buttonStyle(FocusButtonStyle(kind: .quiet, height: 24, horizontalPadding: 6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: FocusStyle.smallRadius).fill(FocusStyle.working.opacity(0.12)))
    }

    nonisolated static func text(_ title: String) -> String {
        "«\(title)» закрыта · перенесена в Done"
    }
}
