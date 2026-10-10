# Focus Island v3 — путь пользователя: план реализации (короткий)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Реализовать спеку v3: шаги плана Claude, «остаться в задаче», очередь промптов, возврат, пульт сессий, перегрузка, забытые сессии, вход в задачу, начало дня, доска с сессиями, сводки дня и недели.

**Architecture:** Чистая логика и хранение — в `FocusCore` (GRDB, миграция `v2`, политики без AppKit, всё под тестами). Разбор TodoWrite — в `OpenIslandCore/BridgeServer`. `FocusCoordinator` выбирает одну карточку по приоритету и пишет интервалы времени. Новые SwiftUI-view в `OpenIslandApp/Focus/Views` по макетам; пульт заменяет строки сессий апстрима в обычном режиме панели.

**Tech Stack:** Swift 6.2, SwiftUI + AppKit, macOS 14+, Swift Testing, GRDB 7, NSAppleScript/osascript, `git` CLI.

**Spec:** `docs/superpowers/specs/2026-10-10-focus-island-journey-design.md` (требования J1–J21). Макеты: https://claude.ai/artifact/DVhi1JVyZ6zz8fyDrDHTqS, исходники макетов: `/private/tmp/claude-501/-Users-diaszhanabayev-Projects-own-focus/2786ad0a-e64e-4bd6-9347-638810ab62f9/scratchpad/focus-design/project/*.dc.html`. Карта кода: `.superpowers/sdd/codemap-2026-10-10.md`. Диаграммы: `docs/diagrams/focus-island-stay-and-return-2026-10-10.md`, `docs/diagrams/focus-island-multi-session-2026-10-10.md`, `docs/diagrams/focus-island-journey-plan-2026-10-10.md`.

**Формат:** план короткий по решению пользователя — у задач нет готового кода. Есть файлы, точные сигнатуры, обязательные тесты и критерий готовности. Исполнитель пишет код сам, сверяясь с реальным кодом, картой кода и макетом. Сигнатуры в разделе «Interfaces» обязательны дословно: на них опираются следующие задачи.

## Global Constraints

- macOS 14+, `swift-tools-version: 6.2`, Swift 6 strict concurrency (все модели `Sendable`).
- **Никаких комментариев в коде** (жёсткое правило пользователя). Существующие комментарии апстрима не трогать.
- **Никаких git-коммитов.** Шаг «Checkpoint» = полная сборка + полный прогон тестов.
- `SessionState.apply` — единственное место изменения живых сессий; Focus-модули только читают `[AgentSession]`.
- Хуки работают в режиме fail-open; никаких сетевых запросов; в терминал ничего не отправляется без клика пользователя.
- Строки UI — русские литералы. Тексты и цвета берутся из макетов.
- Тесты: `zsh /Users/diaszhanabayev/Projects/own/focus/scripts/test-clt.sh [--filter X]`. Сборка: `swift build --package-path /Users/diaszhanabayev/Projects/own/focus`. `cd` в оболочке сломан — только абсолютные пути и `git -C`.
- Не запускать приложение, не трогать `~/.claude` и реальные файлы в `~/Library/Application Support/FocusIsland/`. В тестах использовать `FocusStore.inMemory()`, временные `UserDefaults(suiteName:)` и `ClaudeSessionRegistry.temporaryForTesting()`.
- Время в логике передаётся явно (`now:`), как в существующем коде.
- Значения по умолчанию v3:
  - `maxParallelSessions` 3 (диапазон 1–6), `stalledReminderMinutes` 15 (5–60), `dayStartEnabled` true;
  - порог входа в задачу 10 мин; карточка забытых не чаще раза в 30 мин;
  - «готово, не просмотрено» становится забытым через 60 мин; «без задачи» — через 120 мин; группа «Без задачи» в пульте — после 30 мин без активности;
  - правое ухо становится оранжевым после 10 мин ожидания;
  - diff: кэш 10 с, таймаут 2 с; не больше 5 файлов;
  - `lastAssistantMessage` в карточках обрезается до 240 символов, в строках сессий — до 60;
  - начало дня — не раньше 05:00;
  - ширина раскрытой панели: 700 на экране с вырезом, 680 без выреза, уведомления 700.
- Дизайн-токены `FocusStyle`:
  - акцент `#0064E0`; работает `#30D158`; ждёт `#FF9F0A`, текст ожидания `#FFB340`; готово `#64D2FF`; отвлечение `#FF453A`;
  - вторичный текст `#A1A1A6`; подпись секции 11 пт uppercase `#8E8E93`; поверхность — белый 0.06;
  - радиусы: карточка 14, строка 12, кнопка 7.

## Review Focus

1. **База v1 с данными → миграция v2.** Старые задачи и сессии сохраняются, новые колонки равны `nil`. Тест `FocusStoreTests.migratesV1DatabaseToV2` (Task 1).
2. **TodoWrite с неожиданной формой** (нет `todos`, не массив, пункт без `content`). `activeTasks` остаётся прежним, без падения. Тест `ClaudeTodoParserTests.malformedInputReturnsNil` (Task 4).
3. **Две карточки сразу**: nudge во время `returned` или nextAction во время `overload`. Побеждает приоритет, а младшая карточка не теряет состояние триггера. Тест `FocusCoordinatorCardTests.priorityOrder` (Task 7).
4. **Перезапуск с открытыми интервалами** — закрываются временем запуска, «Ты в работе» не раздувается. Тест `ActivityLogTests.closeAllOpenOnStart` (Task 3) и `FocusCoordinatorSpanTests.startClosesDanglingSpans` (Task 8).
5. **Терминал не поддерживает отправку** — промпт уходит в буфер, переход выполняется, показывается тост, а промпт остаётся неотправленным. Тест `FocusCoordinatorCardTests.unsupportedSendFallsBackToClipboard` (Task 7).

