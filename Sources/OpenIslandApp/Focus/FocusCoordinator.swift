import AppKit
import FocusCore
import Foundation
import Observation
import OpenIslandCore
import os

enum FocusCard: Equatable {
    case onboarding
    case nudge
    case returned(sessionID: String)
    case reEntry(sessionID: String)
    case overload(newSessionID: String)
    case nextAction(triggeringSessionID: String, eventID: Int64?)
    case dayStart
    case pickTask
    case bindToTask(taskID: String)
    case pomodoroEnd(pomodoroID: String)
    case breakEnd(pomodoroID: String)

    var priority: Int {
        switch self {
        case .onboarding: 10
        case .nudge: 9
        case .pomodoroEnd, .breakEnd: 8
        case .returned: 7
        case .reEntry: 6
        case .overload: 5
        case .nextAction: 4
        case .dayStart, .pickTask, .bindToTask: 2
        }
    }

    var bindTaskID: String? {
        if case let .bindToTask(taskID) = self { return taskID }
        return nil
    }

    var pomodoroID: String? {
        switch self {
        case let .pomodoroEnd(id), let .breakEnd(id): id
        default: nil
        }
    }

    static func canReplace(_ current: FocusCard?, with new: FocusCard) -> Bool {
        guard let current else { return true }
        return new.priority >= current.priority
    }
}

enum FocusCardAction: Equatable {
    case jump(sessionID: String)
    case confirmJump(sessionID: String)
    case startTask(taskID: String)
    case quickAdd(title: String)
    case bindTriggering(taskID: String)
    case markTaskDone(taskID: String)
    case queuePrompt(sessionID: String, text: String)
    case sendQueuedPrompt(sessionID: String)
    case toggleCriterion(id: String)
    case addCriterion(taskID: String, text: String)
    case deleteCriterion(id: String)
    case park(sessionID: String)
    case unpark(sessionID: String)
    case snoozeDistraction
    case allowDistraction
    case returnToWork
    case startDay(taskIDs: [String])
    case dismiss

    var countsAsReaction: Bool {
        switch self {
        case .dismiss, .startTask: false
        default: true
        }
    }
}

struct TaskAggregate: Equatable {
    var records: [SessionRecord] = []
    var criteria: CriteriaProgress?
    var sessionIDsWithQueuedPrompt: Set<String> = []
}

struct StalledBadge: Equatable {
    let title: String
    let minutes: Int
}

@MainActor
@Observable
final class FocusCoordinator {
    static let bindingPromptWindow: TimeInterval = 60
    static let snoozeDistractionDuration: TimeInterval = 300
    static let allowDistractionDuration: TimeInterval = 600
    static let nextActionCardLifetime: TimeInterval = 600
    static let reEntryThreshold: TimeInterval = 600
    static let changedFilesCacheLifetime: TimeInterval = 10
    static let toastLifetime: TimeInterval = 4
    static let closedTaskLifetime: TimeInterval = 8
    nonisolated static let breakCountdownSeconds: TimeInterval = 5
    static let breakCountdownFreshness: TimeInterval = 60
    static let breakSoundName = "Glass"
    static let todaySummaryInterval: TimeInterval = 60
    static let clipboardToast = "Промпт в буфере — вставь ⌘V"
    static let stalledBadgeMinutes = 10
    static let onboardingAutomationOpenedKey = "focus.onboarding.automationOpened"
    static let onboardingTaskAddedKey = "focus.onboarding.taskAdded"
    static let onboardingDismissedKey = "focus.onboarding.dismissed"
    static let onboardingPresentedKey = "focus.onboarding.presented"
    static let boundSessionsDoneWindow: TimeInterval = 7 * 86_400
    static let recoveredEndCardWindow: TimeInterval = 2 * 3600

    static func slotToast(projectName: String) -> String {
        "Освободился слот — вернуть \(projectName)?"
    }

    private(set) var board = BoardSnapshot(tasks: [])
    private(set) var liveRecords: [SessionRecord] = []
    private(set) var card: FocusCard?
    private(set) var pendingBindingSessionIDs: [String] = []
    private(set) var hubRows: [HubRow] = []
    private(set) var todaySummary = TodaySummary(focusSeconds: 0, distractionSeconds: 0)
    private(set) var pomodoro: PomodoroSnapshot?
    private(set) var pomodoroCountToday = 0
    private(set) var pendingStartTaskID: String?
    private(set) var focusTaskOverrideID: String?
    private(set) var focusCleared = false
    private(set) var lastJumpedSessionID: String?
    private(set) var todaySummaryRefreshedAt: Date?
    private(set) var alternatives: [NextAlternative] = []
    private(set) var changedFiles: [String: [ChangedFile]] = [:]
    private(set) var toast: String?
    private(set) var closedTask: ClosedTaskNotice?
    private(set) var breakCountdownEndsAt: Date?
    private(set) var breakCountdownLeft: Int?
    nonisolated static let labelRetrySeconds: TimeInterval = 15
    nonisolated static let labelRefreshSeconds: TimeInterval = 300
    private(set) var sessionLabels: [String: String] = [:]
    private(set) var sessionStatuses: [String: String] = [:]
    @ObservationIgnored var lookupSessionLabels: (@Sendable (Set<String>) async -> [String: SessionLabel])?
    @ObservationIgnored private var labelLookupInFlight = false
    @ObservationIgnored private var labelLookedUpAt: [String: Date] = [:]
    private(set) var breakMinutesChoice: Int?
    private(set) var lastJumpProjectName: String?
    private(set) var distractionTarget: String?
    private(set) var nudgeSessionIDState: String?
    private(set) var nudgeSuggestionState: NextAlternative?
    private(set) var distractionStartedAt: Date?
    private(set) var stalledBadge: StalledBadge?
    private(set) var waitingOutside: [HubRow] = []
    private(set) var doneSessionNotice: DoneSessionNotice?
    private(set) var allDoneDismissed: [String: Int] = [:]
    @ObservationIgnored private var doneSessionShownAt: Date?
    private(set) var waitingOutsideExpanded = false
    private(set) var focusElapsedMinutes: Int?
    private(set) var hooksInstalled: Bool?
    private(set) var onboardingAutomationOpened: Bool
    private(set) var onboardingTaskAdded: Bool
    private(set) var onboardingDismissed: Bool
    let storeOutcome: FocusStoreOpenOutcome
    var storeRecoveredBackupURL: URL? {
        if case let .recovered(backupURL) = storeOutcome { return backupURL }
        return nil
    }
    var storeIsInMemoryFallback: Bool {
        storeOutcome == .inMemoryFallback
    }
    private(set) var liveSessionIDs: Set<String> = []
    var settings: FocusSettings {
        didSet {
            settings.save(to: defaults)
            turnTracker.delay = settings.nextActionDelay
            distractionTracker.threshold = settings.distractionThreshold
            onSettingsChanged?(settings)
        }
    }

    @ObservationIgnored var presentCard: (() -> Void)?
    @ObservationIgnored var playSound: (String) -> Void = { _ in }
    @ObservationIgnored var onSettingsChanged: ((FocusSettings) -> Void)?
    @ObservationIgnored var jumpToSession: ((String) -> Void)?
    @ObservationIgnored private(set) var changedFilesTask: Task<Void, Never>?
    @ObservationIgnored private(set) var actionTask: Task<Void, Never>?

    @ObservationIgnored private let store: FocusStore
    @ObservationIgnored private let boardService: BoardService
    @ObservationIgnored private let history: SessionHistory
    @ObservationIgnored private let distractionLog: DistractionLog
    @ObservationIgnored private let nextActionLog: NextActionLog
    @ObservationIgnored private let statsService: StatsService
    @ObservationIgnored private let criteriaService: TaskCriteriaService
    @ObservationIgnored private let promptQueue: PromptQueue
    @ObservationIgnored private let dayPlans: DayPlanStore
    @ObservationIgnored private let activityLog: ActivityLog
    @ObservationIgnored private let pomodoroStore: PomodoroStore
    @ObservationIgnored private var activePomodoro: Pomodoro?
    @ObservationIgnored private var activeCycleCompleted = 0
    @ObservationIgnored private var pendingPomodoroCard: FocusCard?
    @ObservationIgnored private var queuedCards: [FocusCard] = []
    @ObservationIgnored private var finishedTurnLog: [(sessionID: String, at: Date)] = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let launcher: TerminalLaunching
    @ObservationIgnored private let promptSender: PromptSending
    @ObservationIgnored private let gitDiff: GitDiffProviding
    @ObservationIgnored private let clipboard: (String) -> Void
    @ObservationIgnored private let runBackfill: Bool
    @ObservationIgnored private var turnTracker: TurnTracker
    @ObservationIgnored private var distractionTracker: DistractionTracker
    @ObservationIgnored private var latestSessions: [AgentSession] = []
    @ObservationIgnored private var lastObservations: [String: SessionObservation] = [:]
    @ObservationIgnored private var previousPhases: [String: SessionPhase] = [:]
    @ObservationIgnored private var unseenCompleted: Set<String> = []
    @ObservationIgnored private var planStartedAt: [String: Date] = [:]
    @ObservationIgnored private var runStartedAt: [String: Date] = [:]
    @ObservationIgnored private var turnPrompts: [String: String] = [:]
    @ObservationIgnored private var lastTurnDurations: [String: TimeInterval] = [:]
    @ObservationIgnored private var changedFilesFetchedAt: [String: Date] = [:]
    @ObservationIgnored private var frontmostBundleID: String?
    @ObservationIgnored private var frontmostSince: Date?
    @ObservationIgnored private var frontmostIsDistracting = false
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var nextActionShownAt: Date?
    @ObservationIgnored private var toastShownAt: Date?
    @ObservationIgnored private var closedTaskShownAt: Date?
    @ObservationIgnored private var pendingReturnedSessionIDs: [String] = []
    @ObservationIgnored private var deferredReturnedSessionIDs: Set<String> = []
    @ObservationIgnored private var presenceTracker = PresenceTracker()
    @ObservationIgnored private var sendingSessionIDs: Set<String> = []
    @ObservationIgnored private var sessionSpans: [String: OpenSpan] = [:]
    @ObservationIgnored private var youSpan: OpenSpan?
    @ObservationIgnored private var knownSessionIDs: Set<String> = []
    @ObservationIgnored private var slotArmed = false
    @ObservationIgnored private var dayStartShownDay: String?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var spansSuspended = false
    @ObservationIgnored private let logger = Logger(subsystem: "dev.zhanabayev.focusisland", category: "focus")
    private(set) var workRevision = 0 {
        didSet { refreshTaskAggregates() }
    }
    private(set) var taskAggregates: [String: TaskAggregate] = [:]

    init(
        store: FocusStore,
        storeOutcome: FocusStoreOpenOutcome = .normal,
        defaults: UserDefaults = .standard,
        launcher: TerminalLaunching,
        promptSender: PromptSending = TerminalPromptSender(),
        gitDiff: GitDiffProviding = GitDiffProvider(),
        clipboard: @escaping (String) -> Void = FocusCoordinator.copyToPasteboard,
        runBackfill: Bool = true
    ) {
        self.store = store
        self.storeOutcome = storeOutcome
        self.boardService = BoardService(store: store)
        self.history = SessionHistory(store: store)
        self.distractionLog = DistractionLog(store: store)
        self.nextActionLog = NextActionLog(store: store)
        self.statsService = StatsService(store: store)
        self.criteriaService = TaskCriteriaService(store: store)
        self.promptQueue = PromptQueue(store: store)
        self.dayPlans = DayPlanStore(store: store)
        self.activityLog = ActivityLog(store: store)
        self.pomodoroStore = PomodoroStore(store: store)
        self.onboardingAutomationOpened = defaults.bool(forKey: Self.onboardingAutomationOpenedKey)
        self.onboardingTaskAdded = defaults.bool(forKey: Self.onboardingTaskAddedKey)
        self.onboardingDismissed = defaults.bool(forKey: Self.onboardingDismissedKey)
        self.defaults = defaults
        self.launcher = launcher
        self.promptSender = promptSender
        self.gitDiff = gitDiff
        self.clipboard = clipboard
        self.runBackfill = runBackfill
        let settings = FocusSettings.load(from: defaults)
        self.settings = settings
        self.turnTracker = TurnTracker(delay: settings.nextActionDelay)
        self.distractionTracker = DistractionTracker(threshold: settings.distractionThreshold)
    }

