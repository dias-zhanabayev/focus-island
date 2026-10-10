import FocusCore
import SwiftUI

struct HistoryView: View {
    @Bindable var focus: FocusCoordinator
    @State private var query = ""
    @State private var projectFilter: String?

    nonisolated static func dayTitle(_ day: Date, now: Date, calendar: Calendar = .current) -> String {
        let base = DaySummaryFormatter.title(day, calendar: calendar)
        let lowered = base.prefix(1).lowercased() + base.dropFirst()
        if calendar.isDate(day, inSameDayAs: now) { return "Сегодня · \(lowered)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "Вчера · \(lowered)"
        }
        return base
    }

    var body: some View {
        let records = focus.searchHistory(text: query, projectPath: projectFilter)
        let groups = Dictionary(grouping: records) { Calendar.current.startOfDay(for: $0.lastActivityAt) }
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Поиск по заголовку и промптам", text: $query).textFieldStyle(.roundedBorder)
                Picker("Проект", selection: $projectFilter) {
                    Text("Все проекты").tag(String?.none)
                    ForEach(focus.knownProjectPaths(), id: \.self) { path in
                        Text(URL(fileURLWithPath: path).lastPathComponent).tag(String?.some(path))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups.keys.sorted(by: >), id: \.self) { day in
                        Text(Self.dayTitle(day, now: .now))
                            .font(.system(size: 14, weight: .bold))
                            .padding(.top, 16)
                            .padding(.bottom, 6)
                        ForEach(groups[day] ?? []) { record in
                            HistoryRow(focus: focus, record: record)
                            Divider().overlay(Color.white.opacity(0.05))
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }
}

struct HistoryRow: View {
    @Bindable var focus: FocusCoordinator
    let record: SessionRecord

    nonisolated static func actionTitle(isLive: Bool) -> String {
        isLive ? "Перейти" : "Продолжить"
    }

    var body: some View {
        let isLive = focus.liveSessionIDs.contains(record.id)
        let canAct = focus.canResume(record)
        HStack(spacing: 12) {
            StatusDot(color: isLive ? FocusStyle.working : Color(focusHex: 0x636366))
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let detail = Self.detail(record, canAct: canAct) {
                    Text(detail)
                        .font(FocusStyle.secondaryFont)
                        .foregroundStyle(FocusStyle.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let project = record.projectName { ProjectTag(project) }
            Text(focus.board.task(id: record.taskId)?.title ?? "без задачи")
                .font(FocusStyle.secondaryFont)
                .foregroundStyle(FocusStyle.secondaryText)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
            Text(record.lastActivityAt.formatted(date: .omitted, time: .shortened))
                .font(FocusStyle.secondaryFont)
                .foregroundStyle(FocusStyle.secondaryText)
                .monospacedDigit()
                .frame(width: 44, alignment: .leading)
            Button(Self.actionTitle(isLive: isLive)) {
                if isLive {
                    focus.requestJump(sessionID: record.id)
                } else {
                    focus.resume(record: record)
                }
            }
            .buttonStyle(FocusButtonStyle(kind: .secondary, height: 26, horizontalPadding: 12))
            .disabled(!canAct)
            .help(canAct ? "" : "Папка проекта больше не существует")
        }
        .padding(.vertical, 8)
        .opacity(canAct ? 1 : 0.6)
    }

    nonisolated static func detail(_ record: SessionRecord, canAct: Bool) -> String? {
        if !canAct { return "Папка проекта удалена — продолжить нельзя" }
        let text = record.lastAssistantMessage ?? record.lastPrompt ?? record.firstPrompt
        return text.map { FocusText.truncated($0, limit: 120) }
    }
}