## File Structure

| Файл | Ответственность |
|---|---|
| `Sources/FocusCore/FocusModels.swift` (mod) | новые поля `SessionRecord`; `TaskCriterion`, `QueuedPrompt`, `ActivityKind`, `ActivitySpan`, `DayPlan` |
| `Sources/FocusCore/FocusStore.swift` (mod) | миграция `v2` |
| `Sources/FocusCore/FocusSettings.swift` (mod) | 3 новых поля |
| `Sources/FocusCore/TaskWork.swift` (new) | `TaskCriteriaService`, `PromptQueue`, `DayPlanStore` |
| `Sources/FocusCore/ActivityLog.swift` (new) | `ActivityLog`, `DayReport`, `WeekReport`, `ReportBuilder` |
| `Sources/FocusCore/SessionHub.swift` (new) | `PlanProgress`, `HubGroup`, `HubRow`, `SessionHub`, `StalledPolicy`, `OverloadPolicy`, `DayStartPolicy` |
| `Sources/FocusCore/NextActionEngine.swift` (mod) | `NextAlternative`, `alternatives(...)`; `evaluate` удаляется в Task 7 |
| `Sources/OpenIslandCore/ClaudeTodoParser.swift` (new), `ClaudeHooks.swift`, `BridgeServer.swift` (mod) | TodoWrite → `activeTasks` с `activeForm` |
| `Sources/OpenIslandApp/Focus/PromptSender.swift`, `GitDiffProvider.swift` (new) | отправка промпта, `git diff --numstat` |
| `Sources/OpenIslandApp/Focus/FocusCoordinator.swift` (mod) | карточки, приоритет, действия, интервалы, триггеры |
| `Sources/OpenIslandApp/Focus/Views/FocusStyle.swift` (new) | токены и мелкие компоненты (`FocusSectionCaption`, `StatusDot`, `ProgressBar`, `ProjectTag`, `FocusButtonStyle`) |
| `Sources/OpenIslandApp/Focus/Views/Cards/*.swift` (new) | карточки island |
| `Sources/OpenIslandApp/Focus/Views/SessionHubView.swift` (new), `FocusIslandSection.swift` (mod) | пульт и контейнер |
| `Sources/OpenIslandApp/Views/IslandPanelView.swift`, `V6NotchContent.swift`, `OverlayPanelController.swift`, `AppModel.swift` (mod) | интеграция в панель, уши, ширина |
| `Sources/OpenIslandApp/Focus/Views/BoardView.swift`, `TaskDetailView.swift`, `HistoryView.swift`, `FocusSettingsPane.swift` (mod); `DaySummaryView.swift`, `WeekSummaryView.swift`, `TimelineView.swift` (new); `StatsView.swift` (delete) | окно доски и настройки |

---

## Фаза A — FocusCore и OpenIslandCore

### Task 1: Модели, миграция v2, настройки

**Files:**
- Modify: `Sources/FocusCore/FocusModels.swift`, `Sources/FocusCore/FocusStore.swift`, `Sources/FocusCore/FocusSettings.swift`
- Test: `Tests/FocusCoreTests/FocusStoreTests.swift`, `Tests/FocusCoreTests/FocusSettingsTests.swift`

**Interfaces (Produces):**
- `SessionRecord` получает `public var parkedAt: Date?` и `public var lastSeenAt: Date?`. В memberwise init они идут последними параметрами со значением по умолчанию `nil`, поэтому существующие вызовы не ломаются.
- `public struct TaskCriterion: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord` (таблица `task_criteria`): `id: String, taskId: String, text: String, done: Bool, position: Double, createdAt: Date` и публичный init.
- `public struct QueuedPrompt: … PersistableRecord` (таблица `queued_prompts`): `id: String, sessionId: String, taskId: String?, text: String, createdAt: Date, sentAt: Date?`.
- `public enum ActivityKind: String, Codable, Sendable, CaseIterable { case claude, waiting, you, distraction }`.
- `public struct ActivitySpan: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord` (таблица `activity_spans`): `id: Int64?, kind: ActivityKind, sessionId: String?, taskId: String?, startedAt: Date, endedAt: Date?`; `didInsert` выставляет id.
- `public struct DayPlan: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord` (таблица `day_plans`): `day: String, focusTaskIds: [String], tomorrowNote: String?, dayStartShownAt: Date?`. Колонка `focusTaskIds` хранится как JSON-текст (`'[]'` по умолчанию) через собственный `encode(to container:)` / `init(row:)`.
- `FocusSettings`: `public var maxParallelSessions: Int = 3`, `public var stalledReminderMinutes: Int = 15`, `public var dayStartEnabled: Bool = true`. Все читаются через `decodeIfPresent`.
- Миграция `registerMigration("v2")`: колонки, таблицы и индексы точно по спеке §5.

**Тесты (обязательные):** `migratesV1DatabaseToV2`, `criterionRoundTrip`, `queuedPromptRoundTrip`, `activitySpanInsertSetsID`, `dayPlanFocusTaskIdsRoundTrip`, `settingsDecodeOldJSONKeepsNewDefaults`.
- Тест миграции: создать `DatabaseQueue`, применить только v1 (вынести `static func migrator(upTo:)` или аналогичный testable-хук), вставить задачу и сессию, затем мигрировать полностью и проверить данные.