    nonisolated static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    var hasRunningSession: Bool {
        latestSessions.contains { $0.phase == .running && !$0.isSessionEnded }
    }

    var currentTask: FocusTask? {
        if let task = board.task(id: pomodoro?.taskID), task.boardColumn != .done {
            return task
        }
        if let id = focusTaskOverrideID, let task = board.task(id: id), task.boardColumn == .inProgress {
            return task
        }
        if focusCleared { return nil }
        return board.currentTask(liveSessions: liveRecords)
    }

    var focusTaskSessions: [HubRow] {
        guard let taskID = currentTask?.id else { return [] }
        return hubRows.filter { $0.taskID == taskID && $0.group != .done }
    }

    var focusTaskDoneSessions: [HubRow] {
        guard let taskID = currentTask?.id else { return [] }
        return hubRows.filter { $0.taskID == taskID && $0.group == .done }
    }

    func markSessionDone(sessionID: String, now: Date = .now) {
        attempt { try history.markDone(sessionID: sessionID, at: now) }
        doneSessionNotice = DoneSessionNotice(sessionID: sessionID, title: sessionTitle(sessionID))
        doneSessionShownAt = now
        reload()
        workRevision += 1
        refreshHub(now: now)
    }

    func reopenDoneSession(sessionID: String, now: Date = .now) {
        attempt { try history.unmarkDone(sessionID: sessionID) }
        if doneSessionNotice?.sessionID == sessionID {
            doneSessionNotice = nil
            doneSessionShownAt = nil
        }
        reload()
        workRevision += 1
        refreshHub(now: now)
    }

    func moveTargets(excludingTaskID taskID: String?) -> [FocusTask] {
        (board.tasks(in: .inProgress) + board.tasks(in: .todo)).filter { $0.id != taskID }
    }

    func showsAllDoneSuggestion(taskID: String) -> Bool {
        let rows = hubRows.filter { $0.taskID == taskID }
        let done = rows.filter { $0.group == .done }.count
        return Self.allDone(doneCount: done, activeCount: rows.count - done, dismissedAt: allDoneDismissed[taskID])
    }

    func dismissAllDoneSuggestion(taskID: String) {
        allDoneDismissed[taskID] = hubRows.filter { $0.taskID == taskID && $0.group == .done }.count
    }

    nonisolated static func allDone(doneCount: Int, activeCount: Int, dismissedAt: Int?) -> Bool {
        doneCount > 0 && activeCount == 0 && dismissedAt != doneCount
    }

