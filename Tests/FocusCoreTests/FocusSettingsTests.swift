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
}