- [ ] Тесты → красные → реализация → зелёные → Checkpoint (полная сборка + все тесты).

### Task 2: Критерии, очередь промптов, план дня

**Files:** Create `Sources/FocusCore/TaskWork.swift`; Modify `Sources/FocusCore/BoardService.swift` (`deleteTask`), `Sources/FocusCore/SessionHistory.swift`; Test: `Tests/FocusCoreTests/TaskWorkTests.swift`, `SessionHistoryTests.swift`, `BoardServiceTests.swift`

**Interfaces (Produces):**
- `public struct CriteriaProgress: Equatable, Sendable { public let done: Int; public let total: Int }`
- `public final class TaskCriteriaService: Sendable`:
  - `init(store: FocusStore)`;
  - `criteria(taskID: String) throws -> [TaskCriterion]` — сортировка по position;
  - `@discardableResult add(taskID: String, text: String, now: Date = .now) throws -> TaskCriterion` — trim; пустой текст → `BoardError.emptyTitle`;
  - `toggle(id: String) throws`, `delete(id: String) throws`;
  - `progress(taskID: String) throws -> CriteriaProgress`.
- `public final class PromptQueue: Sendable`:
  - `init(store:)`;
  - `pending(sessionID: String) throws -> QueuedPrompt?`;
  - `@discardableResult enqueue(sessionID: String, taskID: String?, text: String, now: Date = .now) throws -> QueuedPrompt` — заменяет неотправленный промпт сессии; пустой текст → `discard`;
  - `markSent(id: String, at: Date) throws`, `discard(sessionID: String) throws`;
  - `pendingSessionIDs() throws -> Set<String>`.
- `public final class DayPlanStore: Sendable`:
  - `init(store:)`;
  - `static func dayKey(_ date: Date, calendar: Calendar = .current) -> String` (`yyyy-MM-dd` в локальной дате);
  - `plan(day: String) throws -> DayPlan?`;
  - `setFocusTasks(_ ids: [String], day: String) throws`;
  - `setTomorrowNote(_ text: String?, day: String) throws`;
  - `markDayStartShown(day: String, at: Date) throws`.
  - Все записи — upsert.
- `BoardService.deleteTask`: дополнительно удаляет критерии задачи, обнуляет `queued_prompts.taskId` и `activity_spans.taskId` — всё в одной транзакции.
- `SessionHistory`:
  - `park(sessionID:at:)`, `unpark(sessionID:)`, `markSeen(sessionID:at:)`;
  - в `record(_:)` при смене `lastPrompt` у существующей записи сбрасывается `parkedAt`;
  - `parkedSessionIDs() throws -> Set<String>`.

**Тесты:**
- критерии: add/toggle/delete/progress, пустой текст;
- очередь: enqueue заменяет неотправленный, markSent убирает из `pendingSessionIDs`;
- план дня: dayKey на границе суток с явным `Calendar`/`TimeZone`; upsert;
- `deleteTaskCascadesCriteriaAndNullsPromptAndSpanTask`;
- `newPromptClearsPark`, `markSeenSetsLastSeenAt`.

- [ ] Тесты → реализация → Checkpoint.

### Task 3: Учёт времени и отчёты

**Files:** Create `Sources/FocusCore/ActivityLog.swift`; Test `Tests/FocusCoreTests/ActivityLogTests.swift`

**Interfaces (Produces):**
- `public final class ActivityLog: Sendable`:
  - `init(store:)`;
  - `@discardableResult open(kind: ActivityKind, sessionID: String?, taskID: String?, at: Date) throws -> Int64`;
  - `close(id: Int64, at: Date) throws`, `closeAllOpen(at: Date) throws`;
  - `spans(from: Date, to: Date) throws -> [ActivitySpan]` — пересекающие интервал; открытые считаются до `to`.
- `public struct LaneSegment: Equatable, Sendable { public let kind: ActivityKind; public let start: Date; public let end: Date }`
- `public struct TaskLane: Equatable, Sendable, Identifiable { public let id: String; public let taskID: String?; public let title: String; public let segments: [LaneSegment] }`
- `public struct DayReport: Equatable, Sendable`:
  - время: `youSeconds`, `claudeSeconds`, `waitingSeconds`, `distractionSeconds: TimeInterval`;
  - отвлечения: `distractionCount: Int`, `returnedCount: Int`;
  - `maxParallel: Int`, `firstAt: Date?`, `lastAt: Date?`;
  - `lanes: [TaskLane]` (до 6 задач + «Другие»), `distractionLane: [LaneSegment]`.
- `public struct DayBar: Equatable, Sendable { public let day: Date; public let youSeconds: TimeInterval; public let waitingSeconds: TimeInterval; public let distractionSeconds: TimeInterval }`
- `public struct TaskTimeRow: Equatable, Sendable, Identifiable { public let id: String; public let taskID: String?; public let title: String; public let projectName: String?; public let seconds: TimeInterval; public let sessions: Int; public let isDone: Bool }`
- `public struct WeekReport: Equatable, Sendable`: `days: [DayBar]` (7), `tasksDone: Int`, `sessions: Int`, `boundShare: Double?`, `waitingSeconds: TimeInterval`, `averageWaitSeconds: TimeInterval?`, `distractionSeconds: TimeInterval`, `rows: [TaskTimeRow]` (сортировка по seconds desc; последняя строка — «Без задачи», если есть).
- `public enum ReportBuilder`:
  - `static func day(spans: [ActivitySpan], episodes: [DistractionEpisode], tasks: [FocusTask], dayStart: Date, dayEnd: Date) -> DayReport`;
  - `static func week(spans: [ActivitySpan], episodes: [DistractionEpisode], tasks: [FocusTask], sessions: [SessionRecord], weekStart: Date, calendar: Calendar) -> WeekReport`.
  - Секунды одного вида считаются по объединению пересекающихся интервалов. `maxParallel` — максимум одновременных `claude`. Время задачи в недельной таблице — объединение `claude` и `you` этой задачи.
