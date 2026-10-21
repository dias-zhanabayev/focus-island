import FocusCore
import SwiftUI

struct PickTaskCard: View {
    @Bindable var focus: FocusCoordinator
    var showsHeader = true
    @State private var options = PickTaskOptions(inProgress: [], todo: [])
    @State private var todoExpanded = false

    var body: some View {
        let primaryID = Self.primaryOptionID(options.inProgress)
        let showsTodo = Self.showsTodoList(inProgressIsEmpty: options.inProgress.isEmpty, userExpanded: todoExpanded)
        VStack(alignment: .leading, spacing: 12) {
            if showsHeader {
                header
            } else {
                Text("Над чем работаешь сейчас?")
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(1)
            }
            list(primaryID: primaryID, showsTodo: showsTodo)
            HStack(spacing: 8) {
                Button("+ Новая задача") { openBoard() }
                    .buttonStyle(FocusButtonStyle(kind: .quiet, height: 28, horizontalPadding: 6))
                Spacer(minLength: 0)
                if Self.showsEmptyCaption(inProgressIsEmpty: options.inProgress.isEmpty, todoIsEmpty: options.todo.isEmpty) {
                    Text("Пусто в работе — сразу список Todo")
                        .font(.system(size: 11))
                        .foregroundStyle(FocusStyle.captionText)
                        .lineLimit(1)
                }
            }
            .padding(.top, 12)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: focus.board) { _, _ in reload() }
        .onChange(of: focus.hubRows) { _, _ in reload() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("В фокусе")
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                Text("Над чем работаешь сейчас?")
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(FocusIslandSection.boardButtonTitle(focus.settings.boardHotKey)) { openBoard() }
                .buttonStyle(FocusButtonStyle(kind: .secondary, height: 28))
        }
    }

    private func list(primaryID: String?, showsTodo: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if !options.inProgress.isEmpty {
                    FocusSectionCaption(Self.inProgressCaption(options.inProgress.count))
                    ForEach(options.inProgress) { option in
                        row(option, isPrimary: option.id == primaryID)
                    }
                }
                if !options.todo.isEmpty {
                    FocusSectionCaption(Self.todoCaption(options.todo.count))
                        .padding(.top, options.inProgress.isEmpty ? 0 : 6)
                    if showsTodo {
                        ForEach(options.todo) { option in
                            row(option, isPrimary: false)
                        }
                    } else {
                        collapsedTodoRow
                    }
                }
            }
        }
        .frame(maxHeight: 280)
    }

    private var collapsedTodoRow: some View {
        HStack(spacing: 10) {
            Text(Self.todoSummary(titles: options.todo.map(\.title)))
                .font(FocusStyle.secondaryFont)
                .foregroundStyle(FocusStyle.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Показать") { todoExpanded = true }
                .buttonStyle(FocusButtonStyle(kind: .quiet, height: 28, horizontalPadding: 6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: FocusStyle.smallRadius)
                .stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }

    private func row(_ option: PickTaskOption, isPrimary: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(option.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FocusStyle.primaryText)
                        .lineLimit(1)
                    if let project = option.projectName {
                        ProjectTag(project)
                    }
                }
                Text(option.sessionStateText)
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(Self.stateIsWarning(option) ? FocusStyle.waitingText : FocusStyle.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Взять") { take(option.id) }
                .buttonStyle(FocusButtonStyle(kind: isPrimary ? .primary : .secondary, height: 28))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: FocusStyle.smallRadius).fill(Color.white.opacity(0.05)))
        .accessibilityElement(children: .contain)
    }

    private func reload() {
        let loaded = focus.pickTaskOptions()
        if loaded != options {
            options = loaded
        }
    }

    private func take(_ taskID: String) {
        focus.takeTask(taskID: taskID)
    }

    private func openBoard() {
        NotificationCenter.default.post(name: .focusOpenBoard, object: nil, userInfo: SessionHubView.boardUserInfo)
    }

    nonisolated static func inProgressCaption(_ count: Int) -> String {
        "В работе · \(count)"
    }

    nonisolated static func todoSummary(titles: [String]) -> String {
        guard !titles.isEmpty else { return "" }
        let shown = titles.prefix(2).joined(separator: " · ")
        let rest = titles.count - 2
        return rest > 0 ? "\(shown) · ещё \(rest)" : shown
    }

    nonisolated static func showsTodoList(inProgressIsEmpty: Bool, userExpanded: Bool) -> Bool {
        inProgressIsEmpty || userExpanded
    }

    nonisolated static func showsEmptyCaption(inProgressIsEmpty: Bool, todoIsEmpty: Bool) -> Bool {
        inProgressIsEmpty && !todoIsEmpty
    }

    nonisolated static func stateIsWarning(_ option: PickTaskOption) -> Bool {
        option.liveSessionCount == 0
    }

    nonisolated static func todoCaption(_ count: Int) -> String {
        "Todo · \(count)"
    }

    nonisolated static func primaryOptionID(_ options: [PickTaskOption]) -> String? {
        options.first { $0.liveSessionCount > 0 }?.id
    }
}
