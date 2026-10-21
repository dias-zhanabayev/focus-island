import FocusCore
import SwiftUI

struct TaskSessionsPicker: View {
    @Bindable var focus: FocusCoordinator
    let taskID: String
    var listMaxHeight: CGFloat = 300
    var showsBack = true
    let onCancel: () -> Void
    var onApplied: () -> Void = {}
    @State private var choices: [BindableSession] = []
    @State private var selected: Set<String> = []
    @State private var seeded = false

    struct Section: Equatable, Identifiable {
        let title: String
        let rows: [BindableSession]
        var id: String { title }
    }

    var body: some View {
        let task = focus.board.task(id: taskID)
        let projectName = task.flatMap { SessionHistory.projectName(for: $0.projectPath) }
        let changes = FocusCoordinator.taskSessionChanges(choices, selected: selected)
        let hasBound = choices.contains(where: \.isBound)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if showsBack {
                    Button("‹ Назад", action: onCancel)
                        .buttonStyle(FocusButtonStyle(kind: .quiet, height: 28, horizontalPadding: 6))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Сессии задачи")
                        .font(FocusStyle.secondaryFont)
                        .foregroundStyle(FocusStyle.secondaryText)
                    HStack(spacing: 8) {
                        Text(task?.title ?? "")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(FocusStyle.primaryText)
                            .lineLimit(1)
                        if let projectName {
                            ProjectTag(projectName)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if !hasBound {
                        FocusSectionCaption(Self.boundCaption(0))
                        Text("Пока ни одной — отметь ниже")
                            .font(FocusStyle.secondaryFont)
                            .foregroundStyle(FocusStyle.secondaryText)
                            .padding(.horizontal, 2)
                            .padding(.bottom, 4)
                    }
                    ForEach(Self.sections(choices, projectName: projectName)) { section in
                        FocusSectionCaption(section.title, color: section.rows.first?.isBound == true ? FocusStyle.link : FocusStyle.captionText)
                            .padding(.top, 4)
                        ForEach(section.rows) { row in
                            sessionRow(row)
                        }
                    }
                    if choices.isEmpty {
                        Text("Открытых сессий нет — запусти Claude Code и вернись сюда")
                            .font(FocusStyle.secondaryFont)
                            .foregroundStyle(FocusStyle.secondaryText)
                            .padding(.horizontal, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: listMaxHeight)
            HStack(spacing: 8) {
                Text(Self.footerHint(changes, choices: choices))
                    .font(.system(size: 11))
                    .foregroundStyle(FocusStyle.captionText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(Self.cancelTitle(hasBound: hasBound), action: onCancel)
                    .buttonStyle(FocusButtonStyle(kind: .secondary, height: 28))
                Button(Self.applyTitle(changes)) {
                    focus.applyTaskSessions(taskID: taskID, selected: selected)
                    onApplied()
                }
                .buttonStyle(FocusButtonStyle(kind: .primary, height: 28))
                .disabled(changes.add.isEmpty && changes.remove.isEmpty)
            }
            .padding(.top, 10)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: focus.board) { _, _ in reload() }
        .onChange(of: focus.hubRows) { _, _ in reload() }
    }

    private func sessionRow(_ session: BindableSession) -> some View {
        let isOn = selected.contains(session.id)
        return Button {
            if isOn {
                selected.remove(session.id)
            } else {
                selected.insert(session.id)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(isOn ? FocusStyle.link : FocusStyle.secondaryText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FocusStyle.primaryText)
                        .lineLimit(1)
                    if !session.detail.isEmpty {
                        Text(session.detail)
                            .font(FocusStyle.secondaryFont)
                            .foregroundStyle(FocusStyle.secondaryText)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let label = Self.trailingLabel(session) {
                    Text(label)
                        .font(FocusStyle.secondaryFont)
                        .foregroundStyle(session.boundTaskTitle == nil ? FocusStyle.secondaryText : FocusStyle.waitingText)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: FocusStyle.smallRadius).fill(isOn ? Color(focusHex: 0x0A84FF).opacity(0.14) : Color.white.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func reload() {
        let loaded = focus.taskSessionChoices(forTaskID: taskID)
        guard loaded != choices else { return }
        let newlyBound = Set(loaded.filter(\.isBound).map(\.id)).subtracting(choices.filter(\.isBound).map(\.id))
        choices = loaded
        if !seeded {
            seeded = true
            selected = FocusCoordinator.defaultTaskSessionSelection(loaded)
        } else {
            selected.formIntersection(Set(loaded.map(\.id)))
            selected.formUnion(newlyBound)
        }
    }

    nonisolated static func sections(_ choices: [BindableSession], projectName: String?) -> [Section] {
        let bound = choices.filter(\.isBound)
        let same = choices.filter { !$0.isBound && $0.isSameProject }
        let other = choices.filter { !$0.isBound && !$0.isSameProject }
        var result: [Section] = []
        if !bound.isEmpty { result.append(Section(title: boundCaption(bound.count), rows: bound)) }
        if !same.isEmpty { result.append(Section(title: sameProjectCaption(projectName), rows: same)) }
        if !other.isEmpty { result.append(Section(title: same.isEmpty && projectName == nil ? "Открытые" : "Открытые · другие проекты", rows: other)) }
        return result
    }

    nonisolated static func boundCaption(_ count: Int) -> String {
        "Привязаны · \(count)"
    }

    nonisolated static func sameProjectCaption(_ projectName: String?) -> String {
        guard let projectName else { return "Открытые · этот проект" }
        return "Открытые · проект \(projectName)"
    }

    nonisolated static func applyTitle(_ changes: (add: [String], remove: [String])) -> String {
        changes.remove.isEmpty ? "Добавить \(changes.add.count)" : "Сохранить"
    }

    nonisolated static func cancelTitle(hasBound: Bool) -> String {
        hasBound ? "Отмена" : "Позже"
    }

    nonisolated static func trailingLabel(_ session: BindableSession) -> String? {
        if session.isBound { return nil }
        if let bound = session.boundTaskTitle { return otherTaskLabel(bound) }
        return "без задачи"
    }

    nonisolated static func otherTaskLabel(_ title: String) -> String {
        "у задачи «\(title)»"
    }

    nonisolated static func footerHint(_ changes: (add: [String], remove: [String]), choices: [BindableSession]) -> String {
        let moving = choices.filter { changes.add.contains($0.id) }.compactMap(\.boundTaskTitle)
        if let title = moving.first {
            return "Сессия переедет из «\(title)» в эту задачу"
        }
        if !changes.remove.isEmpty {
            return "Снятые сессии отвяжутся от задачи"
        }
        return "Сессию чужой задачи не трогаем, пока сам не отметишь"
    }
}
