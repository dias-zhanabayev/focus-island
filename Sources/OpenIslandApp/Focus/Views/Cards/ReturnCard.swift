import FocusCore
import OpenIslandCore
import SwiftUI

struct ReturnCard: View {
    @Bindable var focus: FocusCoordinator
    let sessionID: String
    @State private var isEditing = false
    @State private var editText = ""
    @State private var editSynced: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            doneBox
            criteriaBox
            queuedBox
            footer
        }
        .onChange(of: focus.queuedPrompt(sessionID: sessionID)?.text) { _, queued in
            guard isEditing else { return }
            guard queued != nil else {
                isEditing = false
                return
            }
            let result = StayInTaskCard.syncedDraft(current: editText, lastSynced: editSynced, queued: queued)
            editText = result.draft
            editSynced = result.lastSynced
        }
    }

    private var taskID: String? {
        focus.taskID(forSession: sessionID)
    }

    private var taskTitle: String {
        focus.board.task(id: taskID)?.title ?? focus.sessionTitle(sessionID)
    }

    private var header: some View {
        let project = focus.hubRows.first { $0.id == sessionID }?.projectName
        let away = focus.lastJumpProjectName.flatMap { $0 == project ? nil : $0 }
        let minutes = focus.lastTurnDuration(sessionID: sessionID).map(FocusText.minutes)
        return HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(FocusStyle.working)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10).fill(FocusStyle.working.opacity(0.18)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude закончил «\(taskTitle)»")
                    .font(FocusStyle.titleFont)
                    .lineLimit(2)
                let subtitle = Self.subtitle(progress: focus.planProgress(sessionID: sessionID), minutes: minutes, awayProject: away)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(FocusStyle.secondaryFont)
                        .foregroundStyle(FocusStyle.secondaryText)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var doneBox: some View {
        let completed = (focus.session(sessionID)?.claudeMetadata?.activeTasks ?? [])
            .filter { $0.status == .completed }
            .map(\.title)
        let items = Self.doneItems(completedTitles: completed, lastMessage: focus.record(sessionID)?.lastAssistantMessage)
        if !items.isEmpty {
            FocusBox(spacing: 6) {
                FocusSectionCaption("Что сделано")
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        if !completed.isEmpty {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(FocusStyle.working).padding(.top, 3)
                        }
                        Text(item).font(.system(size: 13)).lineLimit(completed.isEmpty ? 8 : 2)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var criteriaBox: some View {
        if let taskID, !focus.criteria(taskID: taskID).isEmpty {
            FocusBox(spacing: 6) {
                FocusSectionCaption("Твой критерий готовности")
                CriteriaChecklist(focus: focus, taskID: taskID).id(taskID)
            }
        }
    }

    @ViewBuilder
    private var queuedBox: some View {
        if let queued = focus.queuedPrompt(sessionID: sessionID) {
            FocusBox(border: FocusStyle.link.opacity(0.35), spacing: 6) {
                FocusSectionCaption("Промпт в очереди", color: FocusStyle.link)
                if isEditing {
                    TextField("Промпт", text: $editText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(2...5)
                        .font(.system(size: 13))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 9).fill(FocusStyle.surface))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(FocusStyle.link.opacity(0.45), lineWidth: 1))
                    HStack(spacing: 8) {
                        Button("Сохранить") { saveEdit() }
                            .buttonStyle(FocusButtonStyle(kind: .primary))
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Отмена") { isEditing = false }
                            .buttonStyle(FocusButtonStyle(kind: .quiet))
                    }
                } else {
                    Text(queued.text).font(.system(size: 13)).lineLimit(5)
                    HStack(spacing: 8) {
                        Button("Отправить и вернуться") { focus.perform(.sendQueuedPrompt(sessionID: sessionID)) }
                            .buttonStyle(FocusButtonStyle(kind: .primary))
                            .keyboardShortcut(.defaultAction)
                        Button("Изменить") {
                            editText = queued.text
                            editSynced = queued.text
                            isEditing = true
                        }
                        .buttonStyle(FocusButtonStyle(kind: .secondary))
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if focus.queuedPrompt(sessionID: sessionID) == nil {
                Button("Перейти") { focus.perform(.jump(sessionID: sessionID)) }
                    .buttonStyle(FocusButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
            if let taskID {
                Button("Задача готова → Done") { focus.perform(.markTaskDone(taskID: taskID)) }
                    .buttonStyle(FocusButtonStyle(kind: .secondary))
            }
            Spacer(minLength: 0)
            Button("Позже") { focus.perform(.dismiss) }
                .buttonStyle(FocusButtonStyle(kind: .quiet))
        }
    }

    private func saveEdit() {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        focus.perform(.queuePrompt(sessionID: sessionID, text: text))
        isEditing = false
    }

    nonisolated static func subtitle(progress: PlanProgress?, minutes: Int?, awayProject: String?) -> String {
        var parts: [String] = []
        if let progress { parts.append("\(progress.completed) из \(progress.total) шагов") }
        if let minutes { parts.append("\(minutes) мин") }
        if let awayProject, !awayProject.isEmpty { parts.append("пока ты был в \(awayProject)") }
        return parts.joined(separator: " · ")
    }

    nonisolated static func doneItems(completedTitles: [String], lastMessage: String?) -> [String] {
        let titles = completedTitles.filter { !$0.isEmpty }
        if !titles.isEmpty {
            return Array(titles.prefix(4))
        }
        guard let lastMessage else { return [] }
        let text = FocusText.truncated(lastMessage, limit: FocusText.cardMessageLimit)
        return text.isEmpty ? [] : [text]
    }
}