- В `ActivitySpan`/`DistractionEpisode` вид `distraction` берётся только из эпизодов, чтобы ничего не дублировать: координатор не пишет `distraction`-интервалы.

**Тесты:** `openCloseRoundTrip`, `closeAllOpenOnStart`, `dayUnionsOverlaps`, `dayMaxParallel`, `dayLanesCapAtSixPlusOther`, `dayClipsSpansToRange`, `weekSevenBarsAndRowsOrder`, `weekNoTaskRowLast`.

- [ ] Тесты → реализация → Checkpoint.

### Task 4: TodoWrite → шаги плана

**Files:** Create `Sources/OpenIslandCore/ClaudeTodoParser.swift`; Modify `Sources/OpenIslandCore/ClaudeHooks.swift` (`ClaudeTaskInfo`), `Sources/OpenIslandCore/BridgeServer.swift` (ветка `.postToolUse`); Test: `Tests/OpenIslandCoreTests/ClaudeTodoParserTests.swift` и тест моста рядом с существующим тестом TaskCreate/TaskUpdate (найти через grep `TaskCreate` в `Tests/OpenIslandCoreTests`).

**Interfaces (Produces):**
- `ClaudeTaskInfo` получает `public var activeForm: String?`. Он добавляется в init последним параметром со значением по умолчанию `nil`; Codable обратно совместим (`decodeIfPresent`).
- `public enum ClaudeTodoParser { public static func tasks(from input: ClaudeHookJSONValue?) -> [ClaudeTaskInfo]? }`:
  - ожидает объект с массивом `todos`; id пункта — `"todo-<index>"`; `title = content`;
  - статусы pending/in_progress/completed;
  - пункт без `content` пропускается; если массива нет — `nil`.
- `BridgeServer` на `.postToolUse` с `toolName == "TodoWrite"`: если парсер вернул не `nil`, `activeTasks` заменяется целиком и метаданные эмитятся тем же путём, что у TaskUpdate. Пустой массив очищает `activeTasks`.

**Тесты:** `parsesTodos`, `malformedInputReturnsNil`, `emptyTodosClears`, `oldTaskInfoJSONDecodesWithoutActiveForm`; мостовой `postToolUseTodoWriteReplacesActiveTasks`.

- [ ] Тесты → реализация → Checkpoint.

### Task 5: Прогресс, пульт, политики, альтернативы

**Files:** Create `Sources/FocusCore/SessionHub.swift`; Modify `Sources/FocusCore/NextActionEngine.swift`; Test: `Tests/FocusCoreTests/SessionHubTests.swift`, `PolicyTests.swift`, `NextActionEngineTests.swift`

**Interfaces (Produces):**
- `public struct PlanProgress: Equatable, Sendable`:
  - поля: `completed: Int`, `total: Int`, `currentTitle: String?`;
  - `static func from(_ tasks: [ClaudeTaskInfo]) -> PlanProgress?` — `nil`, если пусто; `currentTitle` = `activeForm ?? title` первого in_progress;
  - `func remaining(planStartedAt: Date, now: Date) -> TimeInterval?` — `nil`, если completed == 0;
  - `var fraction: Double`.
- `public enum HubGroup: Int, CaseIterable, Sendable { case waiting, review, running, unbound, parked }` с `title` («Ждут тебя», «Готово, проверь», «Работают», «Без задачи», «На паузе»).
- `public struct HubRow: Equatable, Sendable, Identifiable`:
  - поля: `id: String` (sessionID), `group: HubGroup`, `taskID: String?`, `title: String`, `projectName: String?`, `detail: String`, `since: Date`, `progress: PlanProgress?`;
  - `title` — задача, иначе `"<проект> · «<первый промпт до 40>»"`;
  - `detail` — по макету: «Разрешение <tool/summary> · ждёт N мин», «Claude закончил N мин назад», «Шаг k из n · <currentTitle> · N мин», «Нет активности N мин»;
  - `since` — момент входа в текущее состояние (`updatedAt` сессии).
- `public enum SessionHub { public static func rows(sessions: [AgentSession], records: [String: SessionRecord], board: BoardSnapshot, unseenCompleted: Set<String>, now: Date) -> [HubRow] }`:
  - сессии отбираются: видимые, не завершённые, не demo, не синтетические;
  - группировка по §J5: `parked`, если `records[id]?.parkedAt != nil`; `unbound` — без задачи и `now - updatedAt >= 30 мин` при фазе не `running`;
  - сортировка: группа, затем `since` по возрастанию.
