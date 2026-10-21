import Dispatch
import Foundation
import Testing
@testable import OpenIslandCore

/// Regression coverage for core session lifecycle and visibility behavior.
struct SessionStateTests {

    /// Verifies permission and question events update an already-tracked session.
    @Test
    func appliesPermissionAndQuestionEventsToExistingSessions() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        var state = SessionState()

        state.apply(
            .sessionStarted(
                SessionStarted(
                    sessionID: "session-1",
                    title: "Fix auth bug",
                    tool: .claudeCode,
                    summary: "Booting up",
                    timestamp: startedAt
                )
            )
        )

        state.apply(
            .permissionRequested(
                PermissionRequested(
                    sessionID: "session-1",
                    request: PermissionRequest(
                        title: "Edit file",
                        summary: "Wants to edit middleware",
                        affectedPath: "src/auth/middleware.ts"
                    ),
                    timestamp: startedAt.addingTimeInterval(5)
                )
            )
        )

        #expect(state.attentionCount == 1)
        #expect(state.activeActionableSession?.phase == .waitingForApproval)
        #expect(state.activeActionableSession?.permissionRequest?.affectedPath == "src/auth/middleware.ts")

        state.apply(
            .questionAsked(
                QuestionAsked(
                    sessionID: "session-1",
                    prompt: QuestionPrompt(
                        title: "Which environment?",
                        options: ["Production", "Staging"]
                    ),
                    timestamp: startedAt.addingTimeInterval(10)
                )
            )
        )

