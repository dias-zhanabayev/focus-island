# Architecture

## System Shape

The project is a single Swift package. Focus Island logic lives in `FocusCore` (GRDB store, board, pomodoro, session history) and `OpenIslandApp/Focus` (coordinator and views); the island shell keeps its Open Island target names:

| Target | Role |
|---|---|
| **OpenIslandApp** | SwiftUI + AppKit shell — menu bar extra, overlay panel (notch/top-bar), settings. Entry point: `OpenIslandApp.swift` with `AppModel` as the central `@Observable` state owner. |
| **OpenIslandCore** | Shared library — models (`AgentSession`, `AgentEvent`, `SessionState`), bridge transport (Unix socket IPC with JSON line protocol), hook models/installers, transcript discovery, session persistence/registry. |
| **OpenIslandHooks** | Lightweight CLI executable invoked by agent hooks. Reads hook payload from stdin, forwards to app bridge via Unix socket, writes blocking JSON to stdout only when island denies a `PreToolUse`. |
| **OpenIslandSetup** | Installer CLI for the Claude Code hooks in `~/.claude/settings.json`. |
| **FocusCore** | Focus Island domain: tasks, task sessions, pomodoro, activity spans, SQLite store in `~/Library/Application Support/FocusIsland/focus.sqlite`. |

## Data Flow

### Claude Code hooks

```
Agent
  │  stdin: JSON payload
  ▼
OpenIslandHooks CLI  (--source claude)
  │  Unix socket
  ▼
BridgeServer → AppModel → UI
  │  BridgeResponse
  ▼
OpenIslandHooks CLI
  │  stdout: JSON directive (only when a response is needed)
  ▼
Agent
```

### Session discovery (on launch)

1. Restore cached sessions from registry
2. Discover recent JSONL transcripts (`~/.claude/projects/`)
3. Reconcile with active terminal processes
4. Start live bridge

**Fail-open principle**: if the bridge is unavailable, the hook process exits silently without writing to stdout, so the agent continues running unaffected.

## Event Model

The shared `AgentEvent` enum drives all state transitions:

- Session started / updated / completed
- Permission requested
- Question asked
- Tool use (pre/post)
- Subagent lifecycle
- Jump target updated

Each event carries a stable session identifier, agent type, timestamps, and enough metadata to route approvals or focus changes.

## State Management

- `SessionState.apply(_:)` is the single source of truth for session mutations (pure reducer)
- `AppModel` owns all live state and bridge lifecycle
- All models are `Sendable` and `Codable`

## Transport

- Unix domain sockets for app ↔ hook communication
- Newline-delimited JSON envelopes (`BridgeCodec`)
- Bridge server lives inside the app process

## Terminal Jump-Back

Terminal focus restoration is implemented per-terminal:

| Terminal | Strategy |
|---|---|
| Terminal.app | TTY targeting via AppleScript |
| Ghostty | Window ID matching |
| cmux | Unix socket API |
| Kaku | CLI pane targeting |
| WezTerm | CLI pane targeting |
| iTerm2 | AppleScript session/TTY probe |
| tmux (multiplexer) | switch-client → select-window → select-pane |
| Claude.app (Code tab) | `claude://code/continue?session=local_…` deep link, id resolved from Claude's session files |

The hook helper enriches payloads with terminal-local hints (terminal app, TTY, session ID, window title) from environment inspection at hook invocation time.

## Technologies

- SwiftUI for most UI composition
- AppKit for panel behavior, status item control, and activation policy edge cases
- Unix domain sockets for IPC
- JSON event envelopes for debugging and adapter simplicity

## Engineering Rules

- Preserve clean separation between UI state and transport concerns
- Version the event schema so adapters can evolve safely
- Keep setup reversible when editing third-party tool config files
- Keep the runtime surface bound to real agent state rather than shipping UI-level demo toggles