- `public enum StalledPolicy { public static func stalled(rows: [HubRow], reminderMinutes: Int, now: Date) -> [HubRow] }` — пороги по Global Constraints, сортировка по `since`.
- `public struct OverloadSuggestion: Equatable, Sendable { public let slots: [HubRow]; public let attend: HubRow?; public let park: HubRow? }`
- `public enum OverloadPolicy { public static func evaluate(rows: [HubRow], limit: Int) -> OverloadSuggestion? }` — `nil`, если живых без паузы ≤ limit; `attend` — самая старая из `waiting`; `park` — `running` с самым поздним `since`.
- `public enum DayStartPolicy { public static func shouldShow(enabled: Bool, plan: DayPlan?, now: Date, calendar: Calendar) -> Bool }` — час ≥ 5 и `dayStartShownAt == nil`.
- `public enum NextAlternative: Equatable, Sendable { case attend(sessionID: String, reason: AttentionReason, since: Date), review(sessionID: String), startTask(taskID: String, sameProject: Bool) }`
- `NextActionEngine.alternatives(_ input: NextActionInput, triggerCWD: String?, parked: Set<String>, limit: Int = 2) -> [NextAlternative]` — порядок по §J2; `evaluate` пока остаётся.

**Тесты:** прогресс (пусто, оценка); группы и сортировка пульта; синтетические и demo исключены; пауза; StalledPolicy по трём правилам; OverloadPolicy (на границе лимита — `nil`, выбор attend/park); DayStartPolicy (04:59 / 05:00 / уже показано); alternatives (порядок, исключение триггера и паузы, sameProject, limit).

- [ ] Тесты → реализация → Checkpoint.

---

## Фаза B — координатор

### Task 6: PromptSender и GitDiffProvider

**Files:** Create `Sources/OpenIslandApp/Focus/PromptSender.swift`, `Sources/OpenIslandApp/Focus/GitDiffProvider.swift`; при необходимости Modify `Sources/OpenIslandApp/TerminalTextSender.swift` (вынести отправку без гейта `canReply`); Test: `Tests/OpenIslandAppTests/PromptSenderTests.swift`, `GitDiffProviderTests.swift`

**Interfaces (Produces):**
- `enum PromptSendResult: Equatable, Sendable { case sent, unsupported, failed }`
- `protocol PromptSending: Sendable { func send(_ text: String, to session: AgentSession) async -> PromptSendResult }`
- `struct TerminalPromptSender: PromptSending`:
  - tmux и Ghostty — через `TerminalTextSender`;
  - iTerm2 — `static func iTermScript(text: String, sessionID: String?, tty: String?) -> String?`;
  - Terminal.app — `static func terminalScript(text: String, tty: String) -> String?`;
  - скрипты выполняются вне главного потока через `/usr/bin/osascript`, таймаут 2 с;
  - остальное — `.unsupported`.
  - Экранирование — через `AppleScriptQuoting.string`.
- `struct ChangedFile: Equatable, Sendable, Identifiable { let id: String; let path: String; let added: Int; let removed: Int }`
- `protocol GitDiffProviding: Sendable { func changedFiles(cwd: String) async -> [ChangedFile] }`
- `struct GitDiffProvider: GitDiffProviding` — `/usr/bin/git -C <cwd> diff --numstat HEAD`, таймаут 2 с, максимум 5 файлов по (added + removed) desc. Бинарные файлы (`-`) считаются как 0. Ошибка → `[]`. `static func parse(numstat: String) -> [ChangedFile]`.

**Тесты:** тексты скриптов iTerm и Terminal (кавычки, перевод строки), `.unsupported` для Warp; `parse` (обычные строки, бинарные, пробелы в путях, лимит 5).

- [ ] Тесты → реализация → Checkpoint.

### Task 7: Карточки, приоритет и действия координатора

**Files:** Modify `Sources/OpenIslandApp/Focus/FocusCoordinator.swift`, `Sources/FocusCore/NextActionEngine.swift` (удалить `evaluate`/`NextAction` и их тесты), `Sources/OpenIslandApp/Focus/Views/FocusIslandSection.swift` (минимальная адаптация, чтобы собиралось; UI переделывается в Task 9–11), `Sources/OpenIslandApp/AppModel.swift` (передача зависимостей, `jumpToSession` через `focus.requestJump`); Test: `Tests/OpenIslandAppTests/FocusCoordinatorCardTests.swift` (новый) + адаптация `FocusCoordinatorTests.swift`

**Interfaces (Produces):**
- `enum FocusCard: Equatable` с вариантами:
  - `onboarding`, `nudge`;
  - `returned(sessionID: String)`, `reEntry(sessionID: String)`, `overload(newSessionID: String)`;
  - `nextAction(triggeringSessionID: String, eventID: Int64?)`;
  - `stalled(sessionIDs: [String])`, `dayStart`.
- `var priority: Int` по §6 спеки (onboarding 8 … dayStart 1) и `static func canReplace(_ current: FocusCard?, with new: FocusCard) -> Bool` (`current == nil || new.priority >= current.priority`).
- `enum FocusCardAction: Equatable`:
  - переходы: `jump(sessionID:)`, `confirmJump(sessionID:)`;
  - задачи: `startTask(taskID:)`, `quickAdd(title:)`, `bindTriggering(taskID:)`, `markTaskDone(taskID:)`;
  - промпт: `queuePrompt(sessionID:text:)`, `sendQueuedPrompt(sessionID:)`;
  - критерии и заметки: `toggleCriterion(id:)`, `addCriterion(taskID:text:)`, `deleteCriterion(id:)`, `saveNote(taskID:text:)`;
  - пауза: `park(sessionID:)`, `unpark(sessionID:)`;
  - отвлечение: `snoozeDistraction`, `allowDistraction`, `returnToWork`;
  - прочее: `startDay(taskIDs:)`, `deferStalled(sessionIDs:)`, `dismiss`.
