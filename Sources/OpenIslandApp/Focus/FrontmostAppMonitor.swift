import AppKit
import FocusCore
import Foundation
import os

private let frontmostLogger = Logger(subsystem: "dev.zhanabayev.focusisland", category: "frontmost")

@MainActor
final class FrontmostAppMonitor {
    static let pollInterval: TimeInterval = 5

    private let focus: FocusCoordinator
    private var activationObserver: NSObjectProtocol?
    private var timer: Timer?
    private var sampleCounter: Int = 0
    private var isReadingURL = false

    init(focus: FocusCoordinator) {
        self.focus = focus
    }

    nonisolated static func browserURLScript(for bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.Safari":
            "tell application id \"com.apple.Safari\" to if (count of documents) > 0 then return URL of front document"
        case "com.google.Chrome", "company.thebrowser.Browser":
            "tell application id \"\(bundleID)\" to if (count of windows) > 0 then return URL of active tab of front window"
        default:
            nil
        }
    }

    nonisolated static func readBrowserURL(script: String, timeout: TimeInterval = 2) async -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            frontmostLogger.debug("Failed to start osascript: \(error)")
            return nil
        }

        let startTime = Date()
        while process.isRunning {
            if Date().timeIntervalSince(startTime) > timeout {
                process.terminate()
                frontmostLogger.debug("osascript timeout after \(timeout)s")
                return nil
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        guard process.terminationStatus == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrStr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            frontmostLogger.debug("osascript exited with status \(process.terminationStatus): \(stderrStr)")
            return nil
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else {
            return nil
        }

        return URL(string: output)
    }

    func start() {
        stop()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        timer?.invalidate()
        timer = nil
        sampleCounter += 1
    }

    nonisolated static func browserURLSource(for bundleID: String, distractionEnabled: Bool, hasRunningSession: Bool) -> String? {
        guard distractionEnabled, hasRunningSession else { return nil }
        return browserURLScript(for: bundleID)
    }

    private func sample() {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }

        let source = Self.browserURLSource(
            for: bundleID,
            distractionEnabled: focus.settings.distractionEnabled,
            hasRunningSession: focus.hasRunningSession
        )

        guard let source else {
            sampleCounter += 1
            focus.frontmostDidChange(FrontmostSample(bundleID: bundleID, url: nil, at: .now))
            return
        }

        guard !isReadingURL else {
            return
        }

        sampleCounter += 1
        let current = sampleCounter
        isReadingURL = true
        Task { [weak self] in
            let url = await Self.readBrowserURL(script: source)
            guard let self else { return }
            self.isReadingURL = false
            guard self.sampleCounter == current else { return }
            self.focus.frontmostDidChange(FrontmostSample(bundleID: bundleID, url: url, at: .now))
        }
    }
}
