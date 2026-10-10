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
            if let card = focus.card {
                cardView(card)
            }
            if Self.showsBinding(card: focus.card), let sessionID = focus.pendingBindingSessionIDs.first {
                BindingCard(focus: focus, sessionID: sessionID).id(sessionID)
            }
            if focus.card == nil {
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

    static func showsBinding(card: FocusCard?) -> Bool {
        switch card {
        case nil, .nextAction, .returned, .stalled, .dayStart: true
        case .onboarding, .nudge, .reEntry, .overload: false
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
        case let .stalled(sessionIDs):
            StalledCard(focus: focus, sessionIDs: sessionIDs).id(sessionIDs)
        case .dayStart:
            DayStartCard(focus: focus).id("dayStart")
        case .onboarding:
            OnboardingCard(focus: focus, installHooks: { installHooks?() }).id("onboarding")
        }
    }

    static func boardButtonTitle(_ hotKey: BoardHotKey) -> String {
        hotKey == .off ? "Доска" : "Доска " + hotKey.title
    }
}
