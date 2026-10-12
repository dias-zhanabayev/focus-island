# Focus Island — ждут вне задачи — sequence diagram

P17 из `docs/superpowers/specs/2026-10-10-focus-island-pomodoro-design.md`: ждущие сессии других задач без карточки-перехвата, кнопка и секция в пульте, счётчик в пилюле.

```mermaid
sequenceDiagram
    autonumber
    actor Dev as Разработчик
    participant FC as FocusCoordinator
    participant Hub as SessionHubView
    participant Pill as Свёрнутый остров
    participant App as AppModel

    loop tick
        FC->>FC: refreshHub → waitingOutside = StalledPolicy.stalled без задачи в фокусе
    end
    Note over FC: карточки .stalled нет — остров сам не открывается
    FC-->>Pill: слева «N ждут» (во время фокуса — серая цифра)
    FC-->>Hub: кнопка «Ждут вне задачи · N ▸»
    alt клик по левой половине пилюли
        Dev->>App: openIslandFromClosedPillClick(onLeftSide: true)
        App->>FC: showWaitingOutside()
        App->>App: notchOpen
    else кнопка в пульте
        Dev->>Hub: «Ждут вне задачи · N ▸»
        Hub->>FC: toggleWaitingOutside()
    end
    FC-->>Hub: секция под сессиями задачи
    alt «Перейти»
        Hub->>FC: requestJump(sessionID)
        Note over FC: задача в фокусе не меняется
    else «⋯» → «Добавить в «X»»
        Hub->>FC: bind(sessionID, taskID)
        FC-->>Hub: сессия переезжает в «Сессии задачи»
    else «Отложить — на паузу» / «Отложить все»
        Hub->>FC: deferWaitingOutside(sessionIDs)
        FC->>FC: history.park, refreshHub
    end
```
