import AppKit
import FocusCore
import Foundation
import Observation
import OpenIslandCore
import SwiftUI

extension Notification.Name {
    /// Posted by `AppModel.showOnboarding()` to ask `SettingsView` to
    /// switch to the Setup tab. Lets the empty-state CTAs deliver the
    /// user to the right place without `SettingsView`'s `@State` having
    /// to leak into `AppModel`.
    static let openIslandSelectSetupTab = Notification.Name("openIslandSelectSetupTab")
}

@MainActor
@Observable
final class AppModel {
    private static let soundMutedDefaultsKey = "overlay.sound.muted"
    private static let showDockIconDefaultsKey = "app.showDockIcon"
    private static let hapticFeedbackEnabledDefaultsKey = "app.hapticFeedbackEnabled"
    /// When true, click-outside does not dismiss the notch while any session
    /// is waiting for approval or an answer (#547).
    private static let keepNotchOpenUntilDecisionDefaultsKey = "app.keepNotchOpenUntilDecision"
    private static let islandRightSlotDefaultsKey = "appearance.island.v6.rightSlot"
    private static let islandCenterLabelDefaultsKey = "appearance.island.v6.centerLabel"
    private static let completionReplyEnabledDefaultsKey = "feature.completionReply.enabled"
    private static let suppressFrontmostNotificationsDefaultsKey = "app.suppressFrontmostNotifications"
    private static let legacyIslandSessionStateIndicatorDefaultsKey = "appearance.island.v8.stateIndicator"
    private static let legacyIslandSessionGroupDefaultsKey = "appearance.island.v8.sessionGroup"
    private static let legacyIslandSessionSortDefaultsKey = "appearance.island.v8.sessionSort"
    private static let legacyCompletedStaleThresholdDefaultsKey = "appearance.island.v8.completedStaleThreshold"
    private static let appearanceProfileSettingsDefaultsKey = "appearance.island.v8.settingsProfile"

    private static let liveSessionStalenessWindow: TimeInterval = 15 * 60
    private static let jumpOverlayDismissLeadTime: Duration = .milliseconds(20)
    private static let agentsGridObservedSequenceLimit = 512
    static let hoverOpenDelay: TimeInterval = 0.15

    struct AcceptanceStep: Identifiable {
        let id: String
        let title: String
        let detail: String
        let isComplete: Bool
    }

    let lang = LanguageManager.shared

    var state = SessionState() {
        didSet {
            _cachedSessionBuckets = nil
            pruneAgentsGridObservationTicketsIfNeeded()
            bridgeServer.updateStateSnapshot(state)
            focus.sessionsDidChange(state.sessions)
        }
    }
    @ObservationIgnored private var _cachedSessionBuckets: (primary: [AgentSession], overflow: [AgentSession])?

    /// Monotonic ticket assigned the first time a session ID shows up in the
    /// closed-island's right-slot surfaced set. Drives the grid's display
    /// order: newly-surfaced sessions always land at the end, and a session
    /// that briefly leaves (e.g. attachment flip) keeps its old slot when it
    /// returns. Persists for the process lifetime; session IDs are UUIDs so
    /// accumulation over time is bounded in practice.
    @ObservationIgnored private var _agentsGridObservedSequence: [String: Int] = [:]
    @ObservationIgnored private var _agentsGridNextTicket: Int = 0
    var selectedSessionID: String?
    let hooks = HookInstallationCoordinator()
    let focus: FocusCoordinator
    let overlay = OverlayUICoordinator()
    let discovery: SessionDiscoveryCoordinator
    let monitoring = ProcessMonitoringCoordinator()

    var notchStatus: NotchStatus {
        get { overlay.notchStatus }
        set { overlay.notchStatus = newValue }
    }
    var notchOpenReason: NotchOpenReason? {
        get { overlay.notchOpenReason }
        set { overlay.notchOpenReason = newValue }
    }
    var islandSurface: IslandSurface {
        get { overlay.islandSurface }
        set { overlay.islandSurface = newValue }
    }
    var isOverlayVisible: Bool { overlay.isOverlayVisible }
    var isOverlayCloseTransitionPending: Bool { overlay.isCloseTransitionPending }
    var isClaudeHookSetupBusy: Bool { hooks.isClaudeHookSetupBusy }
    var isClaudeUsageSetupBusy: Bool { hooks.isClaudeUsageSetupBusy }
    var claudeHookStatus: ClaudeHookInstallationStatus? { hooks.claudeHookStatus }
    var claudeStatusLineStatus: ClaudeStatusLineInstallationStatus? { hooks.claudeStatusLineStatus }
    var claudeUsageSnapshot: ClaudeUsageSnapshot? { hooks.claudeUsageSnapshot }
    var hooksBinaryURL: URL? { hooks.hooksBinaryURL }
    var claudeHooksInstalled: Bool { hooks.claudeHooksInstalled }
    var claudeUsageInstalled: Bool { hooks.claudeUsageInstalled }
    var claudeStatusLineProvidedByOtherIsland: Bool { hooks.claudeStatusLineProvidedByOtherIsland }
    var claudeHookStatusTitle: String { hooks.claudeHookStatusTitle }
    var claudeHookStatusSummary: String { hooks.claudeHookStatusSummary }
    var claudeUsageStatusTitle: String { hooks.claudeUsageStatusTitle }
    var claudeUsageStatusSummary: String { hooks.claudeUsageStatusSummary }
    var claudeUsageSummaryText: String? { hooks.claudeUsageSummaryText }
    var healthReports: [HookHealthReport] { hooks.healthReports }

    /// Mirrors `AgentIntentStore.firstLaunchCompleted`. Onboarding sets this
    /// to true after the user completes (or explicitly skips) the flow;
    /// legacy migration also flips it for users upgrading with existing
    /// hooks.
    var firstLaunchCompleted: Bool {
        get { hooks.intentStore.firstLaunchCompleted }
        set { hooks.intentStore.firstLaunchCompleted = newValue }
    }

