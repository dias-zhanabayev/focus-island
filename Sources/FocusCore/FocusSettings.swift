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
    public static let pomodoroFocusRange = 5...120
    public static let pomodoroBreakRange = 1...30
    public static let pomodoroCycleRange = 2...8

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
    public var autoBreakEnabled: Bool = true
    public var breakSoundEnabled: Bool = true
    public var pomodoroFocusMinutes: Int = 50
    public var pomodoroBreakMinutes: Int = 10
    public var pomodoroCycle: Int = 4
    private var timerDefaultsVersion = Self.currentTimerDefaultsVersion

    private static let currentTimerDefaultsVersion = 2

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
        autoBreakEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoBreakEnabled) ?? defaults.autoBreakEnabled
        breakSoundEnabled = try container.decodeIfPresent(Bool.self, forKey: .breakSoundEnabled) ?? defaults.breakSoundEnabled
        let focus = try container.decodeIfPresent(Int.self, forKey: .pomodoroFocusMinutes) ?? defaults.pomodoroFocusMinutes
        pomodoroFocusMinutes = min(Self.pomodoroFocusRange.upperBound, max(Self.pomodoroFocusRange.lowerBound, focus))
        let pause = try container.decodeIfPresent(Int.self, forKey: .pomodoroBreakMinutes) ?? defaults.pomodoroBreakMinutes
        pomodoroBreakMinutes = min(Self.pomodoroBreakRange.upperBound, max(Self.pomodoroBreakRange.lowerBound, pause))
        let cycle = try container.decodeIfPresent(Int.self, forKey: .pomodoroCycle) ?? defaults.pomodoroCycle
        pomodoroCycle = min(Self.pomodoroCycleRange.upperBound, max(Self.pomodoroCycleRange.lowerBound, cycle))
        let version = try container.decodeIfPresent(Int.self, forKey: .timerDefaultsVersion) ?? 1
        if version < Self.currentTimerDefaultsVersion, pomodoroFocusMinutes == 25, pomodoroBreakMinutes == 5 {
            pomodoroFocusMinutes = defaults.pomodoroFocusMinutes
            pomodoroBreakMinutes = defaults.pomodoroBreakMinutes
        }
        timerDefaultsVersion = Self.currentTimerDefaultsVersion
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
        case autoBreakEnabled
        case breakSoundEnabled
        case pomodoroFocusMinutes
        case pomodoroBreakMinutes
        case pomodoroCycle
        case timerDefaultsVersion
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
