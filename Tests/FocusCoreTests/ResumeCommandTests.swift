import Testing
@testable import FocusCore

struct ResumeCommandTests {
    @Test
    func buildsResumeCommand() {
        #expect(ResumeCommand.resume(sessionID: "abc-123", cwd: "/Users/me/proj") == "cd '/Users/me/proj' && claude --resume 'abc-123'")
    }

    @Test
    func quotesSingleQuotesInPath() {
        #expect(ResumeCommand.newSession(cwd: "/tmp/it's мой проект") == "cd '/tmp/it'\\''s мой проект' && claude")
    }
}

struct AppleScriptQuotingTests {
    @Test
    func escapesQuotesAndBackslashes() {
        #expect(AppleScriptQuoting.string("say \"hi\" \\ ok") == "\"say \\\"hi\\\" \\\\ ok\"")
    }
}