- Новые init-параметры `FocusCoordinator`: `promptSender: PromptSending = TerminalPromptSender()`, `gitDiff: GitDiffProviding = GitDiffProvider()`, `clipboard: (String) -> Void = { NSPasteboard… }`.
- Наблюдаемые свойства:
  - `private(set) var hubRows: [HubRow]` — пересчитываются в `sessionsDidChange` и `tick`;
  - `private(set) var alternatives: [NextAlternative]`;
  - `private(set) var changedFiles: [String: [ChangedFile]]`;
  - `private(set) var toast: String?` — сбрасывается через 4 с в `tick`;
  - `private(set) var lastJumpProjectName: String?`.
- Хелперы:
  - `planProgress(sessionID:) -> PlanProgress?`, `planRemaining(sessionID:now:) -> TimeInterval?` — момент появления плана хранится в памяти;
  - `queuedPrompt(sessionID:) -> QueuedPrompt?`;
  - `criteria(taskID:) -> [TaskCriterion]`, `criteriaProgress(taskID:) -> CriteriaProgress?`;
  - `taskID(forSession:) -> String?`, `session(_ id:) -> AgentSession?`, `record(_ id:) -> SessionRecord?`.
- `func requestJump(sessionID: String, now: Date = .now)` — правило J11: при необходимости ставит `reEntry`, иначе вызывает `jumpToSession` и `markSeen`. `perform(.jump)` и пульт ходят через него. Порядок закрытия карточки до перехода сохраняется — регрессия из прошлой версии исправляется: `closeCard(reacted: true)` до `jumpToSession`.
- Триггер `returned` — в `sessionsDidChange` на переход running → completed по правилу J4.
- `nextAction` при показе загружает `alternatives` и запускает `gitDiff` для cwd сессии (кэш 10 с).
- `sendQueuedPrompt`: `.sent` → `markSent` + переход; иначе буфер + переход + `toast = "Промпт в буфере — вставь ⌘V"`.

**Тесты:**
- `priorityOrder`;
- `returnedOnCompletionWithQueuedPrompt`, `returnedForFocusTaskWithoutPrompt`, `noReturnedForOtherTaskWithoutPrompt`;
- `queuePromptReplaces`, `sendQueuedPromptMarksSentAndJumps`, `unsupportedSendFallsBackToClipboard`;
- `reEntryWhenUnseenTenMinutesAndOtherTask`, `directJumpWhenRecentlySeen`, `confirmJumpUpdatesLastSeen`;
- `jumpClosesCardAsReactedBeforeJumping`;
- `parkMovesRowToParked`, `criteriaActions`.
- Фейки: `RecordingPromptSender(result:)`, `StubGitDiff(files:)`.

- [ ] Тесты → реализация → Checkpoint.

### Task 8: Интервалы времени и триггеры перегрузки, забытых, начала дня, онбординга

**Files:** Modify `Sources/OpenIslandApp/Focus/FocusCoordinator.swift`, `Sources/OpenIslandApp/AppModel.swift` (`focus.setHooksInstalled(_:)` при изменении статуса хуков); Test: `Tests/OpenIslandAppTests/FocusCoordinatorSpanTests.swift`, `FocusCoordinatorTriggerTests.swift`

**Interfaces (Produces):**
- Интервалы:
  - `claude` / `waiting` открываются и закрываются на переходах фаз в `sessionsDidChange`; `completed` и не просмотрено — `waiting` до `markSeen`;
  - `you` — в `frontmostDidChange`, когда активен терминал или редактор и есть `currentTask`;
  - `start(...)` вызывает `closeAllOpen(at: now)`;
  - интервалы пишутся только на переходах.
- `func dayReport(day: Date, now: Date) -> DayReport?`, `func weekReport(endingAt: Date, now: Date) -> WeekReport?`, `func dayPlan(day: Date) -> DayPlan?`, `func setTomorrowNote(_:day:)`.
- Перегрузка: появилась новая живая сессия → `OverloadPolicy.evaluate(rows, limit: settings.maxParallelSessions)` → `overload(newSessionID:)`, не чаще одного раза на сессию. Тост о слоте — один раз, когда активных меньше лимита и есть сессии на паузе.
- Забытые: в `tick` — `StalledPolicy`. Показ, если прошло ≥ 30 мин с прошлого показа и `canReplace`. `deferStalled` ставит сессии на паузу.
- Начало дня: в `frontmostDidChange` — `DayStartPolicy` → `dayStart` + `markDayStartShown`. Метод `func openDayStart()` для ручного вызова. `startDay(taskIDs:)` по §J12.
- `func setHooksInstalled(_ installed: Bool)`: `false` → `onboarding`; `true` → закрыть `onboarding`. Флаги шагов 2 и 3 в `defaults`: `focus.onboarding.automationOpened`, `focus.onboarding.taskAdded`.
- `var stalledBadge: (title: String, minutes: Int)?` — для правого уха (ожидание ≥ 10 мин).

**Тесты:**
- `startClosesDanglingSpans`, `phaseTransitionsOpenAndCloseSpans`, `youSpanOnlyWithTerminalAndCurrentTask`;
- `overloadShownOncePerNewSession`, `stalledThrottledThirtyMinutes`, `stalledDoesNotReplaceNextAction`, `deferStalledParks`;
- `dayStartOncePerDay`, `startDayMovesTasksAndLaunches`;
- `onboardingFollowsHooksState`, `stalledBadgeAfterTenMinutes`.

