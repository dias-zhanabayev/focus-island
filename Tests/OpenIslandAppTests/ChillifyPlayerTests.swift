import FocusCore
import Foundation
import Testing
@testable import OpenIslandApp

struct ChillifyPlayerTests {
    private func snapshot(_ phase: PomodoroPhase, paused: Bool = false) -> PomodoroSnapshot {
        PomodoroSnapshot(id: "p", taskID: nil, taskTitle: nil, phase: phase, plannedSeconds: 3000, remainingSeconds: 1000, progress: 0.3, isPaused: paused, cycleIndex: 1, cycle: 4)
    }

    @Test
    func musicPlaysOnlyDuringRunningFocus() {
        var settings = FocusSettings()
        #expect(!FocusCoordinator.musicShouldPlay(settings: settings, pomodoro: snapshot(.focus)))
        settings.musicEnabled = true
        #expect(FocusCoordinator.musicShouldPlay(settings: settings, pomodoro: snapshot(.focus)))
        #expect(!FocusCoordinator.musicShouldPlay(settings: settings, pomodoro: snapshot(.focus, paused: true)))
        #expect(!FocusCoordinator.musicShouldPlay(settings: settings, pomodoro: snapshot(.break)))
        #expect(!FocusCoordinator.musicShouldPlay(settings: settings, pomodoro: nil))
    }

    @Test
    func buildsChillifyURLs() {
        #expect(ChillifyPlayer.tracksURL(genre: .chill, userUUID: "u1")?.absoluteString == "https://chillify.me/api/v1/tracks?folder=chill&userUuid=u1")
        #expect(ChillifyPlayer.tracksURL(genre: .mix, userUUID: "u1")?.absoluteString == "https://chillify.me/api/v1/tracks?folder=mix&include=chill,cafe,asian&userUuid=u1")
        #expect(ChillifyPlayer.trackURL("chill/track 1.mp3")?.absoluteString == "https://chillify.me/tracks/chill/track%201.mp3")
        #expect(ChillifyPlayer.trackURL("../secret") == nil)
        #expect(ChillifyPlayer.genre(ofTrack: "cafe/a.mp3") == "cafe")
    }

    @Test
    func fadesOutInLastTenSeconds() {
        #expect(ChillifyPlayer.fadeMultiplier(remaining: 60) == 1)
        #expect(ChillifyPlayer.fadeMultiplier(remaining: 0) == 0)
        let mid = ChillifyPlayer.fadeMultiplier(remaining: 5)
        #expect(mid > 0 && mid < 0.5)
        #expect(ChillifyPlayer.fallbackNext(count: 3, current: 2) == 0)
    }

    @Test
    func musicSettingsDefaultOffChillHalfVolume() throws {
        let settings = FocusSettings()
        #expect(!settings.musicEnabled)
        #expect(settings.musicGenre == .chill)
        #expect(settings.musicVolume == 0.5)
        let decoded = try JSONDecoder().decode(FocusSettings.self, from: Data(#"{"musicEnabled":true,"musicGenre":"unknown","musicVolume":3}"#.utf8))
        #expect(decoded.musicEnabled)
        #expect(decoded.musicGenre == .chill)
        #expect(decoded.musicVolume == 1)
    }
}
