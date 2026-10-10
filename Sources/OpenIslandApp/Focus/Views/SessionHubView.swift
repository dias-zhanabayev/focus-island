import FocusCore
import SwiftUI

struct SessionHubView: View {
    @Bindable var focus: FocusCoordinator
    var openSettings: (() -> Void)?

    struct HubSection: Equatable {
        let group: HubGroup
        let rows: [HubRow]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if focus.hubRows.isEmpty {
                emptyState
            } else {
                let primaryID = Self.primaryRowID(rows: focus.hubRows)
                ForEach(Self.groups(rows: focus.hubRows), id: \.group) { group in
                    groupView(group, primaryID: primaryID)
                }
            }
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("В фокусе")
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                Text(Self.focusTitle(focus.currentTask?.title))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(focus.currentTask == nil ? FocusStyle.secondaryText : FocusStyle.primaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Self.headerCount(live: Self.liveCount(rows: focus.hubRows), limit: focus.settings.maxParallelSessions))
                .font(FocusStyle.secondaryFont)
                .foregroundStyle(FocusStyle.secondaryText)
                .lineLimit(1)
            Button(FocusIslandSection.boardButtonTitle(focus.settings.boardHotKey)) {
                NotificationCenter.default.post(name: .focusOpenBoard, object: nil, userInfo: Self.boardUserInfo)
            }
            .buttonStyle(FocusButtonStyle(kind: .secondary, height: 28))
            Button {
                openSettings?()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FocusStyle.tagText)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: FocusStyle.buttonRadius).fill(Color.white.opacity(0.08)))
                    .contentShape(RoundedRectangle(cornerRadius: FocusStyle.buttonRadius))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Настройки")
        }
    }

    private func groupView(_ group: HubSection, primaryID: String?) -> some View {
        VStack(alignment: .leading, spacing: group.group == .unbound ? 6 : 8) {
            HStack(spacing: 6) {
                groupIcon(group.group)
                FocusSectionCaption(Self.groupCaption(group.group, count: group.rows.count))
            }
            ForEach(group.rows) { row in
                rowView(row, primaryID: primaryID)
            }
        }
    }

    @ViewBuilder
    private func groupIcon(_ group: HubGroup) -> some View {
        switch group {
        case .waiting:
            StatusDot(color: FocusStyle.waiting)
        case .running:
            StatusDot(color: FocusStyle.working)
        case .review:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(FocusStyle.done)
                .accessibilityHidden(true)
        case .idle:
            Image(systemName: "arrow.uturn.left")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(FocusStyle.done)
                .accessibilityHidden(true)
        case .parked:
            Image(systemName: "pause.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(FocusStyle.captionText)
                .accessibilityHidden(true)
        case .unbound:
            EmptyView()
        }
    }

    private func rowView(_ row: HubRow, primaryID: String?) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(row.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FocusStyle.primaryText)
                        .lineLimit(1)
                    if row.taskID != nil, let project = row.projectName {
                        ProjectTag(project)
                    }
                }
                Text(row.detail)
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(row.group == .waiting ? FocusStyle.waitingText : FocusStyle.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if row.group == .running, let progress = row.progress {
                PlanProgressBar(progress: progress, width: 90)
            }
            buttons(row, primaryID: primaryID)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(rowBackground(row.group))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func rowBackground(_ group: HubGroup) -> some View {
        let shape = RoundedRectangle(cornerRadius: FocusStyle.rowRadius)
        switch group {
        case .waiting:
            shape.fill(FocusStyle.waiting.opacity(0.12))
                .overlay(shape.stroke(FocusStyle.waiting.opacity(0.35), lineWidth: 1))
        case .unbound:
            shape.stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        default:
            shape.fill(Color.white.opacity(0.05))
        }
    }

    @ViewBuilder
    private func buttons(_ row: HubRow, primaryID: String?) -> some View {
        switch row.group {
        case .unbound:
            Button(Self.actionTitle(group: row.group)) { focus.requestBinding(sessionID: row.id) }
                .buttonStyle(FocusButtonStyle(kind: .secondary, height: 28))
            Button("Закрыть") { focus.perform(.park(sessionID: row.id)) }
                .buttonStyle(FocusButtonStyle(kind: .quiet, height: 28))
        case .parked:
            Button(Self.actionTitle(group: row.group)) { focus.perform(.unpark(sessionID: row.id)) }
                .buttonStyle(FocusButtonStyle(kind: .secondary, height: 28))
        case .waiting, .review, .running, .idle:
            Button(Self.actionTitle(group: row.group)) { focus.requestJump(sessionID: row.id) }
                .buttonStyle(FocusButtonStyle(kind: Self.isPrimary(row: row, primaryID: primaryID) ? .primary : .secondary, height: 28))
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FocusStyle.secondaryText)
                    .accessibilityHidden(true)
                Text("Сессий нет — запусти claude в терминале")
                    .font(.system(size: 13))
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(2)
            }
            Button("Начать день") { focus.openDayStart() }
                .buttonStyle(FocusButtonStyle(kind: .quiet, height: 28, horizontalPadding: 0))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: FocusStyle.rowRadius).fill(Color.white.opacity(0.05)))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(Self.footerText(focusSeconds: focus.todaySummary.focusSeconds, distractionSeconds: focus.todaySummary.distractionSeconds))
                .font(FocusStyle.secondaryFont)
                .foregroundStyle(FocusStyle.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Сводка дня") {
                NotificationCenter.default.post(name: .focusOpenBoard, object: nil, userInfo: Self.daySummaryUserInfo)
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(FocusStyle.link)
        }
        .padding(.top, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
    }

    nonisolated static var boardUserInfo: [AnyHashable: Any] {
        ["tab": "board"]
    }

    nonisolated static var daySummaryUserInfo: [AnyHashable: Any] {
        ["tab": "today"]
    }

    nonisolated static func primaryRowID(rows: [HubRow]) -> String? {
        rows.first { $0.group == .waiting }?.id
    }

    nonisolated static func liveCount(rows: [HubRow]) -> Int {
        rows.filter { $0.group != .parked }.count
    }

    nonisolated static func headerCount(live: Int, limit: Int) -> String {
        "\(live) \(sessionsWord(live)) · держишь \(limit)"
    }

    nonisolated static func groups(rows: [HubRow]) -> [HubSection] {
        HubGroup.allCases.compactMap { group in
            let matching = rows.filter { $0.group == group }
            return matching.isEmpty ? nil : HubSection(group: group, rows: matching)
        }
    }

    nonisolated static func groupCaption(_ group: HubGroup, count: Int) -> String {
        "\(group.title) · \(count)"
    }

    nonisolated static func actionTitle(group: HubGroup) -> String {
        switch group {
        case .waiting, .running, .idle: "Перейти"
        case .review: "Посмотреть"
        case .unbound: "Привязать"
        case .parked: "Вернуть"
        }
    }

    nonisolated static func isPrimary(row: HubRow, primaryID: String?) -> Bool {
        row.group == .waiting && row.id == primaryID
    }

    nonisolated static func focusTitle(_ title: String?) -> String {
        guard let title, !title.isEmpty else { return "Задача не выбрана" }
        return title
    }

    nonisolated static func durationLabel(seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        guard minutes >= 60 else { return "\(minutes) мин" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60)ч" : "\(minutes / 60)ч \(rest)м"
    }

    nonisolated static func footerText(focusSeconds: TimeInterval, distractionSeconds: TimeInterval) -> String {
        "Сегодня: фокус \(durationLabel(seconds: focusSeconds)) · отвлечения \(durationLabel(seconds: distractionSeconds))"
    }

    nonisolated private static func sessionsWord(_ count: Int) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        if mod10 == 1 && mod100 != 11 { return "сессия" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "сессии" }
        return "сессий"
    }
}
