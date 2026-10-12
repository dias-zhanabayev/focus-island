# Focus Island — взять задачу и работать в её сессиях — sequence diagram

Дополнение P9–P11 к `docs/superpowers/specs/2026-10-10-focus-island-pomodoro-design.md`: выбор из «В работе», привязка сессий в острове, пульт задачи и стабильный фокус.

```mermaid
sequenceDiagram
    autonumber
    actor Dev as Разработчик
    participant UI as Island
    participant FC as FocusCoordinator
    participant Board as BoardService
    participant TJ as TerminalJumpService

    Dev->>UI: открывает остров без фокуса или «Сменить»
    UI->>FC: openPickTask
    FC-->>UI: card = pickTask (В работе, затем Todo)
    Dev->>UI: «Взять» у задачи
    UI->>FC: takeTask(taskID)
    alt у задачи есть живые сессии
        FC->>FC: focusTaskOverride = taskID
        FC-->>UI: .focused, пульт с блоком «Сессии задачи»
    else сессий нет
        FC-->>UI: .needsBinding, card = bindToTask
        Dev->>UI: отмечает сессии, «Привязать N и перейти»
        UI->>FC: bindAndJump(taskID, sessionIDs)
        FC->>Board: bindSession × N
        FC->>TJ: jump(первая сессия)
    end
    loop работа
        Dev->>UI: «Перейти» в сессию задачи
        UI->>FC: requestJump
        FC->>TJ: jump
        Dev->>UI: «Перейти» в другую сессию
        UI->>FC: requestJump
        Note over FC: фокус не меняется (P11)
        FC->>TJ: jump
    end
    opt задача ушла из In progress или «Сменить»
        FC->>FC: сброс фокуса
    end
```
