import FocusCore
import SwiftUI

struct BindingCard: View {
    @Bindable var focus: FocusCoordinator
    let sessionID: String

    private var cwd: String? { focus.sessionCWD(sessionID) }

    var body: some View {
        let groups = Self.groups(tasks: focus.pickerTasks(forSessionID: sessionID), cwd: cwd)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                    .foregroundStyle(FocusStyle.link)
                    .accessibilityHidden(true)
                Text("Новая сессия Claude")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let cwd {
                    Text(Self.shortPath(cwd))
                        .font(FocusStyle.monoFont)
                        .foregroundStyle(FocusStyle.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Text("Над какой задачей работаешь?")
                .font(FocusStyle.titleFont)
                .lineLimit(2)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if !groups.thisProject.isEmpty {
                        FocusSectionCaption("Этот проект")
                        ForEach(groups.thisProject) { taskRow($0) }
                    }
                    if !groups.others.isEmpty {
                        FocusSectionCaption("Другие")
                        ForEach(groups.others) { taskRow($0) }
                    }
                    Button {
                        focus.createTaskForSession(sessionID: sessionID)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(FocusStyle.link)
                                .accessibilityHidden(true)
                            Text("Новая задача из первого промпта")
                                .font(.system(size: 13))
                                .foregroundStyle(FocusStyle.link)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxHeight: 240)
            HStack(spacing: 8) {
                Text("Задача переедет в In progress")
                    .font(.system(size: 11))
                    .foregroundStyle(FocusStyle.captionText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Без задачи") { focus.skipBinding(sessionID: sessionID) }
                    .buttonStyle(FocusButtonStyle(kind: .quiet))
            }
        }
    }

    private func taskRow(_ task: FocusTask) -> some View {
        Button {
            focus.bind(sessionID: sessionID, taskID: task.id)
        } label: {
            HStack(spacing: 10) {
                Text(task.title)
                    .font(.system(size: 13))
                    .foregroundStyle(FocusStyle.primaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ProjectTag(task.boardColumn.title)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: FocusStyle.smallRadius).fill(FocusStyle.surface))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    nonisolated static func groups(tasks: [FocusTask], cwd: String?) -> (thisProject: [FocusTask], others: [FocusTask]) {
        guard let cwd else { return ([], tasks) }
        let matching = tasks.filter { FocusCoordinator.projectPath($0.projectPath, contains: cwd) }
        let others = tasks.filter { !FocusCoordinator.projectPath($0.projectPath, contains: cwd) }
        return (matching, others)
    }

    nonisolated static func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
