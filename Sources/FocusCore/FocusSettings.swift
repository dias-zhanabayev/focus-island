import Foundation

public enum ResumeTerminal: String, Codable, CaseIterable, Sendable, Identifiable {
    case terminal
    case iTerm
    case ghostty

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .terminal: "Terminal"
        case .iTerm: "iTerm"
        case .ghostty: "Ghostty"
        }
    }
}

public enum BoardHotKey: String, Codable, CaseIterable, Sendable, Identifiable {
    case optionCommandB
    case controlOptionB
    case off

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .optionCommandB: "⌥⌘B"
        case .controlOptionB: "⌃⌥B"
        case .off: "Выключен"
        }
    }
}

public struct FocusSettings: Codable, Equatable, Sendable {
    public static let defaultsKey = "focus.settings"
    public static let maxParallelRange = 1...6
    public static let stalledReminderRange = 5...60

    public var nextActionEnabled = true
    public var nextActionDelay: TimeInterval = 15
    public var distractionEnabled = true
    public var distractionThreshold: TimeInterval = 20
    public var stopList: StopList = .default
    public var resumeTerminal: ResumeTerminal = .terminal
    public var boardHotKey: BoardHotKey = .optionCommandB
    public var nudgeSoundEnabled = false
    public var maxParallelSessions: Int = 3
    public var stalledReminderMinutes: Int = 15
    public var dayStartEnabled: Bool = true

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = FocusSettings()
        nextActionEnabled = try container.decodeIfPresent(Bool.self, forKey: .nextActionEnabled) ?? defaults.nextActionEnabled
        nextActionDelay = try container.decodeIfPresent(TimeInterval.self, forKey: .nextActionDelay) ?? defaults.nextActionDelay
        distractionEnabled = try container.decodeIfPresent(Bool.self, forKey: .distractionEnabled) ?? defaults.distractionEnabled
        distractionThreshold = try container.decodeIfPresent(TimeInterval.self, forKey: .distractionThreshold) ?? defaults.distractionThreshold
        stopList = try container.decodeIfPresent(StopList.self, forKey: .stopList) ?? defaults.stopList
        resumeTerminal = try container.decodeIfPresent(ResumeTerminal.self, forKey: .resumeTerminal) ?? defaults.resumeTerminal
        boardHotKey = try container.decodeIfPresent(BoardHotKey.self, forKey: .boardHotKey) ?? defaults.boardHotKey
        nudgeSoundEnabled = try container.decodeIfPresent(Bool.self, forKey: .nudgeSoundEnabled) ?? defaults.nudgeSoundEnabled
        let parallel = try container.decodeIfPresent(Int.self, forKey: .maxParallelSessions) ?? defaults.maxParallelSessions
        maxParallelSessions = min(Self.maxParallelRange.upperBound, max(Self.maxParallelRange.lowerBound, parallel))
        let stalled = try container.decodeIfPresent(Int.self, forKey: .stalledReminderMinutes) ?? defaults.stalledReminderMinutes
        stalledReminderMinutes = min(Self.stalledReminderRange.upperBound, max(Self.stalledReminderRange.lowerBound, stalled))
        dayStartEnabled = try container.decodeIfPresent(Bool.self, forKey: .dayStartEnabled) ?? defaults.dayStartEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case nextActionEnabled
        case nextActionDelay
        case distractionEnabled
        case distractionThreshold
        case stopList
        case resumeTerminal
        case boardHotKey
        case nudgeSoundEnabled
        case maxParallelSessions
        case stalledReminderMinutes
        case dayStartEnabled
    }

    public static func load(from defaults: UserDefaults) -> FocusSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(FocusSettings.self, from: data) else {
            return FocusSettings()
        }
        return settings
    }

    public func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