- [ ] Тесты → реализация → Checkpoint.

---

## Фаза C — интерфейс

Для UI-задач: вёрстка по соответствующему `.dc.html` (тексты, порядок блоков, цвета `FocusStyle`). Иконки — SF Symbols. У кнопок только из иконки — `accessibilityLabel`. Логику (форматирование, выбор кнопки, заголовки) выносить в чистые статические функции и покрывать тестами `Tests/OpenIslandAppTests/FocusViewLogicTests.swift`. Для чистой вёрстки критерий — сборка.

### Task 9: FocusStyle и карточки «остаться в задаче», «отвлёкся», «возврат», «вход в задачу»

**Files:** Create `Sources/OpenIslandApp/Focus/Views/FocusStyle.swift`, `Views/Cards/StayInTaskCard.swift` (макет StayInTask), `Views/Cards/NudgeCard.swift` (Nudge), `Views/Cards/ReturnCard.swift` (Return), `Views/Cards/ReEntryCard.swift` (ReEntry); Test: `FocusViewLogicTests.swift`

**Interfaces (Produces):**
- `enum FocusStyle` — цвета, радиусы, шрифт подписи.
- Компоненты: `FocusSectionCaption(_ text: String)`, `StatusDot(color:)`, `PlanProgressBar(progress: PlanProgress, width: CGFloat)`, `ProjectTag(_ name: String)`, `FocusButtonStyle(kind: .primary | .secondary | .quiet)`.
- Карточки — `struct XCard: View { @Bindable var focus: FocusCoordinator; let sessionID: String }`. Все действия идут через `focus.perform`.
- Чистые функции:
  - `StayInTaskCard.header(progress:remaining:elapsed:) -> String`;
  - `StayInTaskCard.switchTitle(remaining:) -> String`;
  - `NudgeCard.title(target:seconds:) -> String`;
  - `ReturnCard.subtitle(progress:minutes:awayProject:) -> String`;
  - `ReEntryCard.breadcrumb(...) -> String?`.
  - Тесты на них.

- [ ] Тесты логики → вёрстка → Checkpoint.

### Task 10: Карточки «перегрузка», «забытые», «начало дня», «первый запуск», привязка

**Files:** Create `Views/Cards/OverloadCard.swift`, `StalledCard.swift`, `DayStartCard.swift`, `OnboardingCard.swift`, `BindingCard.swift` (заменяет `bindingChip`); Test: `FocusViewLogicTests.swift`

**Interfaces (Produces):**
- `OverloadCard(focus:newSessionID:)`, `StalledCard(focus:sessionIDs:)`, `DayStartCard(focus:)`, `OnboardingCard(focus:installHooks: () -> Void)`, `BindingCard(focus:sessionID:)`.
- `OnboardingCard` открывает URL настроек автоматизации из спеки.
- `DayStartCard` хранит выбор 1–3 задач в `@State` и вызывает `.startDay`.
- Чистые функции: `StalledCard.ageLabel(seconds:) -> String` («25 м», «1 ч»); `DayStartCard.primaryTitle(selectedTitles:) -> String`; `BindingCard.groups(tasks:cwd:) -> (thisProject: [FocusTask], others: [FocusTask])`.

- [ ] Тесты логики → вёрстка → Checkpoint.

### Task 11: Пульт сессий и интеграция в панель

**Files:** Create `Views/SessionHubView.swift`; Modify `Views/FocusIslandSection.swift` (контейнер: `onboarding` → `nudge` → … → иначе пульт; биндинг — над пультом, если нет карточки), `Sources/OpenIslandApp/Views/IslandPanelView.swift` (обычный режим: `FocusIslandSection` вместо `sessionRowsContent`; режим уведомления: строка апстрима + `FocusIslandSection`; пустое состояние апстрима «No open terminal sessions» убирается, пульт показывает русское пустое состояние «Сессий нет — запусти claude в терминале»; `installHooksHint` скрывается при онбординге), `Sources/OpenIslandApp/OverlayPanelController.swift` (ширины 700/680/700; тест в `OverlayPanelControllerTests`); Test: `FocusViewLogicTests`, `OverlayPanelControllerTests`

**Interfaces (Produces):**
- `SessionHubView(focus:)` — шапка, группы и подвал по макету IslandExpanded. «Сводка дня» открывает окно доски на вкладке «Сегодня» через `Notification.Name.focusOpenBoard` с `userInfo["tab"] = "today"`.
- `SessionHubView.primaryRowID(rows:) -> String?` — первая строка группы `waiting`.
- `SessionHubView.headerCount(live:limit:) -> String` («4 сессии · держишь 3»).

- [ ] Тесты → реализация → Checkpoint.

### Task 12: Уши свёрнутого island

**Files:** Modify `Sources/OpenIslandApp/Views/V6NotchContent.swift`, `Sources/OpenIslandApp/AppModel.swift` (`islandClosedRightSlotContent`, новая функция для левого уха), `IslandPanelView.swift` (`closedPill`); Test: `Tests/OpenIslandAppTests/V6ClosedPillTests.swift`