    /// True if at least one managed hook is currently present on disk.
    /// Drives the "configure agents" empty-state prompts in the island and
    /// the settings window.
    var hasAnyInstalledAgent: Bool {
        hooks.claudeHooksInstalled
    }
    func refreshClaudeHookStatus() { hooks.refreshClaudeHookStatus() }
    func refreshClaudeUsageState() { hooks.refreshClaudeUsageState() }
    func installClaudeHooks() { hooks.installClaudeHooks() }
    func uninstallClaudeHooks() { hooks.uninstallClaudeHooks() }
    func installClaudeUsageBridge() { hooks.installClaudeUsageBridge() }
    func uninstallClaudeUsageBridge() { hooks.uninstallClaudeUsageBridge() }
    func updateClaudeConfigDirectory(to newDirectory: URL?) { hooks.updateClaudeConfigDirectory(to: newDirectory) }
    func runHealthChecks() { hooks.runHealthChecks() }
    func repairHooks() {
        Task { @MainActor in
            await hooks.repairHooksIfNeeded()
        }
    }
    var isBridgeReady = false
    var lastActionMessage = "Waiting for agent hook events..." {
        didSet {
            guard lastActionMessage != oldValue else {
                return
            }

            harnessRuntimeMonitor?.recordLog(lastActionMessage)
        }
    }
    var isResolvingInitialLiveSessions: Bool {
        get { monitoring.isResolvingInitialLiveSessions }
        set { monitoring.isResolvingInitialLiveSessions = newValue }
    }
    var overlayDisplayOptions: [OverlayDisplayOption] {
        get { overlay.overlayDisplayOptions }
        set { overlay.overlayDisplayOptions = newValue }
    }
    var overlayPlacementDiagnostics: OverlayPlacementDiagnostics? {
        get { overlay.overlayPlacementDiagnostics }
        set { overlay.overlayPlacementDiagnostics = newValue }
    }
    var showDockIcon: Bool = false {
        didSet {
            guard hasFinishedInit, showDockIcon != oldValue else { return }
            UserDefaults.standard.set(showDockIcon, forKey: Self.showDockIconDefaultsKey)
            NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
            if !showDockIcon {
                // macOS does not immediately refresh the Dock when switching to
                // .accessory at runtime. Briefly activating another app forces
                // the Dock to drop the icon.
                NSApp.hide(nil)
                DispatchQueue.main.async {
                    NSApp.unhide(nil)
                }
            }
        }
    }
    var hapticFeedbackEnabled: Bool = false {
        didSet {
            guard hasFinishedInit, hapticFeedbackEnabled != oldValue else { return }
            UserDefaults.standard.set(hapticFeedbackEnabled, forKey: Self.hapticFeedbackEnabledDefaultsKey)
        }
    }
    /// Keep the island open until the user acts on a pending approval /
    /// question surface (Settings → General). Opt-in: permission and
    /// question cards never auto-collapse, so with this on the only way to
    /// get rid of one is to answer it — clicking into the terminal to type
    /// the answer no longer dismisses the card.
    var keepNotchOpenUntilDecision: Bool = false {
        didSet {
            guard hasFinishedInit, keepNotchOpenUntilDecision != oldValue else { return }
            UserDefaults.standard.set(keepNotchOpenUntilDecision, forKey: Self.keepNotchOpenUntilDecisionDefaultsKey)
        }
    }
    var completionReplyEnabled: Bool = false {
        didSet {
            guard hasFinishedInit, completionReplyEnabled != oldValue else { return }
            UserDefaults.standard.set(completionReplyEnabled, forKey: Self.completionReplyEnabledDefaultsKey)
            refreshOverlayPlacementIfVisible()
        }
    }
    var suppressFrontmostNotifications: Bool = true {
        didSet {
            guard hasFinishedInit, suppressFrontmostNotifications != oldValue else { return }
            UserDefaults.standard.set(suppressFrontmostNotifications, forKey: Self.suppressFrontmostNotificationsDefaultsKey)
        }
    }
    var launchAtLoginEnabled: Bool = false {
        didSet {
            guard !isApplyingLaunchAtLogin, hasFinishedInit, launchAtLoginEnabled != oldValue else { return }
            do {
                try LaunchAtLoginService.shared.setEnabled(launchAtLoginEnabled)
            } catch {
                isApplyingLaunchAtLogin = true
                launchAtLoginEnabled = oldValue
                isApplyingLaunchAtLogin = false
                presentLaunchAtLoginError(error)
            }
        }
    }
    private func presentLaunchAtLoginError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = lang.t("settings.general.launchAtLogin")
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
    @ObservationIgnored
    private var isApplyingLaunchAtLogin = false
    var isSoundMuted = false {
        didSet {
            guard isSoundMuted != oldValue else {
                return
            }

            UserDefaults.standard.set(isSoundMuted, forKey: Self.soundMutedDefaultsKey)
            lastActionMessage = isSoundMuted
                ? "Island sound notifications muted."
                : "Island sound notifications enabled."
        }
    }
    var selectedSoundName: String = NotificationSoundService.defaultSoundName {
        didSet {
            guard selectedSoundName != oldValue else { return }
            NotificationSoundService.selectedSoundName = selectedSoundName
        }
    }
    var overlayDisplaySelectionID: String {
        get { overlay.overlayDisplaySelectionID }
        set { overlay.overlayDisplaySelectionID = newValue }
    }

    // MARK: - Appearance

    var appearanceSettingsProfile: IslandAppearanceDisplayProfile = .topBar {
        didSet {
            guard appearanceSettingsProfile != oldValue else { return }
            UserDefaults.standard.set(appearanceSettingsProfile.rawValue, forKey: Self.appearanceProfileSettingsDefaultsKey)
        }
    }

    private var notchAppearancePreferences = IslandAppearancePreferences() {
        didSet {
            guard notchAppearancePreferences != oldValue else { return }
            persistAppearancePreferences(notchAppearancePreferences, for: .notch)
            if activeAppearanceProfile == .notch { appearancePreferencesDidChange(oldValue: oldValue, newValue: notchAppearancePreferences) }
        }
    }

    private var topBarAppearancePreferences = IslandAppearancePreferences() {
        didSet {
            guard topBarAppearancePreferences != oldValue else { return }
            persistAppearancePreferences(topBarAppearancePreferences, for: .topBar)
            if activeAppearanceProfile == .topBar { appearancePreferencesDidChange(oldValue: oldValue, newValue: topBarAppearancePreferences) }
        }
    }

    /// Runtime profile selected from current overlay placement. External
    /// displays use the top-bar presentation; built-in notch displays keep
    /// notch-aware geometry and their own persisted appearance choices.
    var activeAppearanceProfile: IslandAppearanceDisplayProfile {
        overlayPlacementDiagnostics?.mode == .notch ? .notch : .topBar
    }

    var islandRightSlot: IslandRightSlot {
        get { appearancePreferences(for: activeAppearanceProfile).rightSlot }
        set { updateAppearancePreferences(for: activeAppearanceProfile) { $0.rightSlot = newValue } }
    }

    var islandCenterLabel: IslandCenterLabel {
        get { appearancePreferences(for: activeAppearanceProfile).centerLabel }
        set { updateAppearancePreferences(for: activeAppearanceProfile) { $0.centerLabel = newValue } }
    }

    var islandUsageDisplay: IslandUsageDisplay {
        get { appearancePreferences(for: activeAppearanceProfile).usageDisplay }
        set { updateAppearancePreferences(for: activeAppearanceProfile) { $0.usageDisplay = newValue } }
    }

    var islandSessionStateIndicator: IslandSessionStateIndicator {
        get { appearancePreferences(for: activeAppearanceProfile).sessionStateIndicator }
        set { updateAppearancePreferences(for: activeAppearanceProfile) { $0.sessionStateIndicator = newValue } }
    }

    var islandSessionGroup: IslandSessionGroup {
        get { appearancePreferences(for: activeAppearanceProfile).sessionGroup }
        set { updateAppearancePreferences(for: activeAppearanceProfile) { $0.sessionGroup = newValue } }
    }

    var islandSessionSort: IslandSessionSort {
        get { appearancePreferences(for: activeAppearanceProfile).sessionSort }
        set { updateAppearancePreferences(for: activeAppearanceProfile) { $0.sessionSort = newValue } }
    }

    var completedStaleThreshold: IslandCompletedStaleThreshold {
        get { appearancePreferences(for: activeAppearanceProfile).completedStaleThreshold }
        set { updateAppearancePreferences(for: activeAppearanceProfile) { $0.completedStaleThreshold = newValue } }
    }

    @ObservationIgnored
    var openSettingsWindow: (() -> Void)?

    @ObservationIgnored
    private var hasFinishedInit = false

    func appearancePreferences(for profile: IslandAppearanceDisplayProfile) -> IslandAppearancePreferences {
        switch profile {
        case .notch: notchAppearancePreferences
        case .topBar: topBarAppearancePreferences
        }
    }

    func updateAppearancePreferences(
        for profile: IslandAppearanceDisplayProfile,
        _ update: (inout IslandAppearancePreferences) -> Void
    ) {
        switch profile {
        case .notch:
            update(&notchAppearancePreferences)
        case .topBar:
            update(&topBarAppearancePreferences)
        }
    }

    private func appearancePreferencesDidChange(
        oldValue: IslandAppearancePreferences,
        newValue: IslandAppearancePreferences
    ) {
        if oldValue.sessionGroup != newValue.sessionGroup ||
            oldValue.sessionSort != newValue.sessionSort ||
            oldValue.completedStaleThreshold != newValue.completedStaleThreshold {
            _cachedSessionBuckets = nil
        }
        refreshOverlayPlacementIfVisible()
    }

