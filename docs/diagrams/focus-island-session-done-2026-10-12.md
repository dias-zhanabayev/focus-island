# Focus Island session done — sequence diagram

Covers marking a task session as done, returning it, and the all-done suggestion (spec addendum P22). Derived from `FocusCoordinator.markSessionDone`, `reopenDoneSession`, `showsAllDoneSuggestion`, `SessionHistory.markDone` / `record`, `SessionHub.row` and `SessionHubView.focusBlock`.

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant Hub as SessionHubView
    participant Coord as FocusCoordinator
    participant Hist as SessionHistory
    participant Rows as SessionHub.rows

    User->>Hub: "✓ Готово" or "⋯" then "Сессия готова"
    Hub->>Coord: markSessionDone(sessionID)
    Coord->>Hist: markDone (doneAt = now, parkedAt = nil)
    Coord->>Coord: doneSessionNotice, workRevision += 1
    Coord->>Rows: refreshHub
    Rows-->>Coord: row.group = .done (task-bound only)
    Coord-->>Hub: focusTaskSessions without done, focusTaskDoneSessions
    Hub-->>User: "«X» готова · Вернуть" for 8 s, "Готовые · N ▸"
    alt User taps "Вернуть"
        User->>Coord: reopenDoneSession(sessionID)
        Coord->>Hist: unmarkDone (doneAt = nil)
    else User writes a new prompt in that session
        Hist->>Hist: record(observation) clears doneAt
        Note over Coord,Rows: session is active again without asking
    end
    opt no active sessions and some done
        Coord-->>Hub: showsAllDoneSuggestion = true
        alt "✓ Закрыть задачу"
            User->>Coord: closeTask(taskID, showPicker: true)
        else "Не сейчас"
            User->>Coord: dismissAllDoneSuggestion (until done count changes)
        end
    end
```
