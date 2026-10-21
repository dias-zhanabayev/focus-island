import FocusCore
import Foundation
import OpenIslandCore
import Testing
@testable import OpenIslandApp

struct FocusViewLogicTests {
    @Test
    func stayInTaskHeaderWithPlanAndEstimate() {
        let progress = PlanProgress(completed: 2, total: 7, currentTitle: "обновляет хендлеры")
        #expect(StayInTaskCard.header(progress: progress, remaining: 240, elapsed: 100) == "Шаг 3 из 7: обновляет хендлеры · по плану ещё ~4 мин")
    }

    @Test
    func stayInTaskHeaderWithoutEstimateOrTitle() {
        let progress = PlanProgress(completed: 0, total: 3, currentTitle: nil)
        #expect(StayInTaskCard.header(progress: progress, remaining: nil, elapsed: 30) == "Шаг 1 из 3")
    }

    @Test
    func stayInTaskHeaderClampsStepAndRoundsEstimateUp() {
        let progress = PlanProgress(completed: 3, total: 3, currentTitle: "финал")
        #expect(StayInTaskCard.header(progress: progress, remaining: 20, elapsed: nil) == "Шаг 3 из 3: финал · по плану ещё ~1 мин")
    }

    @Test
    func stayInTaskHeaderWithoutPlan() {
        #expect(StayInTaskCard.header(progress: nil, remaining: nil, elapsed: 400) == "Работает · 6 мин")
        #expect(StayInTaskCard.header(progress: nil, remaining: nil, elapsed: 10) == "Работает · меньше минуты")
        #expect(StayInTaskCard.header(progress: nil, remaining: nil, elapsed: nil) == "Работает")
    }

    @Test
    func clockFormatsMinutesAndSeconds() {
        #expect(StayInTaskCard.clock(100) == "1:40")
        #expect(StayInTaskCard.clock(5) == "0:05")
        #expect(StayInTaskCard.clock(3725) == "62:05")
    }

    @Test
    func switchTitleUsesEstimate() {
        #expect(StayInTaskCard.switchTitle(remaining: 240) == "Или переключиться — 4 мин хватит")
        #expect(StayInTaskCard.switchTitle(remaining: 10) == "Или переключиться — 1 мин хватит")
        #expect(StayInTaskCard.switchTitle(remaining: nil) == "Или переключиться")
    }

    @Test
    func changedFileURLJoinsPaths() {
        #expect(StayInTaskCard.fileURL(cwd: "/tmp/proj", path: "Sources/A.swift").path == "/tmp/proj/Sources/A.swift")
        #expect(StayInTaskCard.fileURL(cwd: "/tmp/proj/", path: "A.swift").path == "/tmp/proj/A.swift")
        #expect(StayInTaskCard.fileURL(cwd: "/tmp/proj", path: "/abs/B.swift").path == "/abs/B.swift")
    }

    @Test
    func nudgeTitleFormatsSeconds() {
        #expect(NudgeCard.title(target: "youtube.com", seconds: 25) == "Claude работает — ты на youtube.com уже 25 с")
        #expect(NudgeCard.title(target: "Telegram", seconds: 0) == "Claude работает — ты в Telegram уже 0 с")
        #expect(NudgeCard.title(target: "youtube.com", seconds: 125) == "Claude работает — ты на youtube.com уже 2 мин 5 с")
        #expect(NudgeCard.title(target: "youtube.com", seconds: 120) == "Claude работает — ты на youtube.com уже 2 мин")
        #expect(NudgeCard.title(target: nil, seconds: 30) == "Claude работает — ты отвлёкся")
    }

    @Test
    func nudgeSubtitleJoinsAvailableParts() {
        #expect(NudgeCard.subtitle(project: "focus", task: "Рефакторинг auth", elapsed: 70) == "Сессия focus · «Рефакторинг auth» · 1:10")
        #expect(NudgeCard.subtitle(project: "focus", task: nil, elapsed: nil) == "Сессия focus")
        #expect(NudgeCard.subtitle(project: nil, task: nil, elapsed: nil) == "Сессия")
    }

    @Test
    func returnSubtitleCombinesStepsMinutesAndAwayProject() {
        let progress = PlanProgress(completed: 7, total: 7, currentTitle: nil)
        #expect(ReturnCard.subtitle(progress: progress, minutes: 6, awayProject: "billing") == "7 из 7 шагов · 6 мин · пока ты был в billing")
        #expect(ReturnCard.subtitle(progress: nil, minutes: 6, awayProject: nil) == "6 мин")
        #expect(ReturnCard.subtitle(progress: progress, minutes: nil, awayProject: nil) == "7 из 7 шагов")
        #expect(ReturnCard.subtitle(progress: nil, minutes: nil, awayProject: "billing") == "пока ты был в billing")
    }

    @Test
    func returnDoneStepsFallBackToTruncatedMessage() {
        let long = String(repeating: "я", count: 300)
        let message = ReturnCard.doneItems(completedTitles: [], lastMessage: long)
        #expect(message.count == 1)
        #expect(message[0].count == 240)
        #expect(ReturnCard.doneItems(completedTitles: ["a", "b", "c", "d", "e"], lastMessage: "x") == ["a", "b", "c", "d"])
        #expect(ReturnCard.doneItems(completedTitles: [], lastMessage: nil).isEmpty)
        #expect(ReturnCard.doneItems(completedTitles: [], lastMessage: "  \n ").isEmpty)
    }

    @Test
    func reEntryBreadcrumbDescribesFocusTask() {
        let progress = PlanProgress(completed: 3, total: 7, currentTitle: nil)
        #expect(ReEntryCard.breadcrumb(taskTitle: "Рефакторинг auth", progress: progress, hasQueuedPrompt: true, isRunning: true) == "Рефакторинг auth продолжается · шаг 4 из 7 · промпт в очереди · позову, когда закончит")
        #expect(ReEntryCard.breadcrumb(taskTitle: "Рефакторинг auth", progress: nil, hasQueuedPrompt: false, isRunning: true) == "Рефакторинг auth продолжается · позову, когда закончит")
        #expect(ReEntryCard.breadcrumb(taskTitle: "Рефакторинг auth", progress: progress, hasQueuedPrompt: true, isRunning: false) == nil)
        #expect(ReEntryCard.breadcrumb(taskTitle: nil, progress: progress, hasQueuedPrompt: true, isRunning: true) == nil)
    }

    @Test
    func reEntryAgoText() {
        #expect(ReEntryCard.agoText(minutes: 40) == "40 мин назад")
        #expect(ReEntryCard.agoText(minutes: 60) == "1 ч назад")
        #expect(ReEntryCard.agoText(minutes: 135) == "2 ч 15 мин назад")
        #expect(ReEntryCard.agoText(minutes: 0) == "только что")
    }

    @Test
    func truncationLimits() {
        #expect(FocusText.truncated("abc", limit: 5) == "abc")
        #expect(FocusText.truncated("abcdef", limit: 5) == "abcde")
        #expect(FocusText.truncated("  abc \n", limit: 5) == "abc")
        #expect(FocusText.cardMessageLimit == 240)
    }

    @Test
    func planBarFractionClamps() {
        #expect(PlanProgressBar.fraction(PlanProgress(completed: 3, total: 7, currentTitle: nil)) > 0.42)
        #expect(PlanProgressBar.fraction(PlanProgress(completed: 9, total: 7, currentTitle: nil)) == 1)
        #expect(PlanProgressBar.fraction(PlanProgress(completed: 0, total: 0, currentTitle: nil)) == 0)
    }

    @Test
    func alternativeCopy() {
        let since = Date(timeIntervalSince1970: 0)
        #expect(StayInTaskCard.reason(.attend(sessionID: "a", reason: .approval, since: since)) == "Разрешение · дело на минуту")
        #expect(StayInTaskCard.reason(.attend(sessionID: "a", reason: .question, since: since)) == "Вопрос · дело на минуту")
        #expect(StayInTaskCard.reason(.startTask(taskID: "t", sameProject: true)) == "тот же проект — переключаться легче")
        #expect(StayInTaskCard.attendTitle(name: "billing", reason: .question) == "billing ждёт ответа")
        #expect(StayInTaskCard.attendTitle(name: "billing", reason: .approval) == "billing ждёт разрешения")
        #expect(StayInTaskCard.actionTitle(.startTask(taskID: "t", sameProject: false)) == "Начать")
        #expect(StayInTaskCard.actionTitle(.review(sessionID: "a")) == "Перейти")
    }

    @Test
    func reEntryOriginLine() {
        #expect(ReEntryCard.originLine(project: "billing", minutes: 40) == "billing · последний раз 40 мин назад")
        #expect(ReEntryCard.originLine(project: nil, minutes: 40) == "последний раз 40 мин назад")
        #expect(ReEntryCard.originLine(project: "billing", minutes: nil) == "billing")
    }

    @Test
    func syncedDraftFollowsQueueUnlessUserIsEditing() {
        let initial = StayInTaskCard.syncedDraft(current: "", lastSynced: nil, queued: "old")
        #expect(initial.draft == "old" && initial.lastSynced == "old")
        let unchanged = StayInTaskCard.syncedDraft(current: "typing", lastSynced: "old", queued: "old")
        #expect(unchanged.draft == "typing" && unchanged.lastSynced == "old")
        let followed = StayInTaskCard.syncedDraft(current: "old", lastSynced: "old", queued: "new")
        #expect(followed.draft == "new" && followed.lastSynced == "new")
        let midEdit = StayInTaskCard.syncedDraft(current: "mine", lastSynced: "old", queued: "new")
        #expect(midEdit.draft == "mine" && midEdit.lastSynced == "new")
        let cleared = StayInTaskCard.syncedDraft(current: "old", lastSynced: "old", queued: nil)
        #expect(cleared.draft == "" && cleared.lastSynced == nil)
        let emptyStaysEmpty = StayInTaskCard.syncedDraft(current: "", lastSynced: nil, queued: nil)
        #expect(emptyStaysEmpty.draft == "" && emptyStaysEmpty.lastSynced == nil)
    }

