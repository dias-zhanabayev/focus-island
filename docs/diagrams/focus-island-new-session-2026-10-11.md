# Focus Island new session — sequence diagram

Covers a new Claude Code session appearing with and without a task in focus (spec addenda P18 and P20). Derived from `FocusCoordinator.sessionsDidChange`, `bindNewSession`, `skipBinding`, `opensIslandOnCompletion`, `AppModel.scheduleNotificationSurfacePresentationIfNeeded` and `SessionHubView.newSessionHint`.

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant Hook as OpenIslandHooks
    participant App as AppModel
    participant Coord as FocusCoordinator
    participant Pill as FocusEars pill
    participant Island as Island panel

    Hook->>App: session started
    App->>Coord: sessionsDidChange(sessions)
    Coord->>Coord: pendingBindingSessionIDs.append(id)
    Note over App,Island: island is not opened for a new session
    opt session phase becomes completed
        App->>Coord: opensIslandOnCompletion(id)
        Coord-->>App: true only for a session of the focus task
    end
    alt no task in focus
        App->>Pill: taskSlot(newSessionPending: true)
        Pill-->>User: "✦ Новая сессия · задача?"
        User->>App: click pill
        App->>Island: notchOpen
        Island-->>User: BindingCard "Над какой задачей работаешь?"
        alt pick a task
            User->>Coord: bindNewSession(id, taskID)
            Coord->>Coord: bind, then startTask (task goes to focus)
        else "Новая задача из первого промпта"
            User->>Coord: createTaskForSession(id)
            Coord->>Coord: create, bind, start in focus
        end
    else task in focus
        Island-->>User: dashed row at bottom of hub<br/>"✦ Новая сессия · project · prompt"
        alt "В эту задачу"
            User->>Coord: bind(id, focusTaskID)
        else "✕"
            User->>Coord: skipBinding(id)
        end
    end
    Coord->>Coord: pendingBindingSessionIDs.remove(id)
```
