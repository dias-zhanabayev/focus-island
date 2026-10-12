# Focus Island — старт задачи и помодоро: план

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Goal:** реализовать сценарий 7.0–7.5 (старт задачи, привязка сессий, помодоро).
**Spec:** `docs/superpowers/specs/2026-10-10-focus-island-pomodoro-design.md`
**Mockups:** канвас «Focus Island — экраны», страница «7 · Задача и помодоро» (локальные копии `…/scratchpad/focus-design/project/{NoFocusTask,StartTask,TaskPomodoro,IslandPomodoro,PomodoroEnd,PomodoroBreak}.dc.html`).

## Global Constraints
- Swift 6.2, macOS 14, SwiftUI + AppKit; FocusCore на GRDB 7.
- Никаких комментариев в коде; никаких коммитов.
- TDD на Swift Testing; полный прогон `zsh scripts/test-clt.sh` зелёный.
- Логика — в чистых `nonisolated static` функциях или FocusCore; без чтений БД в `body`.
- Тексты UI — русские, ровно как в спеке и мокапах.
- Тесты не трогают `~/.claude` и реальную `~/Library/Application Support/FocusIsland`; приложение не запускать.

## Tasks

### Task 1: FocusCore — модель помодоро
Files: `Sources/FocusCore/Pomodoro.swift` (новый), `FocusStore.swift` (миграция v3), `FocusSettings.swift` (3 настройки с клампом: фокус 5–120, перерыв 1–30, цикл 2–8), `BoardService.deleteTask` (останов/удаление помодоро задачи); тесты в `Tests/FocusCoreTests`.
Produces: `Pomodoro`, `PomodoroPhase`, `PomodoroStore` (`start`, `pause`, `resume`, `finish(completed:)`, `active()`, `completedFocusCount(taskID:day:)`, `completedFocusCount(day:)`, `recoverExpired(now:)`), `PomodoroClock` (`remaining`, `progress`, `isExpired`, `cycleIndex`).

### Task 2: Координатор — помодоро, старт задачи, карточки
Files: `FocusCoordinator.swift`, тесты `FocusCoordinatorPomodoroTests`.
Produces: `pomodoro` (observed snapshot: phase, remaining, planned, isPaused, cycleIndex, taskID), `startTask(taskID:sessionIDs:focusMinutes:)`, `requestStartTask(taskID:)` / `pendingStartTaskID`, `startPomodoro(taskID:minutes:)`, `pausePomodoro`, `resumePomodoro`, `stopPomodoro`, `startBreak`, `extendBreak(minutes:)`, `endWithoutBreak`, `continueFocus`, `pomodoroSummary(id:)` (KPI за интервал и события), новые карточки `.pickTask`, `.pomodoroEnd(id:)`, `.breakEnd(id:)` с приоритетами из спеки; на перерыве — без nudge/эпизодов отвлечения/nextAction/stalled; `bindableSessions(forTaskID:)` для поповера и листа; `todaySummary` + число помодоро; восстановление при `start`.

### Task 3: UI старта и карточки задачи
Files: `Views/StartTaskSheet.swift`, `Views/TaskDetailView.swift` (PomodoroBlock, «Привязать сессию ▾»), `Views/BoardView.swift` (drop в In progress → лист), `BoardWindowController` (показ листа по `pendingStartTaskID`); тесты логики в `FocusViewLogicTests`.

### Task 4: UI island
Files: `Views/Cards/PickTaskCard.swift`, `PomodoroEndCard.swift`, `BreakEndCard.swift`, `FocusIslandSection.swift`, `SessionHubView.swift` (строка таймера, футер), `V6NotchContent.swift` + `AppModel` (уши: подсказка «Выбрать задачу · Todo N», таймер, перерыв), клик по пилюле в состоянии подсказки → `.pickTask`; `DaySummaryView` KPI «Помодоро» + markdown.

### Task 5: Документация
`docs/focus-smoke.md` S13–S16 (7.0, 7.1–7.2, 7.3–7.4, 7.5), README «Что умеет».

### Task 6: Координатор — стабильный фокус и привязка из острова (P9–P11)
Files: `FocusCoordinator.swift`, тесты. Produces: `pickTaskOptions()` → секции inProgress/todo с числом и состоянием сессий; `takeTask(taskID:) -> TakeTaskResult` (.focused / .needsBinding); карточка `.bindToTask(taskID:)`; `bindAndJump(taskID:sessionIDs:)`; `focusTaskSessions` (живые сессии фокусной задачи + `hereSessionID`); `otherHubRows`; правило P11 (снять очистку оверрайда на jump/промпт чужой задачи).

### Task 7: UI — PickTaskCard v2, BindToTaskCard, пульт задачи
Files: `Cards/PickTaskCard.swift`, `Cards/BindToTaskCard.swift` (новый), `SessionHubView.swift` (шапка «Сменить», блок «Сессии задачи», «Другие сессии», свёрнутая пауза), `FocusIslandSection.swift`; тесты логики.

### Task 8: Документация — S17–S18 в smoke, README.