    @Test
    func stalledAgeLabelUsesMinutesThenHours() {
        #expect(WaitingOutsideSection.ageLabel(seconds: 25 * 60) == "25 м")
        #expect(WaitingOutsideSection.ageLabel(seconds: 59 * 60 + 59) == "59 м")
        #expect(WaitingOutsideSection.ageLabel(seconds: 3600) == "1 ч")
        #expect(WaitingOutsideSection.ageLabel(seconds: 2 * 3600 + 1800) == "2 ч")
        #expect(WaitingOutsideSection.ageLabel(seconds: -5) == "0 м")
    }

    @Test
    func dayStartPrimaryTitleUsesFirstSelected() {
        #expect(DayStartCard.primaryTitle(selectedTitles: ["Рефакторинг auth", "Webhook"]) == "Начать с «Рефакторинг auth»")
        #expect(DayStartCard.primaryTitle(selectedTitles: []) == "Начать день")
    }

    @Test
    func dayStartSelectionCapsAtThree() {
        #expect(DayStartCard.toggled(["a", "b"], id: "c") == ["a", "b", "c"])
        #expect(DayStartCard.toggled(["a", "b", "c"], id: "d") == ["a", "b", "c"])
        #expect(DayStartCard.toggled(["a", "b", "c"], id: "b") == ["a", "c"])
    }

    @Test
    func dayStartDefaultSelectionTakesInProgressFirstThree() {
        func task(_ id: String, _ column: BoardColumn) -> FocusTask {
            FocusTask(id: id, title: id, details: nil, boardColumn: column, position: 0, projectPath: nil, note: nil, createdAt: .distantPast, updatedAt: .distantPast, doneAt: nil)
        }
        let tasks = [task("a", .inProgress), task("b", .inProgress), task("c", .inProgress), task("d", .inProgress), task("e", .todo)]
        #expect(DayStartCard.defaultSelection(tasks: tasks) == ["a", "b", "c"])
        #expect(DayStartCard.defaultSelection(tasks: [task("e", .todo)]) == [])
    }

    @Test
    func dayStartYesterdayRowsKeepOpenGroupsBeforeToday() {
        let startOfToday = Date(timeIntervalSince1970: 100_000)
        func row(_ id: String, _ group: HubGroup) -> HubRow {
            HubRow(id: id, group: group, taskID: nil, title: id, projectName: nil, detail: "", since: .distantPast, progress: nil)
        }
        let rows = [row("w", .waiting), row("r", .review), row("run", .running), row("p", .parked), row("fresh", .idle), row("u", .unbound)]
        let activity: [String: Date] = [
            "w": startOfToday.addingTimeInterval(-3600),
            "r": startOfToday.addingTimeInterval(-7200),
            "run": startOfToday.addingTimeInterval(-3600),
            "p": startOfToday.addingTimeInterval(-86_400),
            "fresh": startOfToday.addingTimeInterval(60),
            "u": startOfToday.addingTimeInterval(-3600)
        ]
        let result = DayStartCard.yesterdayRows(rows: rows, startOfToday: startOfToday) { activity[$0] }
        #expect(result.map(\.id) == ["w", "r", "p"])
    }

    @Test
    func dayStartYesterdayDetail() {
        #expect(DayStartCard.yesterdayButtonTitle(group: .waiting) == "Продолжить")
        #expect(DayStartCard.yesterdayButtonTitle(group: .review) == "Посмотреть")
        #expect(DayStartCard.yesterdayButtonTitle(group: .parked) == "Вернуть")
        #expect(DayStartCard.yesterdayButtonTitle(group: .idle) == "Продолжить")
    }

    @Test
    func bindingGroupsPutProjectTasksFirst() {
        func task(_ id: String, _ path: String?) -> FocusTask {
            FocusTask(id: id, title: id, details: nil, boardColumn: .todo, position: 0, projectPath: path, note: nil, createdAt: .distantPast, updatedAt: .distantPast, doneAt: nil)
        }
        let tasks = [task("a", "/p/focus"), task("b", "/p/other"), task("c", nil), task("d", "/p/focus/")]
        let groups = BindingCard.groups(tasks: tasks, cwd: "/p/focus/Sources")
        #expect(groups.thisProject.map(\.id) == ["a", "d"])
        #expect(groups.others.map(\.id) == ["b", "c"])
        let none = BindingCard.groups(tasks: tasks, cwd: nil)
        #expect(none.thisProject.isEmpty && none.others.count == 4)
    }

    @Test
    func overloadTitleAndChipText() {
        #expect(OverloadCard.title(liveCount: 4) == "Запускаешь 4-ю сессию")
        #expect(OverloadCard.subtitle(limit: 3) == "Обычно ты уверенно держишь 3. Дальше сессии начинают теряться — давай сначала разгрузим голову.")
        #expect(OverloadCard.stateText(.waiting) == "ждёт")
        #expect(OverloadCard.stateText(.running) == "работает")
        #expect(OverloadCard.stateText(.review) == "готово")
        #expect(OverloadCard.stateText(.idle) == "твой ход")
        #expect(OverloadCard.stateText(.unbound) == "без задачи")
    }

    @Test
    func onboardingCompletionAndInput() {
        #expect(OnboardingCard.canAddTask(text: "  ") == false)
        #expect(OnboardingCard.canAddTask(text: " Задача ") == true)
        #expect(OnboardingCard.stage(hooksInstalled: nil, taskAdded: false) == .connect)
        #expect(OnboardingCard.stage(hooksInstalled: false, taskAdded: false) == .connect)
        #expect(OnboardingCard.stage(hooksInstalled: true, taskAdded: false) == .firstTask)
        #expect(OnboardingCard.stage(hooksInstalled: true, taskAdded: true) == .started)
        #expect(OnboardingCard.startedToast(sessionCount: 2) == "Задача в работе · 2 сессии внутри")
        #expect(OnboardingCard.candidateDetail(cwd: nil, appName: nil) == "сессия Claude")
        #expect(OnboardingCard.candidateDetail(cwd: "/tmp/api", appName: "Ghostty") == "/tmp/api · Ghostty")
        #expect(OnboardingCard.shortPath(NSHomeDirectory() + "/work/api") == "~/work/api")
        #expect(OnboardingCard.launchCommand(projectPath: nil) == "claude")
        #expect(OnboardingCard.launchCommand(projectPath: NSHomeDirectory() + "/work/api") == "cd ~/work/api && claude")
        #expect(OnboardingCard.launchCommand(projectPath: "/tmp/my api") == "cd \"/tmp/my api\" && claude")
    }

    @Test
    func bindingShortPathReplacesHome() {
        let home = NSHomeDirectory()
        #expect(BindingCard.shortPath(home) == "~")
        #expect(BindingCard.shortPath(home + "/Projects/focus") == "~/Projects/focus")
        #expect(BindingCard.shortPath("/tmp/x") == "/tmp/x")
    }

    @Test
    func overloadWaitingDetailUsesNow() {
        let since = Date(timeIntervalSince1970: 1000)
        let row = HubRow(id: "a", group: .waiting, taskID: nil, title: "a", projectName: nil, detail: "", since: since, progress: nil)
        #expect(OverloadCard.waitingDetail(row: row, now: since.addingTimeInterval(190)) == "ждёт 3 мин")
    }

    @Test
    func bindingShownBelowNonModalCardsOnly() {
        #expect(FocusIslandSection.showsBinding(card: nil))
        #expect(FocusIslandSection.showsBinding(card: .dayStart))
        #expect(FocusIslandSection.showsBinding(card: .returned(sessionID: "a")))
        #expect(!FocusIslandSection.showsBinding(card: .onboarding))
        #expect(!FocusIslandSection.showsBinding(card: .nudge))
        #expect(!FocusIslandSection.showsBinding(card: .overload(newSessionID: "a")))
        #expect(!FocusIslandSection.showsBinding(card: .reEntry(sessionID: "a")))
    }

    private func hubRow(_ id: String, _ group: HubGroup) -> HubRow {
        HubRow(id: id, group: group, taskID: nil, title: id, projectName: nil, detail: "", since: .distantPast, progress: nil)
    }

    @Test
    func hubPrimaryRowIsFirstWaiting() {
        #expect(SessionHubView.primaryRowID(rows: [hubRow("r", .running), hubRow("w1", .waiting), hubRow("w2", .waiting)]) == "w1")
        #expect(SessionHubView.primaryRowID(rows: [hubRow("r", .running), hubRow("v", .review)]) == nil)
        #expect(SessionHubView.primaryRowID(rows: []) == nil)
    }

    @Test
    func hubHeaderCountPluralizesSessions() {
        #expect(SessionHubView.headerCount(live: 4, limit: 3) == "4 сессии · держишь 3")
        #expect(SessionHubView.headerCount(live: 1, limit: 3) == "1 сессия · держишь 3")
        #expect(SessionHubView.headerCount(live: 5, limit: 6) == "5 сессий · держишь 6")
        #expect(SessionHubView.headerCount(live: 11, limit: 3) == "11 сессий · держишь 3")
        #expect(SessionHubView.headerCount(live: 21, limit: 3) == "21 сессия · держишь 3")
        #expect(SessionHubView.headerCount(live: 0, limit: 3) == "0 сессий · держишь 3")
    }

