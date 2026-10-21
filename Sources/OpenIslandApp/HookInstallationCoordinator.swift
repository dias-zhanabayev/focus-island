import Foundation
import Observation
import OpenIslandCore

@MainActor
@Observable
final class HookInstallationCoordinator {
    @ObservationIgnored
    let intentStore: AgentIntentStore

    init(
        intentStore: AgentIntentStore = AgentIntentStore()
    ) {
        self.intentStore = intentStore
    }

    var claudeHookStatus: ClaudeHookInstallationStatus? {
        didSet { onClaudeHookStatusChanged?() }
    }
    var claudeStatusLineStatus: ClaudeStatusLineInstallationStatus?
    var claudeUsageSnapshot: ClaudeUsageSnapshot?
    var hooksBinaryURL: URL?
    var isClaudeHookSetupBusy = false
    var isClaudeUsageSetupBusy = false

    @ObservationIgnored
    var onStatusMessage: ((String) -> Void)?

    @ObservationIgnored
    var onClaudeHookStatusChanged: (() -> Void)?

    /// Computed so it always reflects the latest `ClaudeConfigDirectory` setting.
    private var claudeHookInstallationManager: ClaudeHookInstallationManager {
        ClaudeHookInstallationManager()
    }

    /// Computed so it always reflects the latest `ClaudeConfigDirectory` setting.
    private var claudeStatusLineInstallationManager: ClaudeStatusLineInstallationManager {
        ClaudeStatusLineInstallationManager()
    }

    @ObservationIgnored
    private var claudeUsageMonitorTask: Task<Void, Never>?

