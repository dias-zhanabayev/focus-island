import FocusCore
import SwiftUI

struct DayStartCard: View {
    @Bindable var focus: FocusCoordinator
    @State private var selection: [String]

    static let selectionLimit = 3

    init(focus: FocusCoordinator) {
        self.focus = focus
        _selection = State(initialValue: Self.defaultSelection(tasks: Self.candidates(focus.board)))
    }

    private static func candidates(_ board: BoardSnapshot) -> [FocusTask] {
        board.tasks(in: .inProgress) + board.tasks(in: .todo)
    }

    private var tasks: [FocusTask] { Self.candidates(focus.board) }

    private var yesterday: [HubRow] {
        let startOfToday = Calendar.current.startOfDay(for: .now)
        return Self.yesterdayRows(rows: focus.hubRows, startOfToday: startOfToday) { focus.record($0)?.lastActivityAt }
    }

    private var note: String? {
        focus.recentTomorrowNote()
    }

    private var validSelection: [String] {
        selection.filter { id in tasks.contains { $0.id == id } }
    }

    private var selectedTitles: [String] {
        validSelection.compactMap { id in tasks.first { $0.id == id }?.title }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Доброе утро").font(FocusStyle.titleFont)
                Text(Self.dateText(.now))
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
            }
            if !yesterday.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    FocusSectionCaption("Вчера осталось открытым · \(yesterday.count)")
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(yesterday) { row in
                                yesterdayRow(row)
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                }
            }
            if let note {
                FocusBox(spacing: 4) {
                    FocusSectionCaption("Твоя заметка с вечера")
                    Text(note).font(.system(size: 13)).lineLimit(3)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    FocusSectionCaption("Фокус на сегодня")
                    Text("выбери 1–3")
                        .font(.system(size: 11))
                        .foregroundStyle(FocusStyle.captionText)
                }
                ForEach(tasks.prefix(8)) { task in
                    taskRow(task)
                }
            }
            HStack(spacing: 8) {
                Button(Self.primaryTitle(selectedTitles: selectedTitles)) {
                    focus.perform(.startDay(taskIDs: validSelection))
                }
                .buttonStyle(FocusButtonStyle(kind: .primary, height: 32))
                .disabled(validSelection.isEmpty)
                .opacity(validSelection.isEmpty ? 0.5 : 1)
                Text("Выбранное — в In progress, остальное подождёт")
                    .font(.system(size: 11))
                    .foregroundStyle(FocusStyle.captionText)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button("Позже") { focus.perform(.dismiss) }
                    .buttonStyle(FocusButtonStyle(kind: .quiet, height: 32))
            }
        }
    }

    private func yesterdayRow(_ row: HubRow) -> some View {
        HStack(spacing: 10) {
            StatusDot(color: OverloadCard.stateColor(row.group))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let project = row.projectName {
                        ProjectTag(project)
                    }
                }
                Text(row.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(Self.yesterdayButtonTitle(group: row.group)) {
                if row.group == .parked {
                    focus.perform(.unpark(sessionID: row.id))
                } else {
                    focus.perform(.jump(sessionID: row.id))
                }
            }
            .buttonStyle(FocusButtonStyle(kind: .secondary, height: 26))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: FocusStyle.rowRadius).fill(FocusStyle.surface))
    }

    private func taskRow(_ task: FocusTask) -> some View {
        let isOn = selection.contains(task.id)
        return Button {
            selection = Self.toggled(selection, id: task.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundStyle(isOn ? FocusStyle.accent : FocusStyle.captionText)
                    .accessibilityHidden(true)
                Text(task.title).font(.system(size: 13)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ProjectTag(task.boardColumn.title)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .overlay(RoundedRectangle(cornerRadius: FocusStyle.smallRadius).stroke(FocusStyle.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "выбрано" : "не выбрано")
    }

    nonisolated static func primaryTitle(selectedTitles: [String]) -> String {
        guard let first = selectedTitles.first else { return "Начать день" }
        return "Начать с «\(first)»"
    }

    nonisolated static func toggled(_ selection: [String], id: String) -> [String] {
        if selection.contains(id) { return selection.filter { $0 != id } }
        guard selection.count < selectionLimit else { return selection }
        return selection + [id]
    }

    nonisolated static func defaultSelection(tasks: [FocusTask]) -> [String] {
        Array(tasks.filter { $0.boardColumn == .inProgress }.prefix(selectionLimit).map(\.id))
    }

    nonisolated static func yesterdayRows(rows: [HubRow], startOfToday: Date, lastActivity: (String) -> Date?) -> [HubRow] {
        rows.filter { row in
            switch row.group {
            case .waiting, .review, .idle, .parked:
                guard let activity = lastActivity(row.id) else { return false }
                return activity < startOfToday
            case .running, .unbound:
                return false
            }
        }
    }

    nonisolated static func yesterdayButtonTitle(group: HubGroup) -> String {
        switch group {
        case .review: "Посмотреть"
        case .parked: "Вернуть"
        default: "Продолжить"
        }
    }

    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "EEEE, d MMMM"
        let text = formatter.string(from: date)
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
