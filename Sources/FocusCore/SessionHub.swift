import Foundation
import OpenIslandCore

public struct PlanProgress: Equatable, Sendable {
    public var completed: Int
    public var total: Int
    public var currentTitle: String?

    public init(completed: Int, total: Int, currentTitle: String?) {
        self.completed = completed
        self.total = total
        self.currentTitle = currentTitle
    }

    public static func from(_ tasks: [ClaudeTaskInfo]) -> PlanProgress? {
        guard !tasks.isEmpty else { return nil }
        let current = tasks.first { $0.status == .inProgress }
        return PlanProgress(
            completed: tasks.filter { $0.status == .completed }.count,
            total: tasks.count,
            currentTitle: current.map { $0.activeForm ?? $0.title }
        )
    }

    public func remaining(planStartedAt: Date, now: Date) -> TimeInterval? {
        guard completed > 0 else { return nil }
        let elapsed = max(0, now.timeIntervalSince(planStartedAt))
        return elapsed / Double(completed) * Double(max(0, total - completed))
    }

    public var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }
}

public enum HubGroup: Int, CaseIterable, Sendable {
    case waiting
    case review
    case running
    case idle
    case unbound
    case parked
    case done

    public var isSettled: Bool {
        self == .parked || self == .done
    }

    public var title: String {
        switch self {
        case .waiting: "Ждут тебя"
        case .review: "Закончил, проверь"
        case .running: "Работают"
        case .idle: "Твой ход"
        case .unbound: "Без задачи"
        case .parked: "На паузе"
        case .done: "Завершённые"
        }
    }
}

public struct HubRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var group: HubGroup
    public var taskID: String?
    public var title: String
    public var projectName: String?
    public var detail: String
    public var since: Date
    public var progress: PlanProgress?

    public init(id: String, group: HubGroup, taskID: String?, title: String, projectName: String?, detail: String, since: Date, progress: PlanProgress?) {
        self.id = id
        self.group = group
        self.taskID = taskID
        self.title = title
        self.projectName = projectName
        self.detail = detail
        self.since = since
        self.progress = progress
    }
}

public enum SessionHub {
    public static let unboundIdleMinutes = 30
    public static let promptPreviewLength = 40

    public static func rows(sessions: [AgentSession], records: [String: SessionRecord], board: BoardSnapshot, unseenCompleted: Set<String>, now: Date) -> [HubRow] {
        let rows = sessions
            .filter { $0.isVisibleInIsland && !$0.isSessionEnded && !$0.isDemoSession && !$0.isSyntheticProcessSession }
            .compactMap { row(for: $0, record: records[$0.id], board: board, unseenCompleted: unseenCompleted, now: now) }
        return rows.sorted {
            if $0.group != $1.group { return $0.group.rawValue < $1.group.rawValue }
            if $0.since != $1.since { return $0.since < $1.since }
            return $0.id < $1.id
        }
    }

    private static func row(for session: AgentSession, record: SessionRecord?, board: BoardSnapshot, unseenCompleted: Set<String>, now: Date) -> HubRow? {
        let task = board.task(id: record?.taskId)
        let cwd = session.jumpTarget?.workingDirectory ?? record?.cwd
        let projectName = record?.projectName.flatMap { $0.isEmpty ? nil : $0 } ?? SessionHistory.projectName(for: cwd)
        let progress = PlanProgress.from(session.claudeMetadata?.activeTasks ?? [])
        let minutes = max(0, Int(now.timeIntervalSince(session.updatedAt) / 60))

        let group: HubGroup
        if record?.doneAt != nil, record?.taskId != nil {
            group = .done
        } else if record?.parkedAt != nil {
            group = .parked
        } else if session.phase == .waitingForApproval || session.phase == .waitingForAnswer {
            group = .waiting
        } else if session.phase == .completed && unseenCompleted.contains(session.id) {
            group = .review
        } else if task == nil && session.phase != .running && minutes >= unboundIdleMinutes {
            group = .unbound
        } else if session.phase == .running {
            group = .running
        } else {
            group = .idle
        }

        let title: String
        if let task {
            title = task.title
        } else {
            let prompt = (record?.firstPrompt ?? session.claudeMetadata?.initialUserPrompt)?
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            let name = projectName ?? "без проекта"
            if let prompt, !prompt.isEmpty {
                title = "\(name) · «\(String(prompt.prefix(promptPreviewLength)))»"
            } else {
                title = name
            }
        }

        return HubRow(
            id: session.id,
            group: group,
            taskID: task?.id,
            title: title,
            projectName: projectName,
            detail: detail(group: group, session: session, progress: progress, minutes: minutes),
            since: session.updatedAt,
            progress: progress
        )
    }