    private func persistAppearancePreferences(
        _ preferences: IslandAppearancePreferences,
        for profile: IslandAppearanceDisplayProfile
    ) {
        let defaults = UserDefaults.standard
        defaults.set(preferences.rightSlot.rawValue, forKey: Self.appearanceDefaultsKey(profile, "rightSlot"))
        defaults.set(preferences.centerLabel.rawValue, forKey: Self.appearanceDefaultsKey(profile, "centerLabel"))
        defaults.set(preferences.usageDisplay.rawValue, forKey: Self.appearanceDefaultsKey(profile, "usageDisplay"))
        defaults.set(preferences.sessionStateIndicator.rawValue, forKey: Self.appearanceDefaultsKey(profile, "stateIndicator"))
        defaults.set(preferences.sessionGroup.rawValue, forKey: Self.appearanceDefaultsKey(profile, "sessionGroup"))
        defaults.set(preferences.sessionSort.rawValue, forKey: Self.appearanceDefaultsKey(profile, "sessionSort"))
        defaults.set(preferences.completedStaleThreshold.rawValue, forKey: Self.appearanceDefaultsKey(profile, "completedStaleThreshold"))
    }

    var ignoresPointerExitDuringHarness = false
    var disablesOverlayEventMonitoringDuringHarness = false

    @ObservationIgnored
    private var bridgeTask: Task<Void, Never>?

    @ObservationIgnored
    private var bridgeReconnectTask: Task<Void, Never>?

    @ObservationIgnored
    private var hasStarted = false

    @ObservationIgnored
    private let bridgeServer = BridgeServer()

    @ObservationIgnored
    private var bridgeClient = LocalBridgeClient()

    @ObservationIgnored
    private let terminalJumpAction: @Sendable (JumpTarget) throws -> String

    @ObservationIgnored
    private let isNotificationSessionAlreadyFrontmost: @Sendable (AgentSession) async -> Bool


    @ObservationIgnored
    var harnessRuntimeMonitor: HarnessRuntimeMonitor? {
        didSet {
            overlay.harnessRuntimeMonitor = harnessRuntimeMonitor
        }
    }


    @ObservationIgnored
    private var jumpTask: Task<Void, Never>?

    @ObservationIgnored
    private var notificationPresentationTask: Task<Void, Never>?

    @ObservationIgnored
    private var frontmostMonitor: FrontmostAppMonitor?

    @ObservationIgnored
    private var boardHotKey: GlobalHotKey?

    @ObservationIgnored
    private var openBoardObserver: NSObjectProtocol?

    @ObservationIgnored
    private var focusLifecycleObservers: [(NotificationCenter, NSObjectProtocol)] = []

    @ObservationIgnored
    private var focusHookStateReady = false

    private static func appearanceDefaultsKey(_ profile: IslandAppearanceDisplayProfile, _ name: String) -> String {
        "appearance.island.v8.\(profile.rawValue).\(name)"
    }

    private static func loadAppearancePreferences(for profile: IslandAppearanceDisplayProfile) -> IslandAppearancePreferences {
        let defaults = UserDefaults.standard
        return IslandAppearancePreferences(
            rightSlot: IslandRightSlot(
                rawValue: defaults.string(forKey: appearanceDefaultsKey(profile, "rightSlot"))
                    ?? defaults.string(forKey: islandRightSlotDefaultsKey)
                    ?? ""
            ) ?? .currentTask,
            centerLabel: IslandCenterLabel(
                rawValue: defaults.string(forKey: appearanceDefaultsKey(profile, "centerLabel"))
                    ?? defaults.string(forKey: islandCenterLabelDefaultsKey)
                    ?? ""
            ) ?? .agentAction,
            usageDisplay: IslandUsageDisplay(
                rawValue: defaults.string(forKey: appearanceDefaultsKey(profile, "usageDisplay"))
                    ?? ""
            ) ?? .compact,
            sessionStateIndicator: IslandSessionStateIndicator(
                rawValue: defaults.string(forKey: appearanceDefaultsKey(profile, "stateIndicator"))
                    ?? defaults.string(forKey: legacyIslandSessionStateIndicatorDefaultsKey)
                    ?? ""
            ) ?? .animatedDot,
            sessionGroup: IslandSessionGroup(
                rawValue: defaults.string(forKey: appearanceDefaultsKey(profile, "sessionGroup"))
                    ?? defaults.string(forKey: legacyIslandSessionGroupDefaultsKey)
                    ?? ""
            ) ?? .none,
            sessionSort: IslandSessionSort(
                rawValue: defaults.string(forKey: appearanceDefaultsKey(profile, "sessionSort"))
                    ?? defaults.string(forKey: legacyIslandSessionSortDefaultsKey)
                    ?? ""
            ) ?? .attention,
            completedStaleThreshold: IslandCompletedStaleThreshold(
                rawValue: defaults.string(forKey: appearanceDefaultsKey(profile, "completedStaleThreshold"))
                    ?? defaults.string(forKey: legacyCompletedStaleThresholdDefaultsKey)
                    ?? ""
            ) ?? .fiveMinutes
        )
    }

    init(
        terminalJumpAction: @escaping @Sendable (JumpTarget) throws -> String = { target in
            try TerminalJumpService().jump(to: target)
        },
        isNotificationSessionAlreadyFrontmost: @escaping @Sendable (AgentSession) async -> Bool = { session in
            await ForegroundTerminalSessionProbe().matches(session: session)
        },
        focusStore: FocusStore? = nil,
        claudeRegistry: ClaudeSessionRegistry? = nil
    ) {
        self.discovery = SessionDiscoveryCoordinator(claudeSessionRegistry: claudeRegistry ?? ClaudeSessionRegistry())
        self.terminalJumpAction = terminalJumpAction
        self.isNotificationSessionAlreadyFrontmost = isNotificationSessionAlreadyFrontmost
        let openResult = focusStore.map { FocusStoreOpenResult(store: $0, outcome: .normal) } ?? FocusStore.openWithRecovery(fileURL: FocusStore.defaultFileURL)
        self.focus = FocusCoordinator(store: openResult.store, storeOutcome: openResult.outcome, launcher: AppleScriptTerminalLauncher())
        UserDefaults.standard.register(defaults: [
            Self.showDockIconDefaultsKey: true,
            Self.hapticFeedbackEnabledDefaultsKey: false,
            Self.keepNotchOpenUntilDecisionDefaultsKey: false,
            Self.completionReplyEnabledDefaultsKey: false,
            Self.suppressFrontmostNotificationsDefaultsKey: true,
        ])
        isSoundMuted = UserDefaults.standard.bool(forKey: Self.soundMutedDefaultsKey)
        selectedSoundName = NotificationSoundService.selectedSoundName
        showDockIcon = UserDefaults.standard.bool(forKey: Self.showDockIconDefaultsKey)
        hapticFeedbackEnabled = UserDefaults.standard.bool(forKey: Self.hapticFeedbackEnabledDefaultsKey)
        keepNotchOpenUntilDecision = UserDefaults.standard.bool(forKey: Self.keepNotchOpenUntilDecisionDefaultsKey)
        suppressFrontmostNotifications = UserDefaults.standard.bool(forKey: Self.suppressFrontmostNotificationsDefaultsKey)
        completionReplyEnabled = UserDefaults.standard.bool(forKey: Self.completionReplyEnabledDefaultsKey)
        launchAtLoginEnabled = LaunchAtLoginService.shared.isEnabled
        appearanceSettingsProfile = IslandAppearanceDisplayProfile(
            rawValue: UserDefaults.standard.string(forKey: Self.appearanceProfileSettingsDefaultsKey) ?? ""
        ) ?? .topBar
        notchAppearancePreferences = Self.loadAppearancePreferences(for: .notch)
        topBarAppearancePreferences = Self.loadAppearancePreferences(for: .topBar)

        overlay.appModel = self
        overlay.restoreDisplayPreference()
        overlay.startObservingDisplayChanges()
        overlay.onStatusMessage = { [weak self] message in
            self?.lastActionMessage = message
        }
        overlay.activeIslandCardSessionAccessor = { [weak self] in
            self?.activeIslandCardSession
        }
        overlay.isSoundMutedAccessor = { [weak self] in
            self?.isSoundMuted ?? false
        }
        overlay.ignoresPointerExitAccessor = { [weak self] in
            self?.ignoresPointerExitDuringHarness ?? false
        }

        hooks.onStatusMessage = { [weak self] message in
            self?.lastActionMessage = message
        }
        hooks.onClaudeHookStatusChanged = { [weak self] in
            guard let self else { return }
            let installed = self.hooks.claudeHooksInstalled
            guard installed || self.focusHookStateReady else { return }
            self.focus.setHooksInstalled(installed)
        }

        discovery.onStatusMessage = { [weak self] message in
            self?.lastActionMessage = message
        }
        discovery.stateAccessor = { [weak self] in self?.state ?? SessionState() }
        discovery.stateUpdater = { [weak self] in self?.state = $0 }
        discovery.onStateChanged = { [weak self] in
            self?.synchronizeSelection()
            self?.refreshOverlayPlacementIfVisible()
        }
        monitoring.stateAccessor = { [weak self] in self?.state ?? SessionState() }
        monitoring.stateUpdater = { [weak self] in self?.state = $0 }
        monitoring.onSessionsReconciled = { [weak self] in
            self?.synchronizeSelection()
            self?.refreshOverlayPlacementIfVisible()
        }
        monitoring.onPersistenceNeeded = { [weak self] in
            self?.discovery.scheduleClaudeSessionPersistence()
        }
        focus.presentCard = { [weak self] in
            self?.notchOpen(reason: .notification, surface: .sessionList())
        }
        focus.jumpToSession = { [weak self] sessionID in
            guard let self, let session = self.state.session(id: sessionID) else { return }
            self.jumpToSession(session, marksSeen: false)
        }
        refreshOverlayDisplayConfiguration()
        hasFinishedInit = true
    }

