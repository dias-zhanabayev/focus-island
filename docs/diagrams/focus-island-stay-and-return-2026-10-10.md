# Focus Island — остаться в задаче и вернуться — sequence diagram

Ход Claude от промпта до возврата с промптом из очереди (спека v3, J1, J2, J4, J6, J16). Имена — реальные типы апстрима и новые модули из `docs/superpowers/specs/2026-10-10-focus-island-journey-design.md`.

```mermaid
sequenceDiagram
    autonumber
    actor Dev as Разработчик
    participant CC as Claude Code
    participant Hook as OpenIslandHooks
    participant BS as BridgeServer
    participant SS as SessionState
    participant FC as FocusCoordinator
    participant Core as FocusCore
    participant Git as GitDiffProviding
    participant PS as PromptSender
    participant UI as Island (FocusIslandSection)

    Dev->>CC: промпт
    CC->>Hook: UserPromptSubmit
    Hook->>BS: processClaudeHook
    BS->>SS: activityUpdated(running)
    SS-->>FC: sessionsDidChange
    FC->>Core: ActivityLog.open(claude, session, task)
    CC->>Hook: PostToolUse TodoWrite(todos)
    Hook->>BS: processClaudeHook(tool_input)
    BS->>SS: claudeSessionMetadataUpdated(activeTasks + activeForm)
    SS-->>FC: sessionsDidChange
    FC->>Core: PlanProgress(activeTasks)
    Note over FC: TurnTracker: ход ≥ nextActionDelay (15 с)
    FC->>Core: NextActionEngine.alternatives(input)
    FC->>Git: numstat(cwd) вне главного потока, таймаут 2 с
    alt git недоступен или нет изменений
        Git--xFC: ошибка / пусто
        Note over FC: блок diff скрыт
    else есть изменения
        Git-->>FC: файлы +/−
    end
    FC->>UI: card = nextAction (остаться в задаче)
    Dev->>UI: пишет следующий промпт, ⌘↩
    UI->>FC: perform(queuePrompt)
    FC->>Core: PromptQueue.save(session, text)
    Dev->>UI: отмечает критерий
    UI->>FC: perform(toggleCriterion)
    FC->>Core: TaskCriteriaService.toggle
    CC->>Hook: Stop
    Hook->>BS: processClaudeHook
    BS->>SS: activityUpdated(completed)
    SS-->>FC: sessionsDidChange
    FC->>Core: ActivityLog.close(claude) + open(waiting)
    alt есть промпт в очереди или задача в фокусе
        FC->>UI: card = returned (вытесняет nextAction)
        Dev->>UI: «Отправить и вернуться»
        UI->>FC: perform(sendQueuedPrompt)
        FC->>PS: send(text, session)
        alt tmux / Ghostty / iTerm2 / Terminal.app
            PS-->>FC: sent
            FC->>Core: PromptQueue.markSent
        else неподдерживаемый терминал или ошибка
            PS--xFC: unsupported / failed
            FC->>UI: тост «Промпт в буфере — вставь ⌘V»
        end
        FC->>FC: jumpToSession + lastSeenAt = now
        FC->>Core: ActivityLog.close(waiting)
    else иначе
        Note over FC,UI: сессия попадает в «Готово, проверь» пульта
    end
```