    @ObservationIgnored
    private var relativeTimestampFormatter: RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }

    // MARK: - Computed display properties

    var claudeHooksInstalled: Bool {
        claudeHookStatus?.managedHooksPresent == true
    }

    var claudeUsageInstalled: Bool {
        claudeStatusLineStatus?.managedStatusLineInstalled == true
    }

    var claudeStatusLineProvidedByOtherIsland: Bool {
        claudeStatusLineStatus?.providedByOtherIsland == true
    }

    static let statusLineProvidedByOtherIslandText = "Строку статуса уже использует Open Island — Focus её не трогает"

    var claudeHookStatusTitle: String {
        if claudeHooksInstalled {
            return "Claude hooks installed"
        }

        if hooksBinaryURL == nil {
            return "Hook binary not found"
        }

        return "Claude hooks not installed"
    }

    var claudeHookStatusSummary: String {
        guard let status = claudeHookStatus else {
            return "Reading \(ClaudeConfigDirectory.resolved().appendingPathComponent("settings.json").path)."
        }

        if claudeHooksInstalled {
            if status.hasClaudeIslandHooks {
                return "managed hooks present · claude-island hooks also detected"
            }
            return "managed hooks present"
        }

        if hooksBinaryURL == nil {
            return "Build OpenIslandHooks before installing."
        }

        if status.hasClaudeIslandHooks {
            return "claude-island hooks detected · managed hooks absent"
        }

        return "no managed Claude hooks"
    }

    var claudeUsageStatusTitle: String {
        guard let status = claudeStatusLineStatus else {
            return "Claude usage status unavailable"
        }

        if status.providedByOtherIsland && !status.managedStatusLineInstalled {
            return Self.statusLineProvidedByOtherIslandText
        }

        if status.managedStatusLineInstalled {
            return "Claude usage bridge installed"
        }

        if status.managedStatusLineNeedsRepair {
            return "Claude usage bridge needs repair"
        }

        if status.hasConflictingStatusLine {
            return "Custom Claude status line detected"
        }

        return "Claude usage bridge not installed"
    }

    var claudeUsageStatusSummary: String {
        guard let status = claudeStatusLineStatus else {
            return "Reading \(ClaudeConfigDirectory.resolved().appendingPathComponent("settings.json").path)."
        }

        if status.managedStatusLineInstalled {
            if let summary = claudeUsageSummaryText {
                return "Caching rate limits from Claude Code · \(summary)"
            }
            return "Caching rate limits from Claude Code into \(status.cacheURL.path)."
        }

        if status.providedByOtherIsland {
            return Self.statusLineProvidedByOtherIslandText
        }

        if status.managedStatusLineNeedsRepair {
            return "Open Island detected a missing managed Claude status line script and will repair it automatically."
        }

        if status.hasConflictingStatusLine {
            return "Open Island will not overwrite an existing Claude status line automatically."
        }

        return "Install a managed Claude status line to cache 5h and 7d usage locally."
    }

    var claudeUsageSummaryText: String? {
        guard let snapshot = claudeUsageSnapshot else {
            return nil
        }

        var components: [String] = []
        if let fiveHour = snapshot.fiveHour {
            components.append("5h \(fiveHour.roundedUsedPercentage)%")
        }
        if let sevenDay = snapshot.sevenDay {
            components.append("7d \(sevenDay.roundedUsedPercentage)%")
        }
        if let cachedAt = snapshot.cachedAt {
            components.append("updated \(relativeTimestampFormatter.localizedString(for: cachedAt, relativeTo: .now))")
        }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    // MARK: - Claude config directory

    /// Updates the custom Claude config directory, cleans up old hooks if present, and refreshes status.
    func updateClaudeConfigDirectory(to newDirectory: URL?) {
        let oldDirectory = ClaudeConfigDirectory.resolved()
        let oldHadHooks = claudeHookStatus?.managedHooksPresent == true

        ClaudeConfigDirectory.customDirectory = newDirectory

        // Refresh status from the new directory
        refreshClaudeHookStatus()
        refreshClaudeUsageState()

        let newPath = ClaudeConfigDirectory.resolved().path
        if oldHadHooks {
            let oldPath = oldDirectory.path
            if oldPath != newPath {
                onStatusMessage?("Claude config directory changed to \(newPath). Hooks in \(oldPath) were not removed — uninstall them manually if no longer needed.")
            }
        } else {
            onStatusMessage?("Claude config directory set to \(newPath).")
        }
    }

    // MARK: - Auto-update hooks binary

    /// Overwrites the installed hooks binary if the app bundle ships a newer version.
    /// Call once at startup after hooksBinaryURL is set.
    func updateHooksBinaryIfNeeded() {
        guard let sourceURL = hooksBinaryURL else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let source = sourceURL
                let updated = try await Task.detached(priority: .utility) {
                    try ManagedHooksBinary.updateIfNeeded(from: source)
                }.value
                if updated {
                    self.onStatusMessage?("Hooks binary updated to match the current app version.")
                    self.refreshClaudeHookStatus()
                }
            } catch {
                self.onStatusMessage?("Failed to update hooks binary: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Health check & auto-repair

    var claudeHealthReport: HookHealthReport?

    /// Every report produced by the last check, in display order.
    var healthReports: [HookHealthReport] {
        [claudeHealthReport].compactMap(\.self)
    }

    /// Runs health checks for Claude hooks.
    func runHealthChecks() {
        Task { @MainActor [weak self] in
            guard let self else { return }

            let binaryURL = self.hooksBinaryURL
            let claudeReport = await Task.detached(priority: .utility) {
                HookHealthCheck.checkClaude(hooksBinaryURL: binaryURL)
            }.value

            self.claudeHealthReport = claudeReport

            if !claudeReport.isHealthy {
                self.onStatusMessage?("Hook health check: \(claudeReport.errors.count) Claude issue(s).")
            }
        }
    }

    /// Attempts to auto-repair repairable issues by re-installing hooks.
    /// Returns true if any repairs were attempted.
    @discardableResult
    func repairHooksIfNeeded() async -> Bool {
        var repaired = false

        // Re-run health checks first
        let binaryURL = hooksBinaryURL
        let claudeReport = await Task.detached(priority: .utility) {
            HookHealthCheck.checkClaude(hooksBinaryURL: binaryURL)
        }.value

        claudeHealthReport = claudeReport

        // Repair Claude hooks if there are repairable issues
        if !claudeReport.repairableIssues.isEmpty, hooksBinaryURL != nil {
            onStatusMessage?("Repairing Claude hooks: \(claudeReport.repairableIssues.map(\.description).joined(separator: "; "))")
            installClaudeHooks()
            repaired = true
        }

        // Refresh health reports after repair
        if repaired {
            try? await Task.sleep(for: .milliseconds(500))
            let updatedClaude = await Task.detached(priority: .utility) {
                HookHealthCheck.checkClaude(hooksBinaryURL: binaryURL)
            }.value
            claudeHealthReport = updatedClaude

            if updatedClaude.isHealthy {
                onStatusMessage?("Hook repair completed successfully.")
            } else {
                onStatusMessage?("Hook repair finished with \(updatedClaude.errors.count) remaining issue(s).")
            }
        }

        return repaired
    }

    // MARK: - Refresh

    func refreshClaudeHookStatus() {
        Task { [weak self] in
            guard let self else { return }

            do {
                let status = try self.claudeHookInstallationManager.status(hooksBinaryURL: self.hooksBinaryURL)
                self.claudeHookStatus = status
            } catch {
                self.onStatusMessage?("Failed to read Claude hook status: \(error.localizedDescription)")
            }
        }
    }

    /// Awaitable versions of refresh for use in startup flow to avoid race conditions.
    func refreshAllHookStatusAndWait() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let status = try self.claudeHookInstallationManager.status(hooksBinaryURL: self.hooksBinaryURL)
                    self.claudeHookStatus = status
                } catch {
                    self.onStatusMessage?("Failed to read Claude hook status: \(error.localizedDescription)")
                }
            }

            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let usageState = try self.readClaudeUsageState(repairManagedBridgeIfNeeded: true)
                    self.claudeStatusLineStatus = usageState.status
                    self.claudeUsageSnapshot = usageState.snapshot
                } catch {
                    self.onStatusMessage?("Failed to read Claude usage state: \(error.localizedDescription)")
                }
            }
        }
    }

    func refreshClaudeUsageState() {
        let manager = claudeStatusLineInstallationManager
        Task { [weak self] in
            guard let self else { return }

            do {
                let usageState = try await Task.detached(priority: .utility) {
                    var status = try manager.status()
                    var repairedManagedBridge = false
                    if status.shouldAutoRepair {
                        status = try manager.install()
                        repairedManagedBridge = true
                    }
                    let snapshot = try ClaudeUsageLoader.load()
                    return (status: status, snapshot: snapshot, repairedManagedBridge: repairedManagedBridge)
                }.value
                self.claudeStatusLineStatus = usageState.status
                self.claudeUsageSnapshot = usageState.snapshot
                if usageState.repairedManagedBridge {
                    self.onStatusMessage?("Recovered the Claude usage bridge after repairing a missing managed script.")
                }
            } catch {
                self.onStatusMessage?("Failed to read Claude usage state: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Intent-aware helpers

    /// Reports whether the startup flow should auto-install hooks for the
    /// given agent.
    ///
    /// Post-onboarding, the only case that triggers auto-install is
    /// `.installed && !present` — i.e. the user asked for this hook in the
    /// past but it is currently missing (fresh machine, config wiped,
    /// upgraded binary path, etc). This is a repair, not a surprise
    /// install. `.untouched` and `.uninstalled` both return false;
    /// untouched agents are surfaced to the user via the first-run
    /// onboarding window and the empty-state banner instead.
    func shouldAutoInstall(_ agent: AgentIdentifier) -> Bool {
        guard intentStore.intent(for: agent) == .installed else {
            return false
        }

        switch agent {
        case .claudeCode: return !claudeHooksInstalled
        case .claudeUsageBridge: return !claudeUsageInstalled && !claudeStatusLineProvidedByOtherIsland
        }
    }

    // MARK: - Intent store migration

    /// Reconciles the persisted intent store with the hook status currently
    /// observed on disk. Must be called only after
    /// `refreshAllHookStatusAndWait()` has returned, otherwise every agent
    /// will be recorded as `.untouched` and legacy users will have their
    /// installed hooks silently forgotten.
    func migrateIntentStoreIfNeeded() {
        intentStore.migrateFromLegacyStateIfNeeded { [self] agent in
            switch agent {
            case .claudeCode: return claudeHooksInstalled
            case .claudeUsageBridge: return claudeUsageInstalled
            }
        }
    }

    // MARK: - Install / uninstall

    func installClaudeHooks() {
        guard let hooksBinaryURL else {
            onStatusMessage?("Could not find a local OpenIslandHooks binary. Build the package first.")
            return
        }

        updateClaudeHooks(userMessage: "Installing Claude hooks.", intent: .installed) { manager in
            try manager.install(hooksBinaryURL: hooksBinaryURL)
        }
    }

    func uninstallClaudeHooks() {
        updateClaudeHooks(userMessage: "Removing Claude hooks.", intent: .uninstalled) { manager in
            try manager.uninstall()
        }
    }

    func installClaudeUsageBridge() {
        if claudeStatusLineProvidedByOtherIsland {
            onStatusMessage?(Self.statusLineProvidedByOtherIslandText)
            return
        }
        updateClaudeUsageBridge(userMessage: "Installing Claude usage bridge.", intent: .installed) { manager in
            do {
                return try manager.install()
            } catch ClaudeStatusLineInstallationError.existingStatusLineConflict {
                // User already has a custom statusLine (e.g. claude-hud). Install as a
                // wrapper so their script keeps running and we still get rate_limits.
                return try manager.installAsWrapper()
            }
        }
    }

    func uninstallClaudeUsageBridge() {
        updateClaudeUsageBridge(userMessage: "Removing Claude usage bridge.", intent: .uninstalled) { manager in
            try manager.uninstall()
        }
    }

    // MARK: - Monitoring

    func startClaudeUsageMonitoringIfNeeded() {
        guard claudeUsageMonitorTask == nil else { return }

        claudeUsageMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                self.refreshClaudeUsageState()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: - Internal: readClaudeUsageState

    nonisolated func readClaudeUsageState(
        repairManagedBridgeIfNeeded: Bool
    ) throws -> (
        status: ClaudeStatusLineInstallationStatus,
        snapshot: ClaudeUsageSnapshot?,
        repairedManagedBridge: Bool
    ) {
        let manager = ClaudeStatusLineInstallationManager()
        var status = try manager.status()
        var repairedManagedBridge = false

        if repairManagedBridgeIfNeeded && status.shouldAutoRepair {
            status = try manager.install()
            repairedManagedBridge = true
        }

        let snapshot = try ClaudeUsageLoader.load()
        return (status, snapshot, repairedManagedBridge)
    }

    // MARK: - Private helpers

    private func updateClaudeHooks(
        userMessage: String,
        intent: AgentHookIntent,
        operation: @escaping (ClaudeHookInstallationManager) throws -> ClaudeHookInstallationStatus
    ) {
        isClaudeHookSetupBusy = true
        onStatusMessage?(userMessage)

        Task { [weak self] in
            guard let self else { return }

            defer { self.isClaudeHookSetupBusy = false }

            do {
                let status = try operation(self.claudeHookInstallationManager)
                self.claudeHookStatus = status
                self.intentStore.setIntent(intent, for: .claudeCode)
                if status.managedHooksPresent {
                    self.onStatusMessage?(status.hasClaudeIslandHooks
                        ? "Claude hooks are installed. claude-island hooks are also still present."
                        : "Claude hooks are installed and ready.")
                } else {
                    self.onStatusMessage?("Claude hooks are not installed.")
                }
            } catch {
                self.onStatusMessage?("Claude hook update failed: \(error.localizedDescription)")
            }
        }
    }

    private func updateClaudeUsageBridge(
        userMessage: String,
        intent: AgentHookIntent,
        operation: @escaping (ClaudeStatusLineInstallationManager) throws -> ClaudeStatusLineInstallationStatus
    ) {
        isClaudeUsageSetupBusy = true
        onStatusMessage?(userMessage)

        Task { [weak self] in
            guard let self else { return }

            defer { self.isClaudeUsageSetupBusy = false }

            do {
                let status = try operation(self.claudeStatusLineInstallationManager)
                self.claudeStatusLineStatus = status
                self.claudeUsageSnapshot = try ClaudeUsageLoader.load()
                self.intentStore.setIntent(intent, for: .claudeUsageBridge)
                if status.managedStatusLineInstalled {
                    if status.managedStatusLineIsWrapper {
                        self.onStatusMessage?("Claude usage bridge installed in wrapper mode — your existing statusLine is preserved. Start a Claude Code turn to refresh cached rate limits.")
                    } else {
                        self.onStatusMessage?("Claude usage bridge is installed. Start a Claude Code turn to refresh cached rate limits.")
                    }
                } else {
                    self.onStatusMessage?("Claude usage bridge is not installed.")
                }
            } catch {
                self.onStatusMessage?("Claude usage bridge update failed: \(error.localizedDescription)")
            }
        }
    }
}