    var sessions: [AgentSession] {
        state.sessions
    }

    var allSessions: [AgentSession] {
        state.sessions
    }

    /// Measured by SwiftUI GeometryReader in notification mode. Used by panel controller for sizing.
    /// Uses a tolerance of 2pt to avoid infinite layout loops caused by floating-point jitter
    /// in GeometryReader measurements across consecutive layout passes.
    var measuredNotificationContentHeight: CGFloat = 0 {
        didSet {
            let delta = abs(measuredNotificationContentHeight - oldValue)
            if delta >= 2, measuredNotificationContentHeight > 0 {
                overlay.refreshOverlayPlacementIfVisible()
            }
        }
    }

    var focusSectionHeight: CGFloat = 0 {
        didSet {
            if abs(focusSectionHeight - oldValue) > 0.5 {
                overlay.refreshOverlayPlacementIfVisible()
            }
        }
    }

    var surfacedSessions: [AgentSession] {
        sessionBuckets.primary
    }

    var recentSessions: [AgentSession] {
        sessionBuckets.overflow
    }

    var islandListSessions: [AgentSession] {
        islandSessionSections.flatMap(\.sessions)
    }

    var islandSessionSections: [IslandSessionSection] {
        let sessions = sortIslandSessions(surfacedSessions)
        switch islandSessionGroup {
        case .none:
            return [
                IslandSessionSection(
                    id: "all",
                    title: "island.section.sessions",
                    sessions: sessions
                )
            ]
        case .state:
            return stateGroupedSections(for: sessions)
        case .agent:
            return AgentTool.allCases.compactMap { tool in
                let list = sessions.filter { $0.tool == tool }
                guard !list.isEmpty else { return nil }
                return IslandSessionSection(id: "agent-\(tool.rawValue)", title: tool.displayName, sessions: list)
            }
        case .project:
            let names = Set(sessions.map(projectGroupName(for:))).sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
            return names.compactMap { name in
                let list = sessions.filter { projectGroupName(for: $0) == name }
                guard !list.isEmpty else { return nil }
                return IslandSessionSection(id: "project-\(name)", title: name, sessions: list)
            }
        }
    }

    var recentSessionCount: Int {
        recentSessions.count
    }

    var liveSessionCount: Int {
        surfacedSessions.count
    }

    var liveAttentionCount: Int {
        surfacedSessions.filter { $0.phase.requiresAttention }.count
    }

    var liveRunningCount: Int {
        surfacedSessions.filter { $0.phase == .running }.count
    }

    private func sortIslandSessions(_ sessions: [AgentSession]) -> [AgentSession] {
        switch islandSessionSort {
        case .attention:
            return sessions
        case .lastUpdate:
            return sessions.sorted { lhs, rhs in
                if lhs.islandActivityDate == rhs.islandActivityDate {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return lhs.islandActivityDate > rhs.islandActivityDate
            }
        }
    }

    private func stateGroupedSections(for sessions: [AgentSession]) -> [IslandSessionSection] {
        let definitions: [(id: String, title: String, include: (AgentSession) -> Bool)] = [
            ("approval", "island.section.needsApproval", { $0.phase == .waitingForApproval }),
            ("answer", "island.section.needsAnswer", { $0.phase == .waitingForAnswer }),
            ("running", "island.section.inProgress", { $0.phase == .running }),
            ("done", "island.section.justDone", { [completedStaleThreshold] session in
                session.phase == .completed
                    && !session.isStaleCompletedForIsland(at: .now, threshold: completedStaleThreshold.seconds)
            }),
            ("idle", "island.section.idle", { [completedStaleThreshold] session in
                session.phase == .completed
                    && session.isStaleCompletedForIsland(at: .now, threshold: completedStaleThreshold.seconds)
            }),
        ]

        return definitions.compactMap { definition in
            let list = sessions.filter(definition.include)
            guard !list.isEmpty else { return nil }
            return IslandSessionSection(id: "state-\(definition.id)", title: definition.title, sessions: list)
        }
    }

    private func projectGroupName(for session: AgentSession) -> String {
        if let workspace = session.jumpTarget?.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines),
           !workspace.isEmpty {
            return workspace
        }

        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return session.tool.displayName }

