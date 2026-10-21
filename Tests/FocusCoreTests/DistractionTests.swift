import Foundation
import Testing
@testable import FocusCore

struct DistractionTests {
    let t0 = Date(timeIntervalSince1970: 50_000)
    let stopList = StopList.default

    func sample(_ bundleID: String, _ url: String? = nil, _ offset: TimeInterval) -> FrontmostSample {
        FrontmostSample(bundleID: bundleID, url: url.flatMap(URL.init(string:)), at: t0.addingTimeInterval(offset))
    }

    @Test
    func domainMatchingCoversSubdomainsAndWww() {
        #expect(DistractionClassifier.isDistracting(bundleID: "com.google.Chrome", url: URL(string: "https://www.youtube.com/watch?v=1"), stopList: stopList))
        #expect(DistractionClassifier.isDistracting(bundleID: "com.apple.Safari", url: URL(string: "https://old.reddit.com/r/swift"), stopList: stopList))
        #expect(!DistractionClassifier.isDistracting(bundleID: "com.apple.Safari", url: URL(string: "https://notyoutube.com"), stopList: stopList))
        #expect(!DistractionClassifier.isDistracting(bundleID: "com.apple.Safari", url: URL(string: "https://developer.apple.com"), stopList: stopList))
        #expect(!DistractionClassifier.isDistracting(bundleID: "com.apple.Safari", url: nil, stopList: stopList))
    }

    @Test
    func appMatchingUsesBundleID() {
        #expect(DistractionClassifier.isDistracting(bundleID: "ru.keepcoder.Telegram", url: nil, stopList: stopList))
        #expect(!DistractionClassifier.isDistracting(bundleID: "com.apple.Terminal", url: nil, stopList: stopList))
    }

    @Test
    func urlIgnoredForNonBrowsers() {
        #expect(!DistractionClassifier.isDistracting(bundleID: "com.apple.Notes", url: URL(string: "https://youtube.com"), stopList: stopList))
    }

    @Test
    func nudgesAfterThresholdThenRenudgesAfterInterval() {
        var tracker = DistractionTracker(threshold: 20, renudgeInterval: 180)
        #expect(tracker.observe(sample("ru.keepcoder.Telegram", nil, 0), anySessionRunning: true, stopList: stopList) == [])
        #expect(tracker.observe(sample("ru.keepcoder.Telegram", nil, 19), anySessionRunning: true, stopList: stopList) == [])
        #expect(tracker.observe(sample("ru.keepcoder.Telegram", nil, 20), anySessionRunning: true, stopList: stopList) == [.nudge])
        #expect(tracker.observe(sample("ru.keepcoder.Telegram", nil, 100), anySessionRunning: true, stopList: stopList) == [])
        #expect(tracker.observe(sample("ru.keepcoder.Telegram", nil, 200), anySessionRunning: true, stopList: stopList) == [.nudge])
    }

    @Test
    func leavingAfterNudgeLogsReturnTime() {
        var tracker = DistractionTracker(threshold: 20, renudgeInterval: 180)
        _ = tracker.observe(sample("ru.keepcoder.Telegram", nil, 0), anySessionRunning: true, stopList: stopList)
        _ = tracker.observe(sample("ru.keepcoder.Telegram", nil, 25), anySessionRunning: true, stopList: stopList)
        let events = tracker.observe(sample("com.apple.Terminal", nil, 31), anySessionRunning: true, stopList: stopList)
        #expect(events == [.episodeEnded(DistractionEpisode(startedAt: t0, endedAt: t0.addingTimeInterval(31), appBundleID: "ru.keepcoder.Telegram", domain: nil, nudged: true, returnedWithinSec: 6))])
        #expect(tracker.currentEpisode == nil)
    }

    @Test
    func shortGlanceIsNotLogged() {
        var tracker = DistractionTracker(threshold: 20, renudgeInterval: 180)
        _ = tracker.observe(sample("com.google.Chrome", "https://x.com/home", 0), anySessionRunning: true, stopList: stopList)
        #expect(tracker.observe(sample("com.apple.Terminal", nil, 5), anySessionRunning: true, stopList: stopList) == [])
    }

    @Test
    func noRunningSessionMeansNoDistraction() {
        var tracker = DistractionTracker(threshold: 20, renudgeInterval: 180)
        _ = tracker.observe(sample("ru.keepcoder.Telegram", nil, 0), anySessionRunning: false, stopList: stopList)
        #expect(tracker.observe(sample("ru.keepcoder.Telegram", nil, 30), anySessionRunning: false, stopList: stopList) == [])
        #expect(tracker.currentEpisode == nil)
    }

    @Test
    func suppressionBlocksUntilExpiry() {
        var tracker = DistractionTracker(threshold: 20, renudgeInterval: 180)
        tracker.suppress(until: t0.addingTimeInterval(600))
        _ = tracker.observe(sample("ru.keepcoder.Telegram", nil, 0), anySessionRunning: true, stopList: stopList)
        #expect(tracker.observe(sample("ru.keepcoder.Telegram", nil, 30), anySessionRunning: true, stopList: stopList) == [])
        _ = tracker.observe(sample("ru.keepcoder.Telegram", nil, 601), anySessionRunning: true, stopList: stopList)
        #expect(tracker.observe(sample("ru.keepcoder.Telegram", nil, 621), anySessionRunning: true, stopList: stopList) == [.nudge])
    }

    @Test
    func switchingBetweenDistractionsKeepsOneEpisode() {
        var tracker = DistractionTracker(threshold: 20, renudgeInterval: 180)
        _ = tracker.observe(sample("ru.keepcoder.Telegram", nil, 0), anySessionRunning: true, stopList: stopList)
        #expect(tracker.observe(sample("com.google.Chrome", "https://youtube.com", 21), anySessionRunning: true, stopList: stopList) == [.nudge])
        #expect(tracker.currentEpisode?.startedAt == t0)
    }

    @Test
    func busyInOtherAppSuppressesNextActionCard() {
        let since = t0
        #expect(!FocusPresentationPolicy.shouldPresentNextAction(frontmostBundleID: "com.figma.Desktop", frontmostSince: since, frontmostIsDistracting: false, selfBundleID: "dev.zhanabayev.focusisland", now: t0.addingTimeInterval(61)))
        #expect(FocusPresentationPolicy.shouldPresentNextAction(frontmostBundleID: "com.figma.Desktop", frontmostSince: since, frontmostIsDistracting: false, selfBundleID: "dev.zhanabayev.focusisland", now: t0.addingTimeInterval(30)))
        #expect(FocusPresentationPolicy.shouldPresentNextAction(frontmostBundleID: "com.apple.Terminal", frontmostSince: since, frontmostIsDistracting: false, selfBundleID: "dev.zhanabayev.focusisland", now: t0.addingTimeInterval(600)))
        #expect(FocusPresentationPolicy.shouldPresentNextAction(frontmostBundleID: "ru.keepcoder.Telegram", frontmostSince: since, frontmostIsDistracting: true, selfBundleID: "dev.zhanabayev.focusisland", now: t0.addingTimeInterval(600)))
        #expect(FocusPresentationPolicy.shouldPresentNextAction(frontmostBundleID: nil, frontmostSince: nil, frontmostIsDistracting: false, selfBundleID: "x", now: t0))
    }
}
