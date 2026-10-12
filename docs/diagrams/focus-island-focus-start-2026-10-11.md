# Focus Island — включить фокус — sequence diagram

P16 из `docs/superpowers/specs/2026-10-10-focus-island-pomodoro-design.md`: выбор задачи при запуске, старт фокуса из пульта и из свёрнутого острова.

```mermaid
sequenceDiagram
    autonumber
    actor Dev as Разработчик
    participant App as AppModel
    participant FC as FocusCoordinator
    participant Hub as SessionHubView
    participant Pill as Свёрнутый остров

    App->>FC: start(initialSessions)
    App->>FC: offerTaskChoiceOnLaunch()
    alt таймер восстановлен
        FC-->>Hub: фокус = задача таймера
    else задачи есть
        FC->>FC: focusCleared = true
        FC-->>Hub: card = pickTask, остров открыт
    end
    Dev->>FC: «Взять» задачу
    FC->>FC: focusTaskOverrideID, focusCleared = false
    alt старт в пульте
        Dev->>Hub: сегмент 25 / 50 / 90 / Своё
        Dev->>Hub: «▶ Начать фокус · N мин»
        Hub->>FC: startPomodoro(taskID, N)
    else старт со свёрнутого острова
        Pill-->>Dev: «▶ Фокус 50»
        Dev->>App: клик по пилюле
        App->>FC: startPomodoro(currentTask, settings.pomodoroFocusMinutes)
    end
    FC-->>Hub: карточка-таймер: кольцо, время, «Пауза», «Стоп»
    opt «Доска»
        Dev->>App: focusOpenBoard
        App->>App: notchClose, показать доску
    end
```
