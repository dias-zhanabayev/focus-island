# Focus Island first task onboarding — sequence diagram

Covers P24: from connecting Claude Code to a task in progress, including the task that waits for its first session. Derived from `OnboardingCard` and `FocusCoordinator.startFirstTask` / `autoBindToWaitingTask`.

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant Card as OnboardingCard
    participant FC as FocusCoordinator
    participant Board as BoardService
    participant Hooks as Claude Code hooks

    User->>Card: «Подключить»
    Card->>FC: installHooks → setHooksInstalled(true)
    FC-->>Card: stage = firstTask
    Card->>FC: firstTaskCandidates()
    FC-->>Card: live sessions without a task, freshest first
    alt user takes a suggestion
        User->>Card: «Взять»
        Card->>Card: title = suggestion, preselect same cwd
    else user types a title
        User->>Card: types title
        Card->>Card: preselect sessions from freshest cwd
    end
    User->>Card: «Начать задачу»
    Card->>FC: startFirstTask(title, sessionIDs, criterion)
    FC->>Board: createTask(column: inProgress, projectPath: cwd of first session)
    FC->>FC: add criterion, mark onboarding taskAdded
    FC->>FC: startTask(taskID, sessionIDs) binds sessions, sets current task
    FC-->>Card: stage = started
    alt no sessions selected
        Note over FC: firstTaskWaitingID = task
        Card-->>User: «Жду первую сессию Claude» + cd … && claude
        Hooks->>FC: new session (sessionsDidChange)
        FC->>Board: bindSession, fill empty projectPath
        FC-->>User: «Новая сессия в задаче · Отвязать» for 8 s
    else sessions selected
        Card-->>User: «Задача в работе · N сессий внутри»
    end
    alt «▶ Фокус N минут»
        User->>Card: start focus
        Card->>FC: startPomodoro, dismissOnboarding
    else «Без таймера»
        User->>Card: skip timer
        Card->>FC: dismissOnboarding
    end
```
