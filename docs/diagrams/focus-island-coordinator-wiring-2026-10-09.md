# Focus Island: связь FocusCoordinator с AppModel — sequence-диаграмма

Показывает, как реализация из плана `docs/superpowers/plans/2026-10-09-focus-island.md` (Tasks 13–17) встраивается в код апстрима: старт и backfill, обработка `state.didSet`, тик подсказки «Что дальше?», действия пользователя и ветки ошибок. Имена методов взяты из плана и из `AppModel.swift` апстрима.

```mermaid
sequenceDiagram
    autonumber
    participant AM as AppModel
    participant FC as FocusCoordinator
    participant FS as FocusStore (focus.sqlite)
    participant SH as SessionHistory
    participant BS as BoardService
    participant TB as TranscriptBackfill
    participant TT as TurnTracker
    participant NAE as NextActionEngine
    participant TL as AppleScriptTerminalLauncher
    participant OV as OverlayUICoordinator

    AM->>FS: FocusStore.openWithRecovery(defaultFileURL)
    alt файл повреждён
        FS-->>AM: новый store + backupURL focus.sqlite.bak-ts
    else норма
        FS-->>AM: store, nil
    end
    AM->>FC: init(store, backupURL, launcher)
    AM->>FC: start(initialSessions: state.sessions) после applyStartupDiscoveryPayload
    FC->>SH: markAllLiveEnded(except: живые id)
    FC->>BS: snapshot()
    par фоновый импорт
        FC->>TB: run() в Task.detached
        TB->>SH: mergeTranscript(summary) для новых и изменённых jsonl
        TB-->>FC: reload() на MainActor
    and тик
        FC->>FC: startTicking() раз в 1 с
    end

    loop каждое событие хука
        AM->>AM: state.apply(event)
        AM->>FC: sessionsDidChange(state.sessions) из state.didSet
        alt наблюдение изменилось
            FC->>SH: record(SessionObservation)
        else то же самое
            Note over FC: запись в SQLite пропускается
        end
        opt новая сессия, startup, firstSeenAt моложе 60 с
            FC->>FC: pendingBindingSessionIDs.append
        end
        opt сессия пропала из state
            FC->>SH: markEnded(sessionID)
            FC->>TT: forget(sessionID)
        end
        FC->>TT: observe(sessionID, phase, lastUserPrompt)
    end

    FC->>TT: takeDueSessions(now) в tick()
    alt есть due, card пуста, FocusPresentationPolicy разрешает
        FC->>NAE: evaluate(NextActionInput)
        NAE-->>FC: NextAction
        FC->>FS: NextActionLog.shown(kind)
        FC->>AM: presentCard()
        AM->>OV: notchOpen(reason: .notification)
    else пользователь занят в другом приложении 60 с и больше
        Note over FC: карточка не показывается, ход израсходован
    end

    alt perform(.startTask)
        FC->>BS: moveTask(to: .inProgress)
        FC->>TL: run(ResumeCommand.newSession(cwd), terminal)
        alt AppleScript упал
            TL--xFC: TerminalLaunchError.scriptFailed
            Note over FC: ошибка уходит в лог, карточка всё равно закрывается
        end
        FC->>FS: NextActionLog.reacted(id)
    else perform(.jump)
        FC->>AM: jumpToSession(sessionID)
        FC->>FC: unseenCompleted.remove
    else perform(.snooze)
        FC->>TT: snooze(until: now + 300 с)
    end
```