    @Test
    func hubLiveCountSkipsParked() {
        #expect(SessionHubView.liveCount(rows: [hubRow("a", .running), hubRow("b", .parked), hubRow("c", .unbound)]) == 2)
    }

    @Test
    func hubGroupsKeepOrderAndSkipEmpty() {
        let rows = [hubRow("p", .parked), hubRow("r", .running), hubRow("w", .waiting), hubRow("r2", .running)]
        let groups = SessionHubView.groups(rows: rows)
        #expect(groups.map(\.group) == [.waiting, .running, .parked])
        #expect(groups[1].rows.map(\.id) == ["r", "r2"])
        #expect(SessionHubView.groupCaption(.running, count: 2) == "Работают · 2")
    }

    @Test
    func hubRowActions() {
        #expect(SessionHubView.actionTitle(group: .waiting) == "Ответить")
        #expect(SessionHubView.actionTitle(group: .review) == "Посмотреть")
        #expect(SessionHubView.actionTitle(group: .running) == "Перейти")
        #expect(SessionHubView.actionTitle(group: .idle) == "Перейти")
        #expect(SessionHubView.actionTitle(group: .unbound) == "Привязать")
        #expect(SessionHubView.actionTitle(group: .parked) == "Вернуть")
        #expect(SessionHubView.isPrimary(row: hubRow("w1", .waiting), primaryID: "w1"))
        #expect(!SessionHubView.isPrimary(row: hubRow("w2", .waiting), primaryID: "w1"))
        #expect(!SessionHubView.isPrimary(row: hubRow("r", .running), primaryID: nil))
    }

    @Test
    func hubDurationLabel() {
        #expect(SessionHubView.durationLabel(seconds: 7800) == "2ч 10м")
        #expect(SessionHubView.durationLabel(seconds: 7200) == "2ч")
        #expect(SessionHubView.durationLabel(seconds: 360) == "6 мин")
        #expect(SessionHubView.durationLabel(seconds: 59) == "0 мин")
        #expect(SessionHubView.durationLabel(seconds: -5) == "0 мин")
    }

    @Test
    func hubFooterText() {
        #expect(SessionHubView.footerText(focusSeconds: 7800, distractionSeconds: 360) == "Сегодня: фокус 2ч 10м · отвлечения 6 мин")
        #expect(SessionHubView.footerText(focusSeconds: 0, distractionSeconds: 0) == "Сегодня: фокус 0 мин · отвлечения 0 мин")
    }

    @Test
    func hubFocusTitleFallsBack() {
        #expect(SessionHubView.focusTitle(nil) == "Не выбрана")
        #expect(SessionHubView.focusTitle("Рефакторинг auth") == "Рефакторинг auth")
    }

    @Test
    func hubDaySummaryNotificationTargetsToday() {
        #expect(SessionHubView.daySummaryUserInfo["tab"] as? String == "today")
    }

    @Test
    func panelActionableSessionsKeepOnlyApprovalAndQuestion() {
        func session(_ id: String, _ phase: SessionPhase) -> AgentSession {
            AgentSession(id: id, title: id, tool: .claudeCode, origin: .live, attachmentState: .attached, phase: phase, summary: "", updatedAt: .distantPast)
        }
        let sessions = [session("r", .running), session("a", .waitingForApproval), session("c", .completed), session("q", .waitingForAnswer)]
        #expect(IslandPanelView.actionableSessions(sessions).map(\.id) == ["a", "q"])
        #expect(IslandPanelView.actionableSessions([session("r", .running)]).isEmpty)
    }

    private func hubRow(_ id: String, _ group: HubGroup, taskID: String? = "t1") -> HubRow {
        HubRow(id: id, group: group, taskID: taskID, title: id, projectName: nil, detail: "", since: .distantPast, progress: nil)
    }

    private func record(_ id: String, start: TimeInterval, end: TimeInterval, message: String? = nil) -> SessionRecord {
        SessionRecord(id: id, cwd: nil, projectName: nil, title: id, firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: message, startedAt: Date(timeIntervalSince1970: start), lastActivityAt: Date(timeIntervalSince1970: end), endedAt: Date(timeIntervalSince1970: end), status: .ended, taskId: "t1", transcriptPath: nil)
    }

    @Test
    func boardTabParsesUserInfo() {
        #expect(BoardTab.from(userInfo: ["tab": "today"]) == .today)
        #expect(BoardTab.from(userInfo: ["tab": "week"]) == .week)
        #expect(BoardTab.from(userInfo: ["tab": "history"]) == .history)
        #expect(BoardTab.from(userInfo: ["tab": "board"]) == .board)
        #expect(BoardTab.from(userInfo: ["tab": "bogus"]) == .board)
        #expect(BoardTab.from(userInfo: ["tab": 3]) == .board)
        #expect(BoardTab.from(userInfo: nil) == .board)
        #expect(BoardTab.from(userInfo: SessionHubView.daySummaryUserInfo) == .today)
    }

    @Test
    func boardTabTitles() {
        #expect(BoardTab.allCases.map(\.title) == ["Доска", "Сегодня", "Неделя", "История"])
    }

    @Test
    func borderStylePrefersWaitingThenRunningThenReview() {
        #expect(TaskCardView.borderStyle(rows: [hubRow("a", .running), hubRow("b", .waiting), hubRow("c", .review)]) == .waiting)
        #expect(TaskCardView.borderStyle(rows: [hubRow("a", .review), hubRow("b", .running)]) == .running)
        #expect(TaskCardView.borderStyle(rows: [hubRow("a", .review)]) == .review)
        #expect(TaskCardView.borderStyle(rows: [hubRow("a", .idle), hubRow("b", .parked), hubRow("c", .unbound)]) == TaskCardBorder.none)
        #expect(TaskCardView.borderStyle(rows: []) == TaskCardBorder.none)
    }

    @Test
    func pastSummaryCountsOnlyNonLiveSessions() {
        let records = [record("a", start: 0, end: 1200), record("b", start: 2000, end: 2960), record("live", start: 4000, end: 9000)]
        #expect(TaskCardView.pastSummary(records: records, live: ["live"]) == "ещё 2 сессии · 36 мин")
        #expect(TaskCardView.pastSummary(records: [record("a", start: 0, end: 600)], live: []) == "ещё 1 сессия · 10 мин")
        #expect(TaskCardView.pastSummary(records: [record("live", start: 0, end: 600)], live: ["live"]) == nil)
        #expect(TaskCardView.pastSummary(records: [], live: []) == nil)
    }

    @Test
    func sessionsWordAgrees() {
        #expect(TaskCardView.pastSummary(records: (0..<5).map { record("s\($0)", start: 0, end: 60) }, live: []) == "ещё 5 сессий · 5 мин")
        #expect(TaskCardView.pastSummary(records: (0..<21).map { record("s\($0)", start: 0, end: 60) }, live: []) == "ещё 21 сессия · 21 мин")
    }

    @Test
    func boardDurationFormatting() {
        #expect(BoardView.duration(0) == "0 мин")
        #expect(BoardView.duration(20) == "1 мин")
        #expect(BoardView.duration(52 * 60) == "52 мин")
        #expect(BoardView.duration(65 * 60) == "1 ч 05 мин")
        #expect(BoardView.duration(120 * 60) == "2 ч")
    }

    @Test
    func toolbarCountsGroupRows() {
        let rows = [hubRow("a", .running), hubRow("b", .running), hubRow("c", .waiting), hubRow("d", .review), hubRow("e", .idle)]
        let counts = BoardView.toolbarCounts(rows: rows)
        #expect(counts == BoardToolbarCounts(working: 2, waiting: 1, review: 1))
        #expect(BoardView.workingLabel(2) == "2 работают")
        #expect(BoardView.workingLabel(1) == "1 работает")
        #expect(BoardView.waitingLabel(1) == "1 ждёт тебя")
        #expect(BoardView.waitingLabel(3) == "3 ждут тебя")
        #expect(BoardView.reviewLabel(1) == "1 готово")
    }

