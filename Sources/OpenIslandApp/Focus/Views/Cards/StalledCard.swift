import FocusCore
import SwiftUI

struct StalledCard: View {
    @Bindable var focus: FocusCoordinator
    let sessionIDs: [String]

    private var rows: [HubRow] {
        sessionIDs.compactMap { id in focus.hubRows.first { $0.id == id } }
    }

    var body: some View {
        if rows.isEmpty {
            EmptyView()
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.title(count: rows.count))
                    .font(FocusStyle.titleFont)
                    .lineLimit(2)
                Text("Самые старые сверху. Разберись с каждой или осознанно отложи.")
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(2)
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            rowView(row, isFirst: index == 0, now: context.date)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
            HStack(spacing: 8) {
                Text("Напоминаю, если сессия ждёт тебя дольше \(focus.settings.stalledReminderMinutes) мин")
                    .font(.system(size: 11))
                    .foregroundStyle(FocusStyle.captionText)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button("Отложить всё до завтра") { focus.perform(.deferStalled(sessionIDs: sessionIDs)) }
                    .buttonStyle(FocusButtonStyle(kind: .quiet, height: 30))
            }
        }
    }

    private func rowView(_ row: HubRow, isFirst: Bool, now: Date) -> some View {
        HStack(spacing: 12) {
            Text(Self.ageLabel(seconds: now.timeIntervalSince(row.since)))
                .font(.system(size: 15, weight: .bold).monospacedDigit())
                .foregroundStyle(row.group == .waiting ? FocusStyle.waitingText : FocusStyle.primaryText)
                .frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let project = row.projectName {
                        ProjectTag(project)
                    }
                }
                Text(row.detail)
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            buttons(row, isFirst: isFirst)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: FocusStyle.cardRadius).fill(FocusStyle.surface))
    }

    @ViewBuilder
    private func buttons(_ row: HubRow, isFirst: Bool) -> some View {
        switch row.group {
        case .unbound:
            Button(Self.primaryTitle(group: row.group)) {
                focus.requestBinding(sessionID: row.id)
                focus.perform(.dismiss)
            }
            .buttonStyle(FocusButtonStyle(kind: .secondary))
            Button("Закрыть") { focus.perform(.park(sessionID: row.id)) }
                .buttonStyle(FocusButtonStyle(kind: .quiet))
        default:
            Button(Self.primaryTitle(group: row.group)) { focus.perform(.jump(sessionID: row.id)) }
                .buttonStyle(FocusButtonStyle(kind: isFirst && row.group == .waiting ? .primary : .secondary))
        }
    }

    nonisolated static func ageLabel(seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        return minutes < 60 ? "\(minutes) м" : "\(minutes / 60) ч"
    }

    nonisolated static func primaryTitle(group: HubGroup) -> String {
        switch group {
        case .review: "Посмотреть"
        case .unbound: "Привязать"
        default: "Перейти"
        }
    }

    nonisolated static func title(count: Int) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        if mod10 == 1 && mod100 != 11 { return "\(count) сессия ждёт и про неё легко забыть" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "\(count) сессии ждут и про них легко забыть" }
        return "\(count) сессий ждут и про них легко забыть"
    }
}
