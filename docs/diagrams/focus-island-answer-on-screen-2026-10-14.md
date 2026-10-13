# Focus Island answer already on screen — sequence diagram

Covers P26: the completion summary is skipped when the finished session is the one open in front of the user. Derived from `AppModel.scheduleNotificationSurfacePresentationIfNeeded`, `ForegroundTerminalSessionProbe.matches(session:)` and `ClaudeDesktopSessionLocator.focusedCLISessionID`.

```mermaid
sequenceDiagram
    autonumber
    participant Hook as Claude Code hook
    participant App as AppModel
    participant Probe as ForegroundTerminalSessionProbe
    participant Files as Claude.app session files
    participant FC as FocusCoordinator
    participant Island as Island overlay

    Hook->>App: Stop event, session completed
    App->>FC: opensIslandOnCompletion(sessionID)
    FC-->>App: true for a session of the current task
    App->>Probe: matches(session)
    alt Claude.app session
        Probe->>Probe: frontmost is com.anthropic.claudefordesktop?
        Probe->>Files: focusedCLISessionID()
        Files-->>Probe: cliSessionId with newest lastFocusedAt
    else terminal session
        Probe->>Probe: Ghostty id / Terminal tty / iTerm id via AppleScript
    end
    alt session is on screen
        Probe-->>App: true
        App->>FC: markSessionSeen(sessionID)
        Note over FC: unseen cleared, returned card closed
    else not on screen
        Probe-->>App: false
        App->>Island: presentNotificationSurface(summary)
    end
```
