# Focus Island — длительности таймера — sequence diagram

P15 из `docs/superpowers/specs/2026-10-10-focus-island-pomodoro-design.md`: умолчания 50/10 с миграцией, разовый выбор длительности в пульте и на карточке конца помодоро.

```mermaid
sequenceDiagram
    autonumber
    actor Dev as Разработчик
    participant Settings as FocusSettings
    participant Hub as SessionHubView
    participant End as PomodoroEndCard
    participant FC as FocusCoordinator

    Settings->>Settings: decode, timerDefaultsVersion < 2 и 25/5 → 50/10
    alt «Таймер 50 мин ▾» → 25 / 50 / 90
        Dev->>Hub: выбор в меню
        Hub->>FC: startPomodoro(taskID, minutes)
    else «Своё…»
        Dev->>Hub: степпер 5–120, «Начать N мин»
        Hub->>FC: startPomodoro(taskID, clampFocus(N))
    end
    Note over Hub: пока идёт — только «Пауза» и «Стоп»
    FC-->>End: card = pomodoroEnd
    alt клик «Перерыв 10 мин»
        Dev->>End: primaryAction
        End->>FC: startBreak(nextStep, minutes: nil)
        FC->>FC: перерыв = settings.pomodoroBreakMinutes
    else меню перерыва 5 / 10 / 15 / 20
        End->>FC: startBreak(nextStep, minutes)
    else «Ещё N без перерыва ▾»
        End->>FC: continueFocus(nextStep, minutes)
    end
```
