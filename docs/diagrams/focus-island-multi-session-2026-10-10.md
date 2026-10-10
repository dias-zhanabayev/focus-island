# Focus Island — несколько сессий — sequence diagram

Перегрузка, вход в другую задачу и забытые сессии (спека v3, J5, J8, J9, J11). Политики — чистые функции FocusCore, координатор только выбирает карточку по приоритету.

```mermaid
sequenceDiagram
    autonumber
    actor Dev as Разработчик
    participant SS as SessionState
    participant FC as FocusCoordinator
    participant Hub as SessionHub
    participant OP as OverloadPolicy
    participant SP as StalledPolicy
    participant DB as FocusStore
    participant UI as Island
    participant TJ as TerminalJumpService

    SS-->>FC: sessionsDidChange (новая живая сессия)
    FC->>OP: evaluate(live не на паузе, лимит 3)
    alt живых больше лимита
        OP-->>FC: overload(oldestWaiting, youngestRunning)
        FC->>UI: card = overload
        alt «На паузу»
            Dev->>UI: На паузу
            UI->>FC: perform(park(session))
            FC->>DB: sessions.parkedAt = now
        else «Перейти» к ждущей
            Dev->>UI: Перейти
            UI->>FC: perform(jump(session))
        else «Всё равно запустить»
            Dev->>UI: dismiss
        end
    else в пределах лимита
        OP-->>FC: nil
    end
    Note over FC: tick раз в 1 с
    FC->>SP: evaluate(sessions, порог 15 мин, now)
    alt есть забытые и прошло ≥ 30 мин с прошлого показа
        SP-->>FC: stalled([ids по возрасту])
        Note over FC,UI: не поверх nextAction / returned / nudge
        FC->>UI: card = stalled
    else
        SP-->>FC: []
    end
    Dev->>UI: открывает island
    FC->>Hub: groups(sessions, records, now)
    Hub-->>UI: Ждут тебя / Готово / Работают / Без задачи / На паузе
    Dev->>UI: «Перейти» на сессию другой задачи
    UI->>FC: perform(jump(session))
    FC->>DB: lastSeenAt(session)
    alt не видел ≥ 10 мин и задача ≠ currentTask
        FC->>UI: card = reEntry (заметка, что сделал Claude, что ждёт)
        Dev->>UI: «Открыть терминал»
        UI->>FC: perform(confirmJump(session))
    end
    FC->>TJ: jump(to: jumpTarget)
    alt переход не удался
        TJ--xFC: TerminalJumpError
        Note over FC: лог, карточка закрывается без reacted
    else
        TJ-->>FC: ok
        FC->>DB: lastSeenAt = now, parkedAt = nil
    end
```