**Interfaces (Produces):**
- `IslandRightSlotContent` получает `case alert(String)` — оранжевый текст `#FFB340`.
- Новый `enum IslandLeftSlotContent: Equatable { case focusSummary(running: Int, waiting: Int, done: Int), case progress(String) }`. Левое ухо на MacBook и левая часть внешней пилюли рендерят его. Ширина ушей пересчитывается симметрично: `max(левое, правое)`.
- `AppModel`:
  - левое ухо: 2+ живых → `.focusSummary`, 1 → `.progress("шаг k/n")`;
  - правое ухо: `stalledBadge` → `.alert("<задача> ждёт Nм")`, иначе `.text("<задача> · Nм")`.

**Тесты:** ширина ушей для `.focusSummary` и `.alert`; выбор контента левого/правого уха (вынести в статическую функцию).

- [ ] Тесты → реализация → Checkpoint.

### Task 13: Окно доски — вкладки, доска, карточка задачи

**Files:** Modify `Views/BoardView.swift` (`BoardRootView`: сегменты «Доска / Сегодня / Неделя / История», выбор вкладки из `userInfo`; `BoardView` тулбар со счётчиками; `TaskCardView` с сессиями), `Views/TaskDetailView.swift` (макет TaskDetail, лист 820), `BoardWindowController.swift` (`show(focus:tab:)`); Test: `FocusViewLogicTests`

**Interfaces (Produces):**
- `enum BoardTab: String, CaseIterable { case board, today, week, history }`.
- `TaskCardView.borderStyle(rows: [HubRow]) -> TaskCardBorder` (`.waiting`, `.running`, `.review`, `.none`).
- `TaskCardView.pastSummary(records: [SessionRecord], live: Set<String>) -> String?` («ещё N сессий · 36 мин»).
- `TaskDetailView` — критерии, «Где остановился», промпт в очереди, сессии с прогрессом, «Новая сессия по задаче», удаление с подтверждением.

- [ ] Тесты логики → вёрстка → Checkpoint.

### Task 14: Сводка дня

**Files:** Create `Views/DaySummaryView.swift`, `Views/TimelineView.swift`; Test: `FocusViewLogicTests`

**Interfaces (Produces):**
- `DaySummaryView(focus:)` по макету DaySummary: KPI, лента, «Сделано / Осталось открытым / Завтра начать с» (сохранение через `setTomorrowNote` при потере фокуса поля), кнопка «Скопировать в заметку».
- `TimelineView(report: DayReport)` — штриховка для `waiting`/`distraction` (`Canvas` или `Path`), легенда, `accessibilityLabel` с текстовой сводкой.
- `enum DaySummaryFormatter`:
  - `static func duration(_ seconds: TimeInterval) -> String` («5 ч 20 м», «48 м»);
  - `static func markdown(report: DayReport, done: [FocusTask], open: [FocusTask], tomorrow: String?, day: Date) -> String`.

**Тесты:** форматирование длительности; markdown (заголовок, списки, пустые секции не выводятся).

- [ ] Тесты → реализация → Checkpoint.

### Task 15: Неделя, история, настройки

**Files:** Create `Views/WeekSummaryView.swift`; Delete `Views/StatsView.swift`; Modify `Views/HistoryView.swift` (кнопки «Перейти»/«Продолжить»), `Views/FocusSettingsPane.swift` (статус хуков сверху: через замыкания `hooksInstalled: Bool`, `install: () -> Void`, `uninstall: () -> Void`, передаваемые из `SettingsView`; группа «Сессии» со степперами 1–6 и 5–60 и тумблером), `Sources/OpenIslandApp/Views/SettingsView.swift` (передать замыкания); Test: `FocusViewLogicTests`

**Interfaces (Produces):** `WeekSummaryView(focus:)` по макету Stats (KPI с прошлой неделей через второй вызов `weekReport`, столбцы, таблица). `WeekSummaryView.barHeights(days:maxHeight:) -> [CGFloat]` с тестом.

- [ ] Тесты → реализация → Checkpoint.

### Task 16: Документация и ручная проверка

**Files:** Modify `docs/focus-smoke.md` (добавить пункты S7–S12, у каждого «⬜ не проверено»: S7 шаги плана в пульте и на доске; S8 очередь промпта и «Отправить и вернуться» в Ghostty/iTerm/Terminal; S9 перегрузка при 4-й сессии; S10 отправка в Terminal.app в запущенный `claude`; S11 забытые сессии и оранжевое ухо; S12 начало дня и «Завтра начать с»), `README.md` (раздел «Что умеет» по этапам пути).

- [ ] Правки → полная сборка и тесты → Checkpoint.

---

## Self-review

- **Покрытие спеки:**
  - J1 → T4, T5, T7; J2 → T5, T6, T7, T9; J3 → T9; J4 → T7, T9; J5 → T5, T11; J6 → T2, T6, T7;
  - J7 → T2, T9, T13; J8 → T5, T8, T10; J9 → T5, T8, T10, T12; J10 → T5; J11 → T7, T9;
  - J12 → T2, T5, T8, T10; J13 → T8, T10, T11; J14 → T13; J15 → T13; J16 → T3, T8;
  - J17 → T3, T14; J18 → T3, T15; J19 → T15; J20 → T10; J21 → T1, T15.
- **Типы:** `HubRow`, `PlanProgress`, `NextAlternative`, `FocusCard`, `FocusCardAction`, `PromptSendResult`, `ChangedFile`, `DayReport`, `WeekReport` объявлены один раз; дальше используются только эти имена.
- **Порядок:** `evaluate` удаляется в Task 7, когда появляется замена. Минимальная адаптация `FocusIslandSection` в Task 7 держит сборку зелёной до Task 9–11.