    private static func detail(group: HubGroup, session: AgentSession, progress: PlanProgress?, minutes: Int) -> String {
        switch group {
        case .waiting:
            let what: String
            if session.phase == .waitingForApproval {
                let request = session.permissionRequest
                let subject = [request?.summary, request?.toolName, request?.title]
                    .compactMap { $0 }
                    .first { !$0.isEmpty }
                what = subject.map { "Разрешение \($0)" } ?? "Разрешение"
            } else {
                what = session.questionPrompt?.title ?? "Вопрос"
            }
            return "\(what) · ждёт \(minutes) мин"
        case .review:
            return "Claude закончил \(minutes) мин назад"
        case .running:
            guard let progress else { return "\(minutes) мин в работе" }
            let step = min(progress.total, progress.completed + 1)
            var parts = ["Шаг \(step) из \(progress.total)"]
            if let current = progress.currentTitle { parts.append(current) }
            parts.append("\(minutes) мин")
            return parts.joined(separator: " · ")
        case .idle:
            return "Claude закончил \(minutes) мин назад"
        case .unbound:
            return "Нет активности \(minutes) мин"
        case .parked:
            return "На паузе · \(minutes) мин"
        case .done:
            return "Завершена"
        }
    }
}

public enum StalledPolicy {
    public static let reviewMinutes = 60
    public static let unboundMinutes = 120

    public static func stalled(rows: [HubRow], reminderMinutes: Int, now: Date) -> [HubRow] {
        rows
            .filter { row in
                let minutes = Int(now.timeIntervalSince(row.since) / 60)
                switch row.group {
                case .waiting: return minutes >= reminderMinutes
                case .review: return minutes >= reviewMinutes
                case .unbound: return minutes >= unboundMinutes
                case .running, .idle, .parked, .done: return false
                }
            }
            .sorted { $0.since < $1.since }
    }
}

public struct OverloadSuggestion: Equatable, Sendable {
    public let slots: [HubRow]
    public let attend: HubRow?
    public let park: HubRow?

    public init(slots: [HubRow], attend: HubRow?, park: HubRow?) {
        self.slots = slots
        self.attend = attend
        self.park = park
    }
}

public enum OverloadPolicy {
    public static func evaluate(rows: [HubRow], limit: Int, taskID: String?) -> OverloadSuggestion? {
        guard let taskID else { return nil }
        let live = rows.filter { $0.taskID == taskID && !$0.group.isSettled }
        guard live.count > limit else { return nil }
        let attend = live.filter { $0.group == .waiting }.min { $0.since < $1.since }
        let park = live.filter { $0.group == .running }.max { $0.since < $1.since }
        return OverloadSuggestion(slots: live, attend: attend, park: park)
    }
}

public enum DayStartPolicy {
    public static let earliestHour = 5

    public static func shouldShow(enabled: Bool, plan: DayPlan?, now: Date, calendar: Calendar) -> Bool {
        guard enabled else { return false }
        guard calendar.component(.hour, from: now) >= earliestHour else { return false }
        return plan?.dayStartShownAt == nil
    }
}
