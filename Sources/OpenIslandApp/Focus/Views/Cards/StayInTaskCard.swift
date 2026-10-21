import AppKit
import FocusCore
import OpenIslandCore
import SwiftUI

struct StayInTaskCard: View {
    @Bindable var focus: FocusCoordinator
    let sessionID: String
    @State private var promptText = ""
    @State private var quickAddText = ""
    @State private var syncedPrompt: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerBlock
            Text("Пока ждёшь — в этой же задаче")
                .font(.system(size: 18, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            promptBox
            filesBox
            criteriaBox
            alternativesBlock
            footer
        }
        .onAppear(perform: syncPrompt)
        .onChange(of: queued?.text) { syncPrompt() }
    }

    private var taskTitle: String {
        focus.board.task(id: focus.taskID(forSession: sessionID))?.title ?? focus.sessionTitle(sessionID)
    }

    private var headerBlock: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let progress = focus.planProgress(sessionID: sessionID)
            let elapsed = focus.turnElapsed(sessionID: sessionID, now: now)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    StatusDot(color: FocusStyle.working)
                    Text("Claude работает над «\(taskTitle)»")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let elapsed {
                        Text(Self.clock(elapsed))
                            .font(FocusStyle.secondaryFont.monospacedDigit())
                            .foregroundStyle(FocusStyle.secondaryText)
                    }
                }
                if let progress {
                    PlanProgressBar(progress: progress)
                }
                Text(Self.header(progress: progress, remaining: focus.planRemaining(sessionID: sessionID, now: now), elapsed: elapsed))
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(2)
            }
        }
    }

    private var queued: QueuedPrompt? {
        focus.queuedPrompt(sessionID: sessionID)
    }

    private var trimmedPrompt: String {
        promptText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var promptBox: some View {
        FocusBox(border: FocusStyle.link.opacity(0.3), spacing: 10) {
            HStack(spacing: 8) {
                FocusSectionCaption("1 · Следующий промпт", color: FocusStyle.link)
                Text("отправится, когда Claude закончит")
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(1)
            }
            TextField("Следующий промпт", text: $promptText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...4)
                .font(.system(size: 13))
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9).fill(FocusStyle.surface))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(FocusStyle.link.opacity(0.45), lineWidth: 1))
                .accessibilityLabel("Следующий промпт")
            HStack(spacing: 8) {
                Button(queued?.text == trimmedPrompt && !trimmedPrompt.isEmpty ? "В очереди" : "Поставить в очередь", action: queuePrompt)
                    .buttonStyle(FocusButtonStyle(kind: .primary))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(trimmedPrompt.isEmpty || queued?.text == trimmedPrompt)
                Text("или ⌘↩")
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
            }
        }
    }

    @ViewBuilder
    private var filesBox: some View {
        let files = Array((focus.changedFiles[sessionID] ?? []).prefix(5))
        if !files.isEmpty {
            let cwd = focus.sessionCWD(sessionID)
            FocusBox(spacing: 4) {
                FocusSectionCaption("2 · Проверь, что уже сделано")
                ForEach(files) { file in
                    HStack(spacing: 12) {
                        Text(file.path)
                            .font(FocusStyle.monoFont)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("+\(file.added)").font(FocusStyle.monoFont).foregroundStyle(FocusStyle.working)
                        Text("−\(file.removed)").font(FocusStyle.monoFont).foregroundStyle(FocusStyle.removed)
                        Button("Открыть") {
                            if let cwd {
                                NSWorkspace.shared.open(Self.fileURL(cwd: cwd, path: file.path))
                            }
                        }
                        .buttonStyle(FocusButtonStyle(kind: .secondary, height: 26))
                        .disabled(cwd == nil)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private var criteriaBox: some View {
        FocusBox(spacing: 8) {
            FocusSectionCaption("3 · Критерий готовности")
            if let taskID = focus.taskID(forSession: sessionID) {
                CriteriaChecklist(focus: focus, taskID: taskID).id(taskID)
            } else {
                HStack {
                    Text("У сессии нет задачи")
                        .font(FocusStyle.secondaryFont)
                        .foregroundStyle(FocusStyle.secondaryText)
                    Spacer()
                    Menu("Выбрать задачу") {
                        ForEach(focus.pickerTasks(forSessionID: sessionID)) { task in
                            Button(task.title) { focus.perform(.bindTriggering(taskID: task.id)) }
                        }
                    }
                    .fixedSize()
                }
            }
        }
    }

    @ViewBuilder
    private var alternativesBlock: some View {
        let alternatives = Array(focus.alternatives.prefix(2))
        if !alternatives.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    FocusSectionCaption(Self.switchTitle(remaining: focus.planRemaining(sessionID: sessionID, now: context.date)))
                }
                ForEach(Array(alternatives.enumerated()), id: \.offset) { _, alternative in
                    alternativeRow(alternative)
                }
            }
        }
    }

    private func alternativeRow(_ alternative: NextAlternative) -> some View {
        HStack(spacing: 10) {
            StatusDot(color: Self.dotColor(alternative))
            VStack(alignment: .leading, spacing: 1) {
                Text(alternativeTitle(alternative))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(Self.reason(alternative))
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(Self.actionTitle(alternative)) { performAlternative(alternative) }
                .buttonStyle(FocusButtonStyle(kind: .secondary))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(RoundedRectangle(cornerRadius: FocusStyle.rowRadius).stroke(FocusStyle.hairline, lineWidth: 1))
    }

    private func alternativeTitle(_ alternative: NextAlternative) -> String {
        switch alternative {
        case let .attend(id, reason, _):
            Self.attendTitle(name: sessionName(id), reason: reason)
        case let .review(id):
            "\(sessionName(id)) — готово, не просмотрено"
        case let .startTask(taskID, _):
            focus.board.task(id: taskID)?.title ?? ""
        }
    }

    private func sessionName(_ id: String) -> String {
        focus.hubRows.first { $0.id == id }?.projectName ?? focus.sessionTitle(id)
    }

    private func performAlternative(_ alternative: NextAlternative) {
        switch alternative {
        case let .attend(id, _, _), let .review(id):
            focus.perform(.jump(sessionID: id))
        case let .startTask(taskID, _):
            focus.perform(.startTask(taskID: taskID))
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            TextField("+ задача в Todo", text: $quickAddText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit(quickAdd)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Пропустить") { focus.perform(.dismiss) }
                .buttonStyle(FocusButtonStyle(kind: .quiet))
        }
    }

    private func syncPrompt() {
        let result = Self.syncedDraft(current: promptText, lastSynced: syncedPrompt, queued: queued?.text)
        promptText = result.draft
        syncedPrompt = result.lastSynced
    }

    private func queuePrompt() {
        let text = trimmedPrompt
        guard !text.isEmpty else { return }
        focus.perform(.queuePrompt(sessionID: sessionID, text: text))
    }

    private func quickAdd() {
        let title = quickAddText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        focus.perform(.quickAdd(title: title))
        quickAddText = ""
    }

    nonisolated static func syncedDraft(current: String, lastSynced: String?, queued: String?) -> (draft: String, lastSynced: String?) {
        guard queued != lastSynced else { return (current, lastSynced) }
        if current == (lastSynced ?? "") {
            return (queued ?? "", queued)
        }
        return (current, queued)
    }

    nonisolated static func header(progress: PlanProgress?, remaining: TimeInterval?, elapsed: TimeInterval?) -> String {
        guard let progress else {
            guard let elapsed else { return "Работает" }
            let minutes = FocusText.minutes(elapsed)
            return minutes == 0 ? "Работает · меньше минуты" : "Работает · \(minutes) мин"
        }
        let step = min(progress.total, progress.completed + 1)
        var text = "Шаг \(step) из \(progress.total)"
        if let title = progress.currentTitle, !title.isEmpty {
            text += ": \(title)"
        }
        if let remaining {
            text += " · по плану ещё ~\(FocusText.roundedUpMinutes(remaining)) мин"
        }
        return text
    }

    nonisolated static func switchTitle(remaining: TimeInterval?) -> String {
        guard let remaining else { return "Или переключиться" }
        return "Или переключиться — \(FocusText.roundedUpMinutes(remaining)) мин хватит"
    }

    nonisolated static func clock(_ seconds: TimeInterval) -> String {
        FocusText.clock(seconds)
    }

    nonisolated static func fileURL(cwd: String, path: String) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        let base = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        return URL(fileURLWithPath: base + "/" + path)
    }

    nonisolated static func reason(_ alternative: NextAlternative) -> String {
        switch alternative {
        case let .attend(_, reason, _):
            switch reason {
            case .approval: "Разрешение · дело на минуту"
            case .question: "Вопрос · дело на минуту"
            case .unseenCompletion: "Готово, не просмотрено"
            }
        case .review:
            "Можно быстро проверить"
        case let .startTask(_, sameProject):
            sameProject ? "тот же проект — переключаться легче" : "из Todo"
        }
    }

    nonisolated static func attendTitle(name: String, reason: AttentionReason) -> String {
        switch reason {
        case .approval: "\(name) ждёт разрешения"
        case .question: "\(name) ждёт ответа"
        case .unseenCompletion: "\(name) — готово, не просмотрено"
        }
    }

    nonisolated static func actionTitle(_ alternative: NextAlternative) -> String {
        if case .startTask = alternative { "Начать" } else { "Перейти" }
    }

    nonisolated static func dotColor(_ alternative: NextAlternative) -> Color {
        switch alternative {
        case let .attend(_, reason, _): reason == .unseenCompletion ? FocusStyle.done : FocusStyle.waiting
        case .review: FocusStyle.done
        case .startTask: FocusStyle.link
        }
    }
}
