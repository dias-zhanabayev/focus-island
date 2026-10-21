import FocusCore
import SwiftUI

struct OverloadCard: View {
    @Bindable var focus: FocusCoordinator
    let newSessionID: String

    private var suggestion: OverloadSuggestion? {
        OverloadPolicy.evaluate(rows: focus.hubRows, limit: focus.settings.maxParallelSessions)
    }

    private var slots: [HubRow] {
        focus.hubRows.filter { !$0.group.isSettled }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.title(liveCount: slots.count))
                    .font(FocusStyle.titleFont)
                    .lineLimit(2)
                Text(Self.subtitle(limit: focus.settings.maxParallelSessions))
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                ForEach(slots) { row in
                    chip(row)
                }
                newSlot
            }
            if let suggestion, suggestion.attend != nil || suggestion.park != nil {
                FocusSectionCaption("Лучше сначала")
                if let attend = suggestion.attend {
                    attendOption(attend)
                }
                if let park = suggestion.park {
                    parkOption(park)
                }
            }
            HStack(spacing: 8) {
                Text("Лимит меняется в настройках")
                    .font(.system(size: 11))
                    .foregroundStyle(FocusStyle.captionText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Всё равно запустить") { focus.perform(.dismiss) }
                    .buttonStyle(FocusButtonStyle(kind: .quiet, height: 30))
            }
        }
    }

    private func chip(_ row: HubRow) -> some View {
        HStack(spacing: 5) {
            Image(systemName: Self.stateIcon(row.group))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Self.stateColor(row.group))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.projectName ?? row.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(Self.stateText(row.group))
                    .font(.system(size: 10))
                    .foregroundStyle(Self.stateColor(row.group))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .center)
        .background(RoundedRectangle(cornerRadius: FocusStyle.chipRadius).fill(Self.stateColor(row.group).opacity(0.16)))
        .accessibilityElement(children: .combine)
    }

    private var newSlot: some View {
        Text("+ новая")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(FocusStyle.captionText)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 34)
            .overlay(
                RoundedRectangle(cornerRadius: FocusStyle.chipRadius)
                    .strokeBorder(FocusStyle.captionText.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
    }

    private func attendOption(_ row: HubRow) -> some View {
        optionRow(
            title: "Ответить \(row.projectName ?? row.title) — дело на минуту",
            detail: row.detail.isEmpty ? Self.waitingDetail(row: row, now: .now) : "\(row.detail) · \(Self.waitingDetail(row: row, now: .now))",
            buttonTitle: "Перейти",
            primary: true
        ) { focus.perform(.jump(sessionID: row.id)) }
    }

    private func parkOption(_ row: HubRow) -> some View {
        optionRow(
            title: "Поставить \(row.projectName ?? row.title) на паузу",
            detail: "Уберу из пульта, запомню, где остановились, и напомню, когда освободится слот",
            buttonTitle: "На паузу",
            primary: false
        ) { focus.perform(.park(sessionID: row.id)) }
    }

    private func optionRow(title: String, detail: String, buttonTitle: String, primary: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text(detail)
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(buttonTitle, action: action)
                .buttonStyle(FocusButtonStyle(kind: primary ? .primary : .secondary))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: FocusStyle.cardRadius).fill(FocusStyle.surface))
    }

    nonisolated static func title(liveCount: Int) -> String {
        "Запускаешь \(liveCount)-ю сессию"
    }

    nonisolated static func subtitle(limit: Int) -> String {
        "Обычно ты уверенно держишь \(limit). Дальше сессии начинают теряться — давай сначала разгрузим голову."
    }

    nonisolated static func waitingDetail(row: HubRow, now: Date = .now) -> String {
        "ждёт \(FocusText.minutes(now.timeIntervalSince(row.since))) мин"
    }

    nonisolated static func stateText(_ group: HubGroup) -> String {
        switch group {
        case .waiting: "ждёт"
        case .running: "работает"
        case .review: "готово"
        case .idle: "твой ход"
        case .unbound: "без задачи"
        case .parked: "на паузе"
        case .done: "готова"
        }
    }

    nonisolated static func stateIcon(_ group: HubGroup) -> String {
        switch group {
        case .waiting: "hourglass"
        case .running: "circle.fill"
        case .review: "checkmark.circle.fill"
        case .idle: "arrow.uturn.left.circle"
        case .unbound: "questionmark.circle"
        case .parked: "pause.circle"
        case .done: "checkmark.circle"
        }
    }

    static func stateColor(_ group: HubGroup) -> Color {
        switch group {
        case .waiting: FocusStyle.waitingText
        case .running: FocusStyle.working
        case .review: FocusStyle.done
        case .idle, .unbound, .parked, .done: FocusStyle.secondaryText
        }
    }
}
