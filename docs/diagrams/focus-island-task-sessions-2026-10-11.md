# Focus Island — сессии задачи и закрытие — sequence diagram

P12–P14 из `docs/superpowers/specs/2026-10-10-focus-island-pomodoro-design.md`: один экран выбора сессий из пульта, «Взять» и доски, «Отвязать» и «Закрыть задачу».

```mermaid
sequenceDiagram
    autonumber
    actor Dev as Разработчик
    participant Hub as SessionHubView
    participant Picker as TaskSessionsPicker
    participant FC as FocusCoordinator
    participant Board as BoardService

    alt «Взять» задачу без сессий
        Dev->>FC: takeTask(taskID)
        FC->>FC: present(.bindToTask(taskID))
    else «+ Добавить сессию» в пульте
        Dev->>Hub: клик
        Hub->>FC: openTaskSessions(taskID)
    else «+ Добавить сессию» в карточке доски
        Dev->>Picker: лист поверх карточки
    end
    Picker->>FC: taskSessionChoices(taskID)
    FC-->>Picker: привязанные, проект задачи, другие проекты
    Dev->>Picker: галочки, «Добавить N» / «Сохранить»
    Picker->>FC: applyTaskSessions(taskID, selected)
    FC->>Board: bindSession(новые → taskID)
    FC->>Board: bindSession(снятые → nil)
    FC->>FC: closeCard, refreshHub
    FC-->>Hub: пульт задачи, только её сессии
    opt «Отвязать» у сессии
        Dev->>Hub: клик
        Hub->>FC: unbind(sessionID)
        FC->>Board: bindSession(sessionID → nil)
    end
    Dev->>Hub: «✓ Закрыть задачу»
    Hub->>FC: closeTask(taskID)
    FC->>Board: moveTask(Done)
    Note over FC: помодоро задачи остановлен, фокус снят, сессии остаются привязаны
    FC-->>Hub: «… закрыта · Вернуть», выбор задачи
    Note over FC: если закрыта фокусная задача — focusCleared, автоправило не подставляет другую<br/>выбор другой задачи убирает «Вернуть»
    opt «Вернуть» в течение 8 с
        Dev->>FC: reopenClosedTask
        FC->>Board: moveTask(In progress)
        FC->>FC: focusTaskOverrideID = taskID, если была в фокусе
    end
```
