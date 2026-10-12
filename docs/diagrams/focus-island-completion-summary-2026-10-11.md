# Focus Island completion summary — sequence diagram

Covers how the "Claude finished" card picks its one-line summary (spec addendum P21). Derived from `IslandPanelView` (`completionActionBody`, `.task` on the card), `AppModel.loadTurnSummary`, `ClaudeDesktopSessionLocator.turnSummary` and `CompletionSummaryText.brief`.

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant Card as IslandSessionRow (completed)
    participant App as AppModel
    participant Loc as ClaudeDesktopSessionLocator
    participant Files as Claude.app session files
    participant Text as CompletionSummaryText

    Card->>App: task(id: session+phase+updatedAt) loadTurnSummary(session)
    alt terminalApp is Claude.app
        loop delays 0, 2, 3, 5, 10 s until found
            App->>Loc: sessions(forCLISessionIDs: [id])
            Loc->>Files: scan local_*.json newest first
            Files-->>Loc: postTurnSummary, lastAssistantUuid, lastActivityAt
            alt summarizes_uuid == lastAssistantUuid and fresh (within 30 s)
                Loc-->>App: TurnSummary(needs_action or status_detail)
                App->>App: turnSummaries[id] = summary
            else stale or missing
                Loc-->>App: nil, keep polling
            end
        end
    else terminal session
        Note over App: no lookup
    end
    alt turnSummary present
        Card-->>User: needsAction ? "НУЖНО ОТ ТЕБЯ" + question : ✓ status
    else no summary
        Card->>Text: brief(last assistant markdown)
        Text-->>Card: first prose paragraph, no tables or code, max 220 chars
        Card-->>User: ✓ brief text
    end
    opt User taps "Весь ответ ▾"
        Card-->>User: full markdown, scroll up to 160 pt, "Свернуть ▴"
    end
    opt User taps "Перейти"
        Card->>App: jumpToSession(session)
    end
```