    var hereSessionID: String? {
        guard let id = lastJumpedSessionID, focusTaskSessions.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    var isOnBreak: Bool {
        pomodoro?.phase == .break
    }

    func start(initialSessions: [AgentSession], now: Date = .now) {
        attempt { try activityLog.closeAllOpenAtStart() }
        sessionSpans = [:]
        youSpan = nil
        spansSuspended = false
        knownSessionIDs.formUnion(initialSessions.map(\.id))
        attempt { try history.markAllLiveEnded(except: Set(initialSessions.filter { !$0.isSessionEnded }.map(\.id)), at: now) }
        for session in initialSessions {
            previousPhases[session.id] = session.phase
            unseenCompleted.remove(session.id)
        }
        reload()
        restorePomodoro(now: now)
        started = true
        sessionsDidChange(initialSessions, now: now)
        refreshTodaySummary(now: now, force: true)
        presentPendingPomodoroCard(now: now)
        if runBackfill {
            let store = store
            Task.detached(priority: .utility) {
                _ = try? TranscriptBackfill(store: store).run()
                await MainActor.run { [weak self] in self?.reload() }
            }
        }
    }

    func startTicking() {
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.tick()
            }
        }
    }

    func stop(now: Date = .now) {
        attempt { try activityLog.closeAllOpen(at: now) }
        sessionSpans = [:]
        youSpan = nil
        spansSuspended = true
    }

    func wake(now: Date = .now) {
        guard started else { return }
        spansSuspended = false
        syncSessionSpans(latestSessions, now: now)
        syncYouSpan(now: now)
    }

    func sessionsDidChange(_ sessions: [AgentSession], now: Date = .now) {
        guard started else {
            knownSessionIDs.formUnion(sessions.map(\.id))
            return
        }
        let relevant = sessions.filter { !$0.isDemoSession && !$0.isSyntheticProcessSession }
        let currentIDs = Set(relevant.map(\.id))
        let focusTaskIDBefore = currentTask?.id
        var changed = false
        var finishedTurns: [String] = []
        let newLiveIDs = relevant.filter { !$0.isSessionEnded && !knownSessionIDs.contains($0.id) }.map(\.id)
        knownSessionIDs.formUnion(currentIDs)

        for removedID in Set(previousPhases.keys).subtracting(currentIDs) {
            attempt { try history.markEnded(sessionID: removedID, at: now) }
            previousPhases[removedID] = nil
            lastObservations[removedID] = nil
            unseenCompleted.remove(removedID)
            pendingReturnedSessionIDs.removeAll { $0 == removedID }
            deferredReturnedSessionIDs.remove(removedID)
            planStartedAt[removedID] = nil
            runStartedAt[removedID] = nil
            lastTurnDurations[removedID] = nil
            turnPrompts[removedID] = nil
            if lastJumpedSessionID == removedID {
                lastJumpedSessionID = nil
            }
            changedFiles[removedID] = nil
            changedFilesFetchedAt[removedID] = nil
            pendingBindingSessionIDs.removeAll { $0 == removedID }
            turnTracker.forget(sessionID: removedID)
            changed = true
        }

        for session in relevant {
            let observation = SessionObservation(session: session)
            let isNew = previousPhases[session.id] == nil && lastObservations[session.id] == nil
            if lastObservations[session.id] != observation {
                attempt { try history.record(observation) }
                lastObservations[session.id] = observation
                changed = true
            }
            if isNew,
               session.isHookManaged,
               session.claudeMetadata?.startupSource != .resume,
               now.timeIntervalSince(session.firstSeenAt) < Self.bindingPromptWindow,
               (try? history.session(id: session.id))?.taskId == nil,
               !pendingBindingSessionIDs.contains(session.id) {
                pendingBindingSessionIDs.append(session.id)
            }
            let previous = previousPhases[session.id]
            if session.phase == .completed && previous != .completed {
                unseenCompleted.insert(session.id)
            } else if session.phase == .running {
                unseenCompleted.remove(session.id)
            }
            if previous == .running && session.phase == .completed {
                finishedTurns.append(session.id)
            }
            if PlanProgress.from(session.claudeMetadata?.activeTasks ?? []) != nil {
                if planStartedAt[session.id] == nil { planStartedAt[session.id] = now }
            } else {
                planStartedAt[session.id] = nil
            }
            let turnPrompt = session.claudeMetadata?.lastUserPrompt ?? ""
            switch session.phase {
            case .running:
                let newPrompt = runStartedAt[session.id] != nil && turnPrompts[session.id].map { $0 != turnPrompt } == true
                if runStartedAt[session.id] == nil || newPrompt {
                    runStartedAt[session.id] = now
                    turnPrompts[session.id] = turnPrompt
                }
            case .waitingForApproval, .waitingForAnswer:
                break
            case .completed:
                if let startedAt = runStartedAt[session.id] {
                    lastTurnDurations[session.id] = max(0, now.timeIntervalSince(startedAt))
                }
                runStartedAt[session.id] = nil
                turnPrompts[session.id] = nil
            }
            previousPhases[session.id] = session.phase
            turnTracker.observe(sessionID: session.id, phase: session.phase, lastUserPrompt: session.claudeMetadata?.lastUserPrompt, at: now)
        }

        if !finishedTurns.isEmpty {
            finishedTurnLog.removeAll { now.timeIntervalSince($0.at) > 2 * 86_400 }
            finishedTurnLog.append(contentsOf: finishedTurns.map { ($0, now) })
        }

        latestSessions = relevant
        refreshSessionLabels()
        let liveIDs = Set(relevant.filter { !$0.isSessionEnded }.map(\.id))
        let liveSetChanged = liveIDs != liveSessionIDs
        if liveSetChanged {
            liveSessionIDs = liveIDs
        }
        if changed {
            reloadLiveRecords()
        }
        if liveSetChanged {
            attempt { try promptQueue.discardForEndedSessions() }
            workRevision += 1
        }
        syncSessionSpans(relevant, now: now)

        pendingReturnedSessionIDs.removeAll { !isReturnedStillRelevant($0) }
        for sessionID in finishedTurns where shouldPresentReturned(sessionID: sessionID, focusTaskID: focusTaskIDBefore) {
            deferredReturnedSessionIDs.remove(sessionID)
            if !pendingReturnedSessionIDs.contains(sessionID) {
                pendingReturnedSessionIDs.append(sessionID)
            }
        }
        closeResolvedReturned(now: now)
        presentPendingReturned(now: now)

        if case let .nextAction(triggering, _) = card,
           !relevant.contains(where: { $0.id == triggering && $0.phase == .running && !$0.isSessionEnded }) {
            closeCard(reacted: false, now: now)
        }
        if case let .nextAction(triggering, _) = card {
            refreshAlternatives(triggering: triggering)
        }
        refreshHub(now: now)
        closeResolvedOverload(now: now)
        presentOverloadIfNeeded(newLiveIDs: newLiveIDs, now: now)
        syncYouSpan(now: now)
    }

    func tick(now: Date = .now) {
        if let shownAt = toastShownAt, now.timeIntervalSince(shownAt) >= Self.toastLifetime {
            toast = nil
            toastShownAt = nil
        }
        if let shownAt = closedTaskShownAt, now.timeIntervalSince(shownAt) >= Self.closedTaskLifetime {
            closedTask = nil
            closedTaskShownAt = nil
        }
        if let shownAt = doneSessionShownAt, now.timeIntervalSince(shownAt) >= Self.closedTaskLifetime {
            doneSessionNotice = nil
            doneSessionShownAt = nil
        }
        handlePomodoroExpiry(now: now)
        refreshPomodoroSnapshot(now: now)
        presentPendingPomodoroCard(now: now)
        runBreakCountdown(now: now)
        refreshSessionLabels(now: now)
        refreshHub(now: now)
        syncYouSpan(now: now)
        tickNextAction(now: now)
        presentQueuedCards(now: now)
        refreshTodaySummary(now: now)
    }

    func refreshTodaySummary(now: Date, force: Bool = false) {
        if !force, let refreshedAt = todaySummaryRefreshedAt,
           Calendar.current.isDate(refreshedAt, inSameDayAs: now),
           now.timeIntervalSince(refreshedAt) < Self.todaySummaryInterval {
            return
        }
        todaySummaryRefreshedAt = now
        let report = dayReport(day: now, now: now)
        refreshPomodoroCount(now: now)
        let summary = TodaySummary(focusSeconds: report?.youSeconds ?? 0, distractionSeconds: report?.distractionSeconds ?? 0, pomodoroCount: pomodoroCountToday)
        if summary != todaySummary {
            todaySummary = summary
        }
    }

    private func tickNextAction(now: Date) {
        if case .nextAction = card, let shownAt = nextActionShownAt,
           now.timeIntervalSince(shownAt) >= Self.nextActionCardLifetime {
            closeCard(reacted: false, now: now)
        }
        presentPendingReturned(now: now)
        if isOnBreak {
            _ = turnTracker.takeDueSessions(now: now)
            return
        }
        if let card, !cardIsDeferredReturned, card.priority >= FocusCard.nextAction(triggeringSessionID: "", eventID: nil).priority { return }
        guard settings.nextActionEnabled else {
            _ = turnTracker.takeDueSessions(now: now)
            return
        }
        let parked = parkedSessionIDs
        let due = turnTracker.peekDue(now: now)
        for sessionID in due where parked.contains(sessionID) {
            turnTracker.markFired(sessionID: sessionID)
        }
        guard let triggering = due.first(where: { !parked.contains($0) }) else { return }
        guard FocusPresentationPolicy.shouldPresentNextAction(
            frontmostBundleID: frontmostBundleID,
            frontmostSince: frontmostSince,
            frontmostIsDistracting: frontmostIsDistracting,
            selfBundleID: Bundle.main.bundleIdentifier,
            now: now
        ) else { return }
        if presentNextAction(for: triggering, now: now) {
            turnTracker.markFired(sessionID: triggering)
        }
    }

    func overlayDidClose(now: Date = .now) {
        guard let card else { return }
        if card == .onboarding && onboardingPending { return }
        if card.pomodoroID != nil {
            deferredReturnedSessionIDs.formUnion(pendingReturnedSessionIDs)
            return
        }
        closeCard(reacted: false, now: now)
        deferredReturnedSessionIDs.formUnion(pendingReturnedSessionIDs)
        presentPendingReturned(now: now)
    }

    func perform(_ action: FocusCardAction, now: Date = .now) {
        if case .sendQueuedPrompt = action {
            actionTask = Task { [weak self] in
                await self?.run(action, now: now, completionTime: { Date.now })
            }
            return
        }
        performNow(action, now: now)
    }

    func performAsync(_ action: FocusCardAction, now: Date = .now) async {
        await run(action, now: now, completionTime: { now })
    }

    private func run(_ action: FocusCardAction, now: Date, completionTime: () -> Date) async {
        guard case let .sendQueuedPrompt(sessionID) = action else {
            performNow(action, now: now)
            return
        }
        guard sendingSessionIDs.insert(sessionID).inserted else { return }
        defer { sendingSessionIDs.remove(sessionID) }
        markCardReacted(now: now)
        await sendQueuedPrompt(sessionID: sessionID, now: now, completionTime: completionTime)
    }

    func requestJump(sessionID: String, now: Date = .now) {
        let record = record(sessionID)
        let lastSeen = record?.lastSeenAt ?? record?.lastActivityAt
        let targetTaskID = taskID(forSession: sessionID)
        let otherTask = targetTaskID != nil && targetTaskID != currentTask?.id
        if let card, card.priority <= FocusCard.reEntry(sessionID: sessionID).priority || card == .returned(sessionID: sessionID) {
            closeCard(reacted: true, now: now)
        }
        if let lastSeen, now.timeIntervalSince(lastSeen) >= Self.reEntryThreshold, otherTask,
           present(.reEntry(sessionID: sessionID), now: now) {
            return
        }
        directJump(sessionID: sessionID, now: now)
    }

    private func performNow(_ action: FocusCardAction, now: Date) {
        if action.countsAsReaction {
            markCardReacted(now: now)
        }
        switch action {
        case let .jump(sessionID):
            requestJump(sessionID: sessionID, now: now)
        case let .confirmJump(sessionID):
            closeCard(reacted: true, now: now)
            directJump(sessionID: sessionID, now: now)
        case let .startTask(taskID):
            launchTaskSession(taskID: taskID, now: now)
        case let .quickAdd(title):
            createTask(title: title, column: .todo, projectPath: cardSessionID.flatMap(sessionCWD))
        case let .bindTriggering(taskID):
            guard let sessionID = cardSessionID else { return }
            bind(sessionID: sessionID, taskID: taskID, now: now)
            refreshHub(now: now)
        case let .markTaskDone(taskID):
            markDone(taskID: taskID, now: now)
            closeCard(reacted: true, now: now)
        case let .queuePrompt(sessionID, text):
            attempt { try promptQueue.enqueue(sessionID: sessionID, taskID: taskID(forSession: sessionID), text: text, now: now) }
            workRevision += 1
        case .sendQueuedPrompt:
            break
        case let .toggleCriterion(id):
            attempt { try criteriaService.toggle(id: id, now: now) }
            workRevision += 1
        case let .addCriterion(taskID, text):
            attempt { try criteriaService.add(taskID: taskID, text: text, now: now) }
            workRevision += 1
        case let .deleteCriterion(id):
            attempt { try criteriaService.delete(id: id) }
            workRevision += 1
        case let .park(sessionID):
            attempt { try history.park(sessionID: sessionID, at: now) }
            reloadLiveRecords()
            syncSessionSpans(latestSessions, now: now)
            refreshHub(now: now)
            closeResolvedOverload(now: now)
            closeResolvedReturned(now: now)
        case let .unpark(sessionID):
            attempt { try history.unpark(sessionID: sessionID) }
            reloadLiveRecords()
            syncSessionSpans(latestSessions, now: now)
            refreshHub(now: now)
        case .snoozeDistraction:
            distractionTracker.suppress(until: now.addingTimeInterval(Self.snoozeDistractionDuration))
            closeCard(reacted: false, now: now)
            presentPendingReturned(now: now)
        case .allowDistraction:
            distractionTracker.suppress(until: now.addingTimeInterval(Self.allowDistractionDuration))
            closeCard(reacted: false, now: now)
            presentPendingReturned(now: now)
        case .returnToWork:
            if let target = latestSessions.filter({ !$0.isSessionEnded }).max(by: { $0.updatedAt < $1.updatedAt }) {
                closeCard(reacted: true, now: now)
                directJump(sessionID: target.id, now: now)
            } else {
                closeCard(reacted: false, now: now)
            }
            presentPendingReturned(now: now)
        case let .startDay(taskIDs):
            startDay(taskIDs: taskIDs, now: now)
        case .dismiss:
            closeCard(reacted: false, now: now)
            presentPendingReturned(now: now)
        }
    }

    private func launchTaskSession(taskID: String, now: Date) {
        guard let task = board.task(id: taskID) else { return closeCard(reacted: false, now: now) }
        attempt { try boardService.moveTask(id: taskID, to: .inProgress, beforeTaskID: nil, now: now) }
        let cwd = task.projectPath ?? cardSessionID.flatMap(sessionCWD) ?? FileManager.default.homeDirectoryForCurrentUser.path
        do {
            try launcher.run(command: ResumeCommand.newSession(cwd: cwd), in: settings.resumeTerminal)
            reload()
            closeCard(reacted: true, now: now)
        } catch {
            logger.error("terminal launch failed: \(String(describing: error), privacy: .public)")
            reload()
            closeCard(reacted: false, now: now)
        }
    }

    private func sendQueuedPrompt(sessionID: String, now: Date, completionTime: () -> Date) async {
        let origin = card
        guard let prompt = queuedPrompt(sessionID: sessionID) else {
            if card == origin { closeCard(reacted: true, now: now) }
            directJump(sessionID: sessionID, now: now)
            return
        }
        let result: PromptSendResult
        if let session = session(sessionID) {
            result = await promptSender.send(prompt.text, to: session)
        } else {
            result = .unsupported
        }
        let completedAt = completionTime()
        if result == .sent {
            attempt { try promptQueue.markSent(sessionID: sessionID, text: prompt.text, at: completedAt) }
            workRevision += 1
        } else {
            clipboard(prompt.text)
        }
        if card == origin { closeCard(reacted: true, now: now) }
        directJump(sessionID: sessionID, now: completedAt)
        if result != .sent {
            toast = Self.clipboardToast
            toastShownAt = completedAt
        }
    }

    private func directJump(sessionID: String, now: Date) {
        lastJumpedSessionID = sessionID
        lastJumpProjectName = projectName(sessionID: sessionID)
        jumpToSession?(sessionID)
        markSessionSeen(sessionID, now: now)
    }

    func presenceDidChange(_ event: PresenceEvent, now: Date = .now) {
        guard presenceTracker.handle(event) != nil, started else { return }
        syncSessionSpans(latestSessions, now: now)
        syncYouSpan(now: now)
    }

    func recentTomorrowNote(now: Date = .now) -> String? {
        _ = workRevision
        guard let earliest = Calendar.current.date(byAdding: .day, value: -7, to: now) else { return nil }
        return try? dayPlans.latestTomorrowNote(before: DayPlanStore.dayKey(now), notBefore: DayPlanStore.dayKey(earliest))
    }

    func boardDidAppear() {
        refreshTaskAggregates()
    }

    func bind(sessionID: String, taskID: String?, now: Date = .now) {
        attempt { try boardService.bindSession(sessionID: sessionID, toTaskID: taskID) }
        pendingBindingSessionIDs.removeAll { $0 == sessionID }
        reload()
        syncSessionSpans(latestSessions, now: now)
        refreshHub(now: now)
    }

    func createTaskForSession(sessionID: String, now: Date = .now) {
        let record = try? history.session(id: sessionID)
        let title = record?.firstPrompt ?? record?.projectName ?? "Новая задача"
        attempt { try boardService.createTaskForSession(sessionID: sessionID, title: title, projectPath: record?.cwd) }
        pendingBindingSessionIDs.removeAll { $0 == sessionID }
        reload()
        syncSessionSpans(latestSessions, now: now)
        if currentTask == nil, let taskID = taskID(forSession: sessionID) {
            startTask(taskID: taskID, sessionIDs: [], focusMinutes: nil, now: now)
        }
    }

    func requestBinding(sessionID: String) {
        var ids = pendingBindingSessionIDs.filter { $0 != sessionID }
        ids.insert(sessionID, at: 0)
        pendingBindingSessionIDs = ids
    }

    func skipBinding(sessionID: String) {
        pendingBindingSessionIDs.removeAll { $0 == sessionID }
    }

    func createTask(title: String, column: BoardColumn, projectPath: String?) {
        attempt { try boardService.createTask(title: title, column: column, projectPath: projectPath) }
        reload()
    }

    func moveTask(id: String, to column: BoardColumn, before beforeTaskID: String?, now: Date = .now) {
        attempt { try boardService.moveTask(id: id, to: column, beforeTaskID: beforeTaskID) }
        if column != .inProgress, focusTaskOverrideID == id {
            focusTaskOverrideID = nil
        }
        if column == .done, let active = activePomodoro, active.taskId == id, !PomodoroClock.isExpired(active, now: now) {
            attempt { try pomodoroStore.finish(completed: false, now: now) }
            activePomodoro = nil
            refreshActiveCycle(now: now)
            refreshPomodoroSnapshot(now: now)
        }
        reload()
    }

    func updateTask(_ task: FocusTask) {
        attempt { try boardService.updateTask(task) }
        if task.boardColumn != .inProgress, focusTaskOverrideID == task.id {
            focusTaskOverrideID = nil
        }
        reload()
    }

    func deleteTask(id: String, now: Date = .now) {
        let cardTaskID = card?.pomodoroID.flatMap { try? pomodoroStore.pomodoro(id: $0) }?.taskId
        let pendingTaskID = pendingPomodoroCard?.pomodoroID.flatMap { try? pomodoroStore.pomodoro(id: $0) }?.taskId
        attempt { try boardService.deleteTask(id: id, now: now) }
        if activePomodoro?.taskId == id {
            activePomodoro = nil
            refreshPomodoroSnapshot(now: now)
        }
        if pendingTaskID == id {
            pendingPomodoroCard = nil
        }
        if focusTaskOverrideID == id {
            focusTaskOverrideID = nil
        }
        if pendingStartTaskID == id {
            pendingStartTaskID = nil
        }
        let bindCardForTask = card == .bindToTask(taskID: id)
        reload()
        if bindCardForTask {
            closeCard(reacted: false, now: now)
            presentPendingReturned(now: now)
        }
        if cardTaskID == id {
            closeCard(reacted: false, now: now)
            presentPendingReturned(now: now)
        }
    }

    func markDone(taskID: String, now: Date = .now) {
        moveTask(id: taskID, to: .done, before: nil, now: now)
    }

    func startTask(taskID: String, sessionIDs: [String], focusMinutes: Int?, now: Date = .now) {
        guard board.task(id: taskID) != nil else { return }
        handlePomodoroExpiry(now: now)
        if let active = activePomodoro, active.taskId != taskID {
            attempt { try pomodoroStore.finish(completed: false, now: now) }
            activePomodoro = nil
            refreshActiveCycle(now: now)
            refreshPomodoroSnapshot(now: now)
        }
        moveToInProgressIfNeeded(taskID: taskID, now: now)
        for sessionID in sessionIDs {
            attempt { try boardService.bindSession(sessionID: sessionID, toTaskID: taskID, now: now) }
            pendingBindingSessionIDs.removeAll { $0 == sessionID }
        }
        focusTaskOverrideID = taskID
        focusCleared = false
        closedTask = nil
        closedTaskShownAt = nil
        if pendingStartTaskID == taskID {
            pendingStartTaskID = nil
        }
        reload()
        if card == .pickTask || card?.bindTaskID != nil {
            closeCard(reacted: true, now: now)
        }
        if let focusMinutes, focusMinutes > 0 {
            startPomodoro(taskID: taskID, minutes: focusMinutes, now: now)
        }
        syncSessionSpans(latestSessions, now: now)
        syncYouSpan(now: now)
        refreshHub(now: now)
    }

    func requestStartTask(taskID: String, now: Date = .now) {
        guard board.task(id: taskID) != nil else { return }
        moveToInProgressIfNeeded(taskID: taskID, now: now)
        reload()
        pendingStartTaskID = taskID
    }

    func clearPendingStartTask() {
        if pendingStartTaskID != nil {
            pendingStartTaskID = nil
        }
    }

    private func moveToInProgressIfNeeded(taskID: String, now: Date) {
        guard let task = board.task(id: taskID), task.boardColumn != .inProgress else { return }
        let first = board.tasks(in: .inProgress).first { $0.id != taskID }?.id
        attempt { try boardService.moveTask(id: taskID, to: .inProgress, beforeTaskID: first, now: now) }
    }

    func bindableSessions(forTaskID taskID: String) -> [BindableSession] {
        guard let task = board.task(id: taskID) else { return [] }
        let rows = latestSessions
            .filter { !$0.isSessionEnded && self.taskID(forSession: $0.id) != taskID }
            .map { session -> (row: BindableSession, updatedAt: Date) in
                let cwd = sessionCWD(session.id)
                let same = cwd.map { Self.projectPath(task.projectPath, contains: $0) } ?? false
                let boundTitle = board.task(id: self.taskID(forSession: session.id))?.title
                let stored = self.record(session.id)
                let detail = sessionDetail(session.id, prompt: stored?.lastPrompt ?? session.claudeMetadata?.lastUserPrompt, cwd: cwd)
                let row = BindableSession(
                    id: session.id,
                    title: sessionLabels[session.id] ?? session.title,
                    detail: detail,
                    projectName: projectName(sessionID: session.id),
                    boundTaskTitle: boundTitle,
                    isSameProject: same,
                    defaultSelected: same && boundTitle == nil
                )
                return (row, session.updatedAt)
            }
        return rows.sorted { lhs, rhs in
            if lhs.row.isSameProject != rhs.row.isSameProject { return lhs.row.isSameProject }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.row.id < rhs.row.id
        }.map(\.row)
    }

    func pickTaskOptions(now: Date = .now) -> PickTaskOptions {
        let rows = currentHubRows(now: now)
        let option = { (task: FocusTask) -> PickTaskOption in
            let taskRows = rows.filter { $0.taskID == task.id }
            return PickTaskOption(
                taskID: task.id,
                title: task.title,
                projectName: SessionHistory.projectName(for: task.projectPath),
                liveSessionCount: taskRows.count,
                sessionStateText: Self.sessionStateText(rows: taskRows, now: now)
            )
        }
        return PickTaskOptions(inProgress: board.tasks(in: .inProgress).map(option), todo: board.tasks(in: .todo).map(option))
    }

    nonisolated static func sessionStateText(rows allRows: [HubRow], now: Date) -> String {
        let rows = allRows.filter { $0.group != .done }
        guard !rows.isEmpty else { return "нет сессий — добавишь следующим шагом" }
        let ranked: [(groups: Set<HubGroup>, label: String)] = [
            ([.waiting], "ждёт"),
            ([.review, .idle, .unbound], "твой ход"),
            ([.running], "работает"),
            ([.parked], "на паузе")
        ]
        let count = sessionCountText(rows.count)
        for rank in ranked {
            guard let oldest = rows.filter({ rank.groups.contains($0.group) }).map(\.since).min() else { continue }
            let minutes = max(0, Int(now.timeIntervalSince(oldest) / 60))
            return "\(count) · \(rank.label) \(minutes) мин"
        }
        return count
    }

    nonisolated static func sessionCountText(_ count: Int) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        if mod10 == 1 && mod100 != 11 { return "\(count) сессия" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "\(count) сессии" }
        return "\(count) сессий"
    }

    @discardableResult
    func takeTask(taskID: String, now: Date = .now) -> TakeTaskResult? {
        guard board.task(id: taskID) != nil else { return nil }
        startTask(taskID: taskID, sessionIDs: [], focusMinutes: nil, now: now)
        if currentHubRows(now: now).contains(where: { $0.taskID == taskID }) {
            return .focused
        }
        present(.bindToTask(taskID: taskID), now: now)
        return .needsBinding
    }

    func taskSessionChoices(forTaskID taskID: String) -> [BindableSession] {
        guard board.task(id: taskID) != nil else { return [] }
        let bound = latestSessions
            .filter { !$0.isSessionEnded && self.taskID(forSession: $0.id) == taskID }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id < rhs.id
            }
            .map { session in
                let stored = self.record(session.id)
                let cwd = sessionCWD(session.id)
                return BindableSession(
                    id: session.id,
                    title: sessionLabels[session.id] ?? session.title,
                    detail: sessionDetail(session.id, prompt: stored?.lastPrompt ?? session.claudeMetadata?.lastUserPrompt, cwd: cwd),
                    projectName: projectName(sessionID: session.id),
                    boundTaskTitle: nil,
                    isSameProject: true,
                    defaultSelected: true,
                    isBound: true
                )
            }
        return bound + bindableSessions(forTaskID: taskID)
    }

    nonisolated static func defaultTaskSessionSelection(_ choices: [BindableSession]) -> Set<String> {
        Set(choices.filter(\.defaultSelected).map(\.id))
    }

    nonisolated static func taskSessionChanges(_ choices: [BindableSession], selected: Set<String>) -> (add: [String], remove: [String]) {
        let add = choices.filter { !$0.isBound && selected.contains($0.id) }.map(\.id)
        let remove = choices.filter { $0.isBound && !selected.contains($0.id) }.map(\.id)
        return (add, remove)
    }

    @discardableResult
    func openTaskSessions(taskID: String, now: Date = .now) -> Bool {
        guard board.task(id: taskID) != nil else { return false }
        if let card, card.priority >= FocusCard.pomodoroEnd(pomodoroID: "").priority { return false }
        if let card {
            if case let .returned(sessionID) = card, !pendingReturnedSessionIDs.contains(sessionID) {
                pendingReturnedSessionIDs.insert(sessionID, at: 0)
            }
            closeCard(reacted: false, now: now)
        }
        return present(.bindToTask(taskID: taskID), now: now)
    }

    func applyTaskSessions(taskID: String, selected: Set<String>, now: Date = .now) {
        guard board.task(id: taskID) != nil else { return }
        let changes = Self.taskSessionChanges(taskSessionChoices(forTaskID: taskID), selected: selected)
        for sessionID in changes.add {
            attempt { try boardService.bindSession(sessionID: sessionID, toTaskID: taskID, now: now) }
            pendingBindingSessionIDs.removeAll { $0 == sessionID }
        }
        for sessionID in changes.remove {
            attempt { try boardService.bindSession(sessionID: sessionID, toTaskID: nil, now: now) }
        }
        reload()
        syncSessionSpans(latestSessions, now: now)
        if card?.bindTaskID == taskID {
            closeCard(reacted: true, now: now)
        }
        refreshHub(now: now)
        presentPendingReturned(now: now)
    }

    func closeTask(taskID: String, showPicker: Bool, now: Date = .now) {
        guard let task = board.task(id: taskID) else { return }
        let wasFocused = currentTask?.id == taskID
        let cardTaskID = card?.pomodoroID.flatMap { try? pomodoroStore.pomodoro(id: $0) }?.taskId
        let pendingTaskID = pendingPomodoroCard?.pomodoroID.flatMap { try? pomodoroStore.pomodoro(id: $0) }?.taskId
        let sessionsCard = card?.bindTaskID == taskID || cardTaskID == taskID
        if let active = activePomodoro, active.taskId == taskID {
            attempt { try pomodoroStore.finish(completed: PomodoroClock.isExpired(active, now: now), now: now) }
            activePomodoro = nil
            refreshActiveCycle(now: now)
            refreshPomodoroSnapshot(now: now)
        }
        if pendingTaskID == taskID {
            pendingPomodoroCard = nil
        }
        if pendingStartTaskID == taskID {
            pendingStartTaskID = nil
        }
        markDone(taskID: taskID, now: now)
        if wasFocused {
            focusCleared = true
        }
        closedTask = ClosedTaskNotice(taskID: taskID, title: task.title, wasFocused: wasFocused)
        closedTaskShownAt = now
        if sessionsCard {
            closeCard(reacted: true, now: now)
        }
        refreshHub(now: now)
        if showPicker, !board.tasks(in: .inProgress).isEmpty || !board.tasks(in: .todo).isEmpty {
            openPickTask(now: now)
        } else if sessionsCard {
            presentPendingReturned(now: now)
        }
    }

    func reopenClosedTask(now: Date = .now) {
        guard let notice = closedTask else { return }
        closedTask = nil
        closedTaskShownAt = nil
        guard board.task(id: notice.taskID) != nil else { return }
        moveToInProgressIfNeeded(taskID: notice.taskID, now: now)
        if notice.wasFocused {
            focusTaskOverrideID = notice.taskID
            focusCleared = false
        }
        reload()
        if card == .pickTask {
            closeCard(reacted: true, now: now)
            presentPendingReturned(now: now)
        }
        syncYouSpan(now: now)
        refreshHub(now: now)
    }

    private func currentHubRows(now: Date) -> [HubRow] {
        let records = Dictionary(liveRecords.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return SessionHub.rows(sessions: latestSessions, records: records, board: board, unseenCompleted: unseenCompleted, now: now)
    }

    func showWaitingOutside() {
        waitingOutsideExpanded = true
    }

    func toggleWaitingOutside() {
        waitingOutsideExpanded.toggle()
    }

    func deferWaitingOutside(sessionIDs: [String], now: Date = .now) {
        for sessionID in sessionIDs {
            attempt { try history.park(sessionID: sessionID, at: now) }
        }
        reloadLiveRecords()
        syncSessionSpans(latestSessions, now: now)
        refreshHub(now: now)
    }

    func offerTaskChoiceOnLaunch(now: Date = .now) {
        guard pomodoro == nil else { return }
        focusCleared = true
        refreshHub(now: now)
        guard card == nil else { return }
        guard !board.tasks(in: .inProgress).isEmpty || !board.tasks(in: .todo).isEmpty else { return }
        presentCard?()
    }

    func bindNewSession(sessionID: String, taskID: String, now: Date = .now) {
        bind(sessionID: sessionID, taskID: taskID, now: now)
        if currentTask == nil {
            startTask(taskID: taskID, sessionIDs: [], focusMinutes: nil, now: now)
        }
    }

    func opensIslandOnCompletion(sessionID: String) -> Bool {
        guard let task = currentTask else { return false }
        return taskID(forSession: sessionID) == task.id
    }

    @discardableResult
    func openPickTask(now: Date = .now) -> PickTaskOpenResult {
        guard !board.tasks(in: .todo).isEmpty || !board.tasks(in: .inProgress).isEmpty else {
            NotificationCenter.default.post(name: .focusOpenBoard, object: nil, userInfo: ["tab": "board"])
            return .openedBoard
        }
        if let card, card.priority >= FocusCard.pomodoroEnd(pomodoroID: "").priority { return .blocked }
        if let card {
            if case let .returned(sessionID) = card, !pendingReturnedSessionIDs.contains(sessionID) {
                pendingReturnedSessionIDs.insert(sessionID, at: 0)
            }
            closeCard(reacted: false, now: now)
        }
        return present(.pickTask, now: now) ? .presented : .blocked
    }

    @discardableResult
    func startPomodoro(taskID: String?, minutes: Int, now: Date = .now) -> Bool {
        guard minutes > 0 else { return false }
        let clamped = min(FocusSettings.pomodoroFocusRange.upperBound, max(FocusSettings.pomodoroFocusRange.lowerBound, minutes))
        return beginPomodoro(taskID: taskID, phase: .focus, seconds: clamped * 60, now: now)
    }

    func pausePomodoro(now: Date = .now) {
        handlePomodoroExpiry(now: now)
        guard activePomodoro != nil else { return }
        do {
            activePomodoro = try pomodoroStore.pause(now: now)
        } catch {
            logger.error("pomodoro pause failed: \(String(describing: error), privacy: .public)")
        }
        refreshPomodoroSnapshot(now: now)
    }

    func resumePomodoro(now: Date = .now) {
        handlePomodoroExpiry(now: now)
        guard activePomodoro != nil else { return }
        do {
            activePomodoro = try pomodoroStore.resume(now: now)
        } catch {
            logger.error("pomodoro resume failed: \(String(describing: error), privacy: .public)")
        }
        refreshPomodoroSnapshot(now: now)
    }

    func stopPomodoro(now: Date = .now) {
        handlePomodoroExpiry(now: now)
        guard activePomodoro != nil else { return }
        attempt { try pomodoroStore.finish(completed: false, now: now) }
        activePomodoro = nil
        refreshPomodoroSnapshot(now: now)
    }

    func breakCountdownRemaining(now: Date = .now) -> Int? {
        guard let endsAt = breakCountdownEndsAt else { return nil }
        return max(0, Int(endsAt.timeIntervalSince(now).rounded(.up)))
    }

    func chooseBreakMinutes(_ minutes: Int) {
        breakMinutesChoice = min(FocusSettings.pomodoroBreakRange.upperBound, max(FocusSettings.pomodoroBreakRange.lowerBound, minutes))
    }

    func cancelBreakCountdown() {
        breakCountdownEndsAt = nil
        breakCountdownLeft = nil
    }

    func finishBreakEarly(now: Date = .now) {
        guard let active = activePomodoro, active.phase == .break else { return }
        attempt { try pomodoroStore.finish(completed: false, now: now) }
        activePomodoro = nil
        refreshPomodoroSnapshot(now: now)
        pendingPomodoroCard = .breakEnd(pomodoroID: active.id)
        presentPendingPomodoroCard(now: now)
    }

    private func startBreakCountdownIfFresh(pomodoroID: String, now: Date) {
        breakCountdownEndsAt = nil
        guard settings.autoBreakEnabled,
              let ended = (try? pomodoroStore.pomodoro(id: pomodoroID))?.endedAt,
              now.timeIntervalSince(ended) < Self.breakCountdownFreshness else { return }
        breakCountdownEndsAt = now.addingTimeInterval(Self.breakCountdownSeconds)
        breakCountdownLeft = breakCountdownRemaining(now: now)
        if settings.breakSoundEnabled {
            playSound(Self.breakSoundName)
        }
    }

    private func runBreakCountdown(now: Date) {
        let left = breakCountdownRemaining(now: now)
        if breakCountdownLeft != left {
            breakCountdownLeft = left
        }
        guard let endsAt = breakCountdownEndsAt, now >= endsAt else { return }
        guard case .pomodoroEnd = card else {
            breakCountdownEndsAt = nil
            return
        }
        startBreak(nextStep: nil, minutes: breakMinutesChoice, now: now)
    }

    func startBreak(nextStep: String?, minutes chosen: Int? = nil, now: Date = .now) {
        let ended = cardPomodoro()
        let taskID = ended?.taskId ?? currentTask?.id
        saveNextStep(nextStep, taskID: taskID, now: now)
        closePomodoroCard(now: now)
        let minutes = min(FocusSettings.pomodoroBreakRange.upperBound, max(FocusSettings.pomodoroBreakRange.lowerBound, chosen ?? settings.pomodoroBreakMinutes))
        beginPomodoro(taskID: taskID, phase: .break, seconds: minutes * 60, now: now)
    }

    func continueFocus(nextStep: String?, minutes chosen: Int? = nil, now: Date = .now) {
        let ended = cardPomodoro()
        let taskID = ended?.taskId ?? currentTask?.id
        saveNextStep(nextStep, taskID: taskID, now: now)
        closePomodoroCard(now: now)
        startPomodoro(taskID: taskID, minutes: PomodoroFormat.clampFocus(chosen ?? nextFocusMinutes(after: ended)), now: now)
    }

    func endForToday(nextStep: String?, now: Date = .now) {
        let taskID = cardPomodoro()?.taskId ?? currentTask?.id
        saveNextStep(nextStep, taskID: taskID, now: now)
        closePomodoroCard(now: now)
        presentPendingReturned(now: now)
    }

    func saveNextStepDraft(_ text: String?, pomodoroID: String, now: Date = .now) {
        guard let item = try? pomodoroStore.pomodoro(id: pomodoroID),
              let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              board.task(id: item.taskId)?.note != trimmed else { return }
        saveNextStep(trimmed, taskID: item.taskId, now: now)
    }

    func closePickTask(now: Date = .now) {
        guard card == .pickTask else { return }
        closeCard(reacted: false, now: now)
        presentPendingReturned(now: now)
    }

    func pomodoroCount(day: Date) -> Int {
        (try? pomodoroStore.completedFocusCount(day: day)) ?? 0
    }

    func extendBreak(minutes: Int = 5, now: Date = .now) {
        guard minutes > 0 else { return }
        handlePomodoroExpiry(now: now)
        if let active = activePomodoro, active.phase == .break {
            do {
                activePomodoro = try pomodoroStore.extendActive(bySeconds: minutes * 60)
            } catch {
                logger.error("pomodoro extend failed: \(String(describing: error), privacy: .public)")
            }
            refreshPomodoroSnapshot(now: now)
            return
        }
        guard case .breakEnd = card else { return }
        let taskID = cardPomodoro()?.taskId ?? currentTask?.id
        closePomodoroCard(now: now)
        beginPomodoro(taskID: taskID, phase: .break, seconds: minutes * 60, now: now)
    }

    func endBreakWithoutTimer(now: Date = .now) {
        if case .breakEnd = card {
            closePomodoroCard(now: now)
        }
        if activePomodoro?.phase == .break {
            attempt { try pomodoroStore.finish(completed: false, now: now) }
            activePomodoro = nil
            refreshPomodoroSnapshot(now: now)
        }
        presentPendingReturned(now: now)
    }

    func resumeAfterBreak(minutes chosen: Int? = nil, now: Date = .now) {
        let taskID = cardPomodoro()?.taskId ?? activePomodoro?.taskId ?? currentTask?.id
        closePomodoroCard(now: now)
        if activePomodoro?.phase == .break {
            attempt { try pomodoroStore.finish(completed: false, now: now) }
            activePomodoro = nil
        }
        startPomodoro(taskID: taskID, minutes: PomodoroFormat.clampFocus(chosen ?? settings.pomodoroFocusMinutes), now: now)
        guard let taskID else { return }
        let bound = latestSessions.filter { !$0.isSessionEnded && self.taskID(forSession: $0.id) == taskID }
        let waiting = bound.filter { $0.phase == .waitingForApproval || $0.phase == .waitingForAnswer }
        let target = (waiting.isEmpty ? bound : waiting).max { $0.updatedAt < $1.updatedAt }
        if let target {
            requestJump(sessionID: target.id, now: now)
        }
    }

    func pomodoroSummary(pomodoroID: String, now: Date = .now) -> PomodoroSummary? {
        guard let item = try? pomodoroStore.pomodoro(id: pomodoroID) else { return nil }
        let end = max(item.startedAt, item.endedAt ?? now)
        let report = intervalReport(taskID: item.taskId, from: item.startedAt, to: end)
        let completedBefore = item.taskId.flatMap { try? pomodoroStore.completedFocusCount(taskID: $0, day: item.startedAt, startedBefore: item.startedAt) } ?? 0
        return PomodoroSummary(
            pomodoroID: item.id,
            taskID: item.taskId,
            taskTitle: board.task(id: item.taskId)?.title ?? "",
            plannedMinutes: item.plannedSeconds / 60,
            nextFocusMinutes: nextFocusMinutes(after: item),
            cycleIndex: PomodoroClock.cycleIndex(completedToday: completedBefore, cycle: settings.pomodoroCycle),
            cycle: settings.pomodoroCycle,
            youInTaskSeconds: report?.youSeconds ?? 0,
            claudeSeconds: report?.claudeSeconds ?? 0,
            distractionSeconds: report?.distractionSeconds ?? 0,
            distractionCount: report?.distractionCount ?? 0,
            returnedCount: report?.returnedCount ?? 0,
            finishedSessionTitles: finishedSessionTitles(taskID: item.taskId, from: item.startedAt, to: end),
            checkedCriteria: checkedCriteria(taskID: item.taskId, from: item.startedAt, to: end)
        )
    }

    func breakSummary(pomodoroID: String, now: Date = .now) -> BreakSummary? {
        guard let item = try? pomodoroStore.pomodoro(id: pomodoroID) else { return nil }
        let end = max(item.startedAt, item.endedAt ?? now)
        let task = board.task(id: item.taskId)
        return BreakSummary(
            pomodoroID: item.id,
            taskID: item.taskId,
            taskTitle: task?.title ?? "",
            note: task?.note,
            plannedMinutes: item.plannedSeconds / 60,
            finishedSessionTitles: finishedSessionTitles(taskID: item.taskId, from: item.startedAt, to: end)
        )
    }

    private func intervalReport(taskID: String?, from: Date, to: Date) -> DayReport? {
        do {
            let spans = try activityLog.spans(from: from, to: to).filter { taskID != nil && $0.taskId == taskID }
            let episodes = try distractionLog.episodes(since: from.addingTimeInterval(-86_400)).filter { $0.startedAt < to }
            return ReportBuilder.day(spans: spans, episodes: episodes, tasks: board.tasks, dayStart: from, dayEnd: to)
        } catch {
            logger.error("pomodoro report failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func finishedSessionTitles(taskID: String?, from: Date, to: Date) -> [String] {
        guard let taskID else { return [] }
        var seen: Set<String> = []
        var titles: [String] = []
        for entry in finishedTurnLog where entry.at >= from && entry.at <= to && self.taskID(forSession: entry.sessionID) == taskID {
            guard seen.insert(entry.sessionID).inserted else { continue }
            titles.append(session(entry.sessionID)?.title ?? record(entry.sessionID)?.title ?? entry.sessionID)
        }
        return titles
    }

    func nextFocusMinutes(after ended: Pomodoro?) -> Int {
        let minutes = ended.flatMap { $0.phase == .focus ? $0.plannedSeconds / 60 : nil } ?? settings.pomodoroFocusMinutes
        return min(FocusSettings.pomodoroFocusRange.upperBound, max(FocusSettings.pomodoroFocusRange.lowerBound, minutes))
    }

    private func checkedCriteria(taskID: String?, from: Date, to: Date) -> [String] {
        guard let taskID else { return [] }
        return ((try? criteriaService.criteria(taskID: taskID)) ?? [])
            .filter { criterion in
                guard criterion.done, let checkedAt = criterion.checkedAt else { return false }
                return checkedAt >= from && checkedAt <= to
            }
            .map(\.text)
    }

    private func cardPomodoro() -> Pomodoro? {
        card?.pomodoroID.flatMap { try? pomodoroStore.pomodoro(id: $0) }
    }

    private func closePomodoroCard(now: Date) {
        if card?.pomodoroID != nil {
            closeCard(reacted: true, now: now)
        }
    }

    private func saveNextStep(_ text: String?, taskID: String?, now: Date) {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              var task = board.task(id: taskID) else { return }
        task.note = trimmed
        attempt { try boardService.updateTask(task, now: now) }
        reload()
    }

    @discardableResult
    private func beginPomodoro(taskID: String?, phase: PomodoroPhase, seconds: Int, now: Date) -> Bool {
        guard seconds > 0 else { return false }
        attempt { try pomodoroStore.recoverExpired(now: now) }
        if card?.pomodoroID != nil {
            closeCard(reacted: false, now: now)
        }
        pendingPomodoroCard = nil
        do {
            activePomodoro = try pomodoroStore.start(taskID: taskID, phase: phase, plannedSeconds: seconds, now: now)
        } catch {
            logger.error("pomodoro start failed: \(String(describing: error), privacy: .public)")
            activePomodoro = nil
            refreshPomodoroSnapshot(now: now)
            return false
        }
        refreshActiveCycle(now: now)
        refreshPomodoroCount(now: now)
        refreshPomodoroSnapshot(now: now)
        if phase == .break {
            enterBreak(now: now)
        }
        syncYouSpan(now: now)
        return true
    }

    private func enterBreak(now: Date) {
        if distractionTracker.currentEpisode != nil {
            let sample = FrontmostSample(bundleID: frontmostBundleID ?? "", url: nil, at: now)
            let events = distractionTracker.observe(sample, anySessionRunning: false, stopList: settings.stopList)
            handleDistractionEvents(events, at: now)
            refreshDistractionTarget()
        }
        switch card {
        case .nextAction, .nudge:
            closeCard(reacted: false, now: now)
            presentPendingReturned(now: now)
        default:
            break
        }
        _ = turnTracker.takeDueSessions(now: now)
    }

    private func restorePomodoro(now: Date) {
        do {
            if let recovered = try pomodoroStore.recoverExpired(now: now), let endedAt = recovered.endedAt,
               Calendar.current.isDate(endedAt, inSameDayAs: now), now.timeIntervalSince(endedAt) <= Self.recoveredEndCardWindow {
                pendingPomodoroCard = Self.endCard(for: recovered)
            }
            activePomodoro = try pomodoroStore.active()
        } catch {
            logger.error("pomodoro restore failed: \(String(describing: error), privacy: .public)")
        }
        refreshActiveCycle(now: now)
        refreshPomodoroCount(now: now)
        refreshPomodoroSnapshot(now: now)
    }

    private func handlePomodoroExpiry(now: Date) {
        guard let active = activePomodoro, PomodoroClock.isExpired(active, now: now) else { return }
        var finished = active
        do {
            if let recovered = try pomodoroStore.recoverExpired(now: now) {
                finished = recovered
            }
        } catch {
            logger.error("pomodoro finish failed: \(String(describing: error), privacy: .public)")
        }
        activePomodoro = nil
        refreshPomodoroSnapshot(now: now)
        refreshTodaySummary(now: now, force: true)
        pendingPomodoroCard = Self.endCard(for: finished)
        presentPendingPomodoroCard(now: now)
    }

    private static func endCard(for pomodoro: Pomodoro) -> FocusCard {
        pomodoro.phase == .focus ? .pomodoroEnd(pomodoroID: pomodoro.id) : .breakEnd(pomodoroID: pomodoro.id)
    }

    private func presentPendingPomodoroCard(now: Date) {
        guard started, let pending = pendingPomodoroCard else { return }
        if card == pending {
            pendingPomodoroCard = nil
            return
        }
        if present(pending, now: now) {
            pendingPomodoroCard = nil
        }
    }

    private func refreshActiveCycle(now: Date) {
        guard let active = activePomodoro else {
            activeCycleCompleted = 0
            return
        }
        let count: Int
        if let taskID = active.taskId {
            count = (try? pomodoroStore.completedFocusCount(taskID: taskID, day: active.startedAt, startedBefore: active.startedAt)) ?? 0
        } else {
            count = (try? pomodoroStore.completedFocusCount(day: active.startedAt)) ?? 0
        }
        activeCycleCompleted = active.phase == .focus ? count : max(0, count - 1)
    }

    private func refreshPomodoroCount(now: Date) {
        let count = (try? pomodoroStore.completedFocusCount(day: now)) ?? 0
        if count != pomodoroCountToday {
            pomodoroCountToday = count
        }
    }

    private func refreshPomodoroSnapshot(now: Date) {
        guard let active = activePomodoro else {
            if pomodoro != nil { pomodoro = nil }
            return
        }
        let remaining = Int(PomodoroClock.remaining(active, now: now).rounded(.up))
        let progress = active.plannedSeconds > 0 ? min(1, max(0, 1 - Double(remaining) / Double(active.plannedSeconds))) : 1
        let snapshot = PomodoroSnapshot(
            id: active.id,
            taskID: active.taskId,
            taskTitle: board.task(id: active.taskId)?.title,
            phase: active.phase,
            plannedSeconds: active.plannedSeconds,
            remainingSeconds: remaining,
            progress: progress,
            isPaused: active.pausedAt != nil,
            cycleIndex: PomodoroClock.cycleIndex(completedToday: activeCycleCompleted, cycle: settings.pomodoroCycle),
            cycle: settings.pomodoroCycle
        )
        if snapshot != pomodoro {
            pomodoro = snapshot
        }
    }

    func markSessionSeen(_ sessionID: String, now: Date = .now) {
        unseenCompleted.remove(sessionID)
        pendingReturnedSessionIDs.removeAll { $0 == sessionID }
        deferredReturnedSessionIDs.remove(sessionID)
        attempt { try history.markSeen(sessionID: sessionID, at: now) }
        reloadLiveRecords()
        syncSessionSpans(latestSessions, now: now)
        refreshHub(now: now)
        closeResolvedReturned(now: now)
    }

    func frontmostDidChange(_ sample: FrontmostSample) {
        if sample.bundleID != frontmostBundleID {
            frontmostBundleID = sample.bundleID
            frontmostSince = sample.at
        }
        frontmostIsDistracting = DistractionClassifier.isDistracting(bundleID: sample.bundleID, url: sample.url, stopList: settings.stopList)
        defer { refreshDistractionTarget() }
        syncYouSpan(now: sample.at)
        presentDayStartIfDue(now: sample.at)
        guard settings.distractionEnabled else { return }
        let events = distractionTracker.observe(sample, anySessionRunning: hasRunningSession && !isOnBreak, stopList: settings.stopList)
        handleDistractionEvents(events, at: sample.at)
    }

    private func handleDistractionEvents(_ events: [DistractionEvent], at date: Date) {
        for event in events {
            switch event {
            case .nudge:
                if present(.nudge, now: date), settings.nudgeSoundEnabled {
                    NSSound.beep()
                }
            case let .episodeEnded(episode):
                attempt { try distractionLog.save(episode) }
                if card == .nudge {
                    card = nil
                    presentPendingReturned(now: date)
                }
            }
        }
    }

    private func refreshDistractionTarget() {
        let episode = distractionTracker.currentEpisode
        let target = episode.map { Self.distractionName(domain: $0.domain, bundleID: $0.appBundleID) }
        if target != distractionTarget { distractionTarget = target }
        if episode?.startedAt != distractionStartedAt { distractionStartedAt = episode?.startedAt }
    }

    static func distractionName(domain: String?, bundleID: String) -> String {
        if let domain, !domain.isEmpty { return domain }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
    }

    func turnElapsed(sessionID: String, now: Date) -> TimeInterval? {
        runStartedAt[sessionID].map { max(0, now.timeIntervalSince($0)) }
    }

    func lastTurnDuration(sessionID: String) -> TimeInterval? {
        lastTurnDurations[sessionID]
    }

    func nudgeSessionID() -> String? {
        let parked = parkedSessionIDs
        return latestSessions
            .filter { $0.phase == .running && !$0.isSessionEnded && !parked.contains($0.id) }
            .max { $0.updatedAt < $1.updatedAt }?
            .id
    }

    func nudgeSuggestion(now: Date = .now) -> NextAlternative? {
        guard let triggering = nudgeSessionID() else { return nil }
        return computeAlternatives(triggering: triggering, limit: 1).first
    }

    func resume(record: SessionRecord, now: Date = .now) {
        if liveSessionIDs.contains(record.id) {
            requestJump(sessionID: record.id, now: now)
            return
        }
        guard let cwd = record.cwd, FileManager.default.fileExists(atPath: cwd) else { return }
        attempt { try launcher.run(command: ResumeCommand.resume(sessionID: record.id, cwd: cwd), in: settings.resumeTerminal) }
    }

    func startNewSession(forTaskID taskID: String) {
        guard let task = board.task(id: taskID) else { return }
        let cwd = TaskDetailView.newSessionCwd(projectPath: task.projectPath, home: FileManager.default.homeDirectoryForCurrentUser.path)
        attempt { try launcher.run(command: ResumeCommand.newSession(cwd: cwd), in: settings.resumeTerminal) }
    }

    func taskSpans(taskID: String, now: Date) -> [ActivitySpan] {
        (try? activityLog.spans(taskID: taskID, to: now)) ?? []
    }

    func aggregate(taskID: String) -> TaskAggregate {
        taskAggregates[taskID] ?? TaskAggregate()
    }

    func canResume(_ record: SessionRecord) -> Bool {
        liveSessionIDs.contains(record.id) || record.cwd.map { FileManager.default.fileExists(atPath: $0) } == true
    }

    func sessions(forTaskID taskID: String) -> [SessionRecord] {
        (try? history.sessions(forTaskID: taskID)) ?? []
    }

    func searchHistory(text: String?, projectPath: String?) -> [SessionRecord] {
        (try? history.search(text: text, projectPath: projectPath, limit: 500)) ?? []
    }

    func recentHistory(limit: Int) -> [SessionRecord] {
        (try? history.recent(limit: limit)) ?? []
    }

    func knownProjectPaths() -> [String] {
        (try? history.knownProjectPaths()) ?? []
    }

    func stats(since: Date) -> FocusStats? {
        try? statsService.stats(since: since)
    }

    func sessionCWD(_ sessionID: String) -> String? {
        if let cwd = latestSessions.first(where: { $0.id == sessionID })?.jumpTarget?.workingDirectory {
            return cwd
        }
        return (try? history.session(id: sessionID))?.cwd
    }

    func pickerTasks(forSessionID sessionID: String?) -> [FocusTask] {
        let tasks = board.tasks(in: .inProgress) + board.tasks(in: .todo)
        guard let cwd = sessionID.flatMap(sessionCWD) else { return tasks }
        let matching = tasks.filter { Self.projectPath($0.projectPath, contains: cwd) }
        let others = tasks.filter { !Self.projectPath($0.projectPath, contains: cwd) }
        return matching + others
    }

    nonisolated static func projectPath(_ projectPath: String?, contains cwd: String) -> Bool {
        guard let projectPath, !projectPath.isEmpty else { return false }
        let root = projectPath.hasSuffix("/") && projectPath.count > 1 ? String(projectPath.dropLast()) : projectPath
        return cwd == root || cwd.hasPrefix(root == "/" ? "/" : root + "/")
    }

    func sessionTitle(_ sessionID: String) -> String {
        sessionLabels[sessionID] ?? latestSessions.first { $0.id == sessionID }?.title ?? sessionID
    }

    func sessionLabel(_ sessionID: String) -> String? {
        sessionLabels[sessionID]
    }

    func refreshSessionLabels(now: Date = .now) {
        guard let lookup = lookupSessionLabels, !labelLookupInFlight else { return }
        let ids = Set(latestSessions.filter { session in
            guard session.jumpTarget.map({ ClaudeDesktopSessionLocator.isClaudeDesktop(terminalApp: $0.terminalApp) }) ?? false else { return false }
            return Self.labelLookupDue(lastLookup: labelLookedUpAt[session.id], hasLabel: sessionLabels[session.id] != nil, now: now)
        }.map(\.id))
        guard !ids.isEmpty else { return }
        labelLookupInFlight = true
        Task { @MainActor [weak self] in
            let found = await lookup(ids)
            guard let self else { return }
            for id in ids { self.labelLookedUpAt[id] = now }
            self.labelLookupInFlight = false
            for (id, label) in found {
                if let title = label.title, self.sessionLabels[id] != title { self.sessionLabels[id] = title }
                if let status = label.status, self.sessionStatuses[id] != status { self.sessionStatuses[id] = status }
            }
        }
    }

    nonisolated static func labelLookupDue(lastLookup: Date?, hasLabel: Bool, now: Date) -> Bool {
        guard let lastLookup else { return true }
        let age = now.timeIntervalSince(lastLookup)
        return age >= (hasLabel ? labelRefreshSeconds : labelRetrySeconds)
    }

    nonisolated static func promptPreview(_ prompt: String?) -> String? {
        guard var text = prompt else { return nil }
        text = text.replacingOccurrences(of: #"<([A-Za-z][\w-]*)\b[^>]*>[\s\S]*?</\1>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[A-Za-z][\w-]*\b[^>]*/?>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[Image[^\]]*\]"#, with: " ", options: .regularExpression)
        let lines = text.components(separatedBy: .newlines).filter { !$0.hasPrefix("Base directory for this skill") }
        let cleaned = lines.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    func sessionDetail(_ sessionID: String, prompt: String?, cwd: String?) -> String {
        sessionStatuses[sessionID] ?? Self.promptPreview(prompt) ?? cwd ?? ""
    }

    func session(_ id: String) -> AgentSession? {
        latestSessions.first { $0.id == id }
    }

    func record(_ id: String) -> SessionRecord? {
        if let live = liveRecords.first(where: { $0.id == id }) {
            return live
        }
        return try? history.session(id: id)
    }

    func taskID(forSession sessionID: String) -> String? {
        record(sessionID)?.taskId
    }

    func planProgress(sessionID: String) -> PlanProgress? {
        PlanProgress.from(session(sessionID)?.claudeMetadata?.activeTasks ?? [])
    }

    func planRemaining(sessionID: String, now: Date) -> TimeInterval? {
        guard let progress = planProgress(sessionID: sessionID), let startedAt = planStartedAt[sessionID] else { return nil }
        return progress.remaining(planStartedAt: startedAt, now: now)
    }

    func queuedPrompt(sessionID: String) -> QueuedPrompt? {
        _ = workRevision
        return try? promptQueue.pending(sessionID: sessionID)
    }

    func criteria(taskID: String) -> [TaskCriterion] {
        _ = workRevision
        return (try? criteriaService.criteria(taskID: taskID)) ?? []
    }

    func criteriaProgress(taskID: String) -> CriteriaProgress? {
        _ = workRevision
        guard let progress = try? criteriaService.progress(taskID: taskID), progress.total > 0 else { return nil }
        return progress
    }

    func dayReport(day: Date, now: Date) -> DayReport? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        let end = max(start, min(endOfDay, now))
        do {
            let spans = try activityLog.spans(from: start, to: end)
            let episodes = try distractionLog.episodes(since: start.addingTimeInterval(-86_400)).filter { $0.startedAt < end }
            return ReportBuilder.day(spans: spans, episodes: episodes, tasks: board.tasks, dayStart: start, dayEnd: end)
        } catch {
            logger.error("day report failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func weekReport(endingAt: Date, now: Date) -> WeekReport? {
        let calendar = Calendar.current
        let lastDay = calendar.startOfDay(for: endingAt)
        guard let weekStart = calendar.date(byAdding: .day, value: -6, to: lastDay),
              let weekEnd = calendar.date(byAdding: .day, value: 1, to: lastDay) else { return nil }
        let end = max(weekStart, min(weekEnd, now))
        do {
            let spans = try activityLog.spans(from: weekStart, to: end)
            let episodes = try distractionLog.episodes(since: weekStart.addingTimeInterval(-86_400)).filter { $0.startedAt < end }
            let sessions = try history.sessions(startedFrom: weekStart, to: weekEnd)
            return ReportBuilder.week(spans: spans, episodes: episodes, tasks: board.tasks, sessions: sessions, weekStart: weekStart, calendar: calendar)
        } catch {
            logger.error("week report failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func dayPlan(day: Date) -> DayPlan? {
        _ = workRevision
        return try? dayPlans.plan(day: DayPlanStore.dayKey(day))
    }

    func setTomorrowNote(_ text: String?, day: Date) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        attempt { try dayPlans.setTomorrowNote(trimmed?.isEmpty == true ? nil : trimmed, day: DayPlanStore.dayKey(day)) }
        workRevision += 1
    }

    func openDayStart(now: Date = .now) {
        if let card, card.priority < FocusCard.pomodoroEnd(pomodoroID: "").priority {
            if case let .returned(sessionID) = card, !pendingReturnedSessionIDs.contains(sessionID) {
                pendingReturnedSessionIDs.insert(sessionID, at: 0)
            }
            closeCard(reacted: false, now: now)
        }
        present(.dayStart, now: now)
    }

    func setHooksInstalled(_ installed: Bool, now: Date = .now) {
        let previous = hooksInstalled
        if previous != installed {
            hooksInstalled = installed
        }
        if !installed, previous != false, !onboardingDismissed {
            present(.onboarding, now: now)
        } else if installed, previous == nil, onboardingPending, defaults.bool(forKey: Self.onboardingPresentedKey), card != .onboarding {
            present(.onboarding, now: now)
        }
    }

    private var onboardingPending: Bool {
        !onboardingDismissed && !(onboardingAutomationOpened && onboardingTaskAdded)
    }

    func dismissOnboarding(now: Date = .now) {
        defaults.set(true, forKey: Self.onboardingDismissedKey)
        onboardingDismissed = true
        if card == .onboarding {
            closeCard(reacted: false, now: now)
            presentPendingReturned(now: now)
        }
    }

    func markOnboardingAutomationOpened() {
        defaults.set(true, forKey: Self.onboardingAutomationOpenedKey)
        if !onboardingAutomationOpened {
            onboardingAutomationOpened = true
        }
    }

    func markOnboardingTaskAdded() {
        defaults.set(true, forKey: Self.onboardingTaskAddedKey)
        if !onboardingTaskAdded {
            onboardingTaskAdded = true
        }
    }

    static func stalledBadge(rows: [HubRow], now: Date) -> StalledBadge? {
        guard let oldest = rows.filter({ $0.group == .waiting }).min(by: { $0.since < $1.since }) else { return nil }
        let minutes = Int(now.timeIntervalSince(oldest.since) / 60)
        guard minutes >= stalledBadgeMinutes else { return nil }
        return StalledBadge(title: oldest.title, minutes: minutes)
    }

    private struct OpenSpan {
        let id: Int64
        let kind: ActivityKind
        let taskID: String?
    }

    private func spanKind(for session: AgentSession) -> ActivityKind? {
        guard !session.isSessionEnded else { return nil }
        if session.phase == .running {
            return .claude
        }
        guard !presenceTracker.isAway, !parkedSessionIDs.contains(session.id) else { return nil }
        switch session.phase {
        case .waitingForApproval, .waitingForAnswer:
            return .waiting
        case .completed:
            return unseenCompleted.contains(session.id) ? .waiting : nil
        default:
            return nil
        }
    }

    private func syncSessionSpans(_ sessions: [AgentSession], now: Date) {
        guard !spansSuspended else { return }
        var desired: [String: ActivityKind] = [:]
        for session in sessions {
            if let kind = spanKind(for: session) {
                desired[session.id] = kind
            }
        }
        for sessionID in sessionSpans.keys.sorted() {
            guard let open = sessionSpans[sessionID] else { continue }
            if desired[sessionID] == open.kind {
                let taskID = taskID(forSession: sessionID)
                if taskID != open.taskID {
                    attempt { try activityLog.reassign(id: open.id, taskID: taskID) }
                    sessionSpans[sessionID] = OpenSpan(id: open.id, kind: open.kind, taskID: taskID)
                }
                continue
            }
            attempt { try activityLog.close(id: open.id, at: now) }
            sessionSpans[sessionID] = nil
        }
        for sessionID in desired.keys.sorted() where sessionSpans[sessionID] == nil {
            guard let kind = desired[sessionID] else { continue }
            let taskID = taskID(forSession: sessionID)
            do {
                let id = try activityLog.open(kind: kind, sessionID: sessionID, taskID: taskID, at: now)
                sessionSpans[sessionID] = OpenSpan(id: id, kind: kind, taskID: taskID)
            } catch {
                logger.error("span open failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func syncYouSpan(now: Date) {
        guard !spansSuspended else { return }
        let inTool = frontmostBundleID.map(KnownApps.isTerminalOrEditor) ?? false
        let desired = inTool && !presenceTracker.isAway ? currentTask?.id : nil
        if let open = youSpan {
            if open.taskID == desired { return }
            attempt { try activityLog.close(id: open.id, at: now) }
            youSpan = nil
        }
        guard let desired else { return }
        do {
            let id = try activityLog.open(kind: .you, sessionID: nil, taskID: desired, at: now)
            youSpan = OpenSpan(id: id, kind: .you, taskID: desired)
        } catch {
            logger.error("span open failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func closeResolvedOverload(now: Date) {
        guard case let .overload(sessionID) = card else { return }
        let gone = !hubRows.contains { $0.id == sessionID }
        guard gone || OverloadPolicy.evaluate(rows: hubRows, limit: settings.maxParallelSessions) == nil else { return }
        closeCard(reacted: false, now: now)
        presentPendingReturned(now: now)
    }

    private func presentOverloadIfNeeded(newLiveIDs: [String], now: Date) {
        guard let newest = newLiveIDs.last(where: { id in hubRows.contains { $0.id == id } }),
              OverloadPolicy.evaluate(rows: hubRows, limit: settings.maxParallelSessions) != nil else { return }
        present(.overload(newSessionID: newest), now: now)
    }

    private func evaluateFreeSlot(rows: [HubRow], now: Date) {
        let active = rows.filter { !$0.group.isSettled }.count
        if active >= settings.maxParallelSessions {
            slotArmed = true
            return
        }
        guard slotArmed else { return }
        guard let parked = rows.first(where: { $0.group == .parked }) else {
            slotArmed = false
            return
        }
        guard toast == nil else { return }
        slotArmed = false
        toast = Self.slotToast(projectName: parked.projectName ?? parked.title)
        toastShownAt = now
    }

    private func presentDayStartIfDue(now: Date) {
        guard settings.dayStartEnabled else { return }
        let key = DayPlanStore.dayKey(now)
        guard dayStartShownDay != key else { return }
        let plan = try? dayPlans.plan(day: key)
        if plan?.dayStartShownAt != nil {
            dayStartShownDay = key
            return
        }
        guard DayStartPolicy.shouldShow(enabled: true, plan: plan, now: now, calendar: .current),
              canPresent(.dayStart) else { return }
        attempt { try dayPlans.markDayStartShown(day: key, at: now) }
        dayStartShownDay = key
        workRevision += 1
        present(.dayStart, now: now)
    }

    private func startDay(taskIDs: [String], now: Date) {
        attempt { try dayPlans.setFocusTasks(taskIDs, day: DayPlanStore.dayKey(now)) }
        workRevision += 1
        for taskID in taskIDs {
            guard let task = board.task(id: taskID), task.boardColumn != .inProgress else { continue }
            attempt { try boardService.moveTask(id: taskID, to: .inProgress, beforeTaskID: nil, now: now) }
        }
        reload()
        closeCard(reacted: true, now: now)
        guard let firstID = taskIDs.first, let first = board.task(id: firstID) else { return }
        let live = latestSessions
            .filter { !$0.isSessionEnded && taskID(forSession: $0.id) == firstID }
            .max { $0.updatedAt < $1.updatedAt }
        if let live {
            requestJump(sessionID: live.id, now: now)
            return
        }
        let cwd = first.projectPath ?? FileManager.default.homeDirectoryForCurrentUser.path
        do {
            try launcher.run(command: ResumeCommand.newSession(cwd: cwd), in: settings.resumeTerminal)
        } catch {
            logger.error("terminal launch failed: \(String(describing: error), privacy: .public)")
        }
    }

    private var cardSessionID: String? {
        switch card {
        case let .nextAction(triggering, _): triggering
        case let .returned(sessionID), let .reEntry(sessionID): sessionID
        case let .overload(newSessionID): newSessionID
        default: nil
        }
    }

    private var parkedSessionIDs: Set<String> {
        Set(liveRecords.filter { $0.parkedAt != nil || $0.doneAt != nil }.map(\.id))
    }

    private func projectName(sessionID: String) -> String? {
        if let name = record(sessionID)?.projectName, !name.isEmpty {
            return name
        }
        return SessionHistory.projectName(for: sessionCWD(sessionID))
    }

    private func shouldPresentReturned(sessionID: String, focusTaskID: String?) -> Bool {
        if queuedPrompt(sessionID: sessionID) != nil {
            return true
        }
        guard let taskID = taskID(forSession: sessionID) else { return false }
        return taskID == focusTaskID
    }

    private var cardIsDeferredReturned: Bool {
        guard case let .returned(sessionID) = card else { return false }
        return deferredReturnedSessionIDs.contains(sessionID)
    }

    private func canPresent(_ new: FocusCard) -> Bool {
        cardIsDeferredReturned || FocusCard.canReplace(card, with: new)
    }

    @discardableResult
    private func present(_ new: FocusCard, now: Date, showsOverlay: Bool = true) -> Bool {
        guard canPresent(new) else {
            queueBehindPomodoroCard(new)
            return false
        }
        if case let .returned(displaced) = card, card != new, !pendingReturnedSessionIDs.contains(displaced) {
            pendingReturnedSessionIDs.insert(displaced, at: 0)
        }
        if let displaced = card, displaced.pomodoroID != nil, displaced != new, new.pomodoroID == nil, pendingPomodoroCard == nil {
            pendingPomodoroCard = displaced
        }
        card = new
        if new == .onboarding {
            defaults.set(true, forKey: Self.onboardingPresentedKey)
        }
        if case let .pomodoroEnd(pomodoroID) = new {
            startBreakCountdownIfFresh(pomodoroID: pomodoroID, now: now)
        }
        if new == .nudge {
            nudgeSessionIDState = nudgeSessionID()
            nudgeSuggestionState = nudgeSuggestion(now: now)
        }
        if case let .returned(sessionID) = new {
            pendingReturnedSessionIDs.removeAll { $0 == sessionID }
        }
        if case let .nextAction(triggering, _) = new {
            nextActionShownAt = now
            refreshAlternatives(triggering: triggering)
            loadChangedFiles(sessionID: triggering, now: now)
        } else {
            nextActionShownAt = nil
            clearAlternatives()
        }
        if showsOverlay {
            presentCard?()
        }
        return true
    }

    private func queueBehindPomodoroCard(_ new: FocusCard) {
        guard card?.pomodoroID != nil else { return }
        switch new {
        case .overload, .dayStart:
            queuedCards.removeAll { Self.sameKind($0, new) }
            queuedCards.append(new)
        default:
            break
        }
    }

    private static func sameKind(_ lhs: FocusCard, _ rhs: FocusCard) -> Bool {
        switch (lhs, rhs) {
        case (.overload, .overload), (.dayStart, .dayStart): true
        default: false
        }
    }

    private func presentQueuedCards(now: Date) {
        guard !queuedCards.isEmpty, card == nil else { return }
        queuedCards.removeAll { queued in
            guard case let .overload(sessionID) = queued else { return false }
            return !hubRows.contains { $0.id == sessionID } || OverloadPolicy.evaluate(rows: hubRows, limit: settings.maxParallelSessions) == nil
        }
        guard let next = queuedCards.max(by: { $0.priority < $1.priority }) else { return }
        queuedCards.removeAll { $0 == next }
        present(next, now: now)
    }

    private func presentNextAction(for triggering: String, now: Date) -> Bool {
        guard canPresent(.nextAction(triggeringSessionID: triggering, eventID: nil)) else { return false }
        let eventID = try? nextActionLog.shown(kind: "nextAction", at: now)
        return present(.nextAction(triggeringSessionID: triggering, eventID: eventID), now: now)
    }

    private func refreshAlternatives(triggering: String) {
        let result = computeAlternatives(triggering: triggering, limit: 2)
        if result != alternatives {
            alternatives = result
        }
    }

    private func computeAlternatives(triggering: String, limit: Int) -> [NextAlternative] {
        let bindings = Dictionary(uniqueKeysWithValues: liveRecords.compactMap { record in record.taskId.map { (record.id, $0) } })
        let input = NextActionInput(
            triggeringSessionID: triggering,
            sessions: latestSessions,
            unseenCompletedSessionIDs: unseenCompleted,
            board: board,
            sessionTaskBindings: bindings,
            skippedTaskIDs: []
        )
        return NextActionEngine.alternatives(input, triggerCWD: sessionCWD(triggering), parked: parkedSessionIDs, limit: limit)
    }

    private func loadChangedFiles(sessionID: String, now: Date) {
        guard let cwd = sessionCWD(sessionID) else { return }
        if let fetchedAt = changedFilesFetchedAt[sessionID],
           now >= fetchedAt,
           now.timeIntervalSince(fetchedAt) < Self.changedFilesCacheLifetime {
            return
        }
        changedFilesFetchedAt[sessionID] = now
        let gitDiff = gitDiff
        changedFilesTask = Task { [weak self] in
            let files = await gitDiff.changedFiles(cwd: cwd)
            guard let self, self.liveSessionIDs.contains(sessionID) else { return }
            self.changedFiles[sessionID] = files
        }
    }

    private func refreshHub(now: Date) {
        let rows = currentHubRows(now: now)
        if rows != hubRows {
            hubRows = rows
        }
        let badge = Self.stalledBadge(rows: rows, now: now)
        if badge != stalledBadge {
            stalledBadge = badge
        }
        let minutes = currentTask.flatMap { task in
            rows.first { $0.taskID == task.id && $0.group == .running }
                .flatMap { turnElapsed(sessionID: $0.id, now: now) }
        }.map { Int($0 / 60) }
        if minutes != focusElapsedMinutes {
            focusElapsedMinutes = minutes
        }
        let outside = currentTask.map { task in
            StalledPolicy.stalled(rows: rows, reminderMinutes: settings.stalledReminderMinutes, now: now).filter { $0.taskID != task.id }
        } ?? []
        if outside != waitingOutside {
            waitingOutside = outside
        }
        evaluateFreeSlot(rows: rows, now: now)
    }

    private func markCardReacted(now: Date) {
        if case let .nextAction(_, eventID?) = card {
            attempt { try nextActionLog.reacted(id: eventID, at: now) }
        }
    }

    private func closeCard(reacted: Bool, now: Date) {
        if reacted {
            markCardReacted(now: now)
        }
        if case let .returned(sessionID) = card {
            deferredReturnedSessionIDs.remove(sessionID)
        }
        if case .pomodoroEnd = card {
            breakCountdownEndsAt = nil
            breakMinutesChoice = nil
        }
        card = nil
        nextActionShownAt = nil
        clearAlternatives()
    }

    private func clearAlternatives() {
        if !alternatives.isEmpty {
            alternatives = []
        }
    }

    private func isReturnedStillRelevant(_ sessionID: String) -> Bool {
        guard let session = session(sessionID), session.phase == .completed, !session.isSessionEnded else { return false }
        return unseenCompleted.contains(sessionID) && !parkedSessionIDs.contains(sessionID)
    }

    private func closeResolvedReturned(now: Date) {
        guard case let .returned(sessionID) = card, !isReturnedStillRelevant(sessionID) else { return }
        closeCard(reacted: false, now: now)
        presentPendingReturned(now: now)
    }

    private func presentPendingReturned(now: Date) {
        pendingReturnedSessionIDs.removeAll { !isReturnedStillRelevant($0) }
        var kept = Set(pendingReturnedSessionIDs)
        if case let .returned(shown) = card {
            kept.insert(shown)
        }
        deferredReturnedSessionIDs.formIntersection(kept)
        if let fresh = pendingReturnedSessionIDs.first(where: { !deferredReturnedSessionIDs.contains($0) }) {
            if let card, !cardIsDeferredReturned, card.priority >= FocusCard.returned(sessionID: fresh).priority { return }
            present(.returned(sessionID: fresh), now: now)
            return
        }
        guard card == nil, let deferred = pendingReturnedSessionIDs.first else { return }
        present(.returned(sessionID: deferred), now: now, showsOverlay: false)
    }

    private func reload() {
        if let snapshot = try? boardService.snapshot() {
            board = snapshot
        }
        reloadLiveRecords()
        refreshTaskAggregates()
    }

    private func reloadLiveRecords() {
        liveRecords = (try? history.liveSessions()) ?? []
    }

    private func refreshTaskAggregates() {
        let bound = (try? history.boundSessions(doneSince: Date.now.addingTimeInterval(-Self.boundSessionsDoneWindow))) ?? []
        let progress = (try? criteriaService.allProgress()) ?? [:]
        let pending = (try? promptQueue.pendingSessionIDs()) ?? []
        var result: [String: TaskAggregate] = [:]
        for record in bound {
            guard let taskID = record.taskId else { continue }
            result[taskID, default: TaskAggregate()].records.append(record)
            if pending.contains(record.id) {
                result[taskID, default: TaskAggregate()].sessionIDsWithQueuedPrompt.insert(record.id)
            }
        }
        for (taskID, value) in progress where value.total > 0 {
            result[taskID, default: TaskAggregate()].criteria = value
        }
        if result != taskAggregates {
            taskAggregates = result
        }
    }

    private func attempt(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            logger.error("focus operation failed: \(String(describing: error), privacy: .public)")
        }
    }
}

struct TodaySummary: Equatable, Sendable {
    let focusSeconds: TimeInterval
    let distractionSeconds: TimeInterval
    var pomodoroCount: Int = 0
}

struct PomodoroSnapshot: Equatable, Sendable {
    let id: String
    let taskID: String?
    let taskTitle: String?
    let phase: PomodoroPhase
    let plannedSeconds: Int
    let remainingSeconds: Int
    let progress: Double
    let isPaused: Bool
    let cycleIndex: Int
    let cycle: Int
}

struct BindableSession: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let projectName: String?
    let boundTaskTitle: String?
    let isSameProject: Bool
    let defaultSelected: Bool
    var isBound = false
}

struct DoneSessionNotice: Equatable, Sendable {
    let sessionID: String
    let title: String
}

struct SessionLabel: Equatable, Sendable {
    var title: String?
    var status: String?
}

struct ClosedTaskNotice: Equatable, Sendable {
    let taskID: String
    let title: String
    var wasFocused = true
}

struct PomodoroSummary: Equatable, Sendable {
    let pomodoroID: String
    let taskID: String?
    let taskTitle: String
    let plannedMinutes: Int
    let nextFocusMinutes: Int
    let cycleIndex: Int
    let cycle: Int
    let youInTaskSeconds: TimeInterval
    let claudeSeconds: TimeInterval
    let distractionSeconds: TimeInterval
    let distractionCount: Int
    let returnedCount: Int
    let finishedSessionTitles: [String]
    let checkedCriteria: [String]
}

struct BreakSummary: Equatable, Sendable {
    let pomodoroID: String
    let taskID: String?
    let taskTitle: String
    let note: String?
    let plannedMinutes: Int
    let finishedSessionTitles: [String]
}

enum PickTaskOpenResult: Equatable, Sendable {
    case presented
    case openedBoard
    case blocked
}

struct PickTaskOption: Equatable, Identifiable, Sendable {
    let taskID: String
    let title: String
    let projectName: String?
    let liveSessionCount: Int
    let sessionStateText: String

    var id: String { taskID }
    var hasLiveSessions: Bool { liveSessionCount > 0 }
}

struct PickTaskOptions: Equatable, Sendable {
    let inProgress: [PickTaskOption]
    let todo: [PickTaskOption]
}

enum TakeTaskResult: Equatable, Sendable {
    case focused
    case needsBinding
}