        let pieces = title.split(separator: "·", maxSplits: 1).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return pieces.last?.isEmpty == false ? pieces.last! : title
    }

    // MARK: - v6 closed-island derivation

    /// The aggregate UnifiedBars state for the closed island. Waiting beats
    /// running; everything else is idle. Completed sessions are absorbed
    /// directly into idle so the pill never stops on a tick glyph.
    var islandClosedMode: UnifiedBars.Mode {
        let sessions = surfacedSessions
        if sessions.contains(where: { $0.phase.requiresAttention }) { return .waiting }
        if sessions.contains(where: { $0.phase == .running })       { return .running }
        return .idle
    }

    /// The spotlight session powering the center label (if any). Attention
    /// sessions first, then the most recent running one, then whatever's
    /// first.
    var islandClosedSpotlight: AgentSession? {
        surfacedSessions.first(where: { $0.phase.requiresAttention })
            ?? surfacedSessions.first(where: { $0.phase == .running })
            ?? surfacedSessions.first
    }

    /// Text to show in the closed island's center label. Respects the
    /// `islandCenterLabel` user preference.
    func islandClosedLabel() -> String? {
        if islandCenterLabel == .currentTask {
            return focus.currentTask?.title
        }
        guard islandCenterLabel != .off,
              let session = islandClosedSpotlight else { return nil }

        switch islandCenterLabel {
        case .off:
            return nil
        case .currentTask:
            return nil
        case .sessionName:
            let workspace = session.jumpTarget?.workspaceName ?? ""
            if !workspace.isEmpty { return workspace }
            return session.title.isEmpty ? session.tool.displayName : session.title
        case .agentAction:
            let action = session.displayCurrentToolName
            if let action, !action.isEmpty {
                return "\(session.tool.displayName) · \(action)"
            }
            return session.tool.displayName
        }
    }

    func islandClosedLeftSlotContent() -> IslandLeftSlotContent? {
        FocusEars.leftSlot(preference: islandRightSlot, rows: focus.hubRows)
    }

    /// Right-slot payload derived from the user's `islandRightSlot`
    /// preference and current live state. Returns nil when the preference
    /// is `.none` or there's nothing meaningful to show.
    func islandClosedRightSlotContent() -> IslandRightSlotContent? {
        let sessions = surfacedSessions
        if let alert = FocusEars.alertOverride(
            preference: islandRightSlot,
            toast: focus.toast,
            stalled: focus.stalledBadge
        ) {
            return alert
        }
        switch islandRightSlot {
        case .none:
            return nil
        case .currentTask:
            let task = focus.currentTask
            return FocusEars.rightSlot(
                toast: nil,
                stalled: nil,
                taskTitle: task?.title,
                elapsedMinutes: focus.focusElapsedMinutes
            )
        case .count:
            let n = sessions.count
            guard n > 0 else { return nil }
            return .count(n)
        case .agents:
            // Display order = order-of-first-observation-in-the-island. A
            // session that later flips visibility (e.g. attachment churn,
            // completed↔running) keeps its existing slot instead of being
            // reshuffled by session.firstSeenAt, which tracks the historical
            // event time and can be older than visible peers. Bulk-observing
            // N sessions at once (e.g. at app launch) breaks the tie by
            // session.firstSeenAt so historical order is preserved.
            stampAgentsGridObservationTickets(for: sessions)
            let ordered = sessions.sorted { a, b in
                let ta = _agentsGridObservedSequence[a.id] ?? .max
                let tb = _agentsGridObservedSequence[b.id] ?? .max
                if ta != tb { return ta < tb }
                return a.id < b.id
            }
            var cells: [AgentGridCell] = []
            if ordered.count <= 9 {
                cells = ordered.map(Self.agentsGridCell(for:))
            } else {
                cells = ordered.prefix(7).map(Self.agentsGridCell(for:))
                cells.append(.overflow(ordered.count - 7))
            }
            return cells.isEmpty ? nil : .agents(cells)
        }
    }

    private func stampAgentsGridObservationTickets(for sessions: [AgentSession]) {
        let newcomers = sessions.filter { _agentsGridObservedSequence[$0.id] == nil }
        guard !newcomers.isEmpty else { return }
        let orderedNewcomers = newcomers.sorted { a, b in
            if a.firstSeenAt != b.firstSeenAt { return a.firstSeenAt < b.firstSeenAt }
            return a.id < b.id
        }
        for session in orderedNewcomers {
            _agentsGridObservedSequence[session.id] = _agentsGridNextTicket
            _agentsGridNextTicket += 1
        }
    }

    private func pruneAgentsGridObservationTicketsIfNeeded() {
        guard _agentsGridObservedSequence.count > Self.agentsGridObservedSequenceLimit else {
            return
        }

        let liveIDs = Set(state.sessions.map(\.id))
        let retainedHistoricalCapacity = max(Self.agentsGridObservedSequenceLimit - liveIDs.count, 0)
        let retainedHistoricalIDs = _agentsGridObservedSequence
            .filter { !liveIDs.contains($0.key) }
            .sorted { $0.value > $1.value }
            .prefix(retainedHistoricalCapacity)
            .map(\.key)
        let retainedIDs = liveIDs.union(retainedHistoricalIDs)
        _agentsGridObservedSequence = _agentsGridObservedSequence.filter {
            retainedIDs.contains($0.key)
        }
    }

    private static func agentsGridCell(for session: AgentSession) -> AgentGridCell {
        let color = Color(hex: session.tool.brandColorHex) ?? .gray
        let state: AgentGridCellState
        if session.phase.requiresAttention {
            state = .waiting
        } else if session.phase == .running {
            state = .running
        } else {
            state = .idle
        }
        return .session(color: color, state: state)
    }

    var shouldShowSessionBootstrapPlaceholder: Bool {
        isResolvingInitialLiveSessions
            && liveSessionCount == 0
            && state.sessions.contains(where: \.isTrackedLiveSession)
    }

    var focusedSession: AgentSession? {
        state.session(id: selectedSessionID) ?? surfacedSessions.first ?? state.activeActionableSession ?? state.sessions.first
    }

    var activeIslandCardSession: AgentSession? {
        guard let sessionID = islandSurface.sessionID else {
            return nil
        }

        return state.session(id: sessionID)
    }

    var hasAnySession: Bool {
        !sessions.isEmpty
    }

    var hasClaudeSession: Bool {
        sessions.contains(where: { $0.tool == .claudeCode })
    }

    var hasJumpableSession: Bool {
        sessions.contains(where: { $0.jumpTarget != nil })
    }

    var acceptanceSteps: [AcceptanceStep] {
        [
            AcceptanceStep(
                id: "bridge",
                title: "Bridge ready",
                detail: "The app must own the local socket and register as a bridge observer.",
                isComplete: isBridgeReady
            ),
            AcceptanceStep(
                id: "hooks",
                title: "Claude hooks installed",
                detail: "Managed hook entries should be present in Claude `settings.json`.",
                isComplete: hooks.claudeHooksInstalled
            ),
            AcceptanceStep(
                id: "overlay",
                title: "Island visible",
                detail: "Show the overlay at least once so the notch/top-bar surface is visible.",
                isComplete: isOverlayVisible
            ),
            AcceptanceStep(
                id: "session",
                title: "A Claude session is observed",
                detail: "Start Claude Code in Terminal and wait for the first session row to appear.",
                isComplete: hasClaudeSession
            ),
            AcceptanceStep(
                id: "jump",
                title: "Jump target captured",
                detail: "At least one session should include terminal jump metadata.",
                isComplete: hasJumpableSession
            ),
        ]
    }

    var acceptanceCompletedCount: Int {
        acceptanceSteps.filter(\.isComplete).count
    }

    var isReadyForFirstAcceptance: Bool {
        acceptanceSteps.prefix(3).allSatisfy(\.isComplete)
    }

    var hasPassedAcceptanceFlow: Bool {
        acceptanceSteps.allSatisfy(\.isComplete)
    }

    var acceptanceStatusTitle: String {
        if hasPassedAcceptanceFlow {
            return "v0.1 acceptance passed"
        }

        if isReadyForFirstAcceptance {
            return "Ready for v0.1 acceptance"
        }

        return "v0.1 acceptance not ready"
    }

    var acceptanceStatusSummary: String {
        if hasPassedAcceptanceFlow {
            return "The current build has completed the first-run checklist end to end."
        }

        if isReadyForFirstAcceptance {
            return "You can start your first acceptance run now. Launch Claude Code in Terminal and walk the last two steps."
        }

        return "Finish the setup steps in the left column, then start Claude Code from Terminal."
    }

    func startIfNeeded(
        startBridge: Bool = true,
        shouldPerformBootAnimation: Bool = true,
        loadRuntimeState: Bool = true
    ) {
        guard !hasStarted else {
            return
        }
        hasStarted = true

        if loadRuntimeState {
            isResolvingInitialLiveSessions = true

            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                let payload = self.discovery.loadStartupDiscoveryPayload()
                await MainActor.run {
                    self.applyStartupDiscoveryPayload(payload)
                }
            }

            // These are already async or lightweight — safe to start immediately.
            hooks.refreshClaudeHookStatus()
            hooks.refreshClaudeUsageState()
            hooks.startClaudeUsageMonitoringIfNeeded()

        } else {
            isResolvingInitialLiveSessions = false
        }
        refreshOverlayDisplayConfiguration()
        ensureOverlayPanel()
        if shouldPerformBootAnimation {
            performBootAnimation()
        }

        guard startBridge else {
            isBridgeReady = false
            lastActionMessage = loadRuntimeState
                ? "Harness mode active. Bridge startup skipped."
                : "Deterministic harness mode active. Runtime discovery and bridge startup skipped."
            harnessRuntimeMonitor?.recordMilestone("bridgeSkipped", message: lastActionMessage)
            return
        }

        do {
            try bridgeServer.start()
            connectBridgeObserver()
        } catch {
            isBridgeReady = false
            lastActionMessage = "Failed to start local bridge: \(error.localizedDescription)"
            harnessRuntimeMonitor?.recordMilestone("bridgeStartFailed", message: lastActionMessage)
        }
    }

    // MARK: - Bridge observer connection

    private static let bridgeReconnectDelay: Duration = .seconds(2)
    private static let bridgeMaxReconnectDelay: Duration = .seconds(30)

    private func connectBridgeObserver() {
        bridgeTask?.cancel()
        bridgeReconnectTask?.cancel()

        // Explicitly disconnect the old client so its DispatchSource is
        // cancelled deterministically rather than relying on dealloc timing.
        bridgeClient.disconnect()

        // Create a fresh client for each connection attempt so we don't
        // have to worry about stale file-descriptor state.
        let client = LocalBridgeClient()
        bridgeClient = client

        let stream: AsyncThrowingStream<AgentEvent, Error>
        do {
            stream = try client.connect()
        } catch {
            isBridgeReady = false
            lastActionMessage = "Failed to connect bridge observer: \(error.localizedDescription)"
            scheduleBridgeReconnect()
            return
        }

        // A single task handles both registration and event consumption so
        // there is no untracked task that could race with a reconnect.
        bridgeTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await client.send(.registerClient(role: .observer))
                self.isBridgeReady = true
                self.lastActionMessage = "Bridge ready. Waiting for Claude hook events."
                self.harnessRuntimeMonitor?.recordMilestone("bridgeReady", message: self.lastActionMessage)
            } catch {
                guard !Task.isCancelled else { return }
                self.isBridgeReady = false
                self.lastActionMessage = "Failed to register bridge observer: \(error.localizedDescription)"
                self.harnessRuntimeMonitor?.recordMilestone(
                    "bridgeRegistrationFailed",
                    message: self.lastActionMessage
                )
                self.scheduleBridgeReconnect()
                return
            }

            do {
                for try await event in stream {
                    self.applyTrackedEvent(event)
                }
            } catch {}

            // Stream ended (server closed our connection or transient error).
            // Mark as disconnected and schedule reconnection.
            guard !Task.isCancelled else { return }
            self.isBridgeReady = false
            self.lastActionMessage = "Bridge observer disconnected. Reconnecting…"
            self.harnessRuntimeMonitor?.recordMilestone("bridgeDisconnected", message: self.lastActionMessage)
            self.scheduleBridgeReconnect()
        }
    }

    private func scheduleBridgeReconnect() {
        bridgeReconnectTask?.cancel()
        bridgeReconnectTask = Task { [weak self] in
            var delay = Self.bridgeReconnectDelay
            while !Task.isCancelled {
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled else { return }
                self.connectBridgeObserver()
                // If we're now connected, stop retrying.
                if self.isBridgeReady { return }
                delay = min(delay * 2, Self.bridgeMaxReconnectDelay)
            }
        }
    }

    func select(sessionID: String) {
        selectedSessionID = sessionID
    }

    // MARK: - Overlay forwarding

    func toggleOverlay() { overlay.toggleOverlay() }
    func notchOpen(reason: NotchOpenReason, surface: IslandSurface = .sessionList()) { overlay.notchOpen(reason: reason, surface: surface) }
    func notchClose() { overlay.notchClose() }

    /// Whether click-outside (and similar accidental dismissals) should be
    /// ignored because a session still needs an approve/deny or answer.
    var shouldBlockDismissWhileAwaitingDecision: Bool {
        guard keepNotchOpenUntilDecision else { return false }
        guard notchStatus == .opened else { return false }
        // Only sessions the island actually shows can pin it open; a hidden
        // subagent waiting on its parent must not block dismissal.
        return surfacedSessions.contains { session in
            session.phase.requiresAttention
        }
    }
    func notchPop() { overlay.notchPop() }
    func performBootAnimation() { overlay.performBootAnimation() }
    func ensureOverlayPanel() { overlay.ensureOverlayPanel() }
    func showOverlay() { overlay.showOverlay() }
    func hideOverlay() { overlay.hideOverlay() }
    func expandNotificationToSessionList(clearExpansion: Bool = false) {
        overlay.expandNotificationToSessionList(clearExpansion: clearExpansion)
    }
    func refreshOverlayDisplayConfiguration() { overlay.refreshOverlayDisplayConfiguration() }
    func refreshOverlayPlacement() { overlay.refreshOverlayPlacement() }
    private func refreshOverlayPlacementIfVisible() { overlay.refreshOverlayPlacementIfVisible() }
    func notePointerInsideIslandSurface() { overlay.notePointerInsideIslandSurface() }
    func handlePointerExitedIslandSurface() { overlay.handlePointerExitedIslandSurface() }
    private func presentNotificationSurface(_ surface: IslandSurface) { overlay.presentNotificationSurface(surface) }
    private func reconcileIslandSurfaceAfterStateChange() { overlay.reconcileIslandSurfaceAfterStateChange() }
    private func dismissNotificationSurfaceIfPresent(for sessionID: String) { overlay.dismissNotificationSurfaceIfPresent(for: sessionID) }
    private func dismissOverlayForJump() { overlay.dismissOverlayForJump() }

    var shouldAutoCollapseOnMouseLeave: Bool { overlay.shouldAutoCollapseOnMouseLeave }
    var autoCollapseOnMouseLeaveRequiresPriorSurfaceEntry: Bool { overlay.autoCollapseOnMouseLeaveRequiresPriorSurfaceEntry }
    var showsNotificationCard: Bool { overlay.showsNotificationCard }
    var shouldDeferTimedNotificationAutoCollapse: Bool { overlay.shouldDeferTimedNotificationAutoCollapse }
    var hasPendingNotificationAutoCollapse: Bool { overlay.hasPendingNotificationAutoCollapse }

    func loadDebugSnapshot(
        _ snapshot: IslandDebugSnapshot,
        presentOverlay: Bool = false,
        autoCollapseNotificationCards: Bool = false
    ) {
        state = SessionState(sessions: snapshot.sessions)
        selectedSessionID = snapshot.selectedSessionID ?? snapshot.sessions.first?.id
        lastActionMessage = "Loaded debug scenario: \(snapshot.title)."
        harnessRuntimeMonitor?.recordMilestone("scenarioLoaded", message: snapshot.title)

        overlay.applyOverlayState(from: snapshot, presentOverlay: presentOverlay, autoCollapseNotificationCards: autoCollapseNotificationCards)
    }

    func showSettings() {
        if let opener = openSettingsWindow {
            opener()
        } else {
            // First-launch fallback: SwiftUI's `openWindow` closure is registered
            // by `SettingsWindowContent.onAppear`, which doesn't fire until the
            // settings window renders the first time. Send the standard
            // `showSettingsWindow:` responder action (macOS 13+) so it fires
            // the `CommandGroup(.appSettings)` button that opens the window.
            NSApp.sendAction(NSSelectorFromString("showSettingsWindow:"), to: nil, from: nil)
        }
        if let window = NSApp.windows.first(where: { $0.title == "Open Island Settings" }) {
            window.orderFrontRegardless()
            window.makeKey()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens Settings on the Setup tab so the user can install hooks.
    /// Used by every "Set up agents" CTA in the empty-state UI. A
    /// dedicated first-run onboarding window will replace this in a
    /// later PR; until then this is the canonical entry point.
    func showOnboarding() {
        showSettings()
        NotificationCenter.default.post(name: .openIslandSelectSetupTab, object: nil)
    }

    func toggleSoundMuted() {
        isSoundMuted.toggle()
    }

    func approveFocusedPermission(_ approved: Bool) {
        guard let session = focusedSession else {
            return
        }

        send(
            .resolvePermission(sessionID: session.id, resolution: permissionResolution(for: approved)),
            userMessage: approved
                ? "Approving permission for \(session.title)."
                : "Denying permission for \(session.title)."
        )
    }

    func answerFocusedQuestion(_ answer: String) {
        guard let session = focusedSession else {
            return
        }

        send(
            .answerQuestion(sessionID: session.id, response: QuestionPromptResponse(answer: answer)),
            userMessage: "Sending answer \"\(answer)\" for \(session.title)."
        )
    }

    func jumpToFocusedSession() {
        jump(to: focusedSession?.jumpTarget)
    }

    func jumpToSession(_ session: AgentSession, marksSeen: Bool = true) {
        if marksSeen {
            focus.markSessionSeen(session.id)
        }
        guard let jumpTarget = session.jumpTarget,
              jumpTarget.terminalApp.lowercased() != "unknown" else {
            lastActionMessage = "Cannot jump: terminal app is unknown."
            return
        }
        jump(to: jumpTarget)
    }

    private func jump(to jumpTarget: JumpTarget?) {
        guard let jumpTarget else {
            lastActionMessage = "No jump target is available yet."
            return
        }

        let shouldDelayForDismissAnimation = isOverlayVisible
        let jumpAction = terminalJumpAction

        dismissOverlayForJump()
        jumpTask?.cancel()
        jumpTask = Task { [weak self] in
            if shouldDelayForDismissAnimation {
                try? await Task.sleep(for: Self.jumpOverlayDismissLeadTime)
            }

            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try jumpAction(jumpTarget)
                }.value

                guard !Task.isCancelled else {
                    return
                }

                self?.lastActionMessage = result
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }

                self?.lastActionMessage = "Jump failed: \(error.localizedDescription)"
            }
        }
    }

    func approvePermission(for sessionID: String, approved: Bool) {
        guard let session = state.session(id: sessionID) else {
            return
        }

        let resolution = permissionResolution(for: approved)
        dismissNotificationSurfaceIfPresent(for: sessionID)
        state.resolvePermission(sessionID: session.id, resolution: resolution)
        synchronizeSelection()
        refreshOverlayPlacementIfVisible()

        send(
            .resolvePermission(sessionID: session.id, resolution: resolution),
            userMessage: approved
                ? "Approving permission for \(session.title)."
                : "Denying permission for \(session.title)."
        )
    }

    func approvePermission(for sessionID: String, action: ApprovalAction) {
        guard let session = state.session(id: sessionID) else {
            return
        }

        let resolution: PermissionResolution
        let message: String

        switch action {
        case .deny:
            resolution = .deny(message: "Permission denied in Open Island.", interrupt: false)
            message = "Denying permission for \(session.title)."
        case .allowOnce:
            resolution = .allowOnce()
            message = "Approving permission for \(session.title)."
        case let .allowWithUpdates(updates):
            resolution = .allowOnce(updatedPermissions: updates)
            message = "Always allowing for \(session.title)."
        }

        dismissNotificationSurfaceIfPresent(for: sessionID)
        state.resolvePermission(sessionID: session.id, resolution: resolution)
        synchronizeSelection()
        refreshOverlayPlacementIfVisible()

        send(
            .resolvePermission(sessionID: session.id, resolution: resolution),
            userMessage: message
        )
    }

    func dismissSession(_ sessionID: String) {
        state.dismissSession(id: sessionID)
        dismissNotificationSurfaceIfPresent(for: sessionID)
        synchronizeSelection()
    }

    func answerQuestion(for sessionID: String, answer: QuestionPromptResponse) {
        guard let session = state.session(id: sessionID) else {
            return
        }

        dismissNotificationSurfaceIfPresent(for: sessionID)
        state.answerQuestion(sessionID: session.id, response: answer)
        synchronizeSelection()
        refreshOverlayPlacementIfVisible()

        send(
            .answerQuestion(sessionID: session.id, response: answer),
            userMessage: "Sending answer for \(session.title)."
        )
    }

    func replyToSession(_ session: AgentSession, text: String) {
        dismissNotificationSurfaceIfPresent(for: session.id)
        synchronizeSelection()
        refreshOverlayPlacementIfVisible()

        lastActionMessage = "Sending reply to \(session.title)…"

        Task { [weak self] in
            let success = await Task.detached(priority: .userInitiated) {
                TerminalTextSender.send(text, to: session)
            }.value

            self?.lastActionMessage = success
                ? "Sent reply to \(session.title)."
                : "Failed to send reply to \(session.title)."
        }
    }


    private func send(_ command: BridgeCommand, userMessage: String) {
        lastActionMessage = userMessage

        Task { [weak self] in
            guard let self else {
                return
            }

            do {
                try await self.bridgeClient.send(command)
            } catch {
                self.lastActionMessage = "Failed to send bridge command: \(error.localizedDescription)"
            }
        }
    }

    private func permissionResolution(for approved: Bool) -> PermissionResolution {
        if approved {
            return .allowOnce()
        }

        return .deny(message: "Permission denied in Open Island.", interrupt: false)
    }

    func applyTrackedEvent(
        _ event: AgentEvent,
        updateLastActionMessage: Bool = true,
        ingress: TrackedEventIngress = .bridge
    ) {
        // Snapshot whether this session was already completed before applying
        // the event. Used to suppress duplicate/stale completion notifications
        // (e.g. rollout watcher re-discovering an old completion on startup,
        // or producing a duplicate sessionCompleted that races with the bridge).
        let wasAlreadyCompleted: Bool = {
            guard case let .sessionCompleted(payload) = event else { return false }
            return state.session(id: payload.sessionID)?.phase == .completed
        }()

        // Guard: don't let rollout events downgrade a session from completed
        // back to running. The bridge's sessionCompleted is authoritative; the
        // rollout watcher may have read the JSONL before task_complete was
        // flushed, producing a stale activityUpdated(phase: .running).
        if ingress == .rollout,
           case let .activityUpdated(payload) = event,
           payload.phase == .running,
           state.session(id: payload.sessionID)?.phase == .completed {
            return
        }

        state.apply(event)
        reconcileIslandSurfaceAfterStateChange()
        if ingress == .bridge {
            monitoring.markSessionAttached(for: event)
            monitoring.markSessionProcessAlive(for: event)
        }
        synchronizeSelection()
        refreshOverlayPlacementIfVisible()
        discovery.scheduleClaudeSessionPersistence()

        if updateLastActionMessage {
            lastActionMessage = describe(event)
        }

        if let surface = IslandSurface.notificationSurface(for: event) {
            scheduleNotificationSurfacePresentationIfNeeded(
                surface,
                wasAlreadyCompleted: wasAlreadyCompleted,
                ingress: ingress
            )
        }
    }

    private func scheduleNotificationSurfacePresentationIfNeeded(
        _ surface: IslandSurface,
        wasAlreadyCompleted: Bool,
        ingress: TrackedEventIngress
    ) {
        guard !wasAlreadyCompleted,
              notificationSurfaceIsEligibleForPresentation(surface, ingress: ingress),
              let sessionID = surface.sessionID,
              let session = state.session(id: sessionID) else {
            return
        }

        guard suppressFrontmostNotifications else {
            presentNotificationSurface(surface)
            return
        }

        notificationPresentationTask?.cancel()
        notificationPresentationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let shouldSuppress = await self.isNotificationSessionAlreadyFrontmost(session)
            guard !Task.isCancelled,
                  !shouldSuppress,
                  self.notificationSurfaceIsEligibleForPresentation(surface, ingress: ingress) else {
                return
            }

            self.presentNotificationSurface(surface)
        }
    }

    private func notificationSurfaceIsEligibleForPresentation(
        _ surface: IslandSurface,
        ingress: TrackedEventIngress
    ) -> Bool {
        guard let sessionID = surface.sessionID,
              let session = state.session(id: sessionID) else {
            return false
        }

        return (ingress == .bridge || !isResolvingInitialLiveSessions)
            && (notchStatus == .closed || notchOpenReason == .notification)
            && !overlay.shouldPreserveCurrentNotificationSurface(against: surface)
            && surface.matchesCurrentState(of: session)
    }

    private func synchronizeSelection() {
        let surfacedIDs = Set(surfacedSessions.map(\.id))

        if let activeAction = state.activeActionableSession {
            selectedSessionID = activeAction.id
            return
        }

        guard let selectedSessionID,
              surfacedIDs.contains(selectedSessionID),
              state.session(id: selectedSessionID) != nil else {
            self.selectedSessionID = surfacedSessions.first?.id ?? state.sessions.first?.id
            return
        }
    }

    /// Applies startup discovery results on the main thread after background I/O completes.
    private func applyStartupDiscoveryPayload(_ payload: SessionDiscoveryCoordinator.StartupDiscoveryPayload) {
        discovery.applyStartupDiscoveryPayload(payload)

        // Apply hooks binary URL and update the installed copy if the app ships a newer version.
        hooks.hooksBinaryURL = payload.hooksBinaryURL
        hooks.updateHooksBinaryIfNeeded()

        // Auto-install missing hooks and usage bridge, then run health checks.
        let hooksBinaryLocated = payload.hooksBinaryURL != nil
        Task { @MainActor [weak self] in
            guard let self else { return }

            // Wait for all status reads to complete before checking install state.
            await self.hooks.refreshAllHookStatusAndWait()

            // Reconcile persisted intent with what is actually on disk. For
            // legacy users this records existing hooks as `.installed` and
            // marks first-launch as complete so onboarding does not appear
            // on upgrade. Must run after status reads and before any
            // install decision.
            self.hooks.migrateIntentStoreIfNeeded()

            let autoInstallsClaude = hooksBinaryLocated && self.hooks.shouldAutoInstall(.claudeCode)
            if !autoInstallsClaude {
                self.settleFocusHookState()
            }

            // Everything below writes the hooks binary path into agent
            // config, so it only runs once the binary has been located.
            guard hooksBinaryLocated else { return }

            // Install only hooks the user has not explicitly opted out of.
            // `shouldAutoInstall` skips `.uninstalled` agents and agents
            // whose hooks are already present — it is the single checkpoint
            // that fixes #324.
            if self.hooks.shouldAutoInstall(.claudeCode) { self.installClaudeHooks() }
            if self.hooks.shouldAutoInstall(.claudeUsageBridge) { self.installClaudeUsageBridge() }

            // Run health checks after install to detect stale paths, conflicts, etc.
            try? await Task.sleep(for: .milliseconds(500))
            await self.hooks.repairHooksIfNeeded()
            if autoInstallsClaude {
                self.settleFocusHookState()
            }
        }

        // Reconcile attachments and start monitoring (requires sessions to be loaded).
        monitoring.reconcileSessionAttachments()
        monitoring.startMonitoringIfNeeded()
        focus.start(initialSessions: state.sessions)
        focus.startTicking()
        focus.onSettingsChanged = { [weak self] settings in
            self?.boardHotKey?.update(settings.boardHotKey)
        }
        frontmostMonitor = FrontmostAppMonitor(focus: focus)
        frontmostMonitor?.start()
        boardHotKey = GlobalHotKey(hotKey: focus.settings.boardHotKey) { [weak self] in
            guard let self else { return }
            BoardWindowController.shared.show(focus: self.focus)
        }
        openBoardObserver = NotificationCenter.default.addObserver(forName: .focusOpenBoard, object: nil, queue: .main) { [weak self] notification in
            let tab = BoardTab.explicit(userInfo: notification.userInfo)
            MainActor.assumeIsolated {
                guard let self else { return }
                BoardWindowController.shared.show(focus: self.focus, tab: tab)
            }
        }
        observeFocusLifecycle()
    }

    private func settleFocusHookState() {
        focusHookStateReady = true
        focus.setHooksInstalled(hooks.claudeHooksInstalled)
    }

    private func observeFocusLifecycle() {
        let workspace = NSWorkspace.shared.notificationCenter
        let stopNames: [(NotificationCenter, Notification.Name)] = [
            (NotificationCenter.default, NSApplication.willTerminateNotification),
            (workspace, NSWorkspace.willSleepNotification),
        ]
        for (center, name) in stopNames {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.focus.stop()
                }
            }
            focusLifecycleObservers.append((center, token))
        }
        let wakeToken = workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.focus.wake()
            }
        }
        focusLifecycleObservers.append((workspace, wakeToken))
        let distributed = DistributedNotificationCenter.default()
        let presenceEvents: [(NotificationCenter, Notification.Name, PresenceEvent)] = [
            (distributed, Notification.Name("com.apple.screenIsLocked"), .screenLocked),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), .screenUnlocked),
            (workspace, NSWorkspace.screensDidSleepNotification, .screensSlept),
            (workspace, NSWorkspace.screensDidWakeNotification, .screensWoke),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionResigned),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification, .sessionActivated),
        ]
        for (center, name, event) in presenceEvents {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.focus.presenceDidChange(event)
                }
            }
            focusLifecycleObservers.append((center, token))
        }
    }


    private var sessionBuckets: (primary: [AgentSession], overflow: [AgentSession]) {
        if let cached = _cachedSessionBuckets {
            return cached
        }
        let result = computeSessionBuckets()
        _cachedSessionBuckets = result
        return result
    }

    private func computeSessionBuckets() -> (primary: [AgentSession], overflow: [AgentSession]) {
        let now = Date.now
        let rankedSessions = state.sessions.sorted { lhs, rhs in
            let lhsScore = displayPriority(for: lhs, now: now)
            let rhsScore = displayPriority(for: rhs, now: now)

            if lhsScore == rhsScore {
                if lhs.islandActivityDate == rhs.islandActivityDate {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }

                return lhs.islandActivityDate > rhs.islandActivityDate
            }

            return lhsScore > rhsScore
        }

        var primary: [AgentSession] = []
        var claimedLiveAttachmentKeys: Set<String> = []

        for session in rankedSessions where session.isVisibleInIsland {
            guard !session.isSubagentSession else { continue }

            if let liveAttachmentKey = monitoring.liveAttachmentKey(for: session) {
                guard claimedLiveAttachmentKeys.insert(liveAttachmentKey).inserted else {
                    continue
                }
            }

            primary.append(session)
        }

        let primaryIDs = Set(primary.map(\.id))
        let overflow = rankedSessions.filter { !primaryIDs.contains($0.id) && !$0.isSubagentSession }
        return (primary, overflow)
    }

    private func displayPriority(for session: AgentSession, now: Date) -> Int {
        var score = 0

        let presence = session.islandPresence(at: now)

        if session.isProcessAlive {
            score += presence == .inactive ? 3_000 : 12_000
        } else if session.isDemoSession || session.phase.requiresAttention {
            score += 6_000
        }

        if session.phase.requiresAttention {
            score += 10_000
        }

        if session.currentToolName?.isEmpty == false {
            score += 6_000
        }

        if session.jumpTarget != nil {
            score += 4_000
        }

        switch session.phase {
        case .running:
            score += 2_000
        case .waitingForApproval:
            score += 1_500
        case .waitingForAnswer:
            score += 1_200
        case .completed:
            score += 600
        }

        if session.isStaleCompletedForIsland(at: now, threshold: completedStaleThreshold.seconds) {
            score -= 900
        }

        let age = now.timeIntervalSince(session.islandActivityDate)
        switch age {
        case ..<120:
            score += 500
        case ..<900:
            score += 250
        case ..<3_600:
            score += 120
        case ..<21_600:
            score += 40
        default:
            break
        }

        return score
    }

    private func describe(_ event: AgentEvent) -> String {
        switch event {
        case let .sessionStarted(payload):
            return "Session started: \(payload.title)"
        case let .activityUpdated(payload):
            return payload.summary
        case let .permissionRequested(payload):
            return payload.request.summary
        case let .questionAsked(payload):
            return payload.prompt.title
        case let .sessionCompleted(payload):
            return payload.summary
        case let .jumpTargetUpdated(payload):
            return "Jump target updated to \(payload.jumpTarget.terminalApp)."
        case let .claudeSessionMetadataUpdated(payload):
            if let currentTool = payload.claudeMetadata.currentTool {
                return "Claude is running \(currentTool)."
            }

            return payload.claudeMetadata.lastAssistantMessage ?? "Claude session metadata updated."
        case let .actionableStateResolved(payload):
            return "Actionable state resolved for session \(payload.sessionID)."
        }
    }

    func quitApplication() {
        NSApplication.shared.terminate(nil)
    }

}

// MARK: - Hex color helpers

extension String {
    var normalizedHexColorString: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard raw.count == 6, raw.allSatisfy(\.isHexDigit) else { return "#6E9FFF" }
        return "#\(raw.uppercased())"
    }
}

extension Color {
    init?(hex: String) {
        let raw = String(hex.normalizedHexColorString.dropFirst())
        guard let value = Int(raw, radix: 16) else { return nil }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self = Color(red: red, green: green, blue: blue)
    }

    var opaqueHexString: String? {
        guard let nsColor = NSColor(self).usingColorSpace(.deviceRGB) else { return nil }
        let r = Int(round(nsColor.redComponent * 255))
        let g = Int(round(nsColor.greenComponent * 255))
        let b = Int(round(nsColor.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
