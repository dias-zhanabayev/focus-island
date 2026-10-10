import Foundation
import OpenIslandCore

public enum AttentionReason: String, Equatable, Sendable {
    case approval
    case question
    case unseenCompletion
}

public enum NextAlternative: Equatable, Sendable {
    case attend(sessionID: String, reason: AttentionReason, since: Date)
    case review(sessionID: String)
    case startTask(taskID: String, sameProject: Bool)
}

public struct NextActionInput: Sendable {
    public var triggeringSessionID: String
    public var sessions: [AgentSession]
    public var unseenCompletedSessionIDs: Set<String>
    public var board: BoardSnapshot
    public var sessionTaskBindings: [String: String]
    public var skippedTaskIDs: Set<String>

    public init(triggeringSessionID: String, sessions: [AgentSession], unseenCompletedSessionIDs: Set<String>, board: BoardSnapshot, sessionTaskBindings: [String: String], skippedTaskIDs: Set<String>) {
        self.triggeringSessionID = triggeringSessionID
        self.sessions = sessions
        self.unseenCompletedSessionIDs = unseenCompletedSessionIDs
        self.board = board
        self.sessionTaskBindings = sessionTaskBindings
        self.skippedTaskIDs = skippedTaskIDs
    }
}

public enum NextActionEngine {
    public static func alternatives(_ input: NextActionInput, triggerCWD: String?, parked: Set<String>, limit: Int = 2) -> [NextAlternative] {
        guard limit > 0 else { return [] }
        let others = input.sessions
            .filter { $0.id != input.triggeringSessionID && !parked.contains($0.id) && $0.isVisibleInIsland && !$0.isSessionEnded && !$0.isDemoSession && !$0.isSyntheticProcessSession }
            .sorted { $0.updatedAt < $1.updatedAt }

        var result: [NextAlternative] = []
        for session in others where session.phase == .waitingForApproval {
            result.append(.attend(sessionID: session.id, reason: .approval, since: session.updatedAt))
        }
        for session in others where session.phase == .waitingForAnswer {
            result.append(.attend(sessionID: session.id, reason: .question, since: session.updatedAt))
        }
        for session in others where session.phase == .completed && input.unseenCompletedSessionIDs.contains(session.id) {
            result.append(.review(sessionID: session.id))
        }

        if result.count < limit {
            let todos = input.board.tasks(in: .todo).filter { !input.skippedTaskIDs.contains($0.id) }
            let tagged = todos.map { ($0, isSameProject($0.projectPath, triggerCWD)) }
            for (task, same) in tagged where same {
                result.append(.startTask(taskID: task.id, sameProject: true))
            }
            for (task, same) in tagged where !same {
                result.append(.startTask(taskID: task.id, sameProject: false))
            }
        }
        return Array(result.prefix(limit))
    }

    private static func isSameProject(_ projectPath: String?, _ cwd: String?) -> Bool {
        guard let projectPath, !projectPath.isEmpty, let cwd, !cwd.isEmpty else { return false }
        let project = projectPath.hasSuffix("/") ? String(projectPath.dropLast()) : projectPath
        return cwd == project || cwd.hasPrefix(project + "/")
    }
}
