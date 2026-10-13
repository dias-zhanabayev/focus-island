# Focus Island session continuation — sequence diagram

Covers a Claude.app session that comes back with a new Claude Code session ID (spec addendum P23). Derived from `FocusCoordinator.sessionsDidChange`, `refreshSessionLabels`, `adoptContinuation` and `ClaudeDesktopSessionLocator.sessions(forCLISessionIDs:)`.

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant ClaudeApp as Claude.app
    participant Hook as OpenIslandHooks
    participant Coord as FocusCoordinator
    participant Locator as ClaudeDesktopSessionLocator
    participant History as SessionHistory

    ClaudeApp->>ClaudeApp: respawn CLI, old ID into priorCliSessionIds
    ClaudeApp->>Hook: SessionStart with new ID
    Hook->>Coord: sessionsDidChange (new ID)
    Coord->>Coord: pendingBindingSessionIDs.append(new)
    Coord->>Coord: refreshSessionLabels()
    alt lookup already in flight
        Note over Coord: new ID is checked right after the running lookup
    end
    Coord->>Locator: sessions(forCLISessionIDs: [new])
    Locator-->>Coord: title, status, priorCLISessionIDs
    Coord->>Coord: adoptContinuation(new, priors)
    alt already checked or new ID has a task
        Note over Coord: nothing changes
    else latest prior ID has a task
        Coord->>History: bind(new, taskID)
        opt prior was done or parked
            Coord->>History: markDone / park(new)
        end
        Coord->>Coord: pendingBindingSessionIDs.remove(new)
        Coord-->>User: session stays in the task, no "✦ Новая сессия"
    else no prior ID has a task
        Coord-->>User: "✦ Новая сессия" as before
    end
```