        #expect(state.activeActionableSession?.phase == .waitingForAnswer)
        #expect(state.activeActionableSession?.questionPrompt?.options == ["Production", "Staging"])
        #expect(state.activeActionableSession?.permissionRequest == nil)
    }

    /// Contract that the Claude Desktop fix (#510) relies on: a hook-managed
    /// Claude session stays visible for as long as its ID is reported in
    /// `aliveSessionIDs`, and is only evicted after two consecutive polls
    /// where it is absent. ProcessMonitoringCoordinator keeps Claude Desktop
    /// session IDs in that set while Claude.app is running (the desktop
    /// subprocess is TTY-less and invisible to ps/lsof discovery), so they no
    /// longer vanish ~6s after appearing.
    @Test
    func hookManagedClaudeSessionLivenessFollowsReportedAliveSet() {
        var session = AgentSession(
            id: "desktop-1",
            title: "Claude · demo",
            tool: .claudeCode,
            phase: .running,
            summary: "Working",
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        session.isHookManaged = true
        session.isProcessAlive = true
        var state = SessionState(sessions: [session])

        // Reported alive (Claude.app running): stays visible across polls.
        state.markProcessLiveness(aliveSessionIDs: ["desktop-1"])
        state.markProcessLiveness(aliveSessionIDs: ["desktop-1"])
        #expect(state.session(id: "desktop-1")?.isSessionEnded == false)
        #expect(state.session(id: "desktop-1")?.isVisibleInIsland == true)

        // First miss (e.g. Claude.app just quit): debounced, not yet evicted.
        state.markProcessLiveness(aliveSessionIDs: [])
        #expect(state.session(id: "desktop-1")?.isSessionEnded == false)
        #expect(state.session(id: "desktop-1")?.isVisibleInIsland == true)

        // Second consecutive miss: session ends and leaves the island.
        state.markProcessLiveness(aliveSessionIDs: [])
        #expect(state.session(id: "desktop-1")?.isSessionEnded == true)
        #expect(state.session(id: "desktop-1")?.isVisibleInIsland == false)
    }

    /// Regression for the Conductor host support: Conductor runs Claude Code as
    /// a headless, TTY-less subprocess, so ps/lsof discovery never sees it —
    /// exactly the #510 situation. ProcessMonitoringCoordinator therefore keeps
    /// a "Conductor"-tagged session's ID in `aliveSessionIDs` while Conductor is
    /// running; this pins the liveness contract that fallback relies on: the
    /// session stays visible while reported alive and is only evicted after two
    /// consecutive misses (e.g. Conductor quit).
    @Test
    func hookManagedConductorSessionLivenessFollowsReportedAliveSet() {
        var session = AgentSession(
            id: "conductor-1",
            title: "Claude · demo",
            tool: .claudeCode,
            phase: .running,
            summary: "Working",
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        session.isHookManaged = true
        session.isProcessAlive = true
        session.jumpTarget = JumpTarget(
            terminalApp: "Conductor",
            workspaceName: "demo",
            paneTitle: "Claude"
        )
        var state = SessionState(sessions: [session])

        // Reported alive (Conductor running): stays visible across polls.
        state.markProcessLiveness(aliveSessionIDs: ["conductor-1"])
        state.markProcessLiveness(aliveSessionIDs: ["conductor-1"])
        #expect(state.session(id: "conductor-1")?.isSessionEnded == false)
        #expect(state.session(id: "conductor-1")?.isVisibleInIsland == true)

        // First miss (e.g. Conductor just quit): debounced, not yet evicted.
        state.markProcessLiveness(aliveSessionIDs: [])
        #expect(state.session(id: "conductor-1")?.isSessionEnded == false)
        #expect(state.session(id: "conductor-1")?.isVisibleInIsland == true)

        // Second consecutive miss: session ends and leaves the island.
        state.markProcessLiveness(aliveSessionIDs: [])
        #expect(state.session(id: "conductor-1")?.isSessionEnded == true)
        #expect(state.session(id: "conductor-1")?.isVisibleInIsland == false)
    }



    @Test
    func resolvesUserActionsAndKeepsSessionsSortedByRecency() {
        let startedAt = Date(timeIntervalSince1970: 2_000)
        var state = SessionState(
            sessions: [
                AgentSession(
                    id: "older",
                    title: "Older session",
                    tool: .claudeCode,
                    phase: .running,
                    summary: "Working",
                    updatedAt: startedAt
                ),
                AgentSession(
                    id: "newer",
                    title: "Newer session",
                    tool: .claudeCode,
                    phase: .waitingForApproval,
                    summary: "Needs approval",
                    updatedAt: startedAt.addingTimeInterval(5),
                    permissionRequest: PermissionRequest(
                        title: "Edit users.ts",
                        summary: "Needs access",
                        affectedPath: "src/routes/users.ts"
                    )
                ),
            ]
        )

        state.resolvePermission(
            sessionID: "newer",
            resolution: .allowOnce(),
            at: startedAt.addingTimeInterval(20)
        )

        #expect(state.sessions.first?.id == "newer")
        #expect(state.sessions.first?.phase == .running)
        #expect(state.sessions.first?.permissionRequest == nil)

        state.answerQuestion(
            sessionID: "older",
            response: QuestionPromptResponse(answer: "Production"),
            at: startedAt.addingTimeInterval(25)
        )

        #expect(state.sessions.first?.id == "older")
        #expect(state.sessions.first?.summary == "Answered: Production")
    }

    @Test
    func keepsQuestionStateWhileIncidentalRunningUpdatesArrive() {
        let startedAt = Date(timeIntervalSince1970: 2_500)
        var state = SessionState(
            sessions: [
                AgentSession(
                    id: "claude-question",
                    title: "Claude · repo",
                    tool: .claudeCode,
                    attachmentState: .attached,
                    phase: .waitingForAnswer,
                    summary: "Which environment?",
                    updatedAt: startedAt,
                    questionPrompt: QuestionPrompt(
                        title: "Which environment?",
                        questions: [
                            QuestionPromptItem(
                                question: "Which environment?",
                                header: "Env",
                                options: [
                                    QuestionOption(label: "Production"),
                                    QuestionOption(label: "Staging"),
                                ]
                            )
                        ]
                    )
                )
            ]
        )

        state.apply(
            .activityUpdated(
                SessionActivityUpdated(
                    sessionID: "claude-question",
                    summary: "Claude is still waiting for your answer.",
                    phase: .running,
                    timestamp: startedAt.addingTimeInterval(5)
                )
            )
        )

        #expect(state.session(id: "claude-question")?.phase == .waitingForAnswer)
        #expect(state.session(id: "claude-question")?.summary == "Which environment?")
        #expect(state.session(id: "claude-question")?.questionPrompt?.title == "Which environment?")
    }

    @Test
    func actionableStateResolvedClearsWaitingForApproval() {
        let startedAt = Date(timeIntervalSince1970: 5_000)
        var state = SessionState(
            sessions: [
                AgentSession(
                    id: "claude-approval",
                    title: "Claude · repo",
                    tool: .claudeCode,
                    attachmentState: .attached,
                    phase: .waitingForApproval,
                    summary: "Wants to edit file",
                    updatedAt: startedAt,
                    permissionRequest: PermissionRequest(
                        title: "Edit file",
                        summary: "Wants to edit file",
                        affectedPath: "src/main.ts"
                    )
                )
            ]
        )

        state.apply(
            .actionableStateResolved(
                ActionableStateResolved(
                    sessionID: "claude-approval",
                    summary: "Approval was handled outside Open Island.",
                    timestamp: startedAt.addingTimeInterval(10)
                )
            )
        )

        #expect(state.session(id: "claude-approval")?.phase == .running)
        #expect(state.session(id: "claude-approval")?.permissionRequest == nil)
        #expect(state.session(id: "claude-approval")?.summary == "Approval was handled outside Open Island.")
    }

    @Test
    func actionableStateResolvedClearsWaitingForAnswer() {
        let startedAt = Date(timeIntervalSince1970: 5_500)
        var state = SessionState(
            sessions: [
                AgentSession(
                    id: "claude-question",
                    title: "Claude · repo",
                    tool: .claudeCode,
                    attachmentState: .attached,
                    phase: .waitingForAnswer,
                    summary: "Which environment?",
                    updatedAt: startedAt,
                    questionPrompt: QuestionPrompt(
                        title: "Which environment?",
                        options: ["Production", "Staging"]
                    )
                )
            ]
        )

        state.apply(
            .actionableStateResolved(
                ActionableStateResolved(
                    sessionID: "claude-question",
                    summary: "Approval was handled outside Open Island.",
                    timestamp: startedAt.addingTimeInterval(10)
                )
            )
        )

        #expect(state.session(id: "claude-question")?.phase == .running)
        #expect(state.session(id: "claude-question")?.questionPrompt == nil)
    }

    @Test
    func actionableStateResolvedIsNoOpWhenAlreadyRunning() {
        let startedAt = Date(timeIntervalSince1970: 6_000)
        var state = SessionState(
            sessions: [
                AgentSession(
                    id: "claude-running",
                    title: "Claude · repo",
                    tool: .claudeCode,
                    phase: .running,
                    summary: "Working on it",
                    updatedAt: startedAt
                )
            ]
        )

        state.apply(
            .actionableStateResolved(
                ActionableStateResolved(
                    sessionID: "claude-running",
                    summary: "Should not change anything.",
                    timestamp: startedAt.addingTimeInterval(10)
                )
            )
        )

        #expect(state.session(id: "claude-running")?.phase == .running)
        #expect(state.session(id: "claude-running")?.summary == "Working on it")
    }

    @Test
    func preservesLiveSessionOriginFromStartEvent() {
        var state = SessionState()

        state.apply(
            .sessionStarted(
                SessionStarted(
                    sessionID: "live-session-1",
                    title: "Live session",
                    tool: .claudeCode,
                    origin: .live,
                    summary: "Live data",
                    timestamp: .now
                )
            )
        )

        #expect(state.session(id: "live-session-1")?.origin == .live)
        #expect(state.session(id: "live-session-1")?.isDemoSession == false)
        #expect(state.session(id: "live-session-1")?.attachmentState == .attached)
    }

    @Test
    func reconcileAttachmentStatesUpdatesExistingSessionsOnly() {
        let startedAt = Date(timeIntervalSince1970: 4_000)
        var state = SessionState(
            sessions: [
                AgentSession(
                    id: "attached-session",
                    title: "Attached session",
                    tool: .claudeCode,
                    attachmentState: .stale,
                    phase: .completed,
                    summary: "Turn completed",
                    updatedAt: startedAt
                ),
                AgentSession(
                    id: "untouched-session",
                    title: "Untouched session",
                    tool: .claudeCode,
                    attachmentState: .attached,
                    phase: .running,
                    summary: "Still running",
                    updatedAt: startedAt.addingTimeInterval(5)
                ),
            ]
        )

        let changed = state.reconcileAttachmentStates([
            "attached-session": .attached,
            "missing-session": .detached,
        ])

        #expect(changed)
        #expect(state.session(id: "attached-session")?.attachmentState == .attached)
        #expect(state.session(id: "attached-session")?.summary == "Turn completed")
        #expect(state.session(id: "untouched-session")?.attachmentState == .attached)
    }

    @Test
    func liveCountsOnlyIncludeVisibleSessions() {
        var liveRunning = AgentSession(
            id: "live-running",
            title: "Live running",
            tool: .claudeCode,
            attachmentState: .attached,
            phase: .running,
            summary: "Working",
            updatedAt: .now
        )
        liveRunning.isProcessAlive = true

        var liveAttention = AgentSession(
            id: "live-attention",
            title: "Live attention",
            tool: .claudeCode,
            attachmentState: .attached,
            phase: .waitingForApproval,
            summary: "Needs approval",
            updatedAt: .now
        )
        liveAttention.isProcessAlive = true

        let state = SessionState(
            sessions: [
                liveRunning,
                liveAttention,
                AgentSession(
                    id: "detached-running",
                    title: "Detached running",
                    tool: .claudeCode,
                    attachmentState: .detached,
                    phase: .running,
                    summary: "Old run",
                    updatedAt: .now
                ),
            ]
        )

        #expect(state.liveSessionCount == 2)
        #expect(state.liveRunningCount == 1)
        #expect(state.liveAttentionCount == 1)
        #expect(state.runningCount == 2)
    }

    @Test
    func bridgeEnvelopeRoundTripsThroughLineCodec() throws {
        let envelope = BridgeEnvelope.event(
            .permissionRequested(
                PermissionRequested(
                    sessionID: "session-42",
                    request: PermissionRequest(
                        title: "Edit middleware",
                        summary: "Needs to edit auth middleware.",
                        affectedPath: "src/auth/middleware.ts"
                    ),
                    timestamp: Date(timeIntervalSince1970: 3_000)
                )
            )
        )

        var buffer = try BridgeCodec.encodeLine(envelope)
        let decoded = try BridgeCodec.decodeLines(from: &buffer)

        #expect(decoded == [envelope])
        #expect(buffer.isEmpty)
    }

    @Test
    func bridgeQuestionCommandEmitsQuestionEventForExistingSession() async throws {
        let socketURL = BridgeSocketLocation.uniqueTestURL()
        let server = BridgeServer(socketURL: socketURL)
        try server.start()
        defer { server.stop() }

        let observer = LocalBridgeClient(socketURL: socketURL)
        let stream = try observer.connect()
        defer { observer.disconnect() }
        try await observer.send(.registerClient(role: .observer))

        let startPayload = ClaudeHookPayload(
            cwd: "/tmp/worktree",
            hookEventName: .sessionStart,
            sessionID: "claude-session-question"
        )
        _ = try BridgeCommandClient(socketURL: socketURL).send(.processClaudeHook(startPayload))

        let prompt = QuestionPrompt(
            title: "Which environment?",
            options: ["Production", "Staging", "Local"]
        )
        _ = try BridgeCommandClient(socketURL: socketURL).send(
            .requestQuestion(sessionID: "claude-session-question", prompt: prompt)
        )

        var iterator = stream.makeAsyncIterator()
        let startedEvent = try await nextEvent(from: &iterator)
        let questionEvent = try await nextEvent(from: &iterator)

        #expect(startedEvent.isSessionStarted)
        #expect(questionEvent.questionPrompt?.title == "Which environment?")
        #expect(questionEvent.questionPrompt?.options == ["Production", "Staging", "Local"])
    }

    @Test
    func jumpTargetRoundTripsWarpPaneUUIDThroughCodable() throws {
        let target = JumpTarget(
            terminalApp: "Warp",
            workspaceName: "demo",
            paneTitle: "Claude demo",
            workingDirectory: "/tmp/demo",
            warpPaneUUID: "D1A5DF3027E44FC080FE2656FAF2BA2E"
        )
        let data = try JSONEncoder().encode(target)
        let decoded = try JSONDecoder().decode(JumpTarget.self, from: data)
        #expect(decoded.warpPaneUUID == "D1A5DF3027E44FC080FE2656FAF2BA2E")

        // And: legacy JSON without the field decodes to nil
        let legacyJSON = """
        {"terminalApp":"Warp","workspaceName":"demo","paneTitle":"Claude demo","workingDirectory":"/tmp/demo"}
        """.data(using: .utf8)!
        let legacy = try JSONDecoder().decode(JumpTarget.self, from: legacyJSON)
        #expect(legacy.warpPaneUUID == nil)
    }

    @Test
    func firstSeenAtIsWrittenOnceAndPreservedAcrossSubsequentEvents() {
        let t0 = Date(timeIntervalSince1970: 10_000)
        var state = SessionState()
        state.apply(.sessionStarted(SessionStarted(
            sessionID: "s-1",
            title: "First boot",
            tool: .claudeCode,
            summary: "Starting",
            timestamp: t0
        )))

        #expect(state.session(id: "s-1")?.firstSeenAt == t0)

        // A repeated sessionStarted (e.g. hook reconnect) must preserve the
        // original firstSeenAt even though the payload timestamp is later.
        state.apply(.sessionStarted(SessionStarted(
            sessionID: "s-1",
            title: "Re-attached",
            tool: .claudeCode,
            summary: "Reattached",
            timestamp: t0.addingTimeInterval(120)
        )))
        #expect(state.session(id: "s-1")?.firstSeenAt == t0)
        #expect(state.session(id: "s-1")?.updatedAt == t0.addingTimeInterval(120))

        // Activity updates leave firstSeenAt untouched.
        state.apply(.activityUpdated(SessionActivityUpdated(
            sessionID: "s-1",
            summary: "Working",
            phase: .running,
            timestamp: t0.addingTimeInterval(240)
        )))
        #expect(state.session(id: "s-1")?.firstSeenAt == t0)
    }

    @Test
    func firstSeenAtPersistsThroughRegistryRoundTrip() throws {
        let t0 = Date(timeIntervalSince1970: 20_000)
        let session = AgentSession(
            id: "claude-1",
            title: "Repo",
            tool: .claudeCode,
            phase: .running,
            summary: "Working",
            updatedAt: t0.addingTimeInterval(60),
            firstSeenAt: t0
        )
        let record = ClaudeTrackedSessionRecord(session: session)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ClaudeTrackedSessionRecord.self, from: data)

        #expect(decoded.firstSeenAt == t0)
        #expect(decoded.session.firstSeenAt == t0)

        // Legacy records without firstSeenAt decode cleanly and fall back to
        // updatedAt on the restored AgentSession.
        let legacyJSON = """
        {
          "attachmentState": "stale",
          "phase": "running",
          "sessionID": "claude-legacy",
          "summary": "Legacy",
          "title": "Legacy",
          "updatedAt": "2026-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!
        let legacy = try decoder.decode(ClaudeTrackedSessionRecord.self, from: legacyJSON)
        #expect(legacy.firstSeenAt == nil)
        let legacyUpdated = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")
        #expect(legacy.session.firstSeenAt == legacyUpdated)
    }

}

private enum SessionStateTestError: Error {
    case streamEnded
}

private func nextEvent(
    from iterator: inout AsyncThrowingStream<AgentEvent, Error>.AsyncIterator
) async throws -> AgentEvent {
    guard let event = try await iterator.next() else {
        throw SessionStateTestError.streamEnded
    }

    return event
}

private extension AgentEvent {
    var isSessionStarted: Bool {
        if case .sessionStarted = self {
            true
        } else {
            false
        }
    }

    var startedSession: SessionStarted? {
        if case let .sessionStarted(payload) = self {
            payload
        } else {
            nil
        }
    }

    var isPermissionRequested: Bool {
        if case .permissionRequested = self {
            true
        } else {
            false
        }
    }

    var questionPrompt: QuestionPrompt? {
        if case let .questionAsked(payload) = self {
            payload.prompt
        } else {
            nil
        }
    }

    var activityUpdate: SessionActivityUpdated? {
        if case let .activityUpdated(payload) = self {
            payload
        } else {
            nil
        }
    }

    var jumpTargetUpdate: JumpTargetUpdated? {
        if case let .jumpTargetUpdated(payload) = self {
            payload
        } else {
            nil
        }
    }

    var sessionCompleted: SessionCompleted? {
        if case let .sessionCompleted(payload) = self {
            payload
        } else {
            nil
        }
    }
}

private func jsonObject(from data: Data?) throws -> [String: Any] {
    guard let data else {
        return [:]
    }

    let object = try JSONSerialization.jsonObject(with: data)
    return object as? [String: Any] ?? [:]
}

private func sendOnGCDThread(
    _ command: BridgeCommand,
    socketURL: URL
) async throws -> BridgeResponse? {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            do {
                let response = try BridgeCommandClient(socketURL: socketURL).send(command)
                continuation.resume(returning: response)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
