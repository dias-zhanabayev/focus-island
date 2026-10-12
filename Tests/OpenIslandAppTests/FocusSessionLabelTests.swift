import FocusCore
import Foundation
import OpenIslandCore
import Testing
@testable import OpenIslandApp

@MainActor
struct FocusSessionLabelTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    final class Calls: @unchecked Sendable {
        var count = 0
        var title: String?
    }

    @Test
    func lookupIsRetriedUntilClaudeNamesTheSession() {
        #expect(FocusCoordinator.labelLookupDue(lastLookup: nil, hasLabel: false, now: t0))
        #expect(!FocusCoordinator.labelLookupDue(lastLookup: t0, hasLabel: false, now: t0.addingTimeInterval(5)))
        #expect(FocusCoordinator.labelLookupDue(lastLookup: t0, hasLabel: false, now: t0.addingTimeInterval(15)))
        #expect(!FocusCoordinator.labelLookupDue(lastLookup: t0, hasLabel: true, now: t0.addingTimeInterval(60)))
        #expect(FocusCoordinator.labelLookupDue(lastLookup: t0, hasLabel: true, now: t0.addingTimeInterval(300)))
    }

    @Test
    func promptPreviewDropsServiceBlocks() {
        #expect(FocusCoordinator.promptPreview("<system-reminder>\nYou are in a worktree\n</system-reminder>\nпочини тестовый режим") == "почини тестовый режим")
        #expect(FocusCoordinator.promptPreview("[Image: source: /tmp/x.png] что тут не так?") == "что тут не так?")
        #expect(FocusCoordinator.promptPreview("<scheduled-task name=\"digest\" file=\"/x\">run</scheduled-task>") == nil)
        #expect(FocusCoordinator.promptPreview("Base directory for this skill: /x\nсделай ревью") == "сделай ревью")
        #expect(FocusCoordinator.promptPreview(nil) == nil)
    }

    @Test
    func pickerShowsLateClaudeTitleAndStatus() async throws {
        let store = try FocusStore.inMemory()
        let defaults = UserDefaults(suiteName: "focus-labels-\(UUID().uuidString)")!
        let c = FocusCoordinator(store: store, defaults: defaults, launcher: RecordingLauncher(), promptSender: RecordingPromptSender(result: .unsupported), gitDiff: StubGitDiff(files: []), clipboard: { _ in }, runBackfill: false)
        c.settings.dayStartEnabled = false
        c.settings.nextActionEnabled = false
        let calls = Calls()
        c.lookupSessionLabels = { _ in
            calls.count += 1
            return calls.title.map { ["s1": SessionLabel(title: $0, status: "PR обновлён")] } ?? [:]
        }
        c.start(initialSessions: [], now: t0)
        var session = AgentSession(
            id: "s1", title: "Claude · proj", tool: .claudeCode, origin: .live, attachmentState: .attached, phase: .running, summary: "", updatedAt: t0, firstSeenAt: t0,
            jumpTarget: JumpTarget(terminalApp: "Claude.app", workspaceName: "proj", paneTitle: "", workingDirectory: "/tmp/proj"),
            claudeMetadata: ClaudeSessionMetadata(initialUserPrompt: "<system-reminder>x</system-reminder>", lastUserPrompt: "<system-reminder>x</system-reminder>", startupSource: .startup)
        )
        session.isHookManaged = true
        c.sessionsDidChange([session], now: t0)
        for _ in 0..<50 where calls.count < 1 { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }
        #expect(c.sessionLabel("s1") == nil)
        calls.title = "Тестовый режим отправляет реальным клиентам"
        c.tick(now: t0.addingTimeInterval(16))
        for _ in 0..<100 where c.sessionLabel("s1") == nil { await Task.yield() }
        #expect(c.sessionLabel("s1") == "Тестовый режим отправляет реальным клиентам")
        #expect(c.sessionDetail("s1", prompt: "<system-reminder>x</system-reminder>", cwd: "/tmp/proj") == "PR обновлён")
        #expect(calls.count == 2)
    }
}
