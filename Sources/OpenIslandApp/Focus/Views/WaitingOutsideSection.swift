import FocusCore
import SwiftUI

struct WaitingOutsideSection: View {
    @Bindable var focus: FocusCoordinator
    let task: FocusTask

    var body: some View {
        let rows = focus.waitingOutside
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .stroke(FocusStyle.waiting, lineWidth: 1.5)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                FocusSectionCaption(Self.caption(rows.count), color: FocusStyle.waitingText)
                Spacer(minLength: 0)
                Button("Свернуть") { focus.toggleWaitingOutside() }
                    .buttonStyle(FocusButtonStyle(kind: .quiet, height: 24, horizontalPadding: 6))
            }
            Text(Self.explainer(taskTitle: task.title))
                .font(FocusStyle.secondaryFont)
                .foregroundStyle(FocusStyle.secondaryText)
                .lineLimit(2)
            ForEach(rows) { row in
                rowView(row)
            }
            HStack(spacing: 8) {
                Text("«Перейти» не меняет задачу в фокусе")
                    .font(.system(size: 11))
                    .foregroundStyle(FocusStyle.captionText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Отложить все") { focus.deferWaitingOutside(sessionIDs: rows.map(\.id)) }
                    .buttonStyle(FocusButtonStyle(kind: .quiet, height: 26, horizontalPadding: 6))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(FocusStyle.waiting.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(FocusStyle.waiting.opacity(0.25), lineWidth: 1))
        )
        .accessibilityElement(children: .contain)
    }

    private func rowView(_ row: HubRow) -> some View {
        HStack(spacing: 12) {
            Text(Self.ageLabel(seconds: Date.now.timeIntervalSince(row.since)))
                .font(.system(size: 13, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(FocusStyle.waitingText)
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(row.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FocusStyle.primaryText)
                        .lineLimit(1)
                    if let project = row.projectName {
                        ProjectTag(project)
                    }
                }
                Text(Self.ownerText(taskTitle: focus.board.task(id: row.taskID)?.title))
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Перейти") { focus.requestJump(sessionID: row.id) }
                .buttonStyle(FocusButtonStyle(kind: .secondary, height: 28))
            Menu {
                Button(Self.addTitle(taskTitle: task.title)) { focus.bind(sessionID: row.id, taskID: task.id) }
                Button("Отложить — на паузу") { focus.deferWaitingOutside(sessionIDs: [row.id]) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(FocusStyle.secondaryText)
            .frame(width: 28, height: 28)
            .accessibilityLabel("Ещё действия")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: FocusStyle.rowRadius).fill(Color.white.opacity(0.05)))
    }

    nonisolated static func caption(_ count: Int) -> String {
        "Ждут вне задачи · \(count)"
    }

    nonisolated static func buttonTitle(_ count: Int, expanded: Bool) -> String {
        "Ждут вне задачи · \(count) " + (expanded ? "▾" : "▸")
    }

    nonisolated static func explainer(taskTitle: String) -> String {
        "Claude в этих сессиях закончил и ждёт тебя. Они не относятся к «\(taskTitle)»."
    }

    nonisolated static func ownerText(taskTitle: String?) -> String {
        guard let taskTitle else { return "без задачи" }
        return "у задачи «\(taskTitle)»"
    }

    nonisolated static func addTitle(taskTitle: String) -> String {
        "Добавить в «\(taskTitle)»"
    }

    nonisolated static func ageLabel(seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        return minutes < 60 ? "\(minutes) м" : "\(minutes / 60) ч"
    }
}
