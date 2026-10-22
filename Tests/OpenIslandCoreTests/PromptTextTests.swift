import Foundation
import Testing
@testable import OpenIslandCore

struct PromptTextTests {
    @Test
    func stripsLeadingSystemReminder() {
        let text = "<system-reminder>\nAs you answer, use this context.\n</system-reminder>\nПочини воронку"
        #expect(PromptText.clean(text) == "Почини воронку")
    }

    @Test
    func stripsHarnessBlocksAnywhere() {
        let text = "Сделай отчёт <system-reminder>noise</system-reminder> по продажам\n<local-command-stdout>ok</local-command-stdout>"
        #expect(PromptText.clean(text) == "Сделай отчёт  по продажам")
    }

    @Test
    func dropsUnclosedHarnessBlockToTheEnd() {
        #expect(PromptText.clean("Почини <system-reminder>truncated preview") == "Почини")
    }

    @Test
    func returnsNilWhenOnlyHarnessBlocksRemain() {
        #expect(PromptText.clean("<system-reminder>x</system-reminder>") == nil)
        #expect(PromptText.clean("<command-name>/clear</command-name>\n<command-message>clear</command-message>") == nil)
        #expect(PromptText.clean("   ") == nil)
        #expect(PromptText.clean(nil) == nil)
    }

    @Test
    func keepsUserMarkupAndSimilarTagNames() {
        #expect(PromptText.clean("<div>hi</div> сверстай") == "<div>hi</div> сверстай")
        #expect(PromptText.clean("<system-reminders> list") == "<system-reminders> list")
    }
}
