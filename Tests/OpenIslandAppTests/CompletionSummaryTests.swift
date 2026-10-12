import Foundation
import Testing
@testable import OpenIslandApp

struct CompletionSummaryTests {
    @Test
    func briefTakesFirstProseParagraphWithoutMarkdown() {
        let answer = """
        Точно сказать **что именно** заблокировано, пока не могу: я не смотрел `логи`. Но по коду разница видна сразу.

        | | Наш сервис | Парсер |
        |---|---|---|
        | IP | голый | WARP |
        """
        #expect(CompletionSummaryText.brief(answer) == "Точно сказать что именно заблокировано, пока не могу: я не смотрел логи. Но по коду разница видна сразу.")
    }

    @Test
    func briefSkipsLeadingTablesHeadingsAndCode() {
        let answer = """
        ## Итог

        ```swift
        let x = 1
        ```
        - Сделал [PR](https://x/1) с фиксом
        - Тесты зелёные
        """
        #expect(CompletionSummaryText.brief(answer) == "Сделал PR с фиксом Тесты зелёные")
        #expect(CompletionSummaryText.brief("") == "")
    }

    @Test
    func briefCutsLongTextAtWordBoundary() {
        let long = Array(repeating: "слово", count: 80).joined(separator: " ")
        let brief = CompletionSummaryText.brief(long)
        #expect(brief.hasSuffix("…"))
        #expect(brief.count <= CompletionSummaryText.maxLength + 1)
        #expect(!brief.contains("слов…"))
    }

    @Test
    func hasMoreOnlyWhenFullAnswerIsLonger() {
        #expect(!CompletionSummaryText.hasMore(brief: "Готово.", full: "Готово."))
        #expect(CompletionSummaryText.hasMore(brief: "Готово.", full: "Готово.\n\n| a | b |"))
        #expect(!CompletionSummaryText.hasMore(brief: "", full: "  "))
    }

    @Test
    func desktopSummaryPrefersNeedsActionAndCapitalizes() {
        #expect(CompletionSummaryText.summary(statusDetail: "вероятно бан IP", needsAction: "") == TurnSummary(text: "Вероятно бан IP", needsAction: false))
        #expect(CompletionSummaryText.summary(statusDetail: "2) — сказать?", needsAction: "какой вариант?") == TurnSummary(text: "Какой вариант?", needsAction: true))
        #expect(CompletionSummaryText.summary(statusDetail: " ", needsAction: nil) == nil)
    }

    @Test
    func desktopSummaryMustMatchLastAssistantMessage() {
        let fresh: [String: Any] = ["lastAssistantUuid": "u2", "postTurnSummary": ["status_detail": "PR updated", "needs_action": "", "summarizes_uuid": "u2"]]
        let stale: [String: Any] = ["lastAssistantUuid": "u3", "postTurnSummary": ["status_detail": "PR updated", "summarizes_uuid": "u2"]]
        #expect(ClaudeDesktopSessionLocator.turnSummary(fresh) == TurnSummary(text: "PR updated", needsAction: false))
        #expect(ClaudeDesktopSessionLocator.turnSummary(stale) == nil)
        #expect(ClaudeDesktopSessionLocator.turnSummary([:]) == nil)
    }
}
