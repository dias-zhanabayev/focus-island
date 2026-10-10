# Focus Island: подсказка «Что дальше?» — sequence-диаграмма

Покрывает жизненный цикл одного хода Claude: привязка сессии к задаче на канбан-доске, срабатывание «Что дальше?» и детектор отвлечения. Построена по разделам F4–F6 и 7.4 файла `docs/superpowers/specs/2026-10-09-focus-island-pdr.md` (ревизия 2) и по цепочке апстрима: хук → `bridge.sock` → `BridgeServer` → `SessionState`.

```mermaid
sequenceDiagram
    autonumber
    actor User as Пользователь
    participant CC as Claude Code
    participant Hook as OpenIslandHooks
    participant Bridge as BridgeServer + SessionState
    participant FC as FocusCoordinator
    participant Store as SessionHistory + BoardService (focus.sqlite)
    participant TT as TurnTracker
    participant NAE as NextActionEngine
    participant FAM as FrontmostAppMonitor
    participant UI as Island UI

    User->>CC: запускает claude
    CC->>Hook: SessionStart (source=startup)
    Hook->>Bridge: processClaudeHook через bridge.sock
    Hook-->>CC: сразу exit 0 (fail-open)
    Bridge->>FC: снапшот: новая сессия
    FC->>Store: upsert session record
    alt source=resume и в истории есть taskId
        Store-->>FC: привязка унаследована
    else новая сессия
        FC->>UI: чип «Привязать к задаче?» (Todo и In progress, сначала этот проект)
        alt выбрана существующая задача
            User->>UI: выбирает задачу
            UI->>Store: taskId в сессию, задача переезжает в In progress
        else Новая задача
            User->>UI: «Новая задача…»
            UI->>Store: создать задачу в In progress, projectPath = cwd
        else Пропустить
            User->>UI: пропуск
        end
    end

    User->>CC: отправляет промпт
    CC->>Hook: UserPromptSubmit
    Hook->>Bridge: событие
    Bridge->>FC: phase=running
    FC->>TT: начало хода
    CC->>Hook: PreToolUse
    Hook->>Bridge: событие
    Bridge->>FC: activityUpdated (phase=running, ход уже идёт)
    TT->>TT: таймер nextActionDelay (15 с) от перехода в running

    alt через 15 с сессия всё ещё running и в этом ходе карточки ещё не было
        TT->>NAE: evaluate(sessions, board, history, now)
        alt другая сессия ждёт ответа или не просмотрена
            NAE-->>UI: карточка «Перейти к сессии X»
        else в Todo есть задача
            NAE-->>UI: карточка «Начать задачу Y»
        else
            NAE-->>UI: карточка «Обдумай следующий шаг» с заметкой и «+ задача»
        end
        UI->>User: island раскрывается
        alt Перейти или Начать
            User->>UI: клик
            UI->>FC: jump или новый терминал в projectPath (ResumeLauncher)
            FC->>Store: задача Y переезжает в In progress
        else Отложить 5 мин
            User->>UI: snooze
            UI->>TT: подавить карточки для этой сессии
        end
    else Claude закончил раньше
        CC->>Hook: Stop
        Hook->>Bridge: событие
        Bridge->>FC: phase=completed
        FC->>TT: отменить таймер
    end

    loop пока хотя бы одна сессия running
        FAM->>FAM: активное приложение и URL вкладки раз в 5 с
        alt в стоп-листе 20 с и больше
            FAM->>Store: открыть DistractionEpisode
            FAM->>UI: nudge: текущая задача, ждущие сессии, следующая из Todo
            alt Вернуться
                User->>UI: клик
                UI->>FC: jump к последней активной сессии
                FAM->>Store: закрыть эпизод, returnedWithinSec
            else Мне это нужно (10 мин)
                User->>UI: клик
                UI->>FAM: подавить детектор на 10 мин
            end
        end
    end
```
