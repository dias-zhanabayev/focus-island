import AppKit
import Foundation
import Observation
import OpenIslandCore

typealias ActiveProcessSnapshot = ActiveAgentProcessDiscovery.ProcessSnapshot

@MainActor
@Observable
final class ProcessMonitoringCoordinator {
    var isResolvingInitialLiveSessions = false

    @ObservationIgnored
    var stateAccessor: (() -> SessionState)?

    @ObservationIgnored
    var stateUpdater: ((SessionState) -> Void)?

    @ObservationIgnored
    var onSessionsReconciled: (() -> Void)?

    @ObservationIgnored
    var onPersistenceNeeded: (() -> Void)?

    @ObservationIgnored
    let activeAgentProcessDiscovery = ActiveAgentProcessDiscovery()

    @ObservationIgnored
    private let terminalSessionAttachmentProbe = TerminalSessionAttachmentProbe()

    @ObservationIgnored
    private let terminalJumpTargetResolver = TerminalJumpTargetResolver()

    @ObservationIgnored
    private var sessionAttachmentMonitorTask: Task<Void, Never>?

    private static let startupPollInterval: TimeInterval = 2
    private static let wakeProbeInterval: TimeInterval = 2
    private static let activePollInterval: TimeInterval = 60
    private static let idlePollInterval: TimeInterval = 300
    static let claudeDesktopStalenessTimeout: TimeInterval = 12 * 60 * 60
    private static let conductorStalenessTimeout: TimeInterval = 600  // 10 minutes

    static func monitoringPollInterval(
        isResolvingInitialLiveSessions: Bool,
        hasTrackedLiveSessions: Bool
    ) -> TimeInterval {
        if isResolvingInitialLiveSessions {
            return startupPollInterval
        }

        return hasTrackedLiveSessions ? activePollInterval : idlePollInterval
    }

    static func monitoringWakeInterval(
        isResolvingInitialLiveSessions: Bool,
        hasTrackedLiveSessions: Bool
    ) -> TimeInterval {
        min(
            wakeProbeInterval,
            monitoringPollInterval(
                isResolvingInitialLiveSessions: isResolvingInitialLiveSessions,
                hasTrackedLiveSessions: hasTrackedLiveSessions
            )
        )
    }

    static func shouldPerformFullMonitorReconcile(
        now: Date,
        nextFullReconcileAt: Date,
        isResolvingInitialLiveSessions: Bool,
        hasTrackedLiveSessions: Bool,
        hadTrackedLiveSessions: Bool
    ) -> Bool {
        if isResolvingInitialLiveSessions {
            return true
        }
        if hasTrackedLiveSessions, !hadTrackedLiveSessions {
            return true
        }
        return now >= nextFullReconcileAt
    }

    private var state: SessionState {
        get { stateAccessor?() ?? SessionState() }
        set { stateUpdater?(newValue) }
    }

    // MARK: - Monitoring lifecycle