    @Test
    func doneCaptionShowsDaySessionsAndTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_000_000)
        let yesterday = now.addingTimeInterval(-86_400)
        let records = [record("a", start: 0, end: 1800), record("b", start: 0, end: 1800), record("c", start: 0, end: 1800)]
        #expect(TaskCardView.doneCaption(doneAt: yesterday, records: records, now: now, calendar: calendar) == "вчера · 3 сессии · 1 ч 30 мин")
        #expect(TaskCardView.doneCaption(doneAt: now, records: [], now: now, calendar: calendar) == "сегодня")
        #expect(TaskCardView.doneCaption(doneAt: nil, records: records, now: now, calendar: calendar) == "3 сессии · 1 ч 30 мин")
        #expect(TaskCardView.doneCaption(doneAt: yesterday, records: [record("a", start: 0, end: 1080)], now: now, calendar: calendar) == "вчера · 1 сессия · 18 мин")
    }

    @Test
    func waitMinutesLabel() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(TaskCardView.waitLabel(since: now.addingTimeInterval(-180), now: now) == "3 м")
        #expect(TaskCardView.waitLabel(since: now.addingTimeInterval(-10), now: now) == "0 м")
    }

    @Test
    func taskTimeTotalsUnionSpans() {
        let t = Date(timeIntervalSince1970: 0)
        func span(_ kind: ActivityKind, _ start: TimeInterval, _ end: TimeInterval?) -> ActivitySpan {
            ActivitySpan(kind: kind, sessionId: nil, taskId: "t1", startedAt: t.addingTimeInterval(start), endedAt: end.map { t.addingTimeInterval($0) })
        }
        let spans = [span(.claude, 0, 600), span(.claude, 300, 900), span(.you, 800, 1200), span(.waiting, 1200, 2000), span(.distraction, 0, 5000), span(.claude, 3000, nil)]
        let totals = TaskDetailView.timeTotals(spans: spans, now: t.addingTimeInterval(3300))
        #expect(totals.claudeSeconds == 1200)
        #expect(totals.totalSeconds == 1500)
        #expect(TaskDetailView.timeSummary(totals) == "всего 25 мин · Claude 20 мин")
        #expect(TaskDetailView.timeSummary(TaskTimeTotals(totalSeconds: 0, claudeSeconds: 0)) == nil)
    }

    @Test
    func detailCaptions() {
        #expect(TaskDetailView.criteriaCaption(CriteriaProgress(done: 1, total: 2)) == "Критерий готовности · 1 из 2")
        #expect(TaskDetailView.criteriaCaption(nil) == "Критерий готовности")
        #expect(TaskDetailView.sessionsCaption(count: 3) == "Сессии · 3")
    }

    @Test
    func pastSessionSubtitleTrimsMessage() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_000_000)
        let message = String(repeating: "я", count: 100)
        let rec = SessionRecord(id: "p", cwd: nil, projectName: nil, title: "p", firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: message, startedAt: now.addingTimeInterval(-86_400 - 1440), lastActivityAt: now.addingTimeInterval(-86_400), endedAt: now.addingTimeInterval(-86_400), status: .ended, taskId: "t1", transcriptPath: nil)
        let subtitle = TaskDetailView.pastSubtitle(record: rec, now: now, calendar: calendar)
        #expect(subtitle.hasPrefix("вчера, "))
        #expect(subtitle.contains(" · 24 мин · "))
        #expect(subtitle.hasSuffix(String(repeating: "я", count: 60)))
        let bare = SessionRecord(id: "p", cwd: nil, projectName: nil, title: "p", firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, startedAt: now.addingTimeInterval(-600), lastActivityAt: now, endedAt: now, status: .ended, taskId: "t1", transcriptPath: nil)
        #expect(TaskDetailView.pastSubtitle(record: bare, now: now, calendar: calendar).hasSuffix(" · 10 мин"))
    }

    @Test
    func liveSessionSubtitle() {
        let progress = PlanProgress(completed: 2, total: 7, currentTitle: nil)
        #expect(TaskDetailView.liveSubtitle(progress: progress, group: .running) == "сейчас · шаг 3 из 7")
        #expect(TaskDetailView.liveSubtitle(progress: nil, group: .running) == "сейчас")
        #expect(TaskDetailView.liveSubtitle(progress: nil, group: .waiting) == "ждёт ответа")
        #expect(TaskDetailView.liveSubtitle(progress: nil, group: .review) == "закончил, не просмотрено")
    }

    @Test
    func newSessionCwdFallsBackToHome() {
        #expect(TaskDetailView.newSessionCwd(projectPath: "/tmp/proj", home: "/Users/x") == "/tmp/proj")
        #expect(TaskDetailView.newSessionCwd(projectPath: nil, home: "/Users/x") == "/Users/x")
        #expect(TaskDetailView.newSessionCwd(projectPath: "", home: "/Users/x") == "/Users/x")
    }

    @Test
    func boardTabExplicitIsNilWithoutValidTab() {
        #expect(BoardTab.explicit(userInfo: ["tab": "week"]) == .week)
        #expect(BoardTab.explicit(userInfo: nil) == nil)
        #expect(BoardTab.explicit(userInfo: ["tab": "bogus"]) == nil)
        #expect(BoardTab.explicit(userInfo: SessionHubView.boardUserInfo) == .board)
    }

    @Test
    func liveRecordsWithoutRowStayVisible() {
        let a = record("a", start: 0, end: 60)
        let b = record("b", start: 0, end: 60)
        let c = record("c", start: 0, end: 60)
        let rows = [hubRow("a", .running)]
        #expect(TaskDetailView.unrowedLive(records: [a, b, c], rows: rows, live: ["a", "b"]).map(\.id) == ["b"])
    }

    private func daySummaryCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func summaryTask(_ id: String, _ title: String, column: BoardColumn, updatedAt: Date, doneAt: Date? = nil) -> FocusTask {
        FocusTask(id: id, title: title, details: nil, boardColumn: column, position: 1, projectPath: nil, note: nil, createdAt: Date(timeIntervalSince1970: 0), updatedAt: updatedAt, doneAt: doneAt)
    }

    private func summaryReport(lanes: [TaskLane] = [], first: Date? = nil, last: Date? = nil) -> DayReport {
        DayReport(youSeconds: 19_200, claudeSeconds: 13_500, waitingSeconds: 2_880, distractionSeconds: 660, distractionCount: 4, returnedCount: 3, maxParallel: 4, firstAt: first, lastAt: last, lanes: lanes, distractionLane: [])
    }

    @Test
    func daySummaryDurationFormatsHoursAndMinutes() {
        #expect(DaySummaryFormatter.duration(19_200) == "5 ч 20 м")
        #expect(DaySummaryFormatter.duration(2_880) == "48 м")
        #expect(DaySummaryFormatter.duration(3_600) == "1 ч")
        #expect(DaySummaryFormatter.duration(0) == "0 м")
        #expect(DaySummaryFormatter.duration(-5) == "0 м")
        #expect(DaySummaryFormatter.duration(29) == "0 м")
        #expect(DaySummaryFormatter.duration(31) == "1 м")
    }

    @Test
    func daySummaryTitleAndRange() {
        let calendar = daySummaryCalendar()
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 12))!
        let title = DaySummaryFormatter.title(day, calendar: calendar)
        #expect(title == "Пятница, 9 октября")
        let first = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 9, minute: 14))!
        let last = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 18, minute: 40))!
        #expect(DaySummaryFormatter.range(first: first, last: last, calendar: calendar) == "09:14 – 18:40")
        #expect(DaySummaryFormatter.range(first: nil, last: nil, calendar: calendar) == nil)
    }

    @Test
    func daySummaryDistractionDetail() {
        #expect(DaySummaryFormatter.distractionDetail(count: 4, returned: 3) == "4 раза, вернулся 3")
        #expect(DaySummaryFormatter.distractionDetail(count: 1, returned: 0) == "1 раз, вернулся 0")
        #expect(DaySummaryFormatter.distractionDetail(count: 5, returned: 5) == "5 раз, вернулся 5")
        #expect(DaySummaryFormatter.distractionDetail(count: 0, returned: 0) == nil)
    }

    @Test
    func daySummarySelectsDoneTasksOfTheDay() {
        let calendar = daySummaryCalendar()
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9))!
        let end = start.addingTimeInterval(86_400)
        let tasks = [
            summaryTask("a", "Сегодня", column: .done, updatedAt: start, doneAt: start.addingTimeInterval(3_600)),
            summaryTask("b", "Вчера", column: .done, updatedAt: start, doneAt: start.addingTimeInterval(-60)),
            summaryTask("c", "Завтра", column: .done, updatedAt: start, doneAt: end),
            summaryTask("d", "Без даты", column: .done, updatedAt: start, doneAt: nil),
            summaryTask("e", "В работе", column: .inProgress, updatedAt: start, doneAt: nil)
        ]
        #expect(DaySummaryFormatter.done(tasks: tasks, dayStart: start, dayEnd: end).map(\.id) == ["a"])
    }

    @Test
    func daySummarySelectsOpenTasksWithActivity() {
        let calendar = daySummaryCalendar()
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9))!
        let end = start.addingTimeInterval(86_400)
        let report = DayReport(youSeconds: 0, claudeSeconds: 0, waitingSeconds: 0, distractionSeconds: 0, distractionCount: 0, returnedCount: 0, maxParallel: 0, firstAt: nil, lastAt: nil, lanes: [], distractionLane: [], activeTaskIDs: ["a"])
        let tasks = [
            summaryTask("a", "По ленте", column: .inProgress, updatedAt: start.addingTimeInterval(-86_400)),
            summaryTask("b", "По обновлению", column: .inProgress, updatedAt: start.addingTimeInterval(60)),
            summaryTask("c", "Без активности", column: .inProgress, updatedAt: start.addingTimeInterval(-86_400)),
            summaryTask("d", "Не в работе", column: .todo, updatedAt: start.addingTimeInterval(60)),
            summaryTask("e", "Сделано", column: .done, updatedAt: start.addingTimeInterval(60), doneAt: start.addingTimeInterval(60))
        ]
        #expect(DaySummaryFormatter.open(tasks: tasks, report: report, dayStart: start, dayEnd: end).map(\.id) == ["a", "b"])
    }

    @Test
    func daySummaryOpenSubtitle() {
        #expect(DaySummaryFormatter.openSubtitle(progress: CriteriaProgress(done: 1, total: 2), hasQueuedPrompt: true) == "критерий 1 из 2 · промпт в очереди")
        #expect(DaySummaryFormatter.openSubtitle(progress: CriteriaProgress(done: 0, total: 3), hasQueuedPrompt: false) == "критерий 0 из 3")
        #expect(DaySummaryFormatter.openSubtitle(progress: nil, hasQueuedPrompt: true) == "промпт в очереди")
        #expect(DaySummaryFormatter.openSubtitle(progress: nil, hasQueuedPrompt: false) == nil)
    }

    @Test
    func daySummaryMarkdownIncludesAllSections() {
        let calendar = daySummaryCalendar()
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 12))!
        let start = calendar.startOfDay(for: day)
        let done = [summaryTask("a", "Hero copy", column: .done, updatedAt: start, doneAt: start)]
        let open = [summaryTask("b", "Рефакторинг auth", column: .inProgress, updatedAt: start)]
        let text = DaySummaryFormatter.markdown(report: summaryReport(), done: done, open: open, tomorrow: "Проверить алерты", day: day, calendar: calendar)
        let expected = """
        # Пятница, 9 октября

        - Ты в работе: 5 ч 20 м
        - Claude работал: 3 ч 45 м
        - Сессии ждали тебя: 48 м
        - Отвлечения: 11 м (4 раза, вернулся 3)
        - Макс. параллельно: 4

        ## Сделано
        - Hero copy

        ## Осталось открытым
        - Рефакторинг auth

        ## Завтра начать с
        Проверить алерты
        """
        #expect(text == expected)
    }

    @Test
    func daySummaryMarkdownSkipsEmptySections() {
        let calendar = daySummaryCalendar()
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 12))!
        let text = DaySummaryFormatter.markdown(report: summaryReport(), done: [], open: [], tomorrow: "  ", day: day, calendar: calendar)
        #expect(!text.contains("## Сделано"))
        #expect(!text.contains("## Осталось открытым"))
        #expect(!text.contains("## Завтра начать с"))
        #expect(text.hasPrefix("# Пятница, 9 октября"))
        let nilTomorrow = DaySummaryFormatter.markdown(report: summaryReport(), done: [], open: [], tomorrow: nil, day: day, calendar: calendar)
        #expect(nilTomorrow == text)
    }

    @Test
    func daySummaryMarkdownOmitsDistractionDetailWhenNone() {
        let calendar = daySummaryCalendar()
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 12))!
        let quiet = DayReport(youSeconds: 60, claudeSeconds: 0, waitingSeconds: 0, distractionSeconds: 0, distractionCount: 0, returnedCount: 0, maxParallel: 0, firstAt: nil, lastAt: nil, lanes: [], distractionLane: [])
        let text = DaySummaryFormatter.markdown(report: quiet, done: [], open: [], tomorrow: nil, day: day, calendar: calendar)
        #expect(text.contains("- Отвлечения: 0 м\n"))
    }

    @Test
    func timelineAxisSpansWholeHours() throws {
        let calendar = daySummaryCalendar()
        let first = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 9, minute: 14))!
        let last = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 18, minute: 40))!
        let axis = try #require(DayTimelineView.axis(first: first, last: last, calendar: calendar))
        #expect(axis.hours.count == 11)
        #expect(calendar.component(.hour, from: axis.start) == 9)
        #expect(calendar.component(.hour, from: axis.end) == 19)
        #expect(axis.fraction(axis.start) == 0)
        #expect(axis.fraction(axis.end) == 1)
        #expect(axis.fraction(axis.start.addingTimeInterval(-100)) == 0)
        #expect(axis.fraction(axis.end.addingTimeInterval(100)) == 1)
        #expect(abs(axis.fraction(axis.start.addingTimeInterval(5 * 3_600)) - 0.5) < 0.0001)
    }

    @Test
    func timelineAxisHasMinimumOneHourAndNilWithoutData() {
        let calendar = daySummaryCalendar()
        let exact = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 9))!
        let axis = DayTimelineView.axis(first: exact, last: exact, calendar: calendar)
        #expect(axis?.hours.count == 2)
        #expect(DayTimelineView.axis(first: nil, last: nil, calendar: calendar) == nil)
    }

    @Test
    func timelineAccessibilitySummaryListsLanes() {
        let start = Date(timeIntervalSince1970: 0)
        let lane = TaskLane(id: "a", taskID: "a", title: "Рефакторинг auth", segments: [
            LaneSegment(kind: .claude, start: start, end: start.addingTimeInterval(3_600)),
            LaneSegment(kind: .you, start: start.addingTimeInterval(3_600), end: start.addingTimeInterval(5_400)),
            LaneSegment(kind: .waiting, start: start.addingTimeInterval(5_400), end: start.addingTimeInterval(6_000))
        ])
        let report = DayReport(youSeconds: 1_800, claudeSeconds: 3_600, waitingSeconds: 600, distractionSeconds: 300, distractionCount: 1, returnedCount: 1, maxParallel: 1, firstAt: start, lastAt: start, lanes: [lane], distractionLane: [])
        let text = DayTimelineView.accessibilitySummary(report)
        #expect(text.contains("Рефакторинг auth: Claude 1 ч, ты 30 м, ждал 10 м"))
        #expect(text.contains("Отвлечения: 5 м"))
        #expect(DayTimelineView.accessibilitySummary(summaryReport()) == "Нет данных за день")
    }

    @Test
    func daySummaryOpenIncludesTasksFoldedIntoOtherLane() {
        let calendar = daySummaryCalendar()
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9))!
        let end = start.addingTimeInterval(86_400)
        let old = start.addingTimeInterval(-86_400)
        let spans = (1...7).map { index in
            ActivitySpan(kind: .claude, sessionId: "s\(index)", taskId: "t\(index)", startedAt: start.addingTimeInterval(Double(index) * 100), endedAt: start.addingTimeInterval(Double(index) * 100 + Double(100 - index)))
        }
        let tasks = (1...7).map { summaryTask("t\($0)", "Задача \($0)", column: .inProgress, updatedAt: old) }
        let report = ReportBuilder.day(spans: spans, episodes: [], tasks: tasks, dayStart: start, dayEnd: end)
        #expect(report.lanes.last?.id == "other")
        #expect(DaySummaryFormatter.open(tasks: tasks, report: report, dayStart: start, dayEnd: end).count == 7)
    }

    @Test
    func daySummaryRolloverDetectsNewCalendarDay() {
        let calendar = daySummaryCalendar()
        let evening = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 23, minute: 59))!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 0, minute: 1))!
        let earlier = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 1))!
        #expect(DaySummaryFormatter.rolledOver(from: evening, to: morning, calendar: calendar))
        #expect(!DaySummaryFormatter.rolledOver(from: earlier, to: evening, calendar: calendar))
    }

    @Test
    func daySummaryListItemFlattensNewlinesAndEscapesHash() {
        #expect(DaySummaryFormatter.listItem("Первая\nвторая\r\n  третья") == "- Первая вторая третья")
        #expect(DaySummaryFormatter.listItem("# Заголовок") == "- \\# Заголовок")
        #expect(DaySummaryFormatter.listItem("Тег #1") == "- Тег #1")
    }

    @Test
    func timelineAccessibilitySkipsLanesWithoutDescribableSegments() {
        let start = Date(timeIntervalSince1970: 0)
        let empty = TaskLane(id: "e", taskID: "e", title: "Пустая", segments: [])
        let full = TaskLane(id: "f", taskID: "f", title: "Полная", segments: [LaneSegment(kind: .claude, start: start, end: start.addingTimeInterval(600))])
        let report = DayReport(youSeconds: 0, claudeSeconds: 600, waitingSeconds: 0, distractionSeconds: 0, distractionCount: 0, returnedCount: 0, maxParallel: 1, firstAt: start, lastAt: start, lanes: [empty, full], distractionLane: [])
        #expect(DayTimelineView.accessibilitySummary(report) == "Полная: Claude 10 м")
        let onlyEmpty = DayReport(youSeconds: 0, claudeSeconds: 0, waitingSeconds: 0, distractionSeconds: 0, distractionCount: 0, returnedCount: 0, maxParallel: 0, firstAt: start, lastAt: start, lanes: [empty], distractionLane: [])
        #expect(DayTimelineView.accessibilitySummary(onlyEmpty) == "Нет данных за день")
    }

    @Test
    func barHeightsScaleToTallestDay() {
        let day = Date(timeIntervalSince1970: 0)
        let days = [
            DayBar(day: day, youSeconds: 3600, waitingSeconds: 1800, distractionSeconds: 600),
            DayBar(day: day, youSeconds: 1800, waitingSeconds: 0, distractionSeconds: 0),
            DayBar(day: day, youSeconds: 0, waitingSeconds: 0, distractionSeconds: 0)
        ]
        let heights = WeekSummaryView.barHeights(days: days, maxHeight: 200)
        #expect(heights.count == 3)
        #expect(heights[0] == 200)
        #expect(abs(heights[1] - 200 * 1800 / 6000) < 0.001)
        #expect(heights[2] == 0)
    }

    @Test
    func barHeightsAreZeroWithoutData() {
        let day = Date(timeIntervalSince1970: 0)
        let days = [DayBar(day: day, youSeconds: 0, waitingSeconds: 0, distractionSeconds: 0)]
        #expect(WeekSummaryView.barHeights(days: days, maxHeight: 100) == [0])
        #expect(WeekSummaryView.barHeights(days: [], maxHeight: 100).isEmpty)
    }

    @Test
    func segmentHeightsSplitBarProportionally() {
        let day = Date(timeIntervalSince1970: 0)
        let bar = DayBar(day: day, youSeconds: 600, waitingSeconds: 300, distractionSeconds: 100)
        let parts = WeekSummaryView.segmentHeights(day: bar, barHeight: 100)
        #expect(abs(parts.you - 60) < 0.001)
        #expect(abs(parts.waiting - 30) < 0.001)
        #expect(abs(parts.distraction - 10) < 0.001)
        let empty = WeekSummaryView.segmentHeights(day: DayBar(day: day, youSeconds: 0, waitingSeconds: 0, distractionSeconds: 0), barHeight: 0)
        #expect(empty.you == 0 && empty.waiting == 0 && empty.distraction == 0)
    }

    @Test
    func previousWeekDetailsFormatDeltas() {
        #expect(WeekSummaryView.previousCount(6) == "прошлая неделя 6")
        #expect(WeekSummaryView.previousCount(nil) == "прошлая неделя —")
        #expect(WeekSummaryView.previousDuration(11_100) == "прошлая неделя 3 ч 5 м")
        #expect(WeekSummaryView.previousDuration(nil) == "прошлая неделя —")
    }

    @Test
    func kpiDetailsHandleMissingData() {
        #expect(WeekSummaryView.boundShareDetail(0.87) == "с задачей 87%")
        #expect(WeekSummaryView.boundShareDetail(nil) == "с задачей —")
        #expect(WeekSummaryView.averageWaitDetail(360) == "в среднем 6 мин на ответ")
        #expect(WeekSummaryView.averageWaitDetail(10) == "в среднем 1 мин на ответ")
        #expect(WeekSummaryView.averageWaitDetail(nil) == "нет данных")
        #expect(WeekSummaryView.reactionValue(12.4) == "12 с")
        #expect(WeekSummaryView.reactionValue(nil) == "—")
    }

    @Test
    func hoursLabelUsesOneDecimal() {
        #expect(WeekSummaryView.hoursLabel(14_760) == "4.1")
        #expect(WeekSummaryView.hoursLabel(0) == "0")
    }

    @Test
    func tableRowsScaleSharesAndStatuses() {
        let rows = [
            TaskTimeRow(id: "a", taskID: "a", title: "A", projectName: "p", seconds: 4000, sessions: 3, isDone: false),
            TaskTimeRow(id: "b", taskID: "b", title: "B", projectName: nil, seconds: 1000, sessions: 1, isDone: true),
            TaskTimeRow(id: "none", taskID: nil, title: "Без задачи", projectName: nil, seconds: 0, sessions: 2, isDone: false)
        ]
        let shares = WeekSummaryView.shareWidths(rows: rows, maxWidth: 90)
        #expect(shares == [90, 22.5, 0])
        #expect(WeekSummaryView.shareWidths(rows: [], maxWidth: 90).isEmpty)
        #expect(WeekSummaryView.status(rows[0]) == "в работе")
        #expect(WeekSummaryView.status(rows[1]) == "сделано")
        #expect(WeekSummaryView.status(rows[2]) == "—")
    }

    @Test
    func weekRangeTitleHandlesMonthBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let same = calendar.date(from: DateComponents(year: 2026, month: 10, day: 3)) ?? .now
        #expect(WeekSummaryView.rangeTitle(start: same, calendar: calendar) == "3 – 9 октября")
        let cross = calendar.date(from: DateComponents(year: 2026, month: 9, day: 28)) ?? .now
        #expect(WeekSummaryView.rangeTitle(start: cross, calendar: calendar) == "28 сентября – 4 октября")
    }

    @Test
    func dayLabelIsShortRussianWeekday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let friday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9)) ?? .now
        #expect(WeekSummaryView.dayLabel(friday, calendar: calendar) == "пт")
    }

    @Test
    func historyActionTitleDependsOnLiveness() {
        #expect(HistoryRow.actionTitle(isLive: true) == "Перейти")
        #expect(HistoryRow.actionTitle(isLive: false) == "Продолжить")
    }

    @Test
    func historyDayTitleMarksTodayAndYesterday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 12)) ?? .now
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let older = calendar.date(byAdding: .day, value: -3, to: today) ?? today
        #expect(HistoryView.dayTitle(today, now: now, calendar: calendar) == "Сегодня · пятница, 9 октября")
        #expect(HistoryView.dayTitle(yesterday, now: now, calendar: calendar) == "Вчера · четверг, 8 октября")
        #expect(HistoryView.dayTitle(older, now: now, calendar: calendar) == "Вторник, 6 октября")
    }

    @Test
    func settingsStepperBoundsAreClamped() {
        #expect(FocusSettingsPane.maxParallelRange == 1...6)
        #expect(FocusSettingsPane.stalledReminderRange == 5...60)
        #expect(FocusSettingsPane.hooksTitle(installed: true) == "Хуки Claude Code установлены")
        #expect(FocusSettingsPane.hooksTitle(installed: false) == "Хуки Claude Code не установлены")
        #expect(FocusSettingsPane.hooksPathText(path: "/Users/me/.claude/settings.json", home: "/Users/me") == "~/.claude/settings.json")
        #expect(FocusSettingsPane.hooksPathText(path: "/etc/x.json", home: "/Users/me") == "/etc/x.json")
        #expect(FocusSettingsPane.hooksPathText(path: "/Users/meow/x.json", home: "/Users/me") == "/Users/meow/x.json")
        #expect(FocusSettingsPane.hooksActionTitle(installed: true) == "Удалить хуки")
        #expect(FocusSettingsPane.hooksActionTitle(installed: false) == "Установить хуки")
    }

    @Test
    func pomodoroTimerTextIsZeroPaddedMinutesAndSeconds() {
        #expect(PomodoroFormat.timerText(remainingSeconds: 1445) == "24:05")
        #expect(PomodoroFormat.timerText(remainingSeconds: 59) == "00:59")
        #expect(PomodoroFormat.timerText(remainingSeconds: -3) == "00:00")
        #expect(PomodoroFormat.timerText(remainingSeconds: 6000) == "100:00")
    }

    @Test
    func pomodoroCaptions() {
        #expect(PomodoroFormat.remainingCaption(plannedSeconds: 1500) == "осталось из 25 мин")
        #expect(PomodoroFormat.cycleCaption(index: 2, cycle: 4) == "Помодоро 2 из 4")
        #expect(PomodoroFormat.todayCaption(seconds: 12 * 60) == "сегодня по задаче 12 мин")
        #expect(PomodoroFormat.todayCaption(seconds: 0) == nil)
        #expect(PomodoroFormat.breakCaption(minutes: 5) == "потом перерыв 5 мин")
        #expect(PomodoroFormat.startButtonTitle(minutes: 25) == "Начать · 25 мин")
        #expect(PomodoroFormat.startButtonTitle(minutes: nil) == "Начать")
        #expect(PomodoroFormat.quickStartTitle(minutes: 50) == "Начать 50 мин")
        #expect(PomodoroFormat.pauseTitle(isPaused: false) == "Пауза")
        #expect(PomodoroFormat.pauseTitle(isPaused: true) == "Продолжить")
    }

    @Test
    func sessionSubtitleNamesBoundTask() {
        let bound = BindableSession(id: "a", title: "t", detail: "d", projectName: nil, boundTaskTitle: "Фикс", isSameProject: true, defaultSelected: false)
        let free = BindableSession(id: "b", title: "t", detail: "d", projectName: nil, boundTaskTitle: nil, isSameProject: true, defaultSelected: true)
        #expect(PomodoroFormat.sessionTag(bound) == "у задачи «Фикс»")
        #expect(PomodoroFormat.sessionTag(free) == nil)
        #expect(StartTaskSheet.initialSelection([bound, free]) == ["b"])
    }

    @Test
    func timerChoiceMapsToMinutes() {
        #expect(StartTimerChoice.initial(defaultMinutes: 25) == .m25)
        #expect(StartTimerChoice.initial(defaultMinutes: 50) == .m50)
        #expect(StartTimerChoice.initial(defaultMinutes: 40) == .custom)
        #expect(StartTimerChoice.none.minutes(custom: 40) == nil)
        #expect(StartTimerChoice.m25.minutes(custom: 40) == 25)
        #expect(StartTimerChoice.m50.minutes(custom: 40) == 50)
        #expect(StartTimerChoice.custom.minutes(custom: 40) == 40)
        #expect(StartTimerChoice.custom.minutes(custom: 2) == 5)
        #expect(StartTimerChoice.custom.minutes(custom: 500) == 120)
        #expect(StartTimerChoice.custom.title == "Своё…")
        #expect(StartTimerChoice.allCases.map(\.title) == ["Без таймера", "25 мин", "50 мин", "90 мин", "Своё…"])
    }

    @Test
    func movingIntoInProgressRequestsStartOnlyFromOtherColumns() {
        #expect(PomodoroFormat.shouldRequestStart(from: .todo, to: .inProgress))
        #expect(PomodoroFormat.shouldRequestStart(from: .backlog, to: .inProgress))
        #expect(PomodoroFormat.shouldRequestStart(from: .done, to: .inProgress))
        #expect(!PomodoroFormat.shouldRequestStart(from: .inProgress, to: .inProgress))
        #expect(!PomodoroFormat.shouldRequestStart(from: .inProgress, to: .done))
        #expect(!PomodoroFormat.shouldRequestStart(from: nil, to: .inProgress))
    }

    @Test
    func todaySecondsClipsSpansToStartOfDay() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let start = calendar.startOfDay(for: now)
        let spans = [
            ActivitySpan(kind: .you, sessionId: nil, taskId: "t", startedAt: start.addingTimeInterval(-600), endedAt: start.addingTimeInterval(300)),
            ActivitySpan(kind: .claude, sessionId: nil, taskId: "t", startedAt: start.addingTimeInterval(200), endedAt: start.addingTimeInterval(500)),
            ActivitySpan(kind: .you, sessionId: nil, taskId: "t", startedAt: start.addingTimeInterval(-900), endedAt: start.addingTimeInterval(-700))
        ]
        #expect(TaskDetailView.todaySeconds(spans: spans, now: now, calendar: calendar) == 500)
    }

    @Test
    func quickStartOnlyForInProgressTasks() {
        #expect(TaskPomodoroSection.showsQuickStart(column: .inProgress))
        #expect(!TaskPomodoroSection.showsQuickStart(column: .todo))
        #expect(!TaskPomodoroSection.showsQuickStart(column: .done))
        #expect(!TaskPomodoroSection.showsQuickStart(column: nil))
    }

    @Test
    func resumableIDsKeepLiveAndExistingPaths() {
        let records = [
            SessionRecord(id: "live", cwd: nil, projectName: nil, title: "live", firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, startedAt: .distantPast, lastActivityAt: .distantPast, endedAt: nil, status: .ended, taskId: nil, transcriptPath: nil),
            SessionRecord(id: "gone", cwd: "/definitely/missing/path", projectName: nil, title: "gone", firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, startedAt: .distantPast, lastActivityAt: .distantPast, endedAt: nil, status: .ended, taskId: nil, transcriptPath: nil),
            SessionRecord(id: "here", cwd: NSTemporaryDirectory(), projectName: nil, title: "here", firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, startedAt: .distantPast, lastActivityAt: .distantPast, endedAt: nil, status: .ended, taskId: nil, transcriptPath: nil),
            SessionRecord(id: "none", cwd: nil, projectName: nil, title: "none", firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, startedAt: .distantPast, lastActivityAt: .distantPast, endedAt: nil, status: .ended, taskId: nil, transcriptPath: nil)
        ]
        #expect(TaskDetailView.resumableIDs(records: records, live: ["live"]) == ["live", "here"])
    }

    @Test
    func replaceCaptionOnlyForOtherTasksPomodoro() {
        let running = PomodoroSnapshot(id: "p", taskID: "a", taskTitle: "A", phase: .focus, plannedSeconds: 1500, remainingSeconds: 900, progress: 0.4, isPaused: false, cycleIndex: 1, cycle: 4)
        let loose = PomodoroSnapshot(id: "q", taskID: nil, taskTitle: nil, phase: .break, plannedSeconds: 300, remainingSeconds: 100, progress: 0.6, isPaused: false, cycleIndex: 1, cycle: 4)
        #expect(PomodoroFormat.replaceCaption(pomodoro: running, startingTaskID: "b") == "Сейчас идёт помодоро «A»")
        #expect(PomodoroFormat.replaceCaption(pomodoro: running, startingTaskID: "a") == nil)
        #expect(PomodoroFormat.replaceCaption(pomodoro: nil, startingTaskID: "b") == nil)
        #expect(PomodoroFormat.replaceCaption(pomodoro: loose, startingTaskID: "b") == "Сейчас идёт помодоро")
        #expect(PomodoroFormat.replaceButtonTitle == "Заменить")
    }

    @Test
    func activeElsewhereCaptionNamesTask() {
        #expect(PomodoroFormat.activeElsewhereCaption(taskTitle: "Фикс") == "Сейчас идёт помодоро «Фикс»")
        #expect(PomodoroFormat.activeElsewhereCaption(taskTitle: nil) == "Сейчас идёт помодоро")
    }
    @Test
    func pickTaskTodoCaption() {
        #expect(PickTaskCard.todoCaption(3) == "Todo · 3")
    }

    @Test
    func pickTaskPrimaryIsFirstWithSessions() {
        let options = [
            PickTaskOption(taskID: "a", title: "A", projectName: "p", liveSessionCount: 1, sessionStateText: ""),
            PickTaskOption(taskID: "b", title: "B", projectName: nil, liveSessionCount: 0, sessionStateText: "")
        ]
        #expect(PickTaskCard.primaryOptionID(options) == "a")
        #expect(PickTaskCard.primaryOptionID(Array(options.dropFirst())) == nil)
        #expect(PickTaskCard.primaryOptionID([]) == nil)
    }

    @Test
    func pomodoroEndHeadlineAndTitle() {
        #expect(PomodoroEndCard.headline(cycleIndex: 1, cycle: 4) == "Фокус 1 из 4 готов")
        #expect(PomodoroEndCard.title(minutes: 25, taskTitle: "Чат-бот") == "25 минут в «Чат-бот»")
        #expect(PomodoroEndCard.title(minutes: 21, taskTitle: "X") == "21 минута в «X»")
        #expect(PomodoroEndCard.title(minutes: 22, taskTitle: "X") == "22 минуты в «X»")
        #expect(PomodoroEndCard.title(minutes: 25, taskTitle: "") == "25 минут фокуса")
    }

    @Test
    func pomodoroEndKpiValuesAndDistractionDetail() {
        #expect(PomodoroEndCard.minutesValue(1260) == "21 мин")
        #expect(PomodoroEndCard.minutesValue(0) == "0 мин")
        #expect(PomodoroEndCard.distractionDetail(count: 1, returned: 1) == "1 раз, вернулся")
        #expect(PomodoroEndCard.distractionDetail(count: 2, returned: 0) == "2 раза")
        #expect(PomodoroEndCard.distractionDetail(count: 3, returned: 1) == "3 раза, вернулся 1")
        #expect(PomodoroEndCard.distractionDetail(count: 0, returned: 0) == nil)
    }

    @Test
    func pomodoroEndWhileRunningItems() {
        let items = PomodoroEndCard.whileRunningItems(finishedSessionTitles: ["добавь проверку"], checkedCriteria: ["Бот отвечает"])
        #expect(items == [
            PomodoroEndCard.Item(text: "«добавь проверку» — Claude закончил", isCriterion: false),
            PomodoroEndCard.Item(text: "Критерий «Бот отвечает» отмечен", isCriterion: true)
        ])
        #expect(PomodoroEndCard.whileRunningItems(finishedSessionTitles: [], checkedCriteria: []).isEmpty)
    }

    @Test
    func pomodoroEndButtonTitles() {
        #expect(PomodoroEndCard.continueTitle(minutes: 50) == "Без перерыва — ещё 50 мин")
        #expect(PomodoroEndCard.breakTitle(minutes: 10) == "☕ Начать перерыв · 10 мин")
        #expect(PomodoroEndCard.breakHeadline(minutes: 10, secondsLeft: 4) == "Перерыв 10 мин начнётся через 4 с")
        #expect(PomodoroEndCard.breakHeadline(minutes: 10, secondsLeft: nil) == "Перерыв 10 мин")
        #expect(PomodoroEndCard.afterBreakCaption(focusMinutes: 50) == "потом фокус 50 мин")
        #expect(PomodoroEndCard.countdownProgress(secondsLeft: 5) == 1)
        #expect(PomodoroEndCard.countdownProgress(secondsLeft: 0) == 0)
        #expect(PomodoroEndCard.prefill(note: "  Шаг  ") == "Шаг")
        #expect(PomodoroEndCard.prefill(note: nil) == "")
    }

    @Test
    func breakEndTexts() {
        #expect(BreakEndCard.title(taskTitle: "Чат-бот") == "Вернуться к «Чат-бот»")
        #expect(BreakEndCard.title(taskTitle: "") == "Вернуться к задаче")
        #expect(BreakEndCard.restedLine(finishedSessionTitles: []) == nil)
        #expect(BreakEndCard.restedLine(finishedSessionTitles: ["a", "b"]) == "Пока отдыхал: Claude закончил «a», «b»")
        #expect(BreakEndCard.extendTitle(minutes: 5) == "Ещё 5 мин отдыха")
        #expect(BreakEndCard.noteText(" ") == nil)
        #expect(BreakEndCard.noteText(" Шаг ") == "Шаг")
    }

    @Test
    func hubTimerCaptionAndFooterWithPomodoros() {
        let focusSnap = PomodoroSnapshot(id: "p", taskID: "t", taskTitle: "T", phase: .focus, plannedSeconds: 1500, remainingSeconds: 1122, progress: 0.25, isPaused: false, cycleIndex: 1, cycle: 4)
        let breakSnap = PomodoroSnapshot(id: "b", taskID: "t", taskTitle: "T", phase: .break, plannedSeconds: 300, remainingSeconds: 192, progress: 0.36, isPaused: false, cycleIndex: 1, cycle: 4)
        #expect(SessionHubView.timerCaption(focusSnap, breakMinutes: 10, focusMinutes: 50) == "Фокус 1 из 4 · из 25 мин · потом перерыв 10 мин")
        #expect(SessionHubView.timerCaption(breakSnap, breakMinutes: 10, focusMinutes: 50) == "Перерыв · из 5 мин · потом фокус 50 мин")
    }

    @Test
    func newSessionHintDetailShowsProjectAndFirstPromptLine() {
        #expect(SessionHubView.newSessionDetail(cwd: "/Users/me/focus", prompt: "хочу приложение\nи ещё") == "· focus · «хочу приложение»")
        #expect(SessionHubView.newSessionDetail(cwd: nil, prompt: "  ") == "")
        #expect(SessionHubView.newSessionDetail(cwd: "/tmp/p", prompt: String(repeating: "а", count: 70)) == "· p · «" + String(repeating: "а", count: 60) + "…»")
        #expect(SessionHubView.footerText(focusSeconds: 1860, distractionSeconds: 0, pomodoroCount: 1) == "Сегодня: фокус 31 мин · помодоро 1 · отвлечения 0 мин")
        #expect(SessionHubView.footerText(focusSeconds: 1860, distractionSeconds: 0, pomodoroCount: 0) == "Сегодня: фокус 31 мин · отвлечения 0 мин")
    }

    @Test
    func daySummaryMarkdownListsPomodorosWhenAny() {
        let calendar = daySummaryCalendar()
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 12))!
        let with = DaySummaryFormatter.markdown(report: summaryReport(), done: [], open: [], tomorrow: nil, day: day, pomodoroCount: 3, calendar: calendar)
        #expect(with.contains("- Отвлечения: 11 м (4 раза, вернулся 3)\n- Помодоро: 3\n- Макс. параллельно: 4"))
        let without = DaySummaryFormatter.markdown(report: summaryReport(), done: [], open: [], tomorrow: nil, day: day, pomodoroCount: 0, calendar: calendar)
        #expect(!without.contains("Помодоро"))
    }

    @Test
    func pomodoroEndDraftSavedOnlyWhenChanged() {
        #expect(PomodoroEndCard.draftToSave(text: "  новый шаг ", saved: "старый") == "новый шаг")
        #expect(PomodoroEndCard.draftToSave(text: "старый ", saved: "старый") == nil)
        #expect(PomodoroEndCard.draftToSave(text: "   ", saved: "старый") == nil)
        #expect(PomodoroEndCard.draftToSave(text: "шаг", saved: "") == "шаг")
    }

    @Test
    func pickTaskTodoSummaryCollapsesTail() {
        #expect(PickTaskCard.todoSummary(titles: []) == "")
        #expect(PickTaskCard.todoSummary(titles: ["A"]) == "A")
        #expect(PickTaskCard.todoSummary(titles: ["A", "B"]) == "A · B")
        #expect(PickTaskCard.todoSummary(titles: ["A", "B", "C"]) == "A · B · ещё 1")
        #expect(PickTaskCard.todoSummary(titles: ["A", "B", "C", "D", "E"]) == "A · B · ещё 3")
    }

    @Test
    func pickTaskCaptionsAndExpansion() {
        #expect(PickTaskCard.inProgressCaption(2) == "В работе · 2")
        #expect(PickTaskCard.showsTodoList(inProgressIsEmpty: true, userExpanded: false))
        #expect(!PickTaskCard.showsTodoList(inProgressIsEmpty: false, userExpanded: false))
        #expect(PickTaskCard.showsTodoList(inProgressIsEmpty: false, userExpanded: true))
        #expect(PickTaskCard.showsEmptyCaption(inProgressIsEmpty: true, todoIsEmpty: false))
        #expect(!PickTaskCard.showsEmptyCaption(inProgressIsEmpty: true, todoIsEmpty: true))
        #expect(!PickTaskCard.showsEmptyCaption(inProgressIsEmpty: false, todoIsEmpty: false))
    }

    @Test
    func pickTaskStateColorWarnsOnlyWithoutSessions() {
        let none = PickTaskOption(taskID: "a", title: "A", projectName: nil, liveSessionCount: 0, sessionStateText: "нет сессий — добавишь следующим шагом")
        let some = PickTaskOption(taskID: "b", title: "B", projectName: nil, liveSessionCount: 2, sessionStateText: "2 сессии · ждёт 3 мин")
        #expect(PickTaskCard.stateIsWarning(none))
        #expect(!PickTaskCard.stateIsWarning(some))
    }

    @Test
    func taskSessionsPickerSectionsAndTitles() {
        func choice(_ id: String, bound: Bool = false, same: Bool = true, other: String? = nil) -> BindableSession {
            BindableSession(id: id, title: id, detail: "", projectName: nil, boundTaskTitle: other, isSameProject: same, defaultSelected: bound || (same && other == nil), isBound: bound)
        }
        let choices = [choice("b", bound: true), choice("s"), choice("t", other: "Фикс"), choice("o", same: false)]
        let sections = TaskSessionsPicker.sections(choices, projectName: "wb")
        #expect(sections.map(\.title) == ["Привязаны · 1", "Открытые · проект wb", "Открытые · другие проекты"])
        #expect(sections.map { $0.rows.map(\.id) } == [["b"], ["s", "t"], ["o"]])
        #expect(TaskSessionsPicker.sections([choice("o", same: false)], projectName: nil).map(\.title) == ["Открытые"])
        #expect(TaskSessionsPicker.applyTitle((add: ["s"], remove: [])) == "Добавить 1")
        #expect(TaskSessionsPicker.applyTitle((add: [], remove: [])) == "Добавить 0")
        #expect(TaskSessionsPicker.applyTitle((add: ["s"], remove: ["b"])) == "Сохранить")
        #expect(TaskSessionsPicker.cancelTitle(hasBound: false) == "Позже")
        #expect(TaskSessionsPicker.cancelTitle(hasBound: true) == "Отмена")
        #expect(TaskSessionsPicker.trailingLabel(choices[0]) == nil)
        #expect(TaskSessionsPicker.trailingLabel(choices[1]) == "без задачи")
        #expect(TaskSessionsPicker.trailingLabel(choices[2]) == "у задачи «Фикс»")
        #expect(TaskSessionsPicker.footerHint((add: ["t"], remove: []), choices: choices) == "Сессия переедет из «Фикс» в эту задачу")
        #expect(TaskSessionsPicker.footerHint((add: [], remove: ["b"]), choices: choices) == "Снятые сессии отвяжутся от задачи")
        #expect(TaskSessionsPicker.footerHint((add: ["s"], remove: []), choices: choices) == "Сессию чужой задачи не трогаем, пока сам не отметишь")
    }

    @Test
    func closeTaskTexts() {
        #expect(ClosedTaskBanner.text("A") == "«A» закрыта · перенесена в Done")
        #expect(TaskDetailView.showsCloseTask(column: .inProgress))
        #expect(TaskDetailView.showsCloseTask(column: .todo))
        #expect(!TaskDetailView.showsCloseTask(column: .done))
        #expect(!TaskDetailView.showsCloseTask(column: nil))
    }

    @Test
    func hubFocusBlockTexts() {
        #expect(SessionHubView.focusBlockCaption(3) == "Сессии задачи · 3")
        #expect(PomodoroFormat.startFocusTitle(minutes: 50) == "▶ Начать фокус · 50 мин")
        #expect(SessionHubView.hereDetail("ждёт ответа", isHere: true) == "ты здесь · ждёт ответа")
        #expect(SessionHubView.hereDetail("ждёт ответа", isHere: false) == "ждёт ответа")
        #expect(SessionHubView.hereDetail("", isHere: true) == "ты здесь")
    }

    @Test
    func timerLengthChoices() {
        #expect(PomodoroFormat.focusChoices == [25, 50, 90])
        #expect(PomodoroFormat.breakChoices == [5, 10, 15, 20])
        #expect(PomodoroFormat.choiceTitle(50, defaultMinutes: 50) == "50 мин · по умолчанию")
        #expect(PomodoroFormat.choiceTitle(25, defaultMinutes: 50) == "25 мин")
        #expect(PomodoroFormat.breakButtonTitle(minutes: 10) == "Перерыв 10 мин")
        #expect(PomodoroFormat.clampFocus(500) == 120)
        #expect(PomodoroFormat.clampFocus(2) == 5)
        #expect(StartTimerChoice.allCases.map(\.title) == ["Без таймера", "25 мин", "50 мин", "90 мин", "Своё…"])
        #expect(StartTimerChoice.initial(defaultMinutes: 50) == .m50)
        #expect(StartTimerChoice.initial(defaultMinutes: 90) == .m90)
        #expect(StartTimerChoice.m90.minutes(custom: 0) == 90)
    }

    @Test
    func waitingOutsideTexts() {
        #expect(WaitingOutsideSection.caption(2) == "Ждут вне задачи · 2")
        #expect(WaitingOutsideSection.buttonTitle(2, expanded: false) == "Ждут вне задачи · 2 ▸")
        #expect(WaitingOutsideSection.buttonTitle(2, expanded: true) == "Ждут вне задачи · 2 ▾")
        #expect(WaitingOutsideSection.explainer(taskTitle: "Воронка") == "Claude в этих сессиях закончил и ждёт тебя. Они не относятся к «Воронка».")
        #expect(WaitingOutsideSection.ownerText(taskTitle: nil) == "без задачи")
        #expect(WaitingOutsideSection.ownerText(taskTitle: "Онбординг") == "у задачи «Онбординг»")
        #expect(WaitingOutsideSection.addTitle(taskTitle: "Воронка") == "Добавить в «Воронка»")
    }

    @Test
    func withoutTaskHubShowsOnlyTaskChoice() {
        #expect(SessionHubView.showsOnlyTaskChoice(hasTask: false, pomodoroActive: false))
        #expect(!SessionHubView.showsOnlyTaskChoice(hasTask: true, pomodoroActive: false))
        #expect(!SessionHubView.showsOnlyTaskChoice(hasTask: false, pomodoroActive: true))
    }

    @Test
    func returnedCardIsLeftToTheCompletionCard() {
        #expect(!FocusIslandSection.showsCardView(nil))
        #expect(!FocusIslandSection.showsCardView(.returned(sessionID: "s")))
        #expect(FocusIslandSection.showsCardView(.pomodoroEnd(pomodoroID: "p")))
        #expect(FocusIslandSection.showsCardView(.dayStart))
    }
}
