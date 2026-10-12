# Focus Island auto break — sequence diagram

Covers the end of a focus interval through the auto-started break and the break-end card (spec addendum P19). Derived from `FocusCoordinator.tick`, `startBreakCountdownIfFresh`, `runBreakCountdown`, `finishBreakEarly`, `PomodoroEndCard` and `FocusEars.alertOverride`.

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant Tick as FocusCoordinator.tick (1 s)
    participant Coord as FocusCoordinator
    participant Store as PomodoroStore
    participant App as AppModel
    participant Card as PomodoroEndCard
    participant Pill as FocusEars pill

    Tick->>Coord: handlePomodoroExpiry(now)
    Coord->>Store: finish focus pomodoro
    Coord->>Coord: present(.pomodoroEnd)
    Coord->>Coord: startBreakCountdownIfFresh
    alt autoBreakEnabled and ended < 60 s ago
        Coord->>Coord: breakCountdownEndsAt = now + 5 s
        opt breakSoundEnabled
            Coord->>App: playSound("Glass")
        end
    else auto break off or stale
        Note over Coord: no countdown, card waits for a click
    end
    Coord->>App: presentCard() opens island
    App->>Card: show green break card
    loop every tick while counting
        Tick->>Coord: runBreakCountdown(now)
        Coord->>Coord: breakCountdownLeft = ceil(endsAt - now)
        App->>Pill: alertOverride(card, breakCountdown)
        Pill-->>User: "☕ Перерыв через N"
    end
    alt User picks 5/10/15/20
        User->>Card: segment tap
        Card->>Coord: chooseBreakMinutes(m)
        Note over Coord: countdown keeps running
    else User taps "Начать сейчас" (Enter)
        Card->>Coord: startBreak(nextStep, minutes)
    else User taps "Отменить"
        Card->>Coord: cancelBreakCountdown()
        Pill-->>User: "☕ Перерыв M"
        User->>Card: "☕ Начать перерыв · M мин"
        Card->>Coord: startBreak(nextStep, minutes)
    else countdown reaches 0
        Tick->>Coord: runBreakCountdown(now)
        Coord->>Coord: startBreak(nil, breakMinutesChoice)
        Card->>Coord: onDisappear saveNextStepDraft
    end
    Coord->>Store: start break pomodoro
    Note over Coord: hub shows green timer card<br/>"Перерыв · из M мин · потом фокус N мин"
    alt User taps "Закончить перерыв"
        User->>Coord: finishBreakEarly()
        Coord->>Store: finish break (not completed)
    else break timer expires
        Tick->>Coord: handlePomodoroExpiry(now)
    end
    Coord->>Coord: present(.breakEnd)
    Pill-->>User: "▶ Фокус N"
    alt "▶ Начать фокус · N мин" or pill click
        User->>Coord: resumeAfterBreak(minutes)
    else "Без таймера"
        User->>Coord: endBreakWithoutTimer()
    else "Ещё 5 мин отдыха"
        User->>Coord: extendBreak(5)
    end
```
