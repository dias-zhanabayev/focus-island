# Focus Island v3 — выбор карточки координатором — sequence diagram

Как после плана `docs/superpowers/plans/2026-10-10-focus-island-journey.md` (Task 5–8) входы координатора превращаются в одну карточку island по приоритету `FocusCard.canReplace`.

```mermaid
sequenceDiagram
    autonumber
    participant AM as AppModel
    participant FC as FocusCoordinator
    participant Hub as SessionHub
    participant Pol as Overload/Stalled/DayStart Policy
    participant Eng as NextActionEngine
    participant Log as ActivityLog
    participant UI as FocusIslandSection

    AM->>FC: setHooksInstalled(false)
    FC->>UI: card = onboarding (приоритет 8)
    AM->>FC: sessionsDidChange(sessions)
    FC->>Hub: rows(sessions, records, board, unseen, now)
    Hub-->>FC: hubRows
    FC->>Log: open/close claude, waiting по переходам фаз
    alt новая живая сессия сверх лимита
        FC->>Pol: OverloadPolicy.evaluate(rows, limit)
        Pol-->>FC: OverloadSuggestion
        FC->>FC: canReplace(card, overload)
    end
    alt running → completed и (промпт в очереди или задача в фокусе)
        FC->>FC: canReplace(card, returned)
        FC->>UI: card = returned
    end
    AM->>FC: frontmostDidChange(sample)
    FC->>Log: you-интервал (терминал + currentTask)
    alt первый раз за день после 05:00
        FC->>Pol: DayStartPolicy.shouldShow
        Pol-->>FC: true
        FC->>UI: card = dayStart (если ничего важнее)
    end
    alt стоп-лист ≥ 20 с
        FC->>UI: card = nudge (вытесняет всё, кроме onboarding)
    end
    loop tick каждую секунду
        FC->>Eng: alternatives(input) для хода ≥ 15 с
        Eng-->>FC: [NextAlternative]
        FC->>UI: card = nextAction (если canReplace)
        FC->>Pol: StalledPolicy.stalled(rows, 15 мин)
        alt есть забытые и ≥ 30 мин с прошлого показа
            FC->>UI: card = stalled (не поверх nextAction/returned/nudge)
        end
    end
    alt card == nil
        UI->>UI: SessionHubView(hubRows)
    end
```
