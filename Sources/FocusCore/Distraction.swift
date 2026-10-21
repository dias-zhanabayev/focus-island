import Foundation

public struct StopList: Codable, Equatable, Sendable {
    public var appBundleIDs: [String]
    public var domains: [String]

    public init(appBundleIDs: [String], domains: [String]) {
        self.appBundleIDs = appBundleIDs
        self.domains = domains
    }

    public static let `default` = StopList(
        appBundleIDs: ["ru.keepcoder.Telegram", "com.tdesktop.Telegram", "com.hnc.Discord"],
        domains: ["youtube.com", "x.com", "twitter.com", "reddit.com", "instagram.com", "tiktok.com", "news.ycombinator.com", "vc.ru", "habr.com"]
    )
}

public enum KnownApps {
    public static let browsers: Set<String> = ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser"]

    public static let terminalsAndEditors: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "com.github.wez.wezterm", "net.kovidgoyal.kitty", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
        "dev.zed.Zed", "com.apple.dt.Xcode",
    ]

    public static func isTerminalOrEditor(_ bundleID: String) -> Bool {
        terminalsAndEditors.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.")
    }
}

public enum DistractionClassifier {
    public static func domain(from url: URL?) -> String? {
        guard var host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        return host
    }

    public static func isDistracting(bundleID: String, url: URL?, stopList: StopList) -> Bool {
        if stopList.appBundleIDs.contains(bundleID) {
            return true
        }
        guard KnownApps.browsers.contains(bundleID), let host = domain(from: url) else {
            return false
        }
        return stopList.domains.contains { blocked in
            let blocked = blocked.lowercased()
            return host == blocked || host.hasSuffix("." + blocked)
        }
    }
}

public struct FrontmostSample: Equatable, Sendable {
    public var bundleID: String
    public var url: URL?
    public var at: Date

    public init(bundleID: String, url: URL?, at: Date) {
        self.bundleID = bundleID
        self.url = url
        self.at = at
    }
}

public enum DistractionEvent: Equatable, Sendable {
    case nudge
    case episodeEnded(DistractionEpisode)
}

public struct DistractionTracker: Sendable {
    public var threshold: TimeInterval
    public var renudgeInterval: TimeInterval
    public private(set) var currentEpisode: DistractionEpisode?
    private var lastNudgeAt: Date?
    private var suppressedUntil: Date?

    public init(threshold: TimeInterval = 20, renudgeInterval: TimeInterval = 180) {
        self.threshold = threshold
        self.renudgeInterval = renudgeInterval
    }

    public mutating func suppress(until date: Date) {
        suppressedUntil = date
    }

    public mutating func observe(_ sample: FrontmostSample, anySessionRunning: Bool, stopList: StopList) -> [DistractionEvent] {
        let suppressed = suppressedUntil.map { sample.at < $0 } ?? false
        let distracting = anySessionRunning && !suppressed
            && DistractionClassifier.isDistracting(bundleID: sample.bundleID, url: sample.url, stopList: stopList)

        guard distracting else {
            guard var episode = currentEpisode else { return [] }
            currentEpisode = nil
            defer { lastNudgeAt = nil }
            guard sample.at.timeIntervalSince(episode.startedAt) >= threshold else { return [] }
            episode.endedAt = sample.at
            if episode.nudged, let lastNudgeAt {
                episode.returnedWithinSec = sample.at.timeIntervalSince(lastNudgeAt)
            }
            return [.episodeEnded(episode)]
        }

        if currentEpisode == nil {
            currentEpisode = DistractionEpisode(
                startedAt: sample.at,
                appBundleID: sample.bundleID,
                domain: KnownApps.browsers.contains(sample.bundleID) ? DistractionClassifier.domain(from: sample.url) : nil
            )
        }
        guard let episode = currentEpisode, sample.at.timeIntervalSince(episode.startedAt) >= threshold else { return [] }
        if let lastNudgeAt, sample.at.timeIntervalSince(lastNudgeAt) < renudgeInterval {
            return []
        }
        currentEpisode?.nudged = true
        lastNudgeAt = sample.at
        return [.nudge]
    }
}

public enum FocusPresentationPolicy {
    public static func shouldPresentNextAction(
        frontmostBundleID: String?,
        frontmostSince: Date?,
        frontmostIsDistracting: Bool,
        selfBundleID: String?,
        now: Date,
        busyThreshold: TimeInterval = 60
    ) -> Bool {
        guard let frontmostBundleID, let frontmostSince else { return true }
        if frontmostIsDistracting || frontmostBundleID == selfBundleID || KnownApps.isTerminalOrEditor(frontmostBundleID) {
            return true
        }
        return now.timeIntervalSince(frontmostSince) < busyThreshold
    }
}
