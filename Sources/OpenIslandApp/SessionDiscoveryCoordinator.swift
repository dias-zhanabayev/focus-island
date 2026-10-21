import Foundation
import Observation
import OpenIslandCore

@MainActor
@Observable
final class SessionDiscoveryCoordinator {

    /// Raw I/O results collected off the main thread during startup.
    struct StartupDiscoveryPayload: Sendable {
        var claudeRecords: [ClaudeTrackedSessionRecord]
        var claudeRecordsNeedPrune: Bool
        var discoveredClaudeSessions: [AgentSession]
        var hooksBinaryURL: URL?
    }

    @ObservationIgnored
    var onStatusMessage: ((String) -> Void)?

    @ObservationIgnored
    var stateAccessor: (() -> SessionState)?

    @ObservationIgnored
    var stateUpdater: ((SessionState) -> Void)?

    @ObservationIgnored
    var onStateChanged: (() -> Void)?

    @ObservationIgnored
    private let claudeSessionRegistry: ClaudeSessionRegistry

    init(claudeSessionRegistry: ClaudeSessionRegistry = ClaudeSessionRegistry()) {
        self.claudeSessionRegistry = claudeSessionRegistry
    }

    @ObservationIgnored
    private let claudeTranscriptDiscovery = ClaudeTranscriptDiscovery()

    @ObservationIgnored
    private var claudeSessionPersistenceTask: Task<Void, Never>?

    private var state: SessionState {
        get { stateAccessor?() ?? SessionState() }
        set {
            stateUpdater?(newValue)
            onStateChanged?()
        }
    }

    // MARK: - Startup discovery

    /// Performs all startup file I/O off the main thread and returns the raw results.
    nonisolated func loadStartupDiscoveryPayload() -> StartupDiscoveryPayload {
        let cutoff = Date.now.addingTimeInterval(-86_400)

        let allClaude = (try? claudeSessionRegistry.load()) ?? []
        let claudeRecords = allClaude.filter { $0.updatedAt >= cutoff && $0.shouldRestoreToLiveState }

        let discoveredClaude = claudeTranscriptDiscovery.discoverRecentSessions()

        return StartupDiscoveryPayload(
            claudeRecords: claudeRecords,
            claudeRecordsNeedPrune: claudeRecords != allClaude,
            discoveredClaudeSessions: discoveredClaude,
            hooksBinaryURL: HooksBinaryLocator.locate(
                executableDirectory: Bundle.main.executableURL?.deletingLastPathComponent()
            )
        )
    }

    /// Applies startup discovery results on the main thread after background I/O completes.
    /// Returns the hooksBinaryURL found during startup.
    func applyStartupDiscoveryPayload(_ payload: StartupDiscoveryPayload) {
        // Prune stale records if needed.
        if payload.claudeRecordsNeedPrune {
            try? claudeSessionRegistry.save(payload.claudeRecords)
        }
        // Restore persisted Claude sessions.
        if !payload.claudeRecords.isEmpty {
            let restoredSessions = payload.claudeRecords.map(\.restorableSession)
            state = SessionState(sessions: mergeDiscoveredSessions(restoredSessions))
            onStatusMessage?("Restored \(payload.claudeRecords.count) recent Claude session(s) from local registry.")
        }

        // Merge discovered Claude sessions.
        if !payload.discoveredClaudeSessions.isEmpty {
            let mergedSessions = mergeDiscoveredSessions(payload.discoveredClaudeSessions)
            state = SessionState(sessions: mergedSessions)
            scheduleClaudeSessionPersistence()
            onStatusMessage?("Discovered \(payload.discoveredClaudeSessions.count) recent Claude session(s) from local transcripts.")
        }
    }

    // MARK: - Merge & discovery

    func mergeDiscoveredSessions(_ discoveredSessions: [AgentSession]) -> [AgentSession] {
        var mergedByID = Dictionary(uniqueKeysWithValues: state.sessions.map { ($0.id, $0) })

        for discovered in discoveredSessions {
            if let existing = mergedByID[discovered.id] {
                mergedByID[discovered.id] = merge(discovered: discovered, into: existing)
            } else if let existingID = existingSessionID(matchingTranscriptOf: discovered, in: mergedByID) {
                mergedByID[existingID] = merge(discovered: discovered, into: mergedByID[existingID]!)
            } else {
                mergedByID[discovered.id] = discovered
            }
        }

        return Array(mergedByID.values)
    }