    func startMonitoringIfNeeded() {
        guard sessionAttachmentMonitorTask == nil else {
            return
        }

        sessionAttachmentMonitorTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            var nextFullReconcileAt = Date.distantPast
            var hadTrackedLiveSessions = false

            while !Task.isCancelled {
                let liveSessions = self.state.sessions.filter(\.isTrackedLiveSession)
                let hasTrackedLiveSessions = !liveSessions.isEmpty
                let shouldRunFullReconcile = Self.shouldPerformFullMonitorReconcile(
                    now: Date(),
                    nextFullReconcileAt: nextFullReconcileAt,
                    isResolvingInitialLiveSessions: self.isResolvingInitialLiveSessions,
                    hasTrackedLiveSessions: hasTrackedLiveSessions,
                    hadTrackedLiveSessions: hadTrackedLiveSessions
                )

                if shouldRunFullReconcile {
                    let discovery = self.activeAgentProcessDiscovery
                    let probe = self.terminalSessionAttachmentProbe
                    let resolver = self.terminalJumpTargetResolver
                    let shouldResolveTerminals = hasTrackedLiveSessions
                    let (snapshots, ghosttyAvail, terminalAvail, jumpTargets) = await Task.detached(priority: .utility) {
                        let s = discovery.discover()
                        let g: TerminalSessionAttachmentProbe.SnapshotAvailability<TerminalSessionAttachmentProbe.GhosttyTerminalSnapshot>
                        let t: TerminalSessionAttachmentProbe.SnapshotAvailability<TerminalSessionAttachmentProbe.TerminalTabSnapshot>
                        let j: [String: JumpTarget]

                        if shouldResolveTerminals {
                            g = probe.ghosttySnapshotAvailability()
                            t = probe.terminalSnapshotAvailability()
                            j = resolver.resolveJumpTargets(for: liveSessions, activeProcesses: s)
                        } else {
                            g = .available([], appIsRunning: false)
                            t = .available([], appIsRunning: false)
                            j = [:]
                        }

                        return (s, g, t, j)
                    }.value
                    self.reconcileSessionAttachments(
                        activeProcesses: snapshots,
                        ghosttyAvailability: ghosttyAvail,
                        terminalAvailability: terminalAvail,
                        preResolvedJumpTargets: jumpTargets
                    )

                    let pollInterval = Self.monitoringPollInterval(
                        isResolvingInitialLiveSessions: self.isResolvingInitialLiveSessions,
                        hasTrackedLiveSessions: self.state.sessions.contains(where: \.isTrackedLiveSession)
                    )
                    nextFullReconcileAt = Date().addingTimeInterval(pollInterval)
                    hadTrackedLiveSessions = self.state.sessions.contains(where: \.isTrackedLiveSession)
                } else {
                    hadTrackedLiveSessions = hasTrackedLiveSessions
                }

                let wakeInterval = Self.monitoringWakeInterval(
                    isResolvingInitialLiveSessions: self.isResolvingInitialLiveSessions,
                    hasTrackedLiveSessions: self.state.sessions.contains(where: \.isTrackedLiveSession)
                )
                try? await Task.sleep(for: .milliseconds(Int(wakeInterval * 1_000)))
            }
        }
    }

    // MARK: - Reconciliation

    func reconcileSessionAttachments(
        activeProcesses: [ActiveProcessSnapshot]? = nil,
        ghosttyAvailability: TerminalSessionAttachmentProbe.SnapshotAvailability<TerminalSessionAttachmentProbe.GhosttyTerminalSnapshot>? = nil,
        terminalAvailability: TerminalSessionAttachmentProbe.SnapshotAvailability<TerminalSessionAttachmentProbe.TerminalTabSnapshot>? = nil,
        preResolvedJumpTargets: [String: JumpTarget]? = nil
    ) {
        let activeProcesses = activeProcesses ?? activeAgentProcessDiscovery.discover()

        // Work on a local copy to avoid triggering didSet (and its queue.sync +
        // view invalidation) on every intermediate mutation.
        let originalState = state
        var local = originalState

        let mergedSessions = mergedWithSyntheticClaudeSessions(
            existingSessions: local.sessions,
            activeProcesses: activeProcesses
        )
        if mergedSessions != local.sessions {
            local = SessionState(sessions: mergedSessions)
        }

        // Adopt process TTYs inline on local copy.
        adoptProcessTTYsForClaudeSessions(activeProcesses: activeProcesses, sessions: &local)
        adoptProcessTerminalAppsForClaudeSessions(activeProcesses: activeProcesses, sessions: &local)

        let sessions = local.sessions.filter(\.isTrackedLiveSession)
        guard !sessions.isEmpty else {
            // Flush local changes only if something actually changed.
            if local != originalState {
                state = local
            }
            isResolvingInitialLiveSessions = false
            return
        }

        let resolutionReport: TerminalSessionAttachmentProbe.ResolutionReport
        if let ghosttyAvailability, let terminalAvailability {
            resolutionReport = terminalSessionAttachmentProbe.sessionResolutionReport(
                for: sessions,
                ghosttyAvailability: ghosttyAvailability,
                terminalAvailability: terminalAvailability,
                activeProcesses: activeProcesses,
                allowRecentAttachmentGrace: !isResolvingInitialLiveSessions
            )
        } else {
            resolutionReport = terminalSessionAttachmentProbe.sessionResolutionReport(
                for: sessions,
                activeProcesses: activeProcesses,
                allowRecentAttachmentGrace: !isResolvingInitialLiveSessions
            )
        }
        let resolutions = resolutionReport.resolutions
        let attachmentUpdates = resolutions.mapValues { $0.attachmentState }
        let jumpTargetUpdates = resolutions.reduce(into: [String: JumpTarget]()) { partialResult, entry in
            if let correctedJumpTarget = entry.value.correctedJumpTarget {
                partialResult[entry.key] = correctedJumpTarget
            }
        }

        _ = local.reconcileAttachmentStates(attachmentUpdates)
        _ = local.reconcileJumpTargets(jumpTargetUpdates)

        // Phase 1: populate isProcessAlive in parallel with existing system.
        let aliveIDs = sessionIDsWithAliveProcesses(
            activeProcesses: activeProcesses
        )
        _ = local.markProcessLiveness(
            aliveSessionIDs: aliveIDs
        )

        // Resolve jump targets via the new focused resolver.
        // When pre-resolved targets are provided (computed off-main-actor),
        // use them directly to avoid blocking the main thread with AppleScript calls.
        let resolverJumpTargets = preResolvedJumpTargets
            ?? terminalJumpTargetResolver.resolveJumpTargets(
                for: local.sessions.filter(\.isTrackedLiveSession),
                activeProcesses: activeProcesses
            )
        if !resolverJumpTargets.isEmpty {
            _ = local.reconcileJumpTargets(resolverJumpTargets)
        }

        // Phase 4: remove sessions that are no longer visible.
        _ = local.removeInvisibleSessions()

        // Single state assignment — triggers didSet exactly once.
        // Compare against the original snapshot to catch all mutations
        // (including liveness and resolver jump targets) and skip the
        // write when nothing actually changed, avoiding unnecessary
        // SwiftUI view invalidation.
        let anyChange = local != originalState
        if anyChange {
            state = local
        }

        guard anyChange else {
            if resolutionReport.isAuthoritative {
                isResolvingInitialLiveSessions = false
            }
            return
        }

        if resolutionReport.isAuthoritative {
            isResolvingInitialLiveSessions = false
        }
        onSessionsReconciled?()
        onPersistenceNeeded?()
    }

    // MARK: - Event helpers

    func markSessionAttached(for event: AgentEvent) {
        guard let sessionID = sessionID(for: event) else {
            return
        }

        _ = state.reconcileAttachmentStates([sessionID: .attached])
    }

    func markSessionProcessAlive(for event: AgentEvent) {
        guard let sessionID = sessionID(for: event) else {
            return
        }

        state.markSingleSessionAlive(sessionID: sessionID)
    }

    private func sessionID(for event: AgentEvent) -> String? {
        switch event {
        case let .sessionStarted(payload):
            payload.sessionID
        case let .activityUpdated(payload):
            payload.sessionID
        case let .permissionRequested(payload):
            payload.sessionID
        case let .questionAsked(payload):
            payload.sessionID
        case let .sessionCompleted(payload):
            payload.sessionID
        case let .jumpTargetUpdated(payload):
            payload.sessionID
        case let .claudeSessionMetadataUpdated(payload):
            payload.sessionID
        case let .actionableStateResolved(payload):
            payload.sessionID
        }
    }

    // MARK: - Process liveness

    /// Returns the set of session IDs whose backing agent process is still
    /// alive, based on ``ActiveProcessSnapshot`` matching.
    func sessionIDsWithAliveProcesses(
        activeProcesses: [ActiveProcessSnapshot]
    ) -> Set<String> {
        var aliveIDs: Set<String> = []
        let sessions = state.sessions

        // Claude sessions: reuse the multi-pass matching from representedClaudeProcessKeys.
        let claudeProcesses = activeProcesses.filter { $0.tool == .claudeCode }
        let trackedClaudeSessions = sessions.filter { $0.tool == .claudeCode && !isSyntheticClaudeSession($0) }
        var claimedSessionIDs: Set<String> = []

        // Pass 1: exact session ID match.
        for process in claudeProcesses {
            guard let processSessionID = process.sessionID,
                  let matched = trackedClaudeSessions.first(where: {
                      !claimedSessionIDs.contains($0.id) && $0.id == processSessionID
                  }) else { continue }
            aliveIDs.insert(matched.id)
            claimedSessionIDs.insert(matched.id)
        }

        // Pass 2: transcript path match.
        for process in claudeProcesses {
            guard let transcriptPath = process.transcriptPath,
                  let matched = trackedClaudeSessions.first(where: {
                      !claimedSessionIDs.contains($0.id)
                          && $0.claudeMetadata?.transcriptPath == transcriptPath
                  }) else { continue }
            aliveIDs.insert(matched.id)
            claimedSessionIDs.insert(matched.id)
        }

        // Pass 3: TTY + CWD fallback match.
        for process in claudeProcesses {
            guard let matched = uniqueTrackedClaudeSession(
                for: process,
                sessions: trackedClaudeSessions,
                claimedSessionIDs: claimedSessionIDs
            ) else { continue }
            aliveIDs.insert(matched.id)
            claimedSessionIDs.insert(matched.id)
        }

        // Claude Desktop sessions: Claude Code launched by Claude.app ("local
        // agent mode") runs as a TTY-less subprocess that ps/lsof discovery
        // never sees, so the hook-managed liveness fallback in
        // SessionState.markProcessLiveness would evict these sessions ~6s after
        // they appear (#510).  Keep them alive while Claude.app is running, but
        // let completed sessions expire after a staleness window — Claude
        // Desktop has no per-conversation "closed" signal beyond the SessionEnd
        // hook.  The session is identified
        // by the "Claude.app" terminalApp tag stamped by the hook.
        let isClaudeDesktopRunning = Self.isClaudeDesktopAppRunning()
        if isClaudeDesktopRunning {
            for session in sessions
            where session.tool == .claudeCode
                && !session.isDemoSession
                && session.jumpTarget?.terminalApp == "Claude.app" {
                if session.isSessionEnded { continue }
                let isStale = session.phase == .completed
                    && session.updatedAt.addingTimeInterval(Self.claudeDesktopStalenessTimeout) < Date.now
                if !isStale {
                    aliveIDs.insert(session.id)
                }
            }
        }

        // Conductor sessions: Conductor (conductor.build) runs Claude Code as a
        // headless, TTY-less subprocess of its own runtime, so ps/lsof discovery
        // never sees it — exactly like the Claude Desktop case above (#510).
        // Without an app-level fallback, SessionState.markProcessLiveness would
        // evict these sessions two polls after they appear.  Keep them alive
        // while Conductor is running, but let completed sessions expire after a
        // staleness window (Conductor has no per-session "closed" signal beyond
        // the SessionEnd hook — mirrors the Claude Desktop handling above).  The
        // session is identified by the "Conductor" terminalApp tag stamped by
        // the hook.
        let isConductorRunning = Self.isConductorAppRunning()
        if isConductorRunning {
            for session in sessions
            where session.tool == .claudeCode
                && !session.isDemoSession
                && session.jumpTarget?.terminalApp == "Conductor" {
                if session.isSessionEnded { continue }
                let isStale = session.phase == .completed
                    && session.updatedAt.addingTimeInterval(Self.conductorStalenessTimeout) < Date.now
                if !isStale {
                    aliveIDs.insert(session.id)
                }
            }
        }

        // Synthetic sessions: always alive if the process exists.
        let syntheticSessions = sessions.filter { isSyntheticClaudeSession($0) }
        for session in syntheticSessions {
            aliveIDs.insert(session.id)
        }

        return aliveIDs
    }

    // MARK: - Synthetic Claude sessions

    func mergedWithSyntheticClaudeSessions(
        existingSessions: [AgentSession],
        activeProcesses: [ActiveProcessSnapshot],
        now: Date = .now
    ) -> [AgentSession] {
        let baseSessions = existingSessions.filter { !isSyntheticClaudeSession($0) }
        let syntheticSessions = syntheticClaudeSessions(
            existingSessions: baseSessions,
            activeProcesses: activeProcesses,
            now: now
        )

        return baseSessions + syntheticSessions
    }

    private func syntheticClaudeSessions(
        existingSessions: [AgentSession],
        activeProcesses: [ActiveProcessSnapshot],
        now: Date
    ) -> [AgentSession] {
        let activeClaudeProcesses = activeProcesses.filter { process in
            process.tool == .claudeCode
        }
        let trackedClaudeSessions = existingSessions.filter { session in
            session.tool == .claudeCode && !isSyntheticClaudeSession(session)
        }

        let representedProcessKeys = representedClaudeProcessKeys(
            sessions: trackedClaudeSessions,
            activeProcesses: activeClaudeProcesses
        )

        return activeClaudeProcesses
            .filter { !representedProcessKeys.contains(processIdentityKey($0)) }
            .sorted { processIdentityKey($0) < processIdentityKey($1) }
            .map { syntheticClaudeSession(for: $0, now: now) }
    }

    private func syntheticClaudeSession(
        for process: ActiveProcessSnapshot,
        now: Date
    ) -> AgentSession {
        let workingDirectory = process.workingDirectory
        let workspaceName = workingDirectory.map { WorkspaceNameResolver.workspaceName(for: $0) } ?? "Workspace"
        let terminalApp = supportedTerminalApp(for: process.terminalApp) ?? "Unknown"
        let identity = processIdentityKey(process)

        var session = AgentSession(
            id: "\(AgentSession.syntheticClaudeProcessPrefix)\(identity)",
            title: "Claude · \(workspaceName)",
            tool: .claudeCode,
            origin: .live,
            attachmentState: .attached,
            phase: .completed,
            summary: "Claude session detected from \(terminalApp).",
            updatedAt: now,
            jumpTarget: JumpTarget(
                terminalApp: terminalApp,
                workspaceName: workspaceName,
                paneTitle: "Claude \(workspaceName)",
                workingDirectory: workingDirectory,
                terminalTTY: process.terminalTTY,
                tmuxTarget: process.tmuxTarget,
                tmuxSocketPath: process.tmuxSocketPath
            )
        )
        session.isProcessAlive = true
        return session
    }

    func isSyntheticClaudeSession(_ session: AgentSession) -> Bool {
        session.tool == .claudeCode && session.isSyntheticProcessSession
    }

    // MARK: - Process matching

    private func representedClaudeProcessKeys(
        sessions: [AgentSession],
        activeProcesses: [ActiveProcessSnapshot]
    ) -> Set<String> {
        let trackedClaudeSessions = sessions.filter { session in
            session.tool == .claudeCode && !isSyntheticClaudeSession(session)
        }

        var representedProcessKeys: Set<String> = []
        var claimedSessionIDs: Set<String> = []

        for process in activeProcesses {
            guard let processSessionID = process.sessionID,
                  let matchedSession = trackedClaudeSessions.first(where: {
                      !claimedSessionIDs.contains($0.id) && $0.id == processSessionID
                  }) else {
                continue
            }

            representedProcessKeys.insert(processIdentityKey(process))
            claimedSessionIDs.insert(matchedSession.id)
        }

        for process in activeProcesses {
            let processKey = processIdentityKey(process)
            guard !representedProcessKeys.contains(processKey),
                  let transcriptPath = process.transcriptPath,
                  let matchedSession = trackedClaudeSessions.first(where: {
                      !claimedSessionIDs.contains($0.id)
                          && $0.claudeMetadata?.transcriptPath == transcriptPath
                  }) else {
                continue
            }

            representedProcessKeys.insert(processKey)
            claimedSessionIDs.insert(matchedSession.id)
        }

        for process in activeProcesses {
            let processKey = processIdentityKey(process)
            guard !representedProcessKeys.contains(processKey),
                  let matchedSession = uniqueTrackedClaudeSession(
                      for: process,
                      sessions: trackedClaudeSessions,
                      claimedSessionIDs: claimedSessionIDs
                  ) else {
                continue
            }

            representedProcessKeys.insert(processKey)
            claimedSessionIDs.insert(matchedSession.id)
        }

        return representedProcessKeys
    }

    private func uniqueTrackedClaudeSession(
        for process: ActiveProcessSnapshot,
        sessions: [AgentSession],
        claimedSessionIDs: Set<String>
    ) -> AgentSession? {
        if let terminalTTY = normalizedTTYForMatching(process.terminalTTY),
           let workingDirectory = normalizedPathForMatching(process.workingDirectory) {
            let candidates = claudeTrackedSessions(
                in: sessions,
                claimedSessionIDs: claimedSessionIDs,
                terminalTTY: terminalTTY,
                workingDirectory: workingDirectory
            )
            if candidates.count == 1 {
                return candidates[0]
            }
        }

        if let terminalTTY = normalizedTTYForMatching(process.terminalTTY) {
            let candidates = claudeTrackedSessions(
                in: sessions,
                claimedSessionIDs: claimedSessionIDs,
                terminalTTY: terminalTTY,
                workingDirectory: nil
            )
            if candidates.count == 1 {
                return candidates[0]
            }
        }

        if let workingDirectory = normalizedPathForMatching(process.workingDirectory) {
            let processTTY = normalizedTTYForMatching(process.terminalTTY)
            // When matching by cwd alone, skip sessions whose TTY is known but
            // differs from the process — they belong to a different terminal and
            // should not consume this process's slot.
            let candidates = claudeTrackedSessions(
                in: sessions,
                claimedSessionIDs: claimedSessionIDs,
                terminalTTY: nil,
                workingDirectory: workingDirectory
            ).filter { session in
                guard let sessionTTY = normalizedTTYForMatching(session.jumpTarget?.terminalTTY) else {
                    return true
                }
                return processTTY == nil || sessionTTY == processTTY
            }
            if candidates.count == 1 {
                return candidates[0]
            }

            if candidates.count > 1 {
                return candidates.max(by: { $0.updatedAt < $1.updatedAt })
            }
        }

        return nil
    }

    private func claudeTrackedSessions(
        in sessions: [AgentSession],
        claimedSessionIDs: Set<String>,
        terminalTTY: String?,
        workingDirectory: String?
    ) -> [AgentSession] {
        sessions.filter { session in
            guard session.tool == .claudeCode,
                  !claimedSessionIDs.contains(session.id) else {
                return false
            }

            if let terminalTTY,
               normalizedTTYForMatching(session.jumpTarget?.terminalTTY) != terminalTTY {
                return false
            }

            if let workingDirectory,
               normalizedPathForMatching(session.jumpTarget?.workingDirectory) != workingDirectory {
                return false
            }

            return true
        }
    }

    /// When a Claude session was matched to a process by cwd but has a nil or
    /// mismatched TTY, adopt the process's TTY so that the subsequent terminal
    /// attachment resolution can find and promote the session.
    @discardableResult
    private func adoptProcessTerminalAppsForClaudeSessions(
        activeProcesses: [ActiveProcessSnapshot],
        sessions localState: inout SessionState
    ) {
        var appByTTY: [String: String] = [:]
        for process in activeProcesses where process.tool == .claudeCode {
            guard let tty = normalizedTTYForMatching(process.terminalTTY),
                  let app = supportedTerminalApp(for: process.terminalApp) else { continue }
            appByTTY[tty] = app
        }
        guard !appByTTY.isEmpty else { return }
        let adopted = Self.adoptingTerminalApps(
            sessions: localState.sessions,
            appByTTY: appByTTY,
            ttyKey: { [self] session in normalizedTTYForMatching(session.jumpTarget?.terminalTTY) }
        )
        if adopted != localState.sessions {
            localState = SessionState(sessions: adopted)
        }
    }

    nonisolated static func adoptingTerminalApps(
        sessions: [AgentSession],
        appByTTY: [String: String],
        ttyKey: (AgentSession) -> String?
    ) -> [AgentSession] {
        sessions.map { session in
            guard session.tool == .claudeCode,
                  let current = session.jumpTarget?.terminalApp.trimmingCharacters(in: .whitespacesAndNewlines),
                  current.isEmpty || current.lowercased() == "unknown",
                  let tty = ttyKey(session),
                  let app = appByTTY[tty] else { return session }
            var updated = session
            updated.jumpTarget?.terminalApp = app
            return updated
        }
    }

    private func adoptProcessTTYsForClaudeSessions(
        activeProcesses: [ActiveProcessSnapshot],
        sessions localState: inout SessionState
    ) -> Bool {
        let claudeProcesses = activeProcesses.filter { $0.tool == .claudeCode }
        guard !claudeProcesses.isEmpty else { return false }

        var sessions = localState.sessions
        var changed = false

        for process in claudeProcesses {
            guard let processTTY = process.terminalTTY, !processTTY.isEmpty else { continue }
            let processCWD = normalizedPathForMatching(process.workingDirectory)

            for index in sessions.indices {
                let session = sessions[index]
                guard session.tool == .claudeCode,
                      !isSyntheticClaudeSession(session),
                      let jumpTarget = session.jumpTarget,
                      normalizedPathForMatching(jumpTarget.workingDirectory) == processCWD,
                      normalizedTTYForMatching(jumpTarget.terminalTTY) != normalizedTTYForMatching(processTTY) else {
                    continue
                }

                // Only adopt if no other session already owns this TTY.
                let ttyAlreadyClaimed = sessions.contains { other in
                    other.id != session.id
                        && other.tool == .claudeCode
                        && normalizedTTYForMatching(other.jumpTarget?.terminalTTY) == normalizedTTYForMatching(processTTY)
                }
                guard !ttyAlreadyClaimed else { continue }

                // Only adopt if no other process has the same cwd and already
                // matches this session's TTY (would mean a different process owns it).
                let sessionOwnedByOtherProcess = claudeProcesses.contains { other in
                    normalizedTTYForMatching(other.terminalTTY) == normalizedTTYForMatching(session.jumpTarget?.terminalTTY)
                        && normalizedPathForMatching(other.workingDirectory) == processCWD
                }
                guard !sessionOwnedByOtherProcess else { continue }

                sessions[index].jumpTarget?.terminalTTY = processTTY
                sessions[index].attachmentState = .attached
                sessions[index].updatedAt = .now
                changed = true
                break
            }
        }

        if changed {
            localState = SessionState(sessions: sessions)
        }
        return changed
    }

    // MARK: - Display helpers

    func liveAttachmentKey(for session: AgentSession) -> String? {
        guard let jumpTarget = session.jumpTarget else {
            return nil
        }

        let terminalApp = supportedTerminalApp(for: jumpTarget.terminalApp)
            ?? jumpTarget.terminalApp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !terminalApp.isEmpty else {
            return nil
        }

        if let terminalSessionID = jumpTarget.terminalSessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !terminalSessionID.isEmpty {
            return "\(terminalApp.lowercased()):session:\(terminalSessionID.lowercased())"
        }

        if let terminalTTY = normalizedTTYForMatching(jumpTarget.terminalTTY) {
            return "\(terminalApp.lowercased()):tty:\(terminalTTY.lowercased())"
        }

        let paneTitle = jumpTarget.paneTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let workingDirectory = normalizedPathForMatching(jumpTarget.workingDirectory),
           !paneTitle.isEmpty {
            return "\(terminalApp.lowercased()):cwd:\(workingDirectory):title:\(paneTitle)"
        }

        if let workingDirectory = normalizedPathForMatching(jumpTarget.workingDirectory) {
            return "\(terminalApp.lowercased()):cwd:\(workingDirectory)"
        }

        return nil
    }

    // MARK: - Utilities

    /// Check whether the Claude desktop app is currently running.  Uses
    /// `NSWorkspace.shared.runningApplications` directly because the
    /// `NSRunningApplication.runningApplications(withBundleIdentifier:)` API
    /// can transiently return an empty array even while the app is running,
    /// which would flicker visible Claude Desktop sessions out of the island.
    static func isClaudeDesktopAppRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier == "com.anthropic.claudefordesktop"
        }
    }

    /// Check whether the Conductor app is currently running.  Uses
    /// `NSWorkspace.shared.runningApplications` for the same reason as
    /// ``isClaudeDesktopAppRunning()``.
    static func isConductorAppRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier == "com.conductor.app"
        }
    }

    private func processIdentityKey(_ process: ActiveProcessSnapshot) -> String {
        [
            process.sessionID,
            normalizedTTYForMatching(process.terminalTTY),
            normalizedPathForMatching(process.workingDirectory),
            supportedTerminalApp(for: process.terminalApp),
        ]
        .compactMap { $0 }
        .joined(separator: "|")
    }

    private func syntheticClaudeGroupKey(for process: ActiveProcessSnapshot) -> String? {
        if let workingDirectory = normalizedPathForMatching(process.workingDirectory) {
            return "cwd:\(workingDirectory)"
        }

        if let terminalTTY = normalizedTTYForMatching(process.terminalTTY) {
            return "tty:\(terminalTTY)"
        }

        return nil
    }

    private func syntheticClaudeGroupKey(for session: AgentSession) -> String? {
        if let workingDirectory = normalizedPathForMatching(session.jumpTarget?.workingDirectory) {
            return "cwd:\(workingDirectory)"
        }

        if let terminalTTY = normalizedTTYForMatching(session.jumpTarget?.terminalTTY) {
            return "tty:\(terminalTTY)"
        }

        return nil
    }

    func normalizedPathForMatching(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: value).standardizedFileURL.path.lowercased()
    }

    func normalizedTTYForMatching(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        return value.hasPrefix("/dev/") ? value : "/dev/\(value)"
    }

    func supportedTerminalApp(for value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }

        switch normalized {
        // Standalone terminals
        case "ghostty":
            return "Ghostty"
        case "terminal", "apple_terminal":
            return "Terminal"
        case "iterm", "iterm2", "iterm.app":
            return "iTerm"
        case "cmux":
            return "cmux"
        case "warp", "warpterminal":
            return "Warp"
        case "kaku":
            return "Kaku"
        case "wezterm":
            return "WezTerm"
        case "zellij":
            return "Zellij"
        // VS Code family
        case "vscode", "code", "visual studio code":
            return "VS Code"
        case "vscode-insiders", "code-insiders":
            return "VS Code Insiders"
        case "cursor":
            return "Cursor"
        case "windsurf":
            return "Windsurf"
        case "trae":
            return "Trae"
        case "zed":
            return "Zed"
        // JetBrains family
        case "intellij", "idea":
            return "IntelliJ IDEA"
        case "webstorm":
            return "WebStorm"
        case "pycharm":
            return "PyCharm"
        case "goland":
            return "GoLand"
        case "clion":
            return "CLion"
        case "rubymine":
            return "RubyMine"
        case "phpstorm":
            return "PhpStorm"
        case "rider":
            return "Rider"
        case "rustrover":
            return "RustRover"
        case "conductor":
            return "Conductor"
        default:
            return nil
        }
    }
}
