import Foundation
import Testing
@testable import FocusCore

struct FocusSettingsTests {
    @Test
    func defaultsMatchSpec() {
        let settings = FocusSettings()
        #expect(settings.nextActionDelay == 15)
        #expect(settings.distractionThreshold == 20)
        #expect(settings.stopList == .default)
        #expect(settings.resumeTerminal == .terminal)
        #expect(settings.boardHotKey == .optionCommandB)
        #expect(settings.nudgeSoundEnabled == false)
    }

    @Test
    func partialJSONDecodesWithDefaults() throws {
        let settings = try JSONDecoder().decode(FocusSettings.self, from: Data(#"{"nextActionDelay":30}"#.utf8))
        var expected = FocusSettings()
        expected.nextActionDelay = 30
        #expect(settings == expected)
    }

    @Test
    func roundTripsThroughUserDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "focus-settings-\(UUID().uuidString)"))
        var settings = FocusSettings()
        settings.nextActionDelay = 30
        settings.stopList.domains.append("lenta.ru")
        settings.save(to: defaults)
        #expect(FocusSettings.load(from: defaults) == settings)
    }

    @Test
    func corruptStoredValueFallsBackToDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "focus-settings-\(UUID().uuidString)"))
        defaults.set(Data("nope".utf8), forKey: FocusSettings.defaultsKey)
        #expect(FocusSettings.load(from: defaults) == FocusSettings())
    }

    @Test
    func settingsDecodeOldJSONKeepsNewDefaults() throws {
        let settings = try JSONDecoder().decode(FocusSettings.self, from: Data(#"{"nextActionDelay":30,"nudgeSoundEnabled":true}"#.utf8))
        #expect(settings.maxParallelSessions == 3)
        #expect(settings.stalledReminderMinutes == 15)
        #expect(settings.dayStartEnabled == true)
        #expect(settings.nextActionDelay == 30)
    }

    @Test
    func newFieldsRoundTrip() throws {
        var settings = FocusSettings()
        settings.maxParallelSessions = 5
        settings.stalledReminderMinutes = 30
        settings.dayStartEnabled = false
        let decoded = try JSONDecoder().decode(FocusSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }

    @Test
    func decodeClampsOutOfRangeValues() throws {
        let high = try JSONDecoder().decode(FocusSettings.self, from: Data(#"{"maxParallelSessions":99,"stalledReminderMinutes":1000}"#.utf8))
        #expect(high.maxParallelSessions == 6)
        #expect(high.stalledReminderMinutes == 60)
        let low = try JSONDecoder().decode(FocusSettings.self, from: Data(#"{"maxParallelSessions":0,"stalledReminderMinutes":-3}"#.utf8))
        #expect(low.maxParallelSessions == 1)
        #expect(low.stalledReminderMinutes == 5)
        let inRange = try JSONDecoder().decode(FocusSettings.self, from: Data(#"{"maxParallelSessions":4,"stalledReminderMinutes":20}"#.utf8))
        #expect(inRange.maxParallelSessions == 4)
        #expect(inRange.stalledReminderMinutes == 20)
    }

    @Test
    func legacyTimerDefaultsMigrateOnce() throws {
        let legacy = try JSONDecoder().decode(FocusSettings.self, from: Data(#"{"pomodoroFocusMinutes":25,"pomodoroBreakMinutes":5}"#.utf8))
        #expect(legacy.pomodoroFocusMinutes == 50)
        #expect(legacy.pomodoroBreakMinutes == 10)
        let custom = try JSONDecoder().decode(FocusSettings.self, from: Data(#"{"pomodoroFocusMinutes":30,"pomodoroBreakMinutes":5}"#.utf8))
        #expect(custom.pomodoroFocusMinutes == 30)
        #expect(custom.pomodoroBreakMinutes == 5)
        var chosen = FocusSettings()
        chosen.pomodoroFocusMinutes = 25
        chosen.pomodoroBreakMinutes = 5
        let roundTrip = try JSONDecoder().decode(FocusSettings.self, from: JSONEncoder().encode(chosen))
        #expect(roundTrip.pomodoroFocusMinutes == 25)
        #expect(roundTrip.pomodoroBreakMinutes == 5)
    }

    @Test
    func pomodoroDefaultsAndClamping() throws {
        let defaults = FocusSettings()
        #expect(defaults.pomodoroFocusMinutes == 50)
        #expect(defaults.pomodoroBreakMinutes == 10)
        #expect(defaults.pomodoroCycle == 4)
        let high = try JSONDecoder().decode(FocusSettings.self, from: Data(#"{"pomodoroFocusMinutes":500,"pomodoroBreakMinutes":99,"pomodoroCycle":20}"#.utf8))
        #expect(high.pomodoroFocusMinutes == 120)
        #expect(high.pomodoroBreakMinutes == 30)
        #expect(high.pomodoroCycle == 8)
        let low = try JSONDecoder().decode(FocusSettings.self, from: Data(#"{"pomodoroFocusMinutes":1,"pomodoroBreakMinutes":0,"pomodoroCycle":-1}"#.utf8))
        #expect(low.pomodoroFocusMinutes == 5)
        #expect(low.pomodoroBreakMinutes == 1)
        #expect(low.pomodoroCycle == 2)
        let ok = try JSONDecoder().decode(FocusSettings.self, from: Data(#"{"pomodoroFocusMinutes":50,"pomodoroBreakMinutes":10,"pomodoroCycle":3}"#.utf8))
        #expect(ok.pomodoroFocusMinutes == 50)
        #expect(ok.pomodoroBreakMinutes == 10)
        #expect(ok.pomodoroCycle == 3)
        let roundTrip = try JSONDecoder().decode(FocusSettings.self, from: JSONEncoder().encode(ok))
        #expect(roundTrip == ok)
    }
}
