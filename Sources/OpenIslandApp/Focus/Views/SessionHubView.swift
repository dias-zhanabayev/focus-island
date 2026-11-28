import FocusCore
import OpenIslandCore
import SwiftUI

struct SessionHubView: View {
    @Bindable var focus: FocusCoordinator
    var openSettings: (() -> Void)?
    var listOnly = false
    @State private var chosenMinutes: Int?
    @State private var showsAllSessions = false

    struct HubSection: Equatable {
        let group: HubGroup
        let rows: [HubRow]
    }

    var body: some View {
        if listOnly {
            sessionList
        } else if Self.showsOnlyTaskChoice(hasTask: focus.currentTask != nil, pomodoroActive: focus.pomodoro != nil) {
            VStack(alignment: .leading, spacing: 16) {
                header
                quickFocusCard
                listSetup
                if !focus.listRows.isEmpty {
                    flatList
                }
            }
        } else {
            hub
        }
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 16) {
            listSetup
            if let task = focus.currentTask {
                focusBlock(task)
            } else if !focus.listRows.isEmpty {
                flatList
            }
        }
    }

    private var flatList: some View {
        let all = Self.flatRows(rows: focus.listRows)
        let shown = showsAllSessions ? all : Array(all.prefix(Self.flatLimit))
        let primaryID = Self.primaryRowID(rows: all)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                FocusSectionCaption(Self.flatCaption(all.count))
                Spacer(minLength: 0)
                if focus.clearableSessionCount > 0 {
                    Button("Очистить") { focus.clearSessionList() }
                        .buttonStyle(FocusButtonStyle(kind: .quiet, height: 24, horizontalPadding: 0))
                }
            }
            ForEach(shown) { row in
                rowView(row, primaryID: primaryID, isHere: row.id == focus.hereSessionID, flat: true)
            }
            if all.count > Self.flatLimit {
                Button(showsAllSessions ? "Свернуть" : Self.showAllTitle(all.count)) { showsAllSessions.toggle() }
                    .buttonStyle(FocusButtonStyle(kind: .quiet, height: 24, horizontalPadding: 0))
            }
        }
    }

    nonisolated static let flatLimit = 10

    nonisolated static func flatRows(rows: [HubRow]) -> [HubRow] {
        rows.sorted { $0.since > $1.since }
    }

    nonisolated static func flatCaption(_ count: Int) -> String {
        "Сессии · \(count)"
    }

    nonisolated static func showAllTitle(_ count: Int) -> String {
        "Показать все · \(count)"
    }

    private var quickFocusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(PomodoroFormat.startFocusTitle(minutes: focus.settings.pomodoroFocusMinutes)) {
                focus.startQuickFocus()
            }
            .buttonStyle(FocusButtonStyle(kind: .primary, height: 38, horizontalPadding: 18))
            .font(.system(size: 15, weight: .semibold))
            Text(Self.quickFocusCaption(autoBind: focus.settings.autoBindNewSessions))
                .font(FocusStyle.secondaryFont)
                .foregroundStyle(FocusStyle.secondaryText)
                .lineLimit(1)
        }
    }

    private var hub: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let snapshot = focus.pomodoro {
                timerCard(snapshot)
            } else if let task = focus.currentTask {
                startFocusCard(task)
            }
            listSetup
            if let task = focus.currentTask {
                focusBlock(task)
                if focus.waitingOutsideExpanded, !focus.waitingOutside.isEmpty {
                    WaitingOutsideSection(focus: focus, task: task)
                }
            } else if focus.listRows.isEmpty {
                emptyState
            } else {
                flatList
            }
            footer
            if let task = focus.currentTask, let sessionID = focus.bindingRequestIDs.first {
                newSessionHint(sessionID: sessionID, task: task)
            }
        }
    }

    @ViewBuilder
    private var listSetup: some View {
        let choice = focus.sessionListChoiceCount
        if choice > 0 {
            sessionListChoice(count: choice)
        }
        let fresh = focus.newSessionIDs
        if !fresh.isEmpty {
            newSessionsStrip(fresh)
        }
    }

    private func sessionListChoice(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Self.listChoiceTitle(count))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FocusStyle.primaryText)
            Text("Перенеси их в список или начни с чистого — тогда в нём будут появляться только новые сессии")
                .font(FocusStyle.secondaryFont)
                .foregroundStyle(FocusStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Перенести все") { focus.keepAllSessionsInList() }
                    .buttonStyle(FocusButtonStyle(kind: .primary, height: 28))
                Button("Очистить, только новые") { focus.clearSessionList() }
                    .buttonStyle(FocusButtonStyle(kind: .secondary, height: 28))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(FocusStyle.link.opacity(0.07)))
    }

    private func newSessionsStrip(_ ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                FocusSectionCaption(Self.newSessionsCaption(ids.count))
                Spacer(minLength: 0)
                if ids.count > 1 {
                    Button("Добавить все") { focus.addNewSessions(ids) }
                        .buttonStyle(FocusButtonStyle(kind: .quiet, height: 24, horizontalPadding: 0))
                }
            }
            ForEach(ids, id: \.self) { id in
                HStack(spacing: 10) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FocusStyle.link)
                        .accessibilityHidden(true)
                    Text(Self.newSessionDetail(cwd: focus.sessionCWD(id), prompt: focus.session(id)?.claudeMetadata?.initialUserPrompt))
                        .font(.system(size: 13))
                        .foregroundStyle(FocusStyle.primaryText)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Добавить") { focus.addNewSessions([id]) }
                        .buttonStyle(FocusButtonStyle(kind: .primary, height: 28))
                    Button {
                        focus.skipBinding(sessionID: id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 20, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(FocusStyle.secondaryText)
                    .accessibilityLabel("Не добавлять")
                }
                .padding(.leading, 12)
                .padding(.trailing, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(FocusStyle.link.opacity(0.07))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(FocusStyle.link.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                )
            }
        }
    }

    nonisolated static func listChoiceTitle(_ count: Int) -> String {
        "Открыто сессий: \(count)"
    }

    nonisolated static func newSessionsCaption(_ count: Int) -> String {
        "Новые сессии · \(count)"
    }

    private func newSessionHint(sessionID: String, task: FocusTask) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FocusStyle.link)
                .accessibilityHidden(true)
            HStack(spacing: 4) {
                Text("Новая сессия")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FocusStyle.primaryText)
                Text(Self.newSessionDetail(cwd: focus.sessionCWD(sessionID), prompt: focus.session(sessionID)?.claudeMetadata?.initialUserPrompt))
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("В эту задачу") { focus.bind(sessionID: sessionID, taskID: task.id) }
                .buttonStyle(FocusButtonStyle(kind: .primary, height: 28))
            Button {
                focus.skipBinding(sessionID: sessionID)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(FocusStyle.secondaryText)
            .accessibilityLabel("Без задачи")
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(FocusStyle.link.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(FocusStyle.link.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        )
        .id(sessionID)
    }

    private var primaryID: String? {
        Self.primaryRowID(rows: focus.focusTaskSessions)
    }

    private func focusBlock(_ task: FocusTask) -> some View {
        let rows = focus.focusTaskSessions
        let done = focus.focusTaskDoneSessions
        let here = focus.hereSessionID
        return VStack(alignment: .leading, spacing: 8) {
            if let notice = focus.doneSessionNotice {
                DoneSessionNoticeBanner(notice: notice) { focus.reopenDoneSession(sessionID: notice.sessionID) }
            }
            if let notice = focus.boundSessionNotice {
                BoundSessionNoticeBanner { focus.unbindAutoBoundSession() }
                    .id(notice.sessionID)
            }
            FocusSectionCaption(Self.focusBlockCaption(rows.count))
            if focus.showsAllDoneSuggestion(taskID: task.id) {
                AllSessionsDoneCard(
                    onClose: { focus.closeTask(taskID: task.id, showPicker: true) },
                    onDismiss: { focus.dismissAllDoneSuggestion(taskID: task.id) }
                )
            } else if rows.isEmpty {
                Text(focus.settings.autoBindNewSessions ? "Нет сессий — открой Claude Code, сессия появится здесь сама" : "Нет сессий — открой Claude Code и добавь сессию сюда")
                    .font(.system(size: 13))
                    .foregroundStyle(FocusStyle.secondaryText)
                    .padding(.vertical, 4)
            } else {
                ForEach(rows) { row in
                    rowView(row, primaryID: primaryID, isHere: row.id == here, unbindable: true)
                }
            }
            DoneSessionsSection(
                items: done.map { DoneSessionItem(id: $0.id, title: focus.sessionLabel($0.id) ?? focus.sessionTitle($0.id), detail: focus.sessionStatuses[$0.id]) },
                onReopen: { focus.reopenDoneSession(sessionID: $0) },
                onOpen: { focus.requestJump(sessionID: $0) }
            )
            focusActions(task, hasSessions: !rows.isEmpty)
        }
        .accessibilityElement(children: .contain)
    }

    private var selectedMinutes: Int {
        PomodoroFormat.clampFocus(chosenMinutes ?? focus.settings.pomodoroFocusMinutes)
    }

    private func startFocusCard(_ task: FocusTask) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.15), lineWidth: 3.5)
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(FocusStyle.link)
                }
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Фокус не идёт")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(FocusStyle.primaryText)
                    Text("Подсказки и отвлечения будут считаться по этой задаче")
                        .font(FocusStyle.secondaryFont)
                        .foregroundStyle(FocusStyle.secondaryText)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 10) {
                Button(PomodoroFormat.startFocusTitle(minutes: selectedMinutes)) {
                    focus.startPomodoro(taskID: task.id, minutes: selectedMinutes)
                    chosenMinutes = nil
                }
                .buttonStyle(FocusButtonStyle(kind: .primary, height: 38, horizontalPadding: 18))
                .font(.system(size: 15, weight: .semibold))
                .keyboardShortcut(.defaultAction)
                MinutesSegments(choices: PomodoroFormat.focusChoices, selected: selectedMinutes, customRange: FocusSettings.pomodoroFocusRange) {
                    chosenMinutes = $0
                }
                Text(PomodoroFormat.breakCaption(minutes: focus.settings.pomodoroBreakMinutes))
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .background(focusCardBackground(tint: Color(focusHex: 0x0A84FF)))
        .accessibilityElement(children: .contain)
    }

    private func timerCard(_ snapshot: PomodoroSnapshot) -> some View {
        let isBreak = snapshot.phase == .break
        let tint = isBreak ? FocusStyle.working : FocusStyle.link
        return HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.15), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: max(0, min(1, snapshot.progress)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 52, height: 52)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(PomodoroFormat.timerText(remainingSeconds: snapshot.remainingSeconds))
                    .font(.system(size: 28, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                Text(Self.timerCaption(snapshot, breakMinutes: focus.settings.pomodoroBreakMinutes, focusMinutes: focus.settings.pomodoroFocusMinutes))
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(1)
                if !isBreak, focus.settings.musicEnabled, let music = focus.music {
                    MusicControls(player: music, genre: focus.settings.musicGenre)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isBreak {
                Button("Закончить перерыв") { focus.finishBreakEarly() }
                    .buttonStyle(FocusButtonStyle(kind: .secondary, height: 28))
            } else {
                Button(PomodoroFormat.pauseTitle(isPaused: snapshot.isPaused)) {
                    if snapshot.isPaused {
                        focus.resumePomodoro()
                    } else {
                        focus.pausePomodoro()
                    }
                }
                .buttonStyle(FocusButtonStyle(kind: .secondary, height: 28))
                Button("Стоп") { focus.stopPomodoro() }
                    .buttonStyle(FocusButtonStyle(kind: .quiet, height: 28, horizontalPadding: 6))
            }
        }
        .padding(16)
        .background(focusCardBackground(tint: isBreak ? FocusStyle.working : Color(focusHex: 0x0A84FF)))
        .accessibilityElement(children: .contain)
    }

    private func focusCardBackground(tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(LinearGradient(colors: [tint.opacity(0.16), tint.opacity(0.06)], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(tint.opacity(0.35), lineWidth: 1))
    }

    private func focusActions(_ task: FocusTask, hasSessions: Bool) -> some View {
        HStack(spacing: 8) {
            if !focus.settings.autoBindNewSessions {
                Button("+ Добавить сессию") { focus.openTaskSessions(taskID: task.id) }
                    .buttonStyle(FocusButtonStyle(kind: hasSessions ? .secondary : .primary, height: 28))
            }
            if focus.clearableTaskSessionCount(taskID: task.id) > 0 {
                Button("Очистить") { focus.clearTaskSessions(taskID: task.id) }
                    .buttonStyle(FocusButtonStyle(kind: .quiet, height: 28, horizontalPadding: 8))
                    .help("Убрать сессии из задачи в «Скрытые». Сессии, которые ждут ответа, останутся")
            }
            if !focus.waitingOutside.isEmpty {
                Button(WaitingOutsideSection.buttonTitle(focus.waitingOutside.count, expanded: focus.waitingOutsideExpanded)) {
                    focus.toggleWaitingOutside()
                }
                .buttonStyle(FocusButtonStyle(kind: focus.pomodoro == nil ? .waiting : .secondary, height: 28))
            }
            Spacer(minLength: 0)
            Button {
                focus.closeTask(taskID: task.id, showPicker: true)
            } label: {
                Label("Завершить", systemImage: "checkmark")
            }
            .buttonStyle(FocusButtonStyle(kind: .done, height: 28))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Задача")
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                Text(Self.focusTitle(focus.currentTask?.title))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(focus.currentTask == nil ? FocusStyle.secondaryText : FocusStyle.primaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if focus.currentTask != nil {
                Button("Сменить") { focus.openPickTask() }
                    .buttonStyle(FocusButtonStyle(kind: .quiet, height: 28, horizontalPadding: 6))
            }
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
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(FocusStyle.working)
                .accessibilityHidden(true)
        }
    }

    private func rowView(_ row: HubRow, primaryID: String?, isHere: Bool = false, unbindable: Bool = false, flat: Bool = false) -> some View {
        HStack(spacing: 12) {
            if unbindable, SessionDoneFormat.showsDoneCheck(group: row.group) {
                SessionDoneCheck(group: row.group) { focus.markSessionDone(sessionID: row.id) }
                    .padding(.trailing, -6)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(unbindable ? (focus.sessionLabel(row.id) ?? row.title) : row.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FocusStyle.primaryText)
                        .lineLimit(1)
                    if row.taskID != nil || flat, let project = row.projectName {
                        ProjectTag(project)
                    }
                }
                Text(Self.hereDetail(row.detail, isHere: isHere))
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(row.group == .waiting ? FocusStyle.waitingText : FocusStyle.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if row.group == .running, let progress = row.progress {
                PlanProgressBar(progress: progress, width: 90)
            }
            if unbindable || flat, let status = SessionStatusKind.of(row.group) {
                SessionStatusBadge(kind: status)
            }
            buttons(row, primaryID: primaryID)
            if unbindable, let taskID = row.taskID {
                SessionMoreMenu(focus: focus, sessionID: row.id, taskID: taskID)
            }
        }
        .padding(.leading, unbindable && SessionDoneFormat.showsDoneCheck(group: row.group) ? 6 : 12)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .background(rowBackground(row.group))
        .overlay {
            if isHere {
                RoundedRectangle(cornerRadius: FocusStyle.rowRadius).stroke(FocusStyle.link, lineWidth: 1.5)
            }
        }
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
        case .done:
            Button(Self.actionTitle(group: row.group)) { focus.reopenDoneSession(sessionID: row.id) }
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: FocusStyle.rowRadius).fill(Color.white.opacity(0.05)))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(Self.footerText(
                focusSeconds: focus.todaySummary.focusSeconds,
                distractionSeconds: focus.todaySummary.distractionSeconds,
                pomodoroCount: focus.pomodoroCountToday
            ))
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

    nonisolated static func showsOnlyTaskChoice(hasTask: Bool, pomodoroActive: Bool) -> Bool {
        !hasTask && !pomodoroActive
    }

    nonisolated static func primaryRowID(rows: [HubRow]) -> String? {
        rows.first { $0.group == .waiting }?.id
    }

    nonisolated static func focusBlockCaption(_ count: Int) -> String {
        "Сессии задачи · \(count)"
    }



    nonisolated static func hereDetail(_ detail: String, isHere: Bool) -> String {
        guard isHere else { return detail }
        return detail.isEmpty ? "ты здесь" : "ты здесь · \(detail)"
    }

    nonisolated static func liveCount(rows: [HubRow]) -> Int {
        rows.filter { !$0.group.isSettled }.count
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
        case .waiting: "Ответить"
        case .running, .idle: "Перейти"
        case .review: "Посмотреть"
        case .unbound: "Привязать"
        case .parked, .done: "Вернуть"
        }
    }

    nonisolated static func isPrimary(row: HubRow, primaryID: String?) -> Bool {
        row.group == .waiting && row.id == primaryID
    }

    nonisolated static func focusTitle(_ title: String?) -> String {
        guard let title, !title.isEmpty else { return "Не выбрана" }
        return title
    }

    nonisolated static func durationLabel(seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        guard minutes >= 60 else { return "\(minutes) мин" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60)ч" : "\(minutes / 60)ч \(rest)м"
    }

    nonisolated static func footerText(focusSeconds: TimeInterval, distractionSeconds: TimeInterval, pomodoroCount: Int = 0) -> String {
        var parts = ["Сегодня: фокус \(durationLabel(seconds: focusSeconds))"]
        if pomodoroCount > 0 { parts.append("помодоро \(pomodoroCount)") }
        parts.append("отвлечения \(durationLabel(seconds: distractionSeconds))")
        return parts.joined(separator: " · ")
    }

    nonisolated static func timerCaption(_ snapshot: PomodoroSnapshot, breakMinutes: Int, focusMinutes: Int) -> String {
        let planned = snapshot.plannedSeconds / 60
        switch snapshot.phase {
        case .focus: return "Фокус \(snapshot.cycleIndex) из \(snapshot.cycle) · из \(planned) мин · потом перерыв \(breakMinutes) мин"
        case .break: return "Перерыв · из \(planned) мин · потом фокус \(focusMinutes) мин"
        }
    }

    nonisolated static func quickFocusCaption(autoBind: Bool) -> String {
        autoBind ? "Задача создастся сама, открытые сессии попадут в неё" : "Задача создастся сама, сессии добавишь в неё потом"
    }

    nonisolated static func newSessionDetail(cwd: String?, prompt: String?) -> String {
        var parts: [String] = []
        if let cwd, !cwd.isEmpty {
            parts.append((cwd as NSString).lastPathComponent)
        }
        if let prompt = PromptText.clean(prompt) {
            let line = prompt.split(separator: "\n").first.map(String.init) ?? prompt
            parts.append("«\(line.count > 60 ? String(line.prefix(60)) + "…" : line)»")
        }
        return parts.map { "· " + $0 }.joined(separator: " ")
    }
}

struct MusicControls: View {
    let player: ChillifyPlayer
    let genre: MusicGenre

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(FocusStyle.secondaryText)
                .accessibilityHidden(true)
            Text(Self.caption(genre: genre, track: player.currentTrack))
                .font(FocusStyle.secondaryFont)
                .foregroundStyle(FocusStyle.secondaryText)
                .lineLimit(1)
            iconButton(player.isUserPaused ? "play.fill" : "pause.fill", label: player.isUserPaused ? "Включить музыку" : "Выключить музыку") { player.togglePause() }
            iconButton("forward.fill", label: "Следующий трек") { player.next() }
            iconButton(Self.isLiked(player) ? "heart.fill" : "heart", label: "Нравится") { player.like() }
        }
    }

    private func iconButton(_ name: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(FocusStyle.tagText)
        .accessibilityLabel(label)
        .help(label)
    }

    private static func isLiked(_ player: ChillifyPlayer) -> Bool {
        player.currentTrack.map { player.likedTracks.contains($0) } ?? false
    }

    nonisolated static func caption(genre: MusicGenre, track: String?) -> String {
        track == nil ? "\(genre.title) · загружаю" : genre.title
    }
}
