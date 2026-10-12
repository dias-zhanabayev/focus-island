# Focus Island — старт задачи и помодоро — sequence diagram

Путь 7.0–7.5 из `docs/superpowers/specs/2026-10-10-focus-island-pomodoro-design.md`: выбор задачи, привязка открытых сессий, фокус, конец помодоро, перерыв и возврат.

```mermaid
sequenceDiagram
    autonumber
    actor Dev as Разработчик
    participant Pill as Island (пилюля)
    participant FC as FocusCoordinator
    participant Sheet as StartTaskSheet
    participant PS as PomodoroStore
    participant Board as BoardService
    participant Log as ActivityLog

    Note over Pill: currentTask == nil
    Pill->>Dev: «Выбрать задачу · Todo 3»
    Dev->>Pill: клик
    Pill->>FC: present(.pickTask)
    Dev->>FC: «Начать» у задачи
    FC->>FC: requestStartTask(taskID)
    FC->>Sheet: pendingStartTaskID
    Sheet->>FC: bindableSessions(taskID)
    FC-->>Sheet: сессии проекта первыми, чужие с тегом
    Dev->>Sheet: отмечает сессии, 25 мин, «Начать»
    Sheet->>FC: startTask(taskID, sessionIDs, 25)
    FC->>Board: move(In progress) + bindSession × N
    FC->>PS: start(focus, 25 мин)
    alt помодоро идёт
        loop tick 1 с
            FC->>Pill: ухо «mm:ss», строка таймера в пульте
        end
        opt пауза
            Dev->>FC: pausePomodoro / resumePomodoro
            FC->>PS: pause / resume
        end
    else «Стоп»
        Dev->>FC: stopPomodoro
        FC->>PS: finish(completed: false)
    end
    FC->>PS: finish(completed: true) при remaining == 0
    FC->>Log: KPI за интервал
    FC->>Pill: card = pomodoroEnd, island открыт
    Dev->>FC: следующий шаг + «Перерыв 5 мин»
    FC->>Board: note задачи = следующий шаг
    FC->>PS: start(break, 5 мин)
    Note over FC: на перерыве нет nudge, эпизодов, nextAction, stalled
    FC->>PS: finish(break) при remaining == 0
    FC->>Pill: card = breakEnd, island открыт
    alt «Перейти и начать 25»
        Dev->>FC: continueFocus
        FC->>FC: requestJump(сессия задачи)
        FC->>PS: start(focus, 25 мин)
    else «Без таймера»
        Dev->>FC: endWithoutBreak
    end
```