    private func existingSessionID(
        matchingTranscriptOf discovered: AgentSession,
        in sessions: [String: AgentSession]
    ) -> String? {
        guard let discoveredPath = discovered.claudeMetadata?.transcriptPath,
              !discoveredPath.isEmpty else {
            return nil
        }

        return sessions.first(where: {
            $0.value.claudeMetadata?.transcriptPath == discoveredPath
        })?.key
    }

    private func merge(discovered: AgentSession, into existing: AgentSession) -> AgentSession {
        var merged = existing
        let discoveredIsNewer = discovered.updatedAt >= existing.updatedAt

        if discoveredIsNewer {
            merged.title = discovered.title
            merged.phase = discovered.phase
            merged.summary = discovered.summary
            merged.updatedAt = discovered.updatedAt
            merged.permissionRequest = discovered.permissionRequest
            merged.questionPrompt = discovered.questionPrompt
        }

        merged.origin = existing.origin ?? discovered.origin
        merged.attachmentState = mergeAttachmentState(existing.attachmentState, discovered.attachmentState)
        merged.jumpTarget = existing.jumpTarget ?? discovered.jumpTarget
        merged.claudeMetadata = mergeClaudeMetadata(existing.claudeMetadata, discovered.claudeMetadata)

        return merged
    }

    private func mergeAttachmentState(
        _ existing: SessionAttachmentState,
        _ discovered: SessionAttachmentState
    ) -> SessionAttachmentState {
        switch (existing, discovered) {
        case (.attached, _), (_, .attached):
            .attached
        case (.stale, _), (_, .stale):
            .stale
        case (.detached, .detached):
            .detached
        }
    }

    private func mergeClaudeMetadata(
        _ existing: ClaudeSessionMetadata?,
        _ discovered: ClaudeSessionMetadata?
    ) -> ClaudeSessionMetadata? {
        guard let existing else {
            return discovered?.isEmpty == true ? nil : discovered
        }

        guard let discovered else {
            return existing.isEmpty ? nil : existing
        }

        let merged = ClaudeSessionMetadata(
            transcriptPath: discovered.transcriptPath ?? existing.transcriptPath,
            initialUserPrompt: existing.initialUserPrompt ?? discovered.initialUserPrompt ?? discovered.lastUserPrompt,
            lastUserPrompt: discovered.lastUserPrompt ?? existing.lastUserPrompt,
            lastAssistantMessage: discovered.lastAssistantMessage ?? existing.lastAssistantMessage,
            currentTool: discovered.currentTool ?? existing.currentTool,
            currentToolInputPreview: discovered.currentToolInputPreview ?? existing.currentToolInputPreview,
            model: discovered.model ?? existing.model,
            startupSource: discovered.startupSource ?? existing.startupSource,
            permissionMode: discovered.permissionMode ?? existing.permissionMode,
            agentID: discovered.agentID ?? existing.agentID,
            agentType: discovered.agentType ?? existing.agentType,
            worktreeBranch: discovered.worktreeBranch ?? existing.worktreeBranch,
            activeSubagents: existing.activeSubagents.isEmpty ? discovered.activeSubagents : existing.activeSubagents
        )
        return merged.isEmpty ? nil : merged
    }

    // MARK: - Persistence scheduling

    private static func persistenceTask(
        operation: @escaping @Sendable () throws -> Void
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            do {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                try operation()
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    func scheduleClaudeSessionPersistence() {
        claudeSessionPersistenceTask?.cancel()

        let records = state.sessions
            .filter {
                $0.tool == .claudeCode
                    && $0.isTrackedLiveSession
                    && !$0.isSyntheticProcessSession
                    && $0.updatedAt >= Date.now.addingTimeInterval(-86_400)
                    && ($0.jumpTarget != nil || $0.claudeMetadata?.transcriptPath != nil)
            }
            .map(ClaudeTrackedSessionRecord.init(session:))
        let registry = claudeSessionRegistry

        claudeSessionPersistenceTask = Self.persistenceTask {
            try registry.save(records)
        }
    }
}
