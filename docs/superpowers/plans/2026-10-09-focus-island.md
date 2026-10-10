# Focus Island Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Форк open-vibe-island, урезанный до Claude Code, с канбан-доской задач, постоянной историей сессий, подсказкой «Что дальше?» во время работы Claude и мягким детектором отвлечения.

**Architecture:** Код апстрима (хуки → `bridge.sock` → `BridgeServer` → `SessionState` → `AppModel` → нотч-панель) сохраняется, лишние агенты вырезаются. Вся новая логика живёт в SPM-таргете `FocusCore` (чистые типы + SQLite через GRDB, без AppKit, полностью под тестами). В `OpenIslandApp` добавляется `FocusCoordinator`, который читает снапшоты `SessionState`, пишет в `focus.sqlite` и управляет карточками island, а также окно доски, монитор активного приложения и запуск терминала.

**Tech Stack:** Swift 6.2, SwiftUI + AppKit, macOS 14+, Swift Testing (`import Testing`), GRDB.swift 7, Carbon (`RegisterEventHotKey`), NSAppleScript.

**Spec:** `docs/superpowers/specs/2026-10-09-focus-island-pdr.md` (ревизия 2, канбан). Диаграмма: `docs/diagrams/focus-island-next-action-2026-10-09.md`.

## Global Constraints

- macOS 14+, `swift-tools-version: 6.2`, Swift 6 strict concurrency (все модели `Sendable`).
- Никаких комментариев в коде (глобальное правило пользователя). Существующие комментарии апстрима не трогать, кроме удаляемых файлов/блоков.
- Коммиты — только по явной просьбе пользователя в текущем запросе. Шаги «Checkpoint» = `git status` + прогон проверок, без `git commit`.
- `SessionState.apply` — единственное место изменения живых сессий; Focus-модули только читают `[AgentSession]`.
- Хуки fail-open; никаких сетевых запросов (Sparkle удалён).
- Данные Focus: `~/Library/Application Support/FocusIsland/focus.sqlite`.
- Колонки доски фиксированы: Backlog → Todo → In progress → Done.
- Значения по умолчанию: `nextActionDelay` 15 с, `distractionThreshold` 20 с, повторный nudge через 180 с, «Отложить» 300 с, «Мне это нужно» 600 с, «занят в другом приложении» 60 с, опрос URL браузера раз в 5 с, хоткей доски ⌥⌘B.
- Стоп-лист по умолчанию: приложения `ru.keepcoder.Telegram`, `com.tdesktop.Telegram`, `com.hnc.Discord`; домены `youtube.com`, `x.com`, `twitter.com`, `reddit.com`, `instagram.com`, `tiktok.com`, `news.ycombinator.com`, `vc.ru`, `habr.com`.
- Новые Focus-экраны — строки на русском литералами; строки апстрима остаются через `lang.t(...)` (en).
- Тесты запускаются через `zsh scripts/test-clt.sh` (на машине только Command Line Tools — plain `swift test` не находит модуль `Testing`). Фильтр: `zsh scripts/test-clt.sh --filter <SuiteName>`.
- В интерактивной оболочке пользователя `cd` перехвачен gvm и падает — в командах использовать абсолютные пути и `git -C`, `swift build --package-path`.

## Review Focus

1. **Перезапуск приложения при живых сессиях** — записи истории со `status = live`, которых нет в восстановленном `SessionState`, должны стать `ended`, а сессии, восстановленные из реестра апстрима (`firstSeenAt` давно), не должны вызывать чип «Привязать к задаче?». Тесты: `FocusCoordinatorTests.reconcilesStaleLiveRecordsOnStart`, `FocusCoordinatorTests.restoredSessionDoesNotAskForBinding` (Task 13).
2. **Очень частые обновления состояния** (каждое событие хука дергает `state.didSet`) — запись в SQLite только при реальном изменении наблюдения. Тест: `FocusCoordinatorTests.identicalObservationsAreNotRewritten` (Task 13).
3. **Пути и строки со спецсимволами** (`'`, `"`, пробелы, кириллица в `cwd`) в Resume — команда должна оставаться корректной для zsh и AppleScript. Тесты: `ResumeCommandTests.quotesSingleQuotesInPath`, `AppleScriptQuotingTests.escapesQuotesAndBackslashes` (Task 12).
4. **Повреждённый/частично записанный jsonl и мусорные строки транскрипта** (system-reminder, `<command-name>`, tool_result) — backfill не падает и не берёт служебный текст в заголовок/промпты. Тесты: `TranscriptSummaryParserTests.skipsMetaAndCommandMessages`, `TranscriptSummaryParserTests.toleratesTruncatedLastLine` (Task 8).
5. **Пустая доска / все задачи пропущены «Следующая»** — «Что дальше?» должен деградировать до «Обдумай следующий шаг», а не показывать пустую карточку или зацикливаться. Тесты: `NextActionEngineTests.fallsBackToReflectWhenBoardEmpty`, `NextActionEngineTests.fallsBackToReflectWhenAllTasksSkipped` (Task 10).

---

## File Structure

```
Package.swift                                         (modify: GRDB, FocusCore, FocusCoreTests, remove Sparkle)
Sources/FocusCore/
  FocusModels.swift          BoardColumn, FocusTask, SessionRecord, SessionRecordStatus, DistractionEpisode, NextActionEvent
  FocusStore.swift           DatabaseQueue + migrations + openWithRecovery
  BoardService.swift         BoardSnapshot, BoardError, CRUD/move/bind
  SessionHistory.swift       SessionObservation, upsert/merge/search, projectName
  TranscriptSummaryParser.swift  TranscriptSummary + парсер jsonl
  TranscriptBackfill.swift   инкрементальный backfill ~/.claude/projects
  TurnTracker.swift          «сессия ушла в работу» + таймер
  NextActionEngine.swift     NextAction, AttentionReason, NextActionInput, evaluate
  Distraction.swift          StopList, DistractionClassifier, FrontmostSample, DistractionTracker, DistractionEvent, KnownApps
  FocusLogs.swift            DistractionLog, NextActionLog, FocusStats, StatsService
  ResumeCommand.swift        ShellQuoting, AppleScriptQuoting, ResumeCommand
  FocusSettings.swift        FocusSettings, ResumeTerminal, BoardHotKey
Tests/FocusCoreTests/        по файлу тестов на каждый компонент + Fixtures/
Sources/OpenIslandApp/Focus/
  FocusCoordinator.swift     FocusCard, FocusCardAction, координация
  TerminalLauncher.swift     TerminalLaunching + AppleScript/Ghostty
  FrontmostAppMonitor.swift  NSWorkspace + BrowserURLReader
  GlobalHotKey.swift         Carbon hotkey
  BoardWindowController.swift
  Views/FocusIslandSection.swift   карточки + чип привязки + компактный список задач + недавние сессии
  Views/BoardView.swift
  Views/TaskDetailView.swift
  Views/HistoryView.swift
  Views/StatsView.swift
  Views/FocusSettingsPane.swift
Tests/OpenIslandAppTests/FocusCoordinatorTests.swift
```

---

# Фаза A — форк и урезание

### Task 1: Репозиторий и зелёный baseline

**Files:**
- Modify: структура каталога `/Users/diaszhanabayev/Projects/own/focus`

**Interfaces:**
- Produces: git-репозиторий в `/Users/diaszhanabayev/Projects/own/focus` с кодом апстрима в корне, remote `upstream`, ветка `feat/focus-island`.

- [ ] **Step 1: Получить полную историю апстрима**

```bash
git -C /Users/diaszhanabayev/Projects/own/focus/upstream fetch --unshallow
```

- [ ] **Step 2: Поднять клон в корень проекта**

```bash
rsync -a /Users/diaszhanabayev/Projects/own/focus/upstream/ /Users/diaszhanabayev/Projects/own/focus/
rm -rf /Users/diaszhanabayev/Projects/own/focus/upstream
git -C /Users/diaszhanabayev/Projects/own/focus remote rename origin upstream
git -C /Users/diaszhanabayev/Projects/own/focus switch -c feat/focus-island
git -C /Users/diaszhanabayev/Projects/own/focus status --short
```

Expected: в `status` видны только неотслеживаемые `docs/superpowers/specs/2026-10-09-focus-island-pdr.md`, `docs/superpowers/plans/2026-10-09-focus-island.md`, `docs/diagrams/`.

- [ ] **Step 3: Baseline сборка и тесты**

```bash
swift build --package-path /Users/diaszhanabayev/Projects/own/focus
zsh /Users/diaszhanabayev/Projects/own/focus/scripts/test-clt.sh
```

Expected: сборка успешна, тесты PASS. Если какие-то тесты апстрима падают на этой машине до любых изменений — записать их имена в `docs/superpowers/plans/baseline-failures.md` и считать их известными (не чинить в рамках плана).

- [ ] **Step 4: Checkpoint** — `git -C /Users/diaszhanabayev/Projects/own/focus status`.

---

### Task 2: Удалить периферию (iOS/Watch, Sparkle, SSH-remote, zh-локализации)

**Files:**
- Delete: `ios/`, `Sources/OpenIslandCore/WatchHTTPEndpoint.swift`, `Sources/OpenIslandCore/WatchNotificationRelay.swift`, `Tests/OpenIslandCoreTests/WatchNotificationRelayTests.swift`, `Sources/OpenIslandApp/UpdateChecker.swift`, `scripts/open-island-hooks.py`, `scripts/remote-setup.sh`, `scripts/update-appcast.sh`, `docs/ssh-setup.md`, `docs/watch-notification-design.md`, `docs/watch-notification-impl-plan.md`, `Sources/OpenIslandApp/Resources/zh-Hans.lproj`, `Sources/OpenIslandApp/Resources/zh-Hant.lproj`
- Modify: `Package.swift` (убрать Sparkle), `Sources/OpenIslandApp/AppModel.swift` (`watchRelay`, update checker), `Sources/OpenIslandApp/Views/SettingsView.swift` (`SettingsTab.watch`, панель обновлений), `Sources/OpenIslandApp/OpenIslandApp.swift`, `Sources/OpenIslandApp/Localization/LanguageManager.swift` (языки только `en`)

**Interfaces:**
- Produces: пакет без зависимости Sparkle; `SettingsTab` без `.watch`.

- [ ] **Step 1: Удалить файлы**

```bash
R=/Users/diaszhanabayev/Projects/own/focus
git -C $R rm -r -q ios Sources/OpenIslandCore/WatchHTTPEndpoint.swift Sources/OpenIslandCore/WatchNotificationRelay.swift Tests/OpenIslandCoreTests/WatchNotificationRelayTests.swift Sources/OpenIslandApp/UpdateChecker.swift scripts/open-island-hooks.py scripts/remote-setup.sh scripts/update-appcast.sh docs/ssh-setup.md docs/watch-notification-design.md docs/watch-notification-impl-plan.md Sources/OpenIslandApp/Resources/zh-Hans.lproj Sources/OpenIslandApp/Resources/zh-Hant.lproj
```

- [ ] **Step 2: Убрать Sparkle из `Package.swift`**

Удалить строку `.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),` и `.product(name: "Sparkle", package: "Sparkle"),` из зависимостей `OpenIslandApp`.

- [ ] **Step 3: Компилятор как чек-лист**

```bash
swift build --package-path /Users/diaszhanabayev/Projects/own/focus 2>&1 | grep -E "error:" | sort -u
```

Для каждой ошибки удалить использование целиком (не заменять заглушками):
- `AppModel`: свойство `watchRelay`, его создание и блок `if let relay = watchRelay { ... }` в `applyTrackedEvent` (`AppModel.swift` ~строки 1569–1590), всё про `UpdateChecker`/`SPUStandardUpdaterController`.
- `SettingsView`: `case watch` в `SettingsTab` и все его ветки в `switch`, панель Watch, раздел «Обновления» в About.
- `LanguageManager`: список доступных языков — только `en`; если язык сохранён как `zh-*`, падать на `en`.
- `import Sparkle` во всех файлах.

Повторять Step 3 до пустого вывода.

- [ ] **Step 4: Тесты**

Run: `zsh /Users/diaszhanabayev/Projects/own/focus/scripts/test-clt.sh`
Expected: PASS (кроме зафиксированных в `baseline-failures.md`). Тесты, которые ссылаются на удалённые типы, удалить вместе с типами.

- [ ] **Step 5: Checkpoint** — `git -C /Users/diaszhanabayev/Projects/own/focus status --short | head -50`.

---

### Task 3: Оставить только Claude Code

**Files:**
- Delete (Core): `CodexAppServer.swift`, `CodexHookInstallationManager.swift`, `CodexHookInstaller.swift`, `CodexHooks.swift`, `CodexSessionTracking.swift`, `CodexUsage.swift`, `CursorHookInstallationManager.swift`, `CursorHookInstaller.swift`, `CursorHooks.swift`, `CursorSessionRegistry.swift`, `CursorTranscriptReader.swift`, `GeminiHookInstallationManager.swift`, `GeminiHookInstaller.swift`, `GeminiHooks.swift`, `GrokHookInstallationManager.swift`, `GrokHookInstaller.swift`, `GrokHooks.swift`, `KimiHookInstallationManager.swift`, `KimiHookInstaller.swift`, `OpenCodeHooks.swift`, `OpenCodePluginInstallationManager.swift`, `OpenCodeSessionRegistry.swift`, `PiExtensionInstallationManager.swift`, `PiHooks.swift`, `PiSessionRegistry.swift` (все в `Sources/OpenIslandCore/`)
- Delete (App): `Sources/OpenIslandApp/CodexAppServerCoordinator.swift`, `Sources/OpenIslandApp/Resources/open-island-opencode.js`, `Sources/OpenIslandApp/Resources/open-island-pi.ts`
- Delete (Tests): `CodexAppServerBufferTests.swift`, `CodexAppServerLifecycleTests.swift`, `CodexAppServerTimeoutTests.swift`, `CodexHooksTests.swift`, `CodexSessionTrackingTests.swift`, `CodexUsageTests.swift`, `CursorHooksTests.swift`, `GeminiHooksTests.swift`, `GrokHooksTests.swift`, `KimiHooksTests.swift`, `OpenCodeSessionRegistryTests.swift`, `PiIntegrationTests.swift` (в `Tests/OpenIslandCoreTests/`), `GrokProcessLivenessTests.swift`, `PiExtensionEventTests.swift` (в `Tests/OpenIslandAppTests/`)
- Modify: `AgentSession.swift`, `AgentEvent.swift`, `SessionState.swift`, `BridgeServer.swift`, `BridgeTransport.swift`, `ClaudeHooks.swift`, `HookHealthCheck.swift`, `Sources/OpenIslandHooks/OpenIslandHooksCLI.swift`, `Sources/OpenIslandSetup/OpenIslandSetupCLI.swift`, `AppModel.swift`, `SessionDiscoveryCoordinator.swift`, `ProcessMonitoringCoordinator.swift`, `HookInstallationCoordinator.swift`, `ActiveAgentProcessDiscovery.swift`, `AgentSession+Presentation.swift`, `TerminalJumpService.swift` (ветка `codex://`), `IslandDebugScenario.swift`, `Views/*.swift`, оставшиеся тесты.

**Interfaces:**
- Produces: `public enum AgentTool { case claudeCode }`; `AgentSession` без `codexMetadata/geminiMetadata/openCodeMetadata/cursorMetadata/piMetadata`; `AgentEvent` без `geminiSessionMetadataUpdated/openCodeSessionMetadataUpdated/cursorSessionMetadataUpdated/piSessionMetadataUpdated/sessionHeartbeat`; `SessionStarted` без чужих metadata-параметров; `ClaudeSessionMetadata`, `JumpTarget` (без `codexThreadID`) неизменны в остальном.

- [ ] **Step 1: Удалить файлы из списка выше** (`git -C <repo> rm -q ...`).

- [ ] **Step 2: Сузить `AgentTool`**

В `Sources/OpenIslandCore/AgentSession.swift` заменить перечисление на:

```swift
public enum AgentTool: String, CaseIterable, Codable, Sendable {
    case claudeCode

    public var displayName: String { "Claude Code" }
    public var shortName: String { "Claude" }
    public var isClaudeCodeFork: Bool { true }
    public var brandColorHex: String { "#d97742" }
}
```

Если в оригинале у `AgentTool` есть другие вычисляемые свойства — оставить их с единственной веткой `claudeCode`.

- [ ] **Step 3: Удалить чужие metadata и события**

- В `AgentSession`: свойства `codexMetadata`, `geminiMetadata`, `openCodeMetadata`, `cursorMetadata`, `piMetadata`, `isCodexAppSession`, `lastHeartbeatAt`, `heartbeatReconnectStartedAt` и соответствующие параметры `init`. В `isVisibleInIsland` удалить ветку `isCodexAppSession`. `currentToolName` → `claudeMetadata?.currentTool`.
- В `AgentEvent`: кейсы `geminiSessionMetadataUpdated`, `openCodeSessionMetadataUpdated`, `cursorSessionMetadataUpdated`, `piSessionMetadataUpdated`, `sessionHeartbeat`, их payload-структуры и ключи кодирования.
- В `SessionState.apply`: соответствующие ветки, `refreshCodexAppClassification`, всё про heartbeat.
- В `JumpTarget`: `codexThreadID`.

- [ ] **Step 4: `BridgeServer`, хук-CLI, установщики**

- `BridgeServer.swift`: оставить только обработку `processClaudeHook` (и общие `resolvePermission`/`answerQuestion`/служебные команды); удалить разбор payload'ов Codex/Gemini/Cursor/OpenCode/Pi/Kimi/Grok и все `pending*`-кэши, используемые только ими. `BridgeTransport.swift`: удалить соответствующие кейсы команд.
- `OpenIslandHooksCLI.swift`: принимать только `--source claude` (любой другой `--source` → тихий `exit(0)`, fail-open).
- `ClaudeHooks.swift`: убрать маппинг форков (`qoder`, `qwen`, `factory`, `codebuddy`, `kimi`) — `resolvedAgentTool` всегда `.claudeCode`.
- `HookHealthCheck.swift`, `OpenIslandSetupCLI.swift`, `HookInstallationCoordinator.swift`: только Claude-хуки и статус-лайн Claude.

- [ ] **Step 5: Компилятор как чек-лист**

```bash
swift build --package-path /Users/diaszhanabayev/Projects/own/focus 2>&1 | grep -E "error:" | sort -u | head -60
```

Для каждой ошибки удалить чужую ветку целиком (в `switch` по `AgentTool` оставить тело ветки `.claudeCode` без `switch`). В `AppModel.applyTrackedEvent` удалить `discovery.refreshCodexRolloutTracking()`, `schedule{Codex,OpenCode,Cursor,Pi}SessionPersistence()`, оставить `scheduleClaudeSessionPersistence()`. Удалить настройку `showCodexUsage` и UI использования Codex. Повторять до пустого вывода.

- [ ] **Step 6: Проверка остатков**

```bash
grep -rniE "codex|gemini|cursor|opencode|\bpi\b|ohMyPi|kimi|grok|qoder|qwen|factory|codebuddy" /Users/diaszhanabayev/Projects/own/focus/Sources /Users/diaszhanabayev/Projects/own/focus/Tests | grep -v "cursorPosition\|NSCursor\|\.cursor\b" | head -40
```

Expected: только ложные срабатывания (например, курсор мыши). Остальное удалить.

- [ ] **Step 7: Тесты**

Run: `zsh /Users/diaszhanabayev/Projects/own/focus/scripts/test-clt.sh`
Expected: PASS. Тесты в оставшихся файлах, которые проверяют только чужих агентов (например, кейсы `tool: .codex` в `SessionStateTests`), удалить; тесты Claude-поведения сохранить, исправив вызовы `init`.

- [ ] **Step 8: Ручной smoke**

```bash
zsh /Users/diaszhanabayev/Projects/own/focus/scripts/launch-dev-app.sh
```

Запустить `claude` в терминале, отправить промпт, требующий разрешения (например, «создай файл /tmp/fi-smoke.txt»). Expected: сессия появляется в island, карточка разрешения работает, Jump переключает в терминал.

- [ ] **Step 9: Checkpoint** — `git -C /Users/diaszhanabayev/Projects/own/focus status --short | wc -l`.

---

### Task 4: Ребрендинг и изоляция от установленного Open Island

**Files:**
- Modify: `Sources/OpenIslandCore/BridgeTransport.swift:5-14`, `Sources/OpenIslandCore/HooksBinaryLocator.swift:70-85`, `Sources/OpenIslandCore/ClaudeHookInstaller.swift:4`, `Sources/OpenIslandCore/ClaudeSessionRegistry.swift` (каталог `open-island`), `Sources/OpenIslandCore/HookHealthCheck.swift:329,367`, `scripts/launch-dev-app.sh`, `scripts/package-app.sh`, `Sources/OpenIslandApp/Resources/en.lproj/Localizable.strings` (видимое имя), `README.md`

**Interfaces:**
- Produces: каталог данных `~/Library/Application Support/FocusIsland/` (сокет `bridge.sock`, `bin/`, реестр Claude), bundle id `dev.zhanabayev.focusisland`, имя приложения «Focus Island», манифест хуков `focus-island-claude-hooks-install.json`.

- [ ] **Step 1: Пути**

- `BridgeTransport.stableDirectoryURL`: `appendingPathComponent("FocusIsland")`; env-override переименовать в `FOCUS_ISLAND_SOCKET_PATH`; legacy-путь `/tmp/open-island-<uid>.sock` удалить.
- `HooksBinaryLocator`: `"OpenIsland"` → `"FocusIsland"` (оба места).
- `ClaudeSessionRegistry`: каталог `Library/Application Support/open-island` → `Library/Application Support/FocusIsland`.
- `ClaudeHookInstaller.fileName = "focus-island-claude-hooks-install.json"`.
- `HookHealthCheck`: распознавать как свои команды, содержащие `FocusIsland` (а `open-island`/`vibe-island` — как чужие, их не трогать и не удалять).

- [ ] **Step 2: Бандл**

В `scripts/launch-dev-app.sh` и `scripts/package-app.sh`: `CFBundleIdentifier` → `dev.zhanabayev.focusisland`, `CFBundleName`/`CFBundleDisplayName` → `Focus Island`, имя `.app` → `Focus Island.app`. Убедиться, что в Info.plist есть `NSAppleEventsUsageDescription` с текстом «Focus Island читает адрес активной вкладки браузера, чтобы замечать отвлечения, и открывает терминал для возврата в сессию.»

- [ ] **Step 3: Тест пути сокета**

Добавить в `Tests/OpenIslandCoreTests/BridgeTransportPathTests.swift`:

```swift
import Foundation
import Testing
@testable import OpenIslandCore

struct BridgeTransportPathTests {
    @Test
    func stableDirectoryIsFocusIsland() {
        #expect(BridgeSocketLocation.stableDirectoryURL.lastPathComponent == "FocusIsland")
    }
}
```

Имя типа/свойства взять фактическое из `BridgeTransport.swift:5-14` (строка `stableDirectoryURL`); если тип называется иначе — использовать его.

Run: `zsh /Users/diaszhanabayev/Projects/own/focus/scripts/test-clt.sh --filter BridgeTransportPathTests` → PASS.

- [ ] **Step 4: Полные тесты + smoke**

Run: `zsh /Users/diaszhanabayev/Projects/own/focus/scripts/test-clt.sh` → PASS. Запустить dev-приложение, в Settings → Setup установить хуки, проверить, что в `~/.claude/settings.json` команды указывают на `~/Library/Application Support/FocusIsland/bin/OpenIslandHooks`, а `claude` виден в island.

- [ ] **Step 5: Checkpoint** — `git status`.

---

# Фаза B — FocusCore

### Task 5: Таргет FocusCore, модели и FocusStore

**Files:**
- Modify: `Package.swift`, `Sources/OpenIslandCore/AgentSession.swift` (`isVisibleInIsland` → `public`)
- Create: `Sources/FocusCore/FocusModels.swift`, `Sources/FocusCore/FocusStore.swift`
- Test: `Tests/FocusCoreTests/FocusStoreTests.swift`

**Interfaces:**
- Consumes: `OpenIslandCore`.
- Produces:
  - `enum BoardColumn: String { backlog, todo, inProgress, done }`
  - `struct FocusTask` (`id`, `title`, `details`, `boardColumn`, `position`, `projectPath`, `note`, `createdAt`, `updatedAt`, `doneAt`)
  - `enum SessionRecordStatus { live, ended }`, `struct SessionRecord` (`id`, `cwd`, `projectName`, `title`, `firstPrompt`, `lastPrompt`, `lastAssistantMessage`, `startedAt`, `lastActivityAt`, `endedAt`, `status`, `taskId`, `transcriptPath`)
  - `struct DistractionEpisode` (`id: Int64?`, `startedAt`, `endedAt`, `appBundleID`, `domain`, `nudged`, `returnedWithinSec`)
  - `struct NextActionEvent` (`id: Int64?`, `shownAt`, `reactedAt`, `kind`)
  - `final class FocusStore` с `dbQueue`, `init(fileURL:)`, `static func inMemory()`, `static var defaultFileURL`, `static func openWithRecovery(fileURL:now:) -> (FocusStore, URL?)`

- [ ] **Step 1: `Package.swift`**

В `dependencies` добавить:

```swift
.package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
```

В `products` добавить `.library(name: "FocusCore", targets: ["FocusCore"]),`. В `targets` добавить:

```swift
.target(
    name: "FocusCore",
    dependencies: [
        "OpenIslandCore",
        .product(name: "GRDB", package: "GRDB.swift"),
    ]
),
.testTarget(
    name: "FocusCoreTests",
    dependencies: ["FocusCore", "OpenIslandCore"],
    resources: [.copy("Fixtures")]
),
```

В зависимости `OpenIslandApp` и `OpenIslandAppTests` добавить `"FocusCore"`. Создать пустой каталог `Tests/FocusCoreTests/Fixtures/` с файлом `.keep`.

В `AgentSession.swift` сделать `isVisibleInIsland` и `isDemoSession` `public`.

- [ ] **Step 2: Failing test**

`Tests/FocusCoreTests/FocusStoreTests.swift`:

```swift
import Foundation
import GRDB
import Testing
@testable import FocusCore

struct FocusStoreTests {
    @Test
    func migrationsCreateAllTables() throws {
        let store = try FocusStore.inMemory()
        let tables = try store.dbQueue.read { db in
            try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(tables.isSuperset(of: ["tasks", "sessions", "distraction_episodes", "next_action_events", "backfill_files"]))
    }

    @Test
    func taskRoundTrips() throws {
        let store = try FocusStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_000)
        let task = FocusTask(id: "t1", title: "Сделать доску", details: nil, boardColumn: .todo, position: 1, projectPath: "/tmp/p", note: nil, createdAt: now, updatedAt: now, doneAt: nil)
        try store.dbQueue.write { db in try task.insert(db) }
        let loaded = try store.dbQueue.read { db in try FocusTask.fetchOne(db, key: "t1") }
        #expect(loaded == task)
    }

    @Test
    func openWithRecoveryBacksUpCorruptFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("focus.sqlite")
        try Data("not a database".utf8).write(to: file)
        let (store, backup) = FocusStore.openWithRecovery(fileURL: file, now: Date(timeIntervalSince1970: 42))
        #expect(backup?.lastPathComponent == "focus.sqlite.bak-42")
        #expect(FileManager.default.fileExists(atPath: backup!.path))
        let count = try store.dbQueue.read { db in try FocusTask.fetchCount(db) }
        #expect(count == 0)
    }
}
```

- [ ] **Step 3: Run — FAIL**

Run: `zsh /Users/diaszhanabayev/Projects/own/focus/scripts/test-clt.sh --filter FocusStoreTests`
Expected: ошибка компиляции «cannot find 'FocusStore' in scope».

- [ ] **Step 4: Модели — `Sources/FocusCore/FocusModels.swift`**

```swift
import Foundation
import GRDB

public enum BoardColumn: String, Codable, CaseIterable, Sendable, Identifiable {
    case backlog
    case todo
    case inProgress
    case done

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .backlog: "Backlog"
        case .todo: "Todo"
        case .inProgress: "In progress"
        case .done: "Done"
        }
    }
}

public struct FocusTask: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tasks"

    public var id: String
    public var title: String
    public var details: String?
    public var boardColumn: BoardColumn
    public var position: Double
    public var projectPath: String?
    public var note: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var doneAt: Date?

    public init(id: String, title: String, details: String?, boardColumn: BoardColumn, position: Double, projectPath: String?, note: String?, createdAt: Date, updatedAt: Date, doneAt: Date?) {
        self.id = id
        self.title = title
        self.details = details
        self.boardColumn = boardColumn
        self.position = position
        self.projectPath = projectPath
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.doneAt = doneAt
    }
}

public enum SessionRecordStatus: String, Codable, Sendable {
    case live
    case ended
}

public struct SessionRecord: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sessions"

    public var id: String
    public var cwd: String?
    public var projectName: String?
    public var title: String
    public var firstPrompt: String?
    public var lastPrompt: String?
    public var lastAssistantMessage: String?
    public var startedAt: Date
    public var lastActivityAt: Date
    public var endedAt: Date?
    public var status: SessionRecordStatus
    public var taskId: String?
    public var transcriptPath: String?

    public init(id: String, cwd: String?, projectName: String?, title: String, firstPrompt: String?, lastPrompt: String?, lastAssistantMessage: String?, startedAt: Date, lastActivityAt: Date, endedAt: Date?, status: SessionRecordStatus, taskId: String?, transcriptPath: String?) {
        self.id = id
        self.cwd = cwd
        self.projectName = projectName
        self.title = title
        self.firstPrompt = firstPrompt
        self.lastPrompt = lastPrompt
        self.lastAssistantMessage = lastAssistantMessage
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.endedAt = endedAt
        self.status = status
        self.taskId = taskId
        self.transcriptPath = transcriptPath
    }
}

public struct DistractionEpisode: Codable, Equatable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "distraction_episodes"

    public var id: Int64?
    public var startedAt: Date
    public var endedAt: Date?
    public var appBundleID: String
    public var domain: String?
    public var nudged: Bool
    public var returnedWithinSec: Double?

    public init(id: Int64? = nil, startedAt: Date, endedAt: Date? = nil, appBundleID: String, domain: String?, nudged: Bool = false, returnedWithinSec: Double? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.appBundleID = appBundleID
        self.domain = domain
        self.nudged = nudged
        self.returnedWithinSec = returnedWithinSec
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct NextActionEvent: Codable, Equatable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "next_action_events"

    public var id: Int64?
    public var shownAt: Date
    public var reactedAt: Date?
    public var kind: String

    public init(id: Int64? = nil, shownAt: Date, reactedAt: Date? = nil, kind: String) {
        self.id = id
        self.shownAt = shownAt
        self.reactedAt = reactedAt
        self.kind = kind
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
```

- [ ] **Step 5: Хранилище — `Sources/FocusCore/FocusStore.swift`**

```swift
import Foundation
import GRDB

public final class FocusStore: Sendable {
    public let dbQueue: DatabaseQueue

    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FocusIsland", isDirectory: true)
            .appendingPathComponent("focus.sqlite")
    }

    public convenience init(fileURL: URL) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.init(queue: DatabaseQueue(path: fileURL.path))
    }

    public static func inMemory() throws -> FocusStore {
        try FocusStore(queue: DatabaseQueue())
    }

    public static func openWithRecovery(fileURL: URL, now: Date = .now) -> (FocusStore, URL?) {
        if let store = try? FocusStore(fileURL: fileURL) {
            return (store, nil)
        }
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).bak-\(Int(now.timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: fileURL, to: backup)
        if let store = try? FocusStore(fileURL: fileURL) {
            return (store, backup)
        }
        return (try! FocusStore.inMemory(), backup)
    }

    private init(queue: DatabaseQueue) throws {
        dbQueue = queue
        try Self.migrator.migrate(dbQueue)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "tasks") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("details", .text)
                t.column("boardColumn", .text).notNull().indexed()
                t.column("position", .double).notNull()
                t.column("projectPath", .text)
                t.column("note", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("doneAt", .datetime)
            }
            try db.create(table: "sessions") { t in
                t.primaryKey("id", .text)
                t.column("cwd", .text)
                t.column("projectName", .text)
                t.column("title", .text).notNull()
                t.column("firstPrompt", .text)
                t.column("lastPrompt", .text)
                t.column("lastAssistantMessage", .text)
                t.column("startedAt", .datetime).notNull()
                t.column("lastActivityAt", .datetime).notNull().indexed()
                t.column("endedAt", .datetime)
                t.column("status", .text).notNull()
                t.column("taskId", .text).indexed()
                t.column("transcriptPath", .text)
            }
            try db.create(table: "distraction_episodes") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("startedAt", .datetime).notNull().indexed()
                t.column("endedAt", .datetime)
                t.column("appBundleID", .text).notNull()
                t.column("domain", .text)
                t.column("nudged", .boolean).notNull()
                t.column("returnedWithinSec", .double)
            }
            try db.create(table: "next_action_events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("shownAt", .datetime).notNull().indexed()
                t.column("reactedAt", .datetime)
                t.column("kind", .text).notNull()
            }
            try db.create(table: "backfill_files") { t in
                t.primaryKey("path", .text)
                t.column("modifiedAt", .datetime).notNull()
            }
        }
        return migrator
    }
}
```

- [ ] **Step 6: Run — PASS**

Run: `zsh /Users/diaszhanabayev/Projects/own/focus/scripts/test-clt.sh --filter FocusStoreTests`
Expected: 3 теста PASS.

- [ ] **Step 7: Checkpoint** — `swift build --package-path /Users/diaszhanabayev/Projects/own/focus` зелёный.

---

### Task 6: BoardService

**Files:**
- Create: `Sources/FocusCore/BoardService.swift`
- Test: `Tests/FocusCoreTests/BoardServiceTests.swift`

**Interfaces:**
- Consumes: `FocusStore`, `FocusTask`, `SessionRecord`, `BoardColumn`.
- Produces:
  - `struct BoardSnapshot { var tasks: [FocusTask]; func tasks(in: BoardColumn) -> [FocusTask]; func task(id: String?) -> FocusTask?; func currentTask(liveSessions: [SessionRecord]) -> FocusTask? }`
  - `enum BoardError: Error { emptyTitle, unknownTask, unknownSession }`
  - `final class BoardService` с `init(store:)`, `snapshot()`, `createTask(title:column:projectPath:details:now:) -> FocusTask`, `updateTask(_:now:)`, `moveTask(id:to:beforeTaskID:now:)`, `deleteTask(id:)`, `bindSession(sessionID:toTaskID:now:)`, `createTaskForSession(sessionID:title:projectPath:now:) -> FocusTask`, `doneTasks(since:) -> [FocusTask]`

- [ ] **Step 1: Failing tests** — `Tests/FocusCoreTests/BoardServiceTests.swift`:

```swift
import Foundation
import GRDB
import Testing
@testable import FocusCore

struct BoardServiceTests {
    let t0 = Date(timeIntervalSince1970: 10_000)

    func makeService() throws -> (BoardService, FocusStore) {
        let store = try FocusStore.inMemory()
        return (BoardService(store: store), store)
    }

    func insertSession(_ store: FocusStore, id: String, taskId: String? = nil, status: SessionRecordStatus = .live, lastActivityAt: Date) throws {
        let record = SessionRecord(id: id, cwd: "/tmp/p", projectName: "p", title: id, firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, startedAt: lastActivityAt, lastActivityAt: lastActivityAt, endedAt: nil, status: status, taskId: taskId, transcriptPath: nil)
        try store.dbQueue.write { db in try record.insert(db) }
    }

    @Test
    func createAppendsToEndOfColumn() throws {
        let (service, _) = try makeService()
        let a = try service.createTask(title: "A", column: .todo, now: t0)
        let b = try service.createTask(title: "B", column: .todo, now: t0)
        let todo = try service.snapshot().tasks(in: .todo)
        #expect(todo.map(\.id) == [a.id, b.id])
        #expect(b.position > a.position)
    }

    @Test
    func createRejectsBlankTitle() throws {
        let (service, _) = try makeService()
        #expect(throws: BoardError.emptyTitle) {
            try service.createTask(title: "   ", column: .todo, now: t0)
        }
    }

    @Test
    func moveBeforeAnotherTaskReorders() throws {
        let (service, _) = try makeService()
        let a = try service.createTask(title: "A", column: .todo, now: t0)
        let b = try service.createTask(title: "B", column: .todo, now: t0)
        let c = try service.createTask(title: "C", column: .todo, now: t0)
        try service.moveTask(id: c.id, to: .todo, beforeTaskID: a.id, now: t0)
        #expect(try service.snapshot().tasks(in: .todo).map(\.id) == [c.id, a.id, b.id])
        try service.moveTask(id: a.id, to: .todo, beforeTaskID: b.id, now: t0)
        #expect(try service.snapshot().tasks(in: .todo).map(\.id) == [c.id, a.id, b.id])
        try service.moveTask(id: c.id, to: .todo, beforeTaskID: b.id, now: t0)
        #expect(try service.snapshot().tasks(in: .todo).map(\.id) == [a.id, c.id, b.id])
    }

    @Test
    func moveToDoneSetsDoneAtAndMovingOutClearsIt() throws {
        let (service, _) = try makeService()
        let a = try service.createTask(title: "A", column: .inProgress, now: t0)
        try service.moveTask(id: a.id, to: .done, beforeTaskID: nil, now: t0.addingTimeInterval(5))
        #expect(try service.snapshot().task(id: a.id)?.doneAt == t0.addingTimeInterval(5))
        try service.moveTask(id: a.id, to: .todo, beforeTaskID: nil, now: t0.addingTimeInterval(6))
        #expect(try service.snapshot().task(id: a.id)?.doneAt == nil)
    }

    @Test
    func bindingMovesTodoTaskToInProgress() throws {
        let (service, store) = try makeService()
        let a = try service.createTask(title: "A", column: .todo, now: t0)
        try insertSession(store, id: "s1", lastActivityAt: t0)
        try service.bindSession(sessionID: "s1", toTaskID: a.id, now: t0)
        #expect(try service.snapshot().task(id: a.id)?.boardColumn == .inProgress)
        let record = try store.dbQueue.read { db in try SessionRecord.fetchOne(db, key: "s1") }
        #expect(record?.taskId == a.id)
    }

    @Test
    func bindingKeepsDoneTaskInDone() throws {
        let (service, store) = try makeService()
        let a = try service.createTask(title: "A", column: .done, now: t0)
        try insertSession(store, id: "s1", lastActivityAt: t0)
        try service.bindSession(sessionID: "s1", toTaskID: a.id, now: t0)
        #expect(try service.snapshot().task(id: a.id)?.boardColumn == .done)
    }

    @Test
    func bindingUnknownSessionThrows() throws {
        let (service, _) = try makeService()
        let a = try service.createTask(title: "A", column: .todo, now: t0)
        #expect(throws: BoardError.unknownSession) {
            try service.bindSession(sessionID: "nope", toTaskID: a.id, now: t0)
        }
    }

    @Test
    func createTaskForSessionTruncatesTitleAndBinds() throws {
        let (service, store) = try makeService()
        try insertSession(store, id: "s1", lastActivityAt: t0)
        let long = String(repeating: "я", count: 120)
        let task = try service.createTaskForSession(sessionID: "s1", title: long, projectPath: "/tmp/p", now: t0)
        #expect(task.title.count == 80)
        #expect(task.boardColumn == .inProgress)
        let record = try store.dbQueue.read { db in try SessionRecord.fetchOne(db, key: "s1") }
        #expect(record?.taskId == task.id)
    }

    @Test
    func deleteTaskUnbindsSessions() throws {
        let (service, store) = try makeService()
        let a = try service.createTask(title: "A", column: .todo, now: t0)
        try insertSession(store, id: "s1", taskId: a.id, lastActivityAt: t0)
        try service.deleteTask(id: a.id)
        #expect(try service.snapshot().tasks.isEmpty)
        let record = try store.dbQueue.read { db in try SessionRecord.fetchOne(db, key: "s1") }
        #expect(record?.taskId == nil)
    }

    @Test
    func currentTaskPrefersMostRecentBoundLiveSession() throws {
        let (service, _) = try makeService()
        let a = try service.createTask(title: "A", column: .inProgress, now: t0)
        let b = try service.createTask(title: "B", column: .inProgress, now: t0)
        let snapshot = try service.snapshot()
        let older = SessionRecord(id: "s1", cwd: nil, projectName: nil, title: "", firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, startedAt: t0, lastActivityAt: t0, endedAt: nil, status: .live, taskId: a.id, transcriptPath: nil)
        var newer = older
        newer.id = "s2"
        newer.taskId = b.id
        newer.lastActivityAt = t0.addingTimeInterval(60)
        #expect(snapshot.currentTask(liveSessions: [older, newer])?.id == b.id)
        #expect(snapshot.currentTask(liveSessions: [])?.id == a.id)
    }
}
```

- [ ] **Step 2: Run — FAIL** (`--filter BoardServiceTests`, «cannot find 'BoardService'»).

- [ ] **Step 3: Реализация — `Sources/FocusCore/BoardService.swift`**

```swift
import Foundation
import GRDB

public enum BoardError: Error, Equatable {
    case emptyTitle
    case unknownTask
    case unknownSession
}

public struct BoardSnapshot: Equatable, Sendable {
    public var tasks: [FocusTask]

    public init(tasks: [FocusTask]) {
        self.tasks = tasks
    }

    public func tasks(in column: BoardColumn) -> [FocusTask] {
        tasks.filter { $0.boardColumn == column }.sorted { $0.position < $1.position }
    }

    public func task(id: String?) -> FocusTask? {
        guard let id else { return nil }
        return tasks.first { $0.id == id }
    }

    public func currentTask(liveSessions: [SessionRecord]) -> FocusTask? {
        let bound = liveSessions
            .filter { $0.status == .live && $0.taskId != nil }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
        for session in bound {
            if let task = task(id: session.taskId), task.boardColumn != .done {
                return task
            }
        }
        return tasks(in: .inProgress).first
    }
}

public final class BoardService: Sendable {
    public static let maxSessionTitleLength = 80

    private let store: FocusStore

    public init(store: FocusStore) {
        self.store = store
    }

    public func snapshot() throws -> BoardSnapshot {
        try store.dbQueue.read { db in
            BoardSnapshot(tasks: try FocusTask.order(Column("position")).fetchAll(db))
        }
    }

    @discardableResult
    public func createTask(title: String, column: BoardColumn, projectPath: String? = nil, details: String? = nil, now: Date = .now) throws -> FocusTask {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BoardError.emptyTitle }
        return try store.dbQueue.write { db in
            let task = FocusTask(
                id: UUID().uuidString,
                title: trimmed,
                details: details,
                boardColumn: column,
                position: try Self.endPosition(in: column, db: db),
                projectPath: projectPath,
                note: nil,
                createdAt: now,
                updatedAt: now,
                doneAt: column == .done ? now : nil
            )
            try task.insert(db)
            return task
        }
    }

    public func updateTask(_ task: FocusTask, now: Date = .now) throws {
        let trimmed = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BoardError.emptyTitle }
        try store.dbQueue.write { db in
            guard try FocusTask.exists(db, key: task.id) else { throw BoardError.unknownTask }
            var updated = task
            updated.title = trimmed
            updated.updatedAt = now
            try updated.update(db)
        }
    }

    public func moveTask(id: String, to column: BoardColumn, beforeTaskID: String?, now: Date = .now) throws {
        try store.dbQueue.write { db in
            try Self.move(id: id, to: column, beforeTaskID: beforeTaskID, now: now, db: db)
        }
    }

    public func deleteTask(id: String) throws {
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE sessions SET taskId = NULL WHERE taskId = ?", arguments: [id])
            _ = try FocusTask.deleteOne(db, key: id)
        }
    }

    public func bindSession(sessionID: String, toTaskID taskID: String?, now: Date = .now) throws {
        try store.dbQueue.write { db in
            guard var record = try SessionRecord.fetchOne(db, key: sessionID) else { throw BoardError.unknownSession }
            if let taskID {
                guard let task = try FocusTask.fetchOne(db, key: taskID) else { throw BoardError.unknownTask }
                if task.boardColumn == .backlog || task.boardColumn == .todo {
                    try Self.move(id: taskID, to: .inProgress, beforeTaskID: nil, now: now, db: db)
                }
            }
            record.taskId = taskID
            try record.update(db)
        }
    }

    @discardableResult
    public func createTaskForSession(sessionID: String, title: String, projectPath: String?, now: Date = .now) throws -> FocusTask {
        let task = try createTask(title: String(title.prefix(Self.maxSessionTitleLength)), column: .inProgress, projectPath: projectPath, now: now)
        try bindSession(sessionID: sessionID, toTaskID: task.id, now: now)
        return task
    }

    public func doneTasks(since: Date) throws -> [FocusTask] {
        try store.dbQueue.read { db in
            try FocusTask
                .filter(Column("boardColumn") == BoardColumn.done.rawValue && Column("doneAt") >= since)
                .order(Column("doneAt").desc)
                .fetchAll(db)
        }
    }

    private static func endPosition(in column: BoardColumn, db: Database) throws -> Double {
        let maxPosition = try Double.fetchOne(db, sql: "SELECT MAX(position) FROM tasks WHERE boardColumn = ?", arguments: [column.rawValue])
        return (maxPosition ?? 0) + 1
    }

    private static func move(id: String, to column: BoardColumn, beforeTaskID: String?, now: Date, db: Database) throws {
        guard var task = try FocusTask.fetchOne(db, key: id) else { throw BoardError.unknownTask }
        let siblings = try FocusTask
            .filter(Column("boardColumn") == column.rawValue && Column("id") != id)
            .order(Column("position"))
            .fetchAll(db)
        if let beforeTaskID, let index = siblings.firstIndex(where: { $0.id == beforeTaskID }) {
            let next = siblings[index].position
            let previous = index > 0 ? siblings[index - 1].position : next - 2
            task.position = (previous + next) / 2
        } else {
            task.position = (siblings.last?.position ?? 0) + 1
        }
        if column == .done && task.boardColumn != .done {
            task.doneAt = now
        } else if column != .done {
            task.doneAt = nil
        }
        task.boardColumn = column
        task.updatedAt = now
        try task.update(db)
    }
}
```

- [ ] **Step 4: Run — PASS** (`--filter BoardServiceTests`, 10 тестов).

- [ ] **Step 5: Checkpoint.**

---

### Task 7: SessionHistory

**Files:**
- Create: `Sources/FocusCore/SessionHistory.swift`
- Test: `Tests/FocusCoreTests/SessionHistoryTests.swift`

**Interfaces:**
- Consumes: `FocusStore`, `SessionRecord`, `AgentSession`, `ClaudeSessionMetadata` (OpenIslandCore).
- Produces:
  - `struct SessionObservation: Equatable { sessionID, cwd, title, firstPrompt, lastPrompt, lastAssistantMessage, transcriptPath, observedAt, isEnded; init(session: AgentSession) }`
  - `final class SessionHistory` с `init(store:)`, `record(_:)`, `markEnded(sessionID:at:)`, `markAllLiveEnded(except:at:)`, `session(id:)`, `recent(limit:)`, `search(text:projectPath:limit:)`, `sessions(forTaskID:)`, `liveSessions()`, `knownProjectPaths()`, `mergeTranscript(_ summary: TranscriptSummary)` (тело — в Task 8), `static projectName(for:fileManager:)`, `static let maxAssistantMessageLength = 500`

- [ ] **Step 1: Failing tests** — `Tests/FocusCoreTests/SessionHistoryTests.swift`:

```swift
import Foundation
import Testing
import OpenIslandCore
@testable import FocusCore

struct SessionHistoryTests {
    let t0 = Date(timeIntervalSince1970: 20_000)

    func makeSession(id: String = "s1", cwd: String? = "/tmp/proj", initialPrompt: String? = "first", lastPrompt: String? = "last", assistant: String? = "ok", updatedAt: Date, ended: Bool = false) -> AgentSession {
        var session = AgentSession(
            id: id,
            title: "Claude · proj",
            tool: .claudeCode,
            origin: .live,
            attachmentState: .attached,
            phase: .running,
            summary: "",
            updatedAt: updatedAt,
            jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "proj", paneTitle: "", workingDirectory: cwd),
            claudeMetadata: ClaudeSessionMetadata(transcriptPath: "/tmp/t.jsonl", initialUserPrompt: initialPrompt, lastUserPrompt: lastPrompt, lastAssistantMessage: assistant)
        )
        session.isSessionEnded = ended
        return session
    }

    @Test
    func recordCreatesLiveRecord() throws {
        let history = SessionHistory(store: try FocusStore.inMemory())
        try history.record(SessionObservation(session: makeSession(updatedAt: t0)))
        let record = try #require(try history.session(id: "s1"))
        #expect(record.status == .live)
        #expect(record.startedAt == t0)
        #expect(record.cwd == "/tmp/proj")
        #expect(record.projectName == "proj")
        #expect(record.firstPrompt == "first")
        #expect(record.transcriptPath == "/tmp/t.jsonl")
    }

    @Test
    func recordPreservesStartFirstPromptAndTaskOnUpdate() throws {
        let store = try FocusStore.inMemory()
        let history = SessionHistory(store: store)
        try history.record(SessionObservation(session: makeSession(updatedAt: t0)))
        try store.dbQueue.write { db in try db.execute(sql: "UPDATE sessions SET taskId = 'task-1'") }
        try history.record(SessionObservation(session: makeSession(initialPrompt: nil, lastPrompt: "newer", updatedAt: t0.addingTimeInterval(30))))
        let record = try #require(try history.session(id: "s1"))
        #expect(record.startedAt == t0)
        #expect(record.firstPrompt == "first")
        #expect(record.lastPrompt == "newer")
        #expect(record.taskId == "task-1")
        #expect(record.lastActivityAt == t0.addingTimeInterval(30))
    }

    @Test
    func endedObservationSetsEndedOnce() throws {
        let history = SessionHistory(store: try FocusStore.inMemory())
        try history.record(SessionObservation(session: makeSession(updatedAt: t0, ended: true)))
        try history.record(SessionObservation(session: makeSession(updatedAt: t0.addingTimeInterval(5), ended: true)))
        let record = try #require(try history.session(id: "s1"))
        #expect(record.status == .ended)
        #expect(record.endedAt == t0)
    }

    @Test
    func assistantMessageIsTruncated() throws {
        let history = SessionHistory(store: try FocusStore.inMemory())
        try history.record(SessionObservation(session: makeSession(assistant: String(repeating: "x", count: 900), updatedAt: t0)))
        #expect(try history.session(id: "s1")?.lastAssistantMessage?.count == 500)
    }

    @Test
    func markAllLiveEndedSkipsGivenIDs() throws {
        let history = SessionHistory(store: try FocusStore.inMemory())
        try history.record(SessionObservation(session: makeSession(id: "a", updatedAt: t0)))
        try history.record(SessionObservation(session: makeSession(id: "b", updatedAt: t0)))
        try history.markAllLiveEnded(except: ["b"], at: t0.addingTimeInterval(100))
        #expect(try history.session(id: "a")?.status == .ended)
        #expect(try history.session(id: "a")?.endedAt == t0.addingTimeInterval(100))
        #expect(try history.session(id: "b")?.status == .live)
    }

    @Test
    func searchMatchesTitleAndPromptsCaseInsensitively() throws {
        let history = SessionHistory(store: try FocusStore.inMemory())
        try history.record(SessionObservation(session: makeSession(id: "a", initialPrompt: "Почини ДОСКУ", updatedAt: t0)))
        try history.record(SessionObservation(session: makeSession(id: "b", cwd: "/tmp/other", initialPrompt: "другое", lastPrompt: "x", updatedAt: t0.addingTimeInterval(1))))
        #expect(try history.search(text: "доску", projectPath: nil, limit: 10).map(\.id) == ["a"])
        #expect(try history.search(text: nil, projectPath: "/tmp/other", limit: 10).map(\.id) == ["b"])
        #expect(try history.search(text: nil, projectPath: nil, limit: 10).map(\.id) == ["b", "a"])
    }

    @Test
    func projectNameUsesGitRootWhenPresent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repo-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        #expect(SessionHistory.projectName(for: nested.path) == root.lastPathComponent)
        #expect(SessionHistory.projectName(for: "/nonexistent/some/dir") == "dir")
        #expect(SessionHistory.projectName(for: nil) == nil)
    }

    @Test
    func knownProjectPathsAreDistinctAndRecentFirst() throws {
        let history = SessionHistory(store: try FocusStore.inMemory())
        try history.record(SessionObservation(session: makeSession(id: "a", cwd: "/p1", updatedAt: t0)))
        try history.record(SessionObservation(session: makeSession(id: "b", cwd: "/p2", updatedAt: t0.addingTimeInterval(10))))
        try history.record(SessionObservation(session: makeSession(id: "c", cwd: "/p1", updatedAt: t0.addingTimeInterval(20))))
        #expect(try history.knownProjectPaths() == ["/p1", "/p2"])
    }
}
```

- [ ] **Step 2: Run — FAIL** (`--filter SessionHistoryTests`).

- [ ] **Step 3: Реализация — `Sources/FocusCore/SessionHistory.swift`**

```swift
import Foundation
import GRDB
import OpenIslandCore

public struct SessionObservation: Equatable, Sendable {
    public var sessionID: String
    public var cwd: String?
    public var title: String
    public var firstPrompt: String?
    public var lastPrompt: String?
    public var lastAssistantMessage: String?
    public var transcriptPath: String?
    public var observedAt: Date
    public var isEnded: Bool

    public init(sessionID: String, cwd: String?, title: String, firstPrompt: String?, lastPrompt: String?, lastAssistantMessage: String?, transcriptPath: String?, observedAt: Date, isEnded: Bool) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.title = title
        self.firstPrompt = firstPrompt
        self.lastPrompt = lastPrompt
        self.lastAssistantMessage = lastAssistantMessage
        self.transcriptPath = transcriptPath
        self.observedAt = observedAt
        self.isEnded = isEnded
    }

    public init(session: AgentSession) {
        self.init(
            sessionID: session.id,
            cwd: session.jumpTarget?.workingDirectory,
            title: session.title,
            firstPrompt: session.claudeMetadata?.initialUserPrompt,
            lastPrompt: session.claudeMetadata?.lastUserPrompt,
            lastAssistantMessage: session.claudeMetadata?.lastAssistantMessage.map { String($0.prefix(SessionHistory.maxAssistantMessageLength)) },
            transcriptPath: session.claudeMetadata?.transcriptPath,
            observedAt: session.updatedAt,
            isEnded: session.isSessionEnded
        )
    }
}

public final class SessionHistory: Sendable {
    public static let maxAssistantMessageLength = 500

    let store: FocusStore

    public init(store: FocusStore) {
        self.store = store
    }

    public func record(_ observation: SessionObservation) throws {
        try store.dbQueue.write { db in
            if var existing = try SessionRecord.fetchOne(db, key: observation.sessionID) {
                if let cwd = observation.cwd {
                    existing.cwd = cwd
                    existing.projectName = Self.projectName(for: cwd)
                }
                existing.title = observation.title
                existing.firstPrompt = existing.firstPrompt ?? observation.firstPrompt
                existing.lastPrompt = observation.lastPrompt ?? existing.lastPrompt
                existing.lastAssistantMessage = observation.lastAssistantMessage ?? existing.lastAssistantMessage
                existing.transcriptPath = observation.transcriptPath ?? existing.transcriptPath
                existing.lastActivityAt = max(existing.lastActivityAt, observation.observedAt)
                if observation.isEnded {
                    existing.status = .ended
                    existing.endedAt = existing.endedAt ?? observation.observedAt
                } else {
                    existing.status = .live
                    existing.endedAt = nil
                }
                try existing.update(db)
            } else {
                try SessionRecord(
                    id: observation.sessionID,
                    cwd: observation.cwd,
                    projectName: Self.projectName(for: observation.cwd),
                    title: observation.title,
                    firstPrompt: observation.firstPrompt,
                    lastPrompt: observation.lastPrompt,
                    lastAssistantMessage: observation.lastAssistantMessage,
                    startedAt: observation.observedAt,
                    lastActivityAt: observation.observedAt,
                    endedAt: observation.isEnded ? observation.observedAt : nil,
                    status: observation.isEnded ? .ended : .live,
                    taskId: nil,
                    transcriptPath: observation.transcriptPath
                ).insert(db)
            }
        }
    }

    public func markEnded(sessionID: String, at date: Date) throws {
        try store.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET status = 'ended', endedAt = COALESCE(endedAt, ?) WHERE id = ?",
                arguments: [date, sessionID]
            )
        }
    }

    public func markAllLiveEnded(except keep: Set<String>, at date: Date) throws {
        try store.dbQueue.write { db in
            let live = try SessionRecord.filter(Column("status") == SessionRecordStatus.live.rawValue).fetchAll(db)
            for var record in live where !keep.contains(record.id) {
                record.status = .ended
                record.endedAt = record.endedAt ?? date
                try record.update(db)
            }
        }
    }

    public func session(id: String) throws -> SessionRecord? {
        try store.dbQueue.read { db in try SessionRecord.fetchOne(db, key: id) }
    }

    public func recent(limit: Int) throws -> [SessionRecord] {
        try search(text: nil, projectPath: nil, limit: limit)
    }

    public func search(text: String?, projectPath: String?, limit: Int) throws -> [SessionRecord] {
        try store.dbQueue.read { db in
            var request = SessionRecord.all()
            if let projectPath {
                request = request.filter(Column("cwd") == projectPath)
            }
            var records = try request.order(Column("lastActivityAt").desc).fetchAll(db)
            if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                records = records.filter { record in
                    [record.title, record.firstPrompt, record.lastPrompt, record.projectName]
                        .compactMap { $0 }
                        .contains { $0.localizedCaseInsensitiveContains(text) }
                }
            }
            return Array(records.prefix(limit))
        }
    }

    public func sessions(forTaskID taskID: String) throws -> [SessionRecord] {
        try store.dbQueue.read { db in
            try SessionRecord.filter(Column("taskId") == taskID).order(Column("lastActivityAt").desc).fetchAll(db)
        }
    }

    public func liveSessions() throws -> [SessionRecord] {
        try store.dbQueue.read { db in
            try SessionRecord.filter(Column("status") == SessionRecordStatus.live.rawValue).fetchAll(db)
        }
    }

    public func knownProjectPaths() throws -> [String] {
        try store.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT cwd FROM sessions WHERE cwd IS NOT NULL GROUP BY cwd ORDER BY MAX(lastActivityAt) DESC")
        }
    }

    public static func projectName(for cwd: String?, fileManager: FileManager = .default) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        var url = URL(fileURLWithPath: cwd)
        while url.path != "/" {
            if fileManager.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url.lastPathComponent
            }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
}
```

Поиск фильтрует в Swift, чтобы `localizedCaseInsensitiveContains` корректно работал с кириллицей (SQLite `LIKE` регистронезависим только для ASCII).

- [ ] **Step 4: Run — PASS** (`--filter SessionHistoryTests`, 8 тестов). `mergeTranscript` добавляется в Task 8.

- [ ] **Step 5: Checkpoint.**

---

### Task 8: Разбор транскриптов и backfill

**Files:**
- Create: `Sources/FocusCore/TranscriptSummaryParser.swift`, `Sources/FocusCore/TranscriptBackfill.swift`
- Modify: `Sources/FocusCore/SessionHistory.swift` (добавить `mergeTranscript`)
- Test: `Tests/FocusCoreTests/TranscriptSummaryParserTests.swift`, `Tests/FocusCoreTests/TranscriptBackfillTests.swift`, `Tests/FocusCoreTests/Fixtures/basic.jsonl`, `Tests/FocusCoreTests/Fixtures/meta.jsonl`, `Tests/FocusCoreTests/Fixtures/truncated.jsonl`

**Interfaces:**
- Consumes: `SessionHistory`, `FocusStore`, `ClaudeTranscriptDiscovery.defaultRootURL`.
- Produces:
  - `struct TranscriptSummary: Equatable { sessionID, cwd, title, firstPrompt, lastPrompt, lastAssistantMessage, startedAt, lastActivityAt, transcriptPath }`
  - `enum TranscriptSummaryParser { static func parse(fileURL: URL) -> TranscriptSummary? }`
  - `SessionHistory.mergeTranscript(_:) throws`
  - `final class TranscriptBackfill { init(store:rootURL:); func run() throws -> Int }`

- [ ] **Step 1: Фикстуры**

`Tests/FocusCoreTests/Fixtures/basic.jsonl` (каждый JSON — одна строка):

```
{"type":"queue-operation","operation":"enqueue","timestamp":"2026-10-08T20:09:00.000Z","sessionId":"abc-123"}
{"type":"user","sessionId":"abc-123","cwd":"/tmp/proj","timestamp":"2026-10-08T20:09:05.510Z","message":{"role":"user","content":"Сделай канбан доску"}}
{"type":"assistant","sessionId":"abc-123","cwd":"/tmp/proj","timestamp":"2026-10-08T20:09:25.804Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"..."},{"type":"text","text":"Начинаю с модели."}]}}
{"type":"user","sessionId":"abc-123","cwd":"/tmp/proj","timestamp":"2026-10-08T20:09:29.945Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"ok"}]}}
{"type":"user","sessionId":"abc-123","cwd":"/tmp/proj","timestamp":"2026-10-08T20:10:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Добавь drag and drop"}]}}
{"type":"assistant","sessionId":"abc-123","cwd":"/tmp/proj","timestamp":"2026-10-08T20:10:30.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Готово."}]}}
{"type":"ai-title","aiTitle":"kanban-board","sessionId":"abc-123"}
```

`Tests/FocusCoreTests/Fixtures/meta.jsonl`:

```
{"type":"user","sessionId":"meta-1","cwd":"/tmp/m","timestamp":"2026-10-08T10:00:00.000Z","isMeta":true,"message":{"role":"user","content":"<system-reminder>ignore</system-reminder>"}}
{"type":"user","sessionId":"meta-1","cwd":"/tmp/m","timestamp":"2026-10-08T10:00:01.000Z","message":{"role":"user","content":"<command-name>/clear</command-name>"}}
{"type":"user","sessionId":"meta-1","cwd":"/tmp/m","timestamp":"2026-10-08T10:00:02.000Z","isSidechain":true,"message":{"role":"user","content":"subagent prompt"}}
{"type":"user","sessionId":"meta-1","cwd":"/tmp/m","timestamp":"2026-10-08T10:00:03.000Z","message":{"role":"user","content":"Настоящий промпт"}}
{"type":"custom-title","customTitle":"Мой заголовок","sessionId":"meta-1"}
{"type":"ai-title","aiTitle":"ai-variant","sessionId":"meta-1"}
{"type":"last-prompt","lastPrompt":"Последний из last-prompt","sessionId":"meta-1"}
```

`Tests/FocusCoreTests/Fixtures/truncated.jsonl` (последняя строка намеренно оборвана, без перевода строки в конце):

```
{"type":"user","sessionId":"tr-1","cwd":"/tmp/t","timestamp":"2026-10-08T11:00:00.000Z","message":{"role":"user","content":"Целый промпт"}}
{"type":"assistant","sessionId":"tr-1","cwd":"/tmp/t","timestamp":"2026-10-08T11:00:05.000Z","message":{"role":"assist
```

- [ ] **Step 2: Failing tests**

`Tests/FocusCoreTests/TranscriptSummaryParserTests.swift`:

```swift
import Foundation
import Testing
@testable import FocusCore

struct TranscriptSummaryParserTests {
    func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
    }

    @Test
    func parsesPromptsAssistantTitleAndTimes() throws {
        let summary = try #require(TranscriptSummaryParser.parse(fileURL: try fixture("basic")))
        #expect(summary.sessionID == "abc-123")
        #expect(summary.cwd == "/tmp/proj")
        #expect(summary.firstPrompt == "Сделай канбан доску")
        #expect(summary.lastPrompt == "Добавь drag and drop")
        #expect(summary.lastAssistantMessage == "Готово.")
        #expect(summary.title == "kanban-board")
        #expect(summary.startedAt == ISO8601DateFormatter.focusFractional.date(from: "2026-10-08T20:09:00.000Z"))
        #expect(summary.lastActivityAt == ISO8601DateFormatter.focusFractional.date(from: "2026-10-08T20:10:30.000Z"))
    }

    @Test
    func skipsMetaAndCommandMessages() throws {
        let summary = try #require(TranscriptSummaryParser.parse(fileURL: try fixture("meta")))
        #expect(summary.firstPrompt == "Настоящий промпт")
        #expect(summary.lastPrompt == "Последний из last-prompt")
        #expect(summary.title == "Мой заголовок")
    }

    @Test
    func toleratesTruncatedLastLine() throws {
        let summary = try #require(TranscriptSummaryParser.parse(fileURL: try fixture("truncated")))
        #expect(summary.firstPrompt == "Целый промпт")
        #expect(summary.lastAssistantMessage == nil)
    }

    @Test
    func titleFallsBackToFirstPromptPrefix() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("s-9.jsonl")
        let prompt = String(repeating: "a", count: 200)
        try Data("{\"type\":\"user\",\"sessionId\":\"s-9\",\"timestamp\":\"2026-10-08T11:00:00.000Z\",\"message\":{\"content\":\"\(prompt)\"}}\n".utf8).write(to: file)
        let summary = try #require(TranscriptSummaryParser.parse(fileURL: file))
        #expect(summary.title.count == 80)
    }

    @Test
    func returnsNilForFileWithoutSessionData() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("empty.jsonl")
        try Data("garbage\n".utf8).write(to: file)
        #expect(TranscriptSummaryParser.parse(fileURL: file) == nil)
    }
}
```

`Tests/FocusCoreTests/TranscriptBackfillTests.swift`:

```swift
import Foundation
import Testing
@testable import FocusCore

struct TranscriptBackfillTests {
    func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("projects-\(UUID().uuidString)")
        let project = root.appendingPathComponent("-tmp-proj")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("abc-123/subagents"), withIntermediateDirectories: true)
        let source = try #require(Bundle.module.url(forResource: "basic", withExtension: "jsonl", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: source, to: project.appendingPathComponent("abc-123.jsonl"))
        try FileManager.default.copyItem(at: source, to: project.appendingPathComponent("abc-123/subagents/agent-1.jsonl"))
        return root
    }

    @Test
    func importsEndedSessionsAndSkipsSubagents() throws {
        let store = try FocusStore.inMemory()
        let backfill = TranscriptBackfill(store: store, rootURL: try makeRoot())
        #expect(try backfill.run() == 1)
        let record = try #require(try SessionHistory(store: store).session(id: "abc-123"))
        #expect(record.status == .ended)
        #expect(record.title == "kanban-board")
        #expect(record.endedAt == record.lastActivityAt)
    }

    @Test
    func secondRunSkipsUnchangedFiles() throws {
        let store = try FocusStore.inMemory()
        let backfill = TranscriptBackfill(store: store, rootURL: try makeRoot())
        _ = try backfill.run()
        #expect(try backfill.run() == 0)
    }

    @Test
    func doesNotDowngradeLiveSessionOrDropTask() throws {
        let store = try FocusStore.inMemory()
        let history = SessionHistory(store: store)
        try history.record(SessionObservation(sessionID: "abc-123", cwd: "/tmp/proj", title: "Live title", firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, transcriptPath: nil, observedAt: Date(timeIntervalSince1970: 1), isEnded: false))
        try store.dbQueue.write { db in try db.execute(sql: "UPDATE sessions SET taskId = 't1'") }
        _ = try TranscriptBackfill(store: store, rootURL: try makeRoot()).run()
        let record = try #require(try history.session(id: "abc-123"))
        #expect(record.status == .live)
        #expect(record.title == "Live title")
        #expect(record.taskId == "t1")
        #expect(record.firstPrompt == "Сделай канбан доску")
    }
}
```

- [ ] **Step 3: Run — FAIL** (`--filter Transcript`).

- [ ] **Step 4: Парсер — `Sources/FocusCore/TranscriptSummaryParser.swift`**

```swift
import Foundation

public struct TranscriptSummary: Equatable, Sendable {
    public var sessionID: String
    public var cwd: String?
    public var title: String
    public var firstPrompt: String?
    public var lastPrompt: String?
    public var lastAssistantMessage: String?
    public var startedAt: Date
    public var lastActivityAt: Date
    public var transcriptPath: String
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let focusFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) static let focusPlain = ISO8601DateFormatter()
}

public enum TranscriptSummaryParser {
    public static let maxTitleLength = 80

    public static func parse(fileURL: URL) -> TranscriptSummary? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        var sessionID: String?
        var cwd: String?
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var firstPrompt: String?
        var lastPrompt: String?
        var lastPromptRecord: String?
        var lastAssistant: String?
        var customTitle: String?
        var aiTitle: String?

        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if sessionID == nil, let value = object["sessionId"] as? String { sessionID = value }
            if cwd == nil, let value = object["cwd"] as? String, !value.isEmpty { cwd = value }
            if let raw = object["timestamp"] as? String, let date = parseDate(raw) {
                firstTimestamp = firstTimestamp ?? date
                lastTimestamp = date
            }
            switch object["type"] as? String {
            case "user":
                guard object["isMeta"] as? Bool != true, object["isSidechain"] as? Bool != true,
                      let text = userText(object["message"]) else { continue }
                firstPrompt = firstPrompt ?? text
                lastPrompt = text
            case "assistant":
                if object["isSidechain"] as? Bool == true { continue }
                if let text = assistantText(object["message"]) {
                    lastAssistant = String(text.prefix(SessionHistory.maxAssistantMessageLength))
                }
            case "custom-title":
                customTitle = (object["customTitle"] as? String) ?? customTitle
            case "ai-title":
                aiTitle = (object["aiTitle"] as? String) ?? aiTitle
            case "last-prompt":
                lastPromptRecord = (object["lastPrompt"] as? String) ?? lastPromptRecord
            default:
                continue
            }
        }

        guard let sessionID, firstPrompt != nil || lastAssistant != nil || customTitle != nil || aiTitle != nil else {
            return nil
        }
        let modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date(timeIntervalSince1970: 0)
        let title = customTitle
            ?? aiTitle
            ?? firstPrompt.map { String($0.prefix(maxTitleLength)) }
            ?? SessionHistory.projectName(for: cwd)
            ?? sessionID
        return TranscriptSummary(
            sessionID: sessionID,
            cwd: cwd,
            title: title,
            firstPrompt: firstPrompt,
            lastPrompt: lastPromptRecord ?? lastPrompt,
            lastAssistantMessage: lastAssistant,
            startedAt: firstTimestamp ?? modifiedAt,
            lastActivityAt: lastTimestamp ?? modifiedAt,
            transcriptPath: fileURL.path
        )
    }

    static func parseDate(_ raw: String) -> Date? {
        ISO8601DateFormatter.focusFractional.date(from: raw) ?? ISO8601DateFormatter.focusPlain.date(from: raw)
    }

    static func userText(_ message: Any?) -> String? {
        guard let message = message as? [String: Any] else { return nil }
        let text: String?
        if let string = message["content"] as? String {
            text = string
        } else if let parts = message["content"] as? [[String: Any]] {
            let texts = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            text = texts.isEmpty ? nil : texts.joined(separator: "\n")
        } else {
            text = nil
        }
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty, !trimmed.hasPrefix("<") else {
            return nil
        }
        return trimmed
    }

    static func assistantText(_ message: Any?) -> String? {
        guard let message = message as? [String: Any], let parts = message["content"] as? [[String: Any]] else { return nil }
        let texts = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
}
```

- [ ] **Step 5: `SessionHistory.mergeTranscript`** — добавить в класс `SessionHistory`:

```swift
public func mergeTranscript(_ summary: TranscriptSummary) throws {
    try store.dbQueue.write { db in
        if var existing = try SessionRecord.fetchOne(db, key: summary.sessionID) {
            existing.cwd = existing.cwd ?? summary.cwd
            existing.projectName = existing.projectName ?? Self.projectName(for: summary.cwd)
            existing.firstPrompt = existing.firstPrompt ?? summary.firstPrompt
            existing.transcriptPath = existing.transcriptPath ?? summary.transcriptPath
            existing.startedAt = min(existing.startedAt, summary.startedAt)
            if existing.status == .ended {
                existing.title = summary.title
                existing.lastPrompt = summary.lastPrompt ?? existing.lastPrompt
                existing.lastAssistantMessage = summary.lastAssistantMessage ?? existing.lastAssistantMessage
                existing.lastActivityAt = max(existing.lastActivityAt, summary.lastActivityAt)
                existing.endedAt = existing.lastActivityAt
            }
            try existing.update(db)
        } else {
            try SessionRecord(
                id: summary.sessionID,
                cwd: summary.cwd,
                projectName: Self.projectName(for: summary.cwd),
                title: summary.title,
                firstPrompt: summary.firstPrompt,
                lastPrompt: summary.lastPrompt,
                lastAssistantMessage: summary.lastAssistantMessage,
                startedAt: summary.startedAt,
                lastActivityAt: summary.lastActivityAt,
                endedAt: summary.lastActivityAt,
                status: .ended,
                taskId: nil,
                transcriptPath: summary.transcriptPath
            ).insert(db)
        }
    }
}
```

- [ ] **Step 6: Backfill — `Sources/FocusCore/TranscriptBackfill.swift`**

```swift
import Foundation
import GRDB
import OpenIslandCore

public final class TranscriptBackfill: Sendable {
    private let store: FocusStore
    private let rootURL: URL
    private let history: SessionHistory

    public init(store: FocusStore, rootURL: URL = ClaudeTranscriptDiscovery.defaultRootURL) {
        self.store = store
        self.rootURL = rootURL
        self.history = SessionHistory(store: store)
    }

    @discardableResult
    public func run() throws -> Int {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        let known: [String: Date] = try store.dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT path, modifiedAt FROM backfill_files")
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["path"] as String, $0["modifiedAt"] as Date) })
        }

        var processed = 0
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl", !fileURL.path.contains("/subagents/") else { continue }
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let modifiedAt = values?.contentModificationDate else { continue }
            if let previous = known[fileURL.path], previous >= modifiedAt { continue }
            if let summary = TranscriptSummaryParser.parse(fileURL: fileURL) {
                try history.mergeTranscript(summary)
                processed += 1
            }
            try store.dbQueue.write { db in
                try db.execute(
                    sql: "INSERT INTO backfill_files (path, modifiedAt) VALUES (?, ?) ON CONFLICT(path) DO UPDATE SET modifiedAt = excluded.modifiedAt",
                    arguments: [fileURL.path, modifiedAt]
                )
            }
        }
        return processed
    }
}
```

- [ ] **Step 7: Run — PASS** (`--filter Transcript`, 8 тестов).

- [ ] **Step 8: Checkpoint.** Проверка на реальных транскриптах и скорость backfill — в Task 13 Step 7.

---

### Task 9: TurnTracker

**Files:**
- Create: `Sources/FocusCore/TurnTracker.swift`
- Test: `Tests/FocusCoreTests/TurnTrackerTests.swift`

**Interfaces:**
- Consumes: `SessionPhase` (OpenIslandCore).
- Produces: `struct TurnTracker { var delay: TimeInterval; init(delay:); mutating observe(sessionID:phase:lastUserPrompt:at:); mutating forget(sessionID:); mutating snooze(sessionID:until:); mutating takeDueSessions(now:) -> [String] }`

- [ ] **Step 1: Failing tests** — `Tests/FocusCoreTests/TurnTrackerTests.swift`:

```swift
import Foundation
import Testing
import OpenIslandCore
@testable import FocusCore

struct TurnTrackerTests {
    let t0 = Date(timeIntervalSince1970: 30_000)

    @Test
    func firesOnceAfterDelayWhileRunning() {
        var tracker = TurnTracker(delay: 15)
        tracker.observe(sessionID: "s", phase: .running, lastUserPrompt: "p1", at: t0)
        #expect(tracker.takeDueSessions(now: t0.addingTimeInterval(14)) == [])
        #expect(tracker.takeDueSessions(now: t0.addingTimeInterval(15)) == ["s"])
        #expect(tracker.takeDueSessions(now: t0.addingTimeInterval(60)) == [])
    }

    @Test
    func repeatedRunningUpdatesDoNotRestartTurn() {
        var tracker = TurnTracker(delay: 15)
        tracker.observe(sessionID: "s", phase: .running, lastUserPrompt: "p1", at: t0)
        tracker.observe(sessionID: "s", phase: .running, lastUserPrompt: "p1", at: t0.addingTimeInterval(10))
        #expect(tracker.takeDueSessions(now: t0.addingTimeInterval(15)) == ["s"])
    }

    @Test
    func promptAppearingLaterIsSameTurn() {
        var tracker = TurnTracker(delay: 15)
        tracker.observe(sessionID: "s", phase: .running, lastUserPrompt: nil, at: t0)
        tracker.observe(sessionID: "s", phase: .running, lastUserPrompt: "p1", at: t0.addingTimeInterval(5))
        #expect(tracker.takeDueSessions(now: t0.addingTimeInterval(15)) == ["s"])
    }

    @Test
    func stoppingBeforeDelayCancels() {
        var tracker = TurnTracker(delay: 15)
        tracker.observe(sessionID: "s", phase: .running, lastUserPrompt: "p1", at: t0)
        tracker.observe(sessionID: "s", phase: .completed, lastUserPrompt: "p1", at: t0.addingTimeInterval(5))
        #expect(tracker.takeDueSessions(now: t0.addingTimeInterval(20)) == [])
    }

    @Test
    func newTurnAfterCompletionFiresAgain() {
        var tracker = TurnTracker(delay: 15)
        tracker.observe(sessionID: "s", phase: .running, lastUserPrompt: "p1", at: t0)
        _ = tracker.takeDueSessions(now: t0.addingTimeInterval(15))
        tracker.observe(sessionID: "s", phase: .completed, lastUserPrompt: "p1", at: t0.addingTimeInterval(20))
        tracker.observe(sessionID: "s", phase: .running, lastUserPrompt: "p2", at: t0.addingTimeInterval(30))
        #expect(tracker.takeDueSessions(now: t0.addingTimeInterval(45)) == ["s"])
    }

    @Test
    func changedPromptWhileRunningStartsNewTurn() {
        var tracker = TurnTracker(delay: 15)
        tracker.observe(sessionID: "s", phase: .running, lastUserPrompt: "p1", at: t0)
        _ = tracker.takeDueSessions(now: t0.addingTimeInterval(15))
        tracker.observe(sessionID: "s", phase: .running, lastUserPrompt: "p2", at: t0.addingTimeInterval(20))
        #expect(tracker.takeDueSessions(now: t0.addingTimeInterval(35)) == ["s"])
    }

    @Test
    func waitingForApprovalPausesTurn() {
        var tracker = TurnTracker(delay: 15)
        tracker.observe(sessionID: "s", phase: .running, lastUserPrompt: "p1", at: t0)
        tracker.observe(sessionID: "s", phase: .waitingForApproval, lastUserPrompt: "p1", at: t0.addingTimeInterval(3))
        #expect(tracker.takeDueSessions(now: t0.addingTimeInterval(20)) == [])
        tracker.observe(sessionID: "s", phase: .running, lastUserPrompt: "p1", at: t0.addingTimeInterval(30))
        #expect(tracker.takeDueSessions(now: t0.addingTimeInterval(45)) == ["s"])
    }

    @Test
    func snoozeConsumesTurnSilently() {
        var tracker = TurnTracker(delay: 15)
        tracker.snooze(sessionID: "s", until: t0.addingTimeInterval(300))
        tracker.observe(sessionID: "s", phase: .running, lastUserPrompt: "p1", at: t0)
        #expect(tracker.takeDueSessions(now: t0.addingTimeInterval(20)) == [])
        tracker.observe(sessionID: "s", phase: .completed, lastUserPrompt: "p1", at: t0.addingTimeInterval(400))
        tracker.observe(sessionID: "s", phase: .running, lastUserPrompt: "p2", at: t0.addingTimeInterval(410))
        #expect(tracker.takeDueSessions(now: t0.addingTimeInterval(425)) == ["s"])
    }

    @Test
    func multipleDueSessionsAreSorted() {
        var tracker = TurnTracker(delay: 15)
        tracker.observe(sessionID: "b", phase: .running, lastUserPrompt: nil, at: t0)
        tracker.observe(sessionID: "a", phase: .running, lastUserPrompt: nil, at: t0)
        #expect(tracker.takeDueSessions(now: t0.addingTimeInterval(15)) == ["a", "b"])
    }
}
```

- [ ] **Step 2: Run — FAIL** (`--filter TurnTrackerTests`).

- [ ] **Step 3: Реализация — `Sources/FocusCore/TurnTracker.swift`**

```swift
import Foundation
import OpenIslandCore

public struct TurnTracker: Sendable {
    private struct Turn: Sendable {
        var startedAt: Date
        var lastPrompt: String?
        var fired: Bool
        var running: Bool
    }

    public var delay: TimeInterval
    private var turns: [String: Turn] = [:]
    private var snoozedUntil: [String: Date] = [:]

    public init(delay: TimeInterval = 15) {
        self.delay = delay
    }

    public mutating func observe(sessionID: String, phase: SessionPhase, lastUserPrompt: String?, at now: Date) {
        guard phase == .running else {
            turns[sessionID]?.running = false
            return
        }
        if var turn = turns[sessionID], turn.running {
            if let previous = turn.lastPrompt, let lastUserPrompt, previous != lastUserPrompt {
                turns[sessionID] = Turn(startedAt: now, lastPrompt: lastUserPrompt, fired: false, running: true)
            } else {
                turn.lastPrompt = turn.lastPrompt ?? lastUserPrompt
                turns[sessionID] = turn
            }
            return
        }
        turns[sessionID] = Turn(startedAt: now, lastPrompt: lastUserPrompt, fired: false, running: true)
    }

    public mutating func forget(sessionID: String) {
        turns[sessionID] = nil
        snoozedUntil[sessionID] = nil
    }

    public mutating func snooze(sessionID: String, until: Date) {
        snoozedUntil[sessionID] = until
    }

    public mutating func takeDueSessions(now: Date) -> [String] {
        var due: [String] = []
        for (id, turn) in turns where turn.running && !turn.fired && now.timeIntervalSince(turn.startedAt) >= delay {
            turns[id]?.fired = true
            if let until = snoozedUntil[id], until > now {
                continue
            }
            due.append(id)
        }
        return due.sorted()
    }
}
```

Новый ход начинается при переходе в `running` из любой другой фазы (или при первом наблюдении) и при смене непустого `lastUserPrompt` во время `running`.

- [ ] **Step 4: Run — PASS** (`--filter TurnTrackerTests`, 9 тестов).

- [ ] **Step 5: Checkpoint.**

---

### Task 10: NextActionEngine

**Files:**
- Create: `Sources/FocusCore/NextActionEngine.swift`
- Test: `Tests/FocusCoreTests/NextActionEngineTests.swift`

**Interfaces:**
- Consumes: `AgentSession`, `SessionPhase` (OpenIslandCore, `isVisibleInIsland` public после Task 5), `BoardSnapshot`, `FocusTask`.
- Produces:
  - `enum AttentionReason: String { approval, question, unseenCompletion }`
  - `enum NextAction: Equatable { attendSession(sessionID: String, reason: AttentionReason); startTask(taskID: String); reflect(sessionID: String, taskID: String?) }` + `var kind: String`
  - `struct NextActionInput { triggeringSessionID, sessions: [AgentSession], unseenCompletedSessionIDs: Set<String>, board: BoardSnapshot, sessionTaskBindings: [String: String], skippedTaskIDs: Set<String> }`
  - `enum NextActionEngine { static func evaluate(_:) -> NextAction }`

- [ ] **Step 1: Failing tests** — `Tests/FocusCoreTests/NextActionEngineTests.swift`:

```swift
import Foundation
import Testing
import OpenIslandCore
@testable import FocusCore

struct NextActionEngineTests {
    let t0 = Date(timeIntervalSince1970: 40_000)

    func session(_ id: String, _ phase: SessionPhase, updatedAt offset: TimeInterval = 0) -> AgentSession {
        var session = AgentSession(id: id, title: id, tool: .claudeCode, origin: .live, attachmentState: .attached, phase: phase, summary: "", updatedAt: t0.addingTimeInterval(offset))
        session.isHookManaged = true
        return session
    }

    func task(_ id: String, _ column: BoardColumn, _ position: Double) -> FocusTask {
        FocusTask(id: id, title: id, details: nil, boardColumn: column, position: position, projectPath: nil, note: nil, createdAt: t0, updatedAt: t0, doneAt: nil)
    }

    func input(sessions: [AgentSession], tasks: [FocusTask] = [], unseen: Set<String> = [], bindings: [String: String] = [:], skipped: Set<String> = []) -> NextActionInput {
        NextActionInput(triggeringSessionID: "me", sessions: sessions, unseenCompletedSessionIDs: unseen, board: BoardSnapshot(tasks: tasks), sessionTaskBindings: bindings, skippedTaskIDs: skipped)
    }

    @Test
    func approvalBeatsQuestionBeatsUnseenCompletion() {
        let sessions = [session("me", .running), session("c", .completed), session("q", .waitingForAnswer), session("a", .waitingForApproval)]
        #expect(NextActionEngine.evaluate(input(sessions: sessions, unseen: ["c"])) == .attendSession(sessionID: "a", reason: .approval))
        let withoutApproval = sessions.filter { $0.id != "a" }
        #expect(NextActionEngine.evaluate(input(sessions: withoutApproval, unseen: ["c"])) == .attendSession(sessionID: "q", reason: .question))
        let onlyCompleted = sessions.filter { $0.id == "me" || $0.id == "c" }
        #expect(NextActionEngine.evaluate(input(sessions: onlyCompleted, unseen: ["c"])) == .attendSession(sessionID: "c", reason: .unseenCompletion))
    }

    @Test
    func longestWaitingSessionWinsWithinSameReason() {
        let sessions = [session("me", .running), session("new", .waitingForApproval, updatedAt: 50), session("old", .waitingForApproval, updatedAt: 10)]
        #expect(NextActionEngine.evaluate(input(sessions: sessions)) == .attendSession(sessionID: "old", reason: .approval))
    }

    @Test
    func seenCompletionIsIgnored() {
        let sessions = [session("me", .running), session("c", .completed)]
        #expect(NextActionEngine.evaluate(input(sessions: sessions, tasks: [task("t1", .todo, 1)])) == .startTask(taskID: "t1"))
    }

    @Test
    func triggeringSessionNeverAttendsItself() {
        let sessions = [session("me", .waitingForApproval)]
        #expect(NextActionEngine.evaluate(input(sessions: sessions)) == .reflect(sessionID: "me", taskID: nil))
    }

    @Test
    func firstTodoByPositionIsSuggested() {
        let tasks = [task("t2", .todo, 2), task("t1", .todo, 1), task("b", .backlog, 0)]
        #expect(NextActionEngine.evaluate(input(sessions: [session("me", .running)], tasks: tasks)) == .startTask(taskID: "t1"))
    }

    @Test
    func skippedTodoMovesToNext() {
        let tasks = [task("t1", .todo, 1), task("t2", .todo, 2)]
        #expect(NextActionEngine.evaluate(input(sessions: [session("me", .running)], tasks: tasks, skipped: ["t1"])) == .startTask(taskID: "t2"))
    }

    @Test
    func emptyTodoFallsBackToInProgressWithoutLiveSession() {
        let tasks = [task("mine", .inProgress, 1), task("busy", .inProgress, 2), task("idle", .inProgress, 3)]
        let sessions = [session("me", .running), session("other", .running)]
        let bindings = ["me": "mine", "other": "busy"]
        #expect(NextActionEngine.evaluate(input(sessions: sessions, tasks: tasks, bindings: bindings)) == .startTask(taskID: "idle"))
    }

    @Test
    func endedSessionDoesNotKeepTaskBusy() {
        var ended = session("other", .completed)
        ended.isSessionEnded = true
        let tasks = [task("busy", .inProgress, 1)]
        let bindings = ["other": "busy"]
        #expect(NextActionEngine.evaluate(input(sessions: [session("me", .running), ended], tasks: tasks, bindings: bindings)) == .startTask(taskID: "busy"))
    }

    @Test
    func fallsBackToReflectWhenBoardEmpty() {
        #expect(NextActionEngine.evaluate(input(sessions: [session("me", .running)], bindings: ["me": "x"])) == .reflect(sessionID: "me", taskID: "x"))
    }

    @Test
    func fallsBackToReflectWhenAllTasksSkipped() {
        let tasks = [task("t1", .todo, 1), task("p", .inProgress, 1)]
        #expect(NextActionEngine.evaluate(input(sessions: [session("me", .running)], tasks: tasks, skipped: ["t1", "p"])) == .reflect(sessionID: "me", taskID: nil))
    }

    @Test
    func doneTasksAreNeverSuggested() {
        let tasks = [task("d", .done, 1)]
        #expect(NextActionEngine.evaluate(input(sessions: [session("me", .running)], tasks: tasks)) == .reflect(sessionID: "me", taskID: nil))
    }
}
```

- [ ] **Step 2: Run — FAIL** (`--filter NextActionEngineTests`).

- [ ] **Step 3: Реализация — `Sources/FocusCore/NextActionEngine.swift`**

```swift
import Foundation
import OpenIslandCore

public enum AttentionReason: String, Equatable, Sendable {
    case approval
    case question
    case unseenCompletion
}

public enum NextAction: Equatable, Sendable {
    case attendSession(sessionID: String, reason: AttentionReason)
    case startTask(taskID: String)
    case reflect(sessionID: String, taskID: String?)

    public var kind: String {
        switch self {
        case let .attendSession(_, reason): "attend.\(reason.rawValue)"
        case .startTask: "startTask"
        case .reflect: "reflect"
        }
    }
}

public struct NextActionInput: Sendable {
    public var triggeringSessionID: String
    public var sessions: [AgentSession]
    public var unseenCompletedSessionIDs: Set<String>
    public var board: BoardSnapshot
    public var sessionTaskBindings: [String: String]
    public var skippedTaskIDs: Set<String>

    public init(triggeringSessionID: String, sessions: [AgentSession], unseenCompletedSessionIDs: Set<String>, board: BoardSnapshot, sessionTaskBindings: [String: String], skippedTaskIDs: Set<String>) {
        self.triggeringSessionID = triggeringSessionID
        self.sessions = sessions
        self.unseenCompletedSessionIDs = unseenCompletedSessionIDs
        self.board = board
        self.sessionTaskBindings = sessionTaskBindings
        self.skippedTaskIDs = skippedTaskIDs
    }
}

public enum NextActionEngine {
    public static func evaluate(_ input: NextActionInput) -> NextAction {
        let others = input.sessions
            .filter { $0.id != input.triggeringSessionID && $0.isVisibleInIsland && !$0.isSessionEnded }
            .sorted { $0.updatedAt < $1.updatedAt }

        if let session = others.first(where: { $0.phase == .waitingForApproval }) {
            return .attendSession(sessionID: session.id, reason: .approval)
        }
        if let session = others.first(where: { $0.phase == .waitingForAnswer }) {
            return .attendSession(sessionID: session.id, reason: .question)
        }
        if let session = others.first(where: { $0.phase == .completed && input.unseenCompletedSessionIDs.contains($0.id) }) {
            return .attendSession(sessionID: session.id, reason: .unseenCompletion)
        }

        if let todo = input.board.tasks(in: .todo).first(where: { !input.skippedTaskIDs.contains($0.id) }) {
            return .startTask(taskID: todo.id)
        }

        let liveSessionIDs = Set(input.sessions.filter { !$0.isSessionEnded }.map(\.id))
        let busyTaskIDs = Set(input.sessionTaskBindings.compactMap { sessionID, taskID in
            liveSessionIDs.contains(sessionID) ? taskID : nil
        })
        if let idle = input.board.tasks(in: .inProgress).first(where: { !busyTaskIDs.contains($0.id) && !input.skippedTaskIDs.contains($0.id) }) {
            return .startTask(taskID: idle.id)
        }

        return .reflect(sessionID: input.triggeringSessionID, taskID: input.sessionTaskBindings[input.triggeringSessionID])
    }
}
```

- [ ] **Step 4: Run — PASS** (`--filter NextActionEngineTests`, 11 тестов).

- [ ] **Step 5: Checkpoint.**

---

### Task 11: Детектор отвлечения (чистая логика)

**Files:**
- Create: `Sources/FocusCore/Distraction.swift`
- Test: `Tests/FocusCoreTests/DistractionTests.swift`

**Interfaces:**
- Consumes: `DistractionEpisode`.
- Produces:
  - `struct StopList: Codable, Equatable { appBundleIDs: [String]; domains: [String]; static let default }`
  - `enum KnownApps { static let browsers: Set<String>; static func isTerminalOrEditor(_ bundleID: String) -> Bool }`
  - `enum DistractionClassifier { static func domain(from: URL?) -> String?; static func isDistracting(bundleID:url:stopList:) -> Bool }`
  - `struct FrontmostSample: Equatable { bundleID: String; url: URL?; at: Date }`
  - `enum DistractionEvent: Equatable { nudge; episodeEnded(DistractionEpisode) }`
  - `struct DistractionTracker { init(threshold:renudgeInterval:); mutating suppress(until:); mutating observe(_:anySessionRunning:stopList:) -> [DistractionEvent]; var currentEpisode: DistractionEpisode? }`
  - `enum FocusPresentationPolicy { static func shouldPresentNextAction(frontmostBundleID:frontmostSince:frontmostIsDistracting:selfBundleID:now:busyThreshold:) -> Bool }`

- [ ] **Step 1: Failing tests** — `Tests/FocusCoreTests/DistractionTests.swift`:

```swift
import Foundation
import Testing
@testable import FocusCore

struct DistractionTests {
    let t0 = Date(timeIntervalSince1970: 50_000)
    let stopList = StopList.default

    func sample(_ bundleID: String, _ url: String? = nil, _ offset: TimeInterval) -> FrontmostSample {
        FrontmostSample(bundleID: bundleID, url: url.flatMap(URL.init(string:)), at: t0.addingTimeInterval(offset))
    }

    @Test
    func domainMatchingCoversSubdomainsAndWww() {
        #expect(DistractionClassifier.isDistracting(bundleID: "com.google.Chrome", url: URL(string: "https://www.youtube.com/watch?v=1"), stopList: stopList))
        #expect(DistractionClassifier.isDistracting(bundleID: "com.apple.Safari", url: URL(string: "https://old.reddit.com/r/swift"), stopList: stopList))
        #expect(!DistractionClassifier.isDistracting(bundleID: "com.apple.Safari", url: URL(string: "https://notyoutube.com"), stopList: stopList))
        #expect(!DistractionClassifier.isDistracting(bundleID: "com.apple.Safari", url: URL(string: "https://developer.apple.com"), stopList: stopList))
        #expect(!DistractionClassifier.isDistracting(bundleID: "com.apple.Safari", url: nil, stopList: stopList))
    }

    @Test
    func appMatchingUsesBundleID() {
        #expect(DistractionClassifier.isDistracting(bundleID: "ru.keepcoder.Telegram", url: nil, stopList: stopList))
        #expect(!DistractionClassifier.isDistracting(bundleID: "com.apple.Terminal", url: nil, stopList: stopList))
    }

    @Test
    func urlIgnoredForNonBrowsers() {
        #expect(!DistractionClassifier.isDistracting(bundleID: "com.apple.Notes", url: URL(string: "https://youtube.com"), stopList: stopList))
    }

    @Test
    func nudgesAfterThresholdThenRenudgesAfterInterval() {
        var tracker = DistractionTracker(threshold: 20, renudgeInterval: 180)
        #expect(tracker.observe(sample("ru.keepcoder.Telegram", nil, 0), anySessionRunning: true, stopList: stopList) == [])
        #expect(tracker.observe(sample("ru.keepcoder.Telegram", nil, 19), anySessionRunning: true, stopList: stopList) == [])
        #expect(tracker.observe(sample("ru.keepcoder.Telegram", nil, 20), anySessionRunning: true, stopList: stopList) == [.nudge])
        #expect(tracker.observe(sample("ru.keepcoder.Telegram", nil, 100), anySessionRunning: true, stopList: stopList) == [])
        #expect(tracker.observe(sample("ru.keepcoder.Telegram", nil, 200), anySessionRunning: true, stopList: stopList) == [.nudge])
    }

    @Test
    func leavingAfterNudgeLogsReturnTime() {
        var tracker = DistractionTracker(threshold: 20, renudgeInterval: 180)
        _ = tracker.observe(sample("ru.keepcoder.Telegram", nil, 0), anySessionRunning: true, stopList: stopList)
        _ = tracker.observe(sample("ru.keepcoder.Telegram", nil, 25), anySessionRunning: true, stopList: stopList)
        let events = tracker.observe(sample("com.apple.Terminal", nil, 31), anySessionRunning: true, stopList: stopList)
        #expect(events == [.episodeEnded(DistractionEpisode(startedAt: t0, endedAt: t0.addingTimeInterval(31), appBundleID: "ru.keepcoder.Telegram", domain: nil, nudged: true, returnedWithinSec: 6))])
        #expect(tracker.currentEpisode == nil)
    }

    @Test
    func shortGlanceIsNotLogged() {
        var tracker = DistractionTracker(threshold: 20, renudgeInterval: 180)
        _ = tracker.observe(sample("com.google.Chrome", "https://x.com/home", 0), anySessionRunning: true, stopList: stopList)
        #expect(tracker.observe(sample("com.apple.Terminal", nil, 5), anySessionRunning: true, stopList: stopList) == [])
    }

    @Test
    func noRunningSessionMeansNoDistraction() {
        var tracker = DistractionTracker(threshold: 20, renudgeInterval: 180)
        _ = tracker.observe(sample("ru.keepcoder.Telegram", nil, 0), anySessionRunning: false, stopList: stopList)
        #expect(tracker.observe(sample("ru.keepcoder.Telegram", nil, 30), anySessionRunning: false, stopList: stopList) == [])
        #expect(tracker.currentEpisode == nil)
    }

    @Test
    func suppressionBlocksUntilExpiry() {
        var tracker = DistractionTracker(threshold: 20, renudgeInterval: 180)
        tracker.suppress(until: t0.addingTimeInterval(600))
        _ = tracker.observe(sample("ru.keepcoder.Telegram", nil, 0), anySessionRunning: true, stopList: stopList)
        #expect(tracker.observe(sample("ru.keepcoder.Telegram", nil, 30), anySessionRunning: true, stopList: stopList) == [])
        _ = tracker.observe(sample("ru.keepcoder.Telegram", nil, 601), anySessionRunning: true, stopList: stopList)
        #expect(tracker.observe(sample("ru.keepcoder.Telegram", nil, 621), anySessionRunning: true, stopList: stopList) == [.nudge])
    }

    @Test
    func switchingBetweenDistractionsKeepsOneEpisode() {
        var tracker = DistractionTracker(threshold: 20, renudgeInterval: 180)
        _ = tracker.observe(sample("ru.keepcoder.Telegram", nil, 0), anySessionRunning: true, stopList: stopList)
        #expect(tracker.observe(sample("com.google.Chrome", "https://youtube.com", 21), anySessionRunning: true, stopList: stopList) == [.nudge])
        #expect(tracker.currentEpisode?.startedAt == t0)
    }

    @Test
    func busyInOtherAppSuppressesNextActionCard() {
        let since = t0
        #expect(!FocusPresentationPolicy.shouldPresentNextAction(frontmostBundleID: "com.figma.Desktop", frontmostSince: since, frontmostIsDistracting: false, selfBundleID: "dev.zhanabayev.focusisland", now: t0.addingTimeInterval(61)))
        #expect(FocusPresentationPolicy.shouldPresentNextAction(frontmostBundleID: "com.figma.Desktop", frontmostSince: since, frontmostIsDistracting: false, selfBundleID: "dev.zhanabayev.focusisland", now: t0.addingTimeInterval(30)))
        #expect(FocusPresentationPolicy.shouldPresentNextAction(frontmostBundleID: "com.apple.Terminal", frontmostSince: since, frontmostIsDistracting: false, selfBundleID: "dev.zhanabayev.focusisland", now: t0.addingTimeInterval(600)))
        #expect(FocusPresentationPolicy.shouldPresentNextAction(frontmostBundleID: "ru.keepcoder.Telegram", frontmostSince: since, frontmostIsDistracting: true, selfBundleID: "dev.zhanabayev.focusisland", now: t0.addingTimeInterval(600)))
        #expect(FocusPresentationPolicy.shouldPresentNextAction(frontmostBundleID: nil, frontmostSince: nil, frontmostIsDistracting: false, selfBundleID: "x", now: t0))
    }
}
```

- [ ] **Step 2: Run — FAIL** (`--filter DistractionTests`).

- [ ] **Step 3: Реализация — `Sources/FocusCore/Distraction.swift`**

```swift
import Foundation

public struct StopList: Codable, Equatable, Sendable {
    public var appBundleIDs: [String]
    public var domains: [String]

    public init(appBundleIDs: [String], domains: [String]) {
        self.appBundleIDs = appBundleIDs
        self.domains = domains
    }

    public static let `default` = StopList(
        appBundleIDs: ["ru.keepcoder.Telegram", "com.tdesktop.Telegram", "com.hnc.Discord"],
        domains: ["youtube.com", "x.com", "twitter.com", "reddit.com", "instagram.com", "tiktok.com", "news.ycombinator.com", "vc.ru", "habr.com"]
    )
}

public enum KnownApps {
    public static let browsers: Set<String> = ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser"]

    public static let terminalsAndEditors: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "com.github.wez.wezterm", "net.kovidgoyal.kitty", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
        "dev.zed.Zed", "com.apple.dt.Xcode",
    ]

    public static func isTerminalOrEditor(_ bundleID: String) -> Bool {
        terminalsAndEditors.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.")
    }
}

public enum DistractionClassifier {
    public static func domain(from url: URL?) -> String? {
        guard var host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        return host
    }

    public static func isDistracting(bundleID: String, url: URL?, stopList: StopList) -> Bool {
        if stopList.appBundleIDs.contains(bundleID) {
            return true
        }
        guard KnownApps.browsers.contains(bundleID), let host = domain(from: url) else {
            return false
        }
        return stopList.domains.contains { blocked in
            let blocked = blocked.lowercased()
            return host == blocked || host.hasSuffix("." + blocked)
        }
    }
}

public struct FrontmostSample: Equatable, Sendable {
    public var bundleID: String
    public var url: URL?
    public var at: Date

    public init(bundleID: String, url: URL?, at: Date) {
        self.bundleID = bundleID
        self.url = url
        self.at = at
    }
}

public enum DistractionEvent: Equatable, Sendable {
    case nudge
    case episodeEnded(DistractionEpisode)
}

public struct DistractionTracker: Sendable {
    public var threshold: TimeInterval
    public var renudgeInterval: TimeInterval
    public private(set) var currentEpisode: DistractionEpisode?
    private var lastNudgeAt: Date?
    private var suppressedUntil: Date?

    public init(threshold: TimeInterval = 20, renudgeInterval: TimeInterval = 180) {
        self.threshold = threshold
        self.renudgeInterval = renudgeInterval
    }

    public mutating func suppress(until date: Date) {
        suppressedUntil = date
    }

    public mutating func observe(_ sample: FrontmostSample, anySessionRunning: Bool, stopList: StopList) -> [DistractionEvent] {
        let suppressed = suppressedUntil.map { sample.at < $0 } ?? false
        let distracting = anySessionRunning && !suppressed
            && DistractionClassifier.isDistracting(bundleID: sample.bundleID, url: sample.url, stopList: stopList)

        guard distracting else {
            guard var episode = currentEpisode else { return [] }
            currentEpisode = nil
            defer { lastNudgeAt = nil }
            guard sample.at.timeIntervalSince(episode.startedAt) >= threshold else { return [] }
            episode.endedAt = sample.at
            if episode.nudged, let lastNudgeAt {
                episode.returnedWithinSec = sample.at.timeIntervalSince(lastNudgeAt)
            }
            return [.episodeEnded(episode)]
        }

        if currentEpisode == nil {
            currentEpisode = DistractionEpisode(
                startedAt: sample.at,
                appBundleID: sample.bundleID,
                domain: KnownApps.browsers.contains(sample.bundleID) ? DistractionClassifier.domain(from: sample.url) : nil
            )
        }
        guard let episode = currentEpisode, sample.at.timeIntervalSince(episode.startedAt) >= threshold else { return [] }
        if let lastNudgeAt, sample.at.timeIntervalSince(lastNudgeAt) < renudgeInterval {
            return []
        }
        currentEpisode?.nudged = true
        lastNudgeAt = sample.at
        return [.nudge]
    }
}

public enum FocusPresentationPolicy {
    public static func shouldPresentNextAction(
        frontmostBundleID: String?,
        frontmostSince: Date?,
        frontmostIsDistracting: Bool,
        selfBundleID: String?,
        now: Date,
        busyThreshold: TimeInterval = 60
    ) -> Bool {
        guard let frontmostBundleID, let frontmostSince else { return true }
        if frontmostIsDistracting || frontmostBundleID == selfBundleID || KnownApps.isTerminalOrEditor(frontmostBundleID) {
            return true
        }
        return now.timeIntervalSince(frontmostSince) < busyThreshold
    }
}
```

- [ ] **Step 4: Run — PASS** (`--filter DistractionTests`, 10 тестов).

- [ ] **Step 5: Checkpoint.**

---

### Task 12: Логи, статистика, Resume-команды, настройки

**Files:**
- Create: `Sources/FocusCore/FocusLogs.swift`, `Sources/FocusCore/ResumeCommand.swift`, `Sources/FocusCore/FocusSettings.swift`
- Test: `Tests/FocusCoreTests/FocusLogsTests.swift`, `Tests/FocusCoreTests/ResumeCommandTests.swift`, `Tests/FocusCoreTests/FocusSettingsTests.swift`

**Interfaces:**
- Consumes: `FocusStore`, `DistractionEpisode`, `NextActionEvent`, `SessionRecord`, `FocusTask`, `StopList`.
- Produces:
  - `final class DistractionLog { init(store:); save(_:) throws; episodes(since:) throws -> [DistractionEpisode] }`
  - `final class NextActionLog { init(store:); shown(kind:at:) throws -> Int64; reacted(id:at:) throws }`
  - `struct FocusStats: Equatable { tasksDone, sessionsStarted: Int; boundShare: Double?; distractionCount: Int; distractionSeconds: Double; medianReactionSec: Double? }`
  - `final class StatsService { init(store:); stats(since:) throws -> FocusStats }`
  - `enum ShellQuoting { static func singleQuoted(_:) -> String }`, `enum AppleScriptQuoting { static func string(_:) -> String }`
  - `enum ResumeCommand { static func resume(sessionID:cwd:) -> String; static func newSession(cwd:) -> String }`
  - `enum ResumeTerminal: String { terminal, iTerm, ghostty }`, `enum BoardHotKey: String { optionCommandB, controlOptionB, off }`
  - `struct FocusSettings: Codable, Equatable { nextActionEnabled, nextActionDelay, distractionEnabled, distractionThreshold, stopList, resumeTerminal, boardHotKey, nudgeSoundEnabled; static let defaultsKey; static func load(from:) -> FocusSettings; func save(to:) }`

- [ ] **Step 1: Failing tests**

`Tests/FocusCoreTests/ResumeCommandTests.swift`:

```swift
import Testing
@testable import FocusCore

struct ResumeCommandTests {
    @Test
    func buildsResumeCommand() {
        #expect(ResumeCommand.resume(sessionID: "abc-123", cwd: "/Users/me/proj") == "cd '/Users/me/proj' && claude --resume 'abc-123'")
    }

    @Test
    func quotesSingleQuotesInPath() {
        #expect(ResumeCommand.newSession(cwd: "/tmp/it's мой проект") == "cd '/tmp/it'\\''s мой проект' && claude")
    }
}

struct AppleScriptQuotingTests {
    @Test
    func escapesQuotesAndBackslashes() {
        #expect(AppleScriptQuoting.string("say \"hi\" \\ ok") == "\"say \\\"hi\\\" \\\\ ok\"")
    }
}
```

`Tests/FocusCoreTests/FocusSettingsTests.swift`:

```swift
import Foundation
import Testing
@testable import FocusCore

struct FocusSettingsTests {
    @Test
    func defaultsMatchSpec() {
        let settings = FocusSettings()
        #expect(settings.nextActionDelay == 15)
        #expect(settings.distractionThreshold == 20)
        #expect(settings.stopList == .default)
        #expect(settings.resumeTerminal == .terminal)
        #expect(settings.boardHotKey == .optionCommandB)
        #expect(settings.nudgeSoundEnabled == false)
    }

    @Test
    func roundTripsThroughUserDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "focus-settings-\(UUID().uuidString)"))
        var settings = FocusSettings()
        settings.nextActionDelay = 30
        settings.stopList.domains.append("lenta.ru")
        settings.save(to: defaults)
        #expect(FocusSettings.load(from: defaults) == settings)
    }

    @Test
    func corruptStoredValueFallsBackToDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "focus-settings-\(UUID().uuidString)"))
        defaults.set(Data("nope".utf8), forKey: FocusSettings.defaultsKey)
        #expect(FocusSettings.load(from: defaults) == FocusSettings())
    }
}
```

`Tests/FocusCoreTests/FocusLogsTests.swift`:

```swift
import Foundation
import GRDB
import Testing
@testable import FocusCore

struct FocusLogsTests {
    let t0 = Date(timeIntervalSince1970: 60_000)

    @Test
    func statsAggregateSinceDate() throws {
        let store = try FocusStore.inMemory()
        let board = BoardService(store: store)
        let done = try board.createTask(title: "A", column: .inProgress, now: t0)
        try board.moveTask(id: done.id, to: .done, beforeTaskID: nil, now: t0.addingTimeInterval(10))
        let old = try board.createTask(title: "Old", column: .inProgress, now: t0)
        try board.moveTask(id: old.id, to: .done, beforeTaskID: nil, now: t0.addingTimeInterval(-10_000))

        try store.dbQueue.write { db in
            for (id, task) in [("s1", done.id), ("s2", nil)] as [(String, String?)] {
                try SessionRecord(id: id, cwd: nil, projectName: nil, title: id, firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, startedAt: t0, lastActivityAt: t0, endedAt: nil, status: .ended, taskId: task, transcriptPath: nil).insert(db)
            }
        }

        let distractions = DistractionLog(store: store)
        try distractions.save(DistractionEpisode(startedAt: t0, endedAt: t0.addingTimeInterval(40), appBundleID: "x", domain: nil, nudged: true, returnedWithinSec: 10))
        try distractions.save(DistractionEpisode(startedAt: t0.addingTimeInterval(100), endedAt: t0.addingTimeInterval(160), appBundleID: "x", domain: nil, nudged: true, returnedWithinSec: 5))

        let reactions = NextActionLog(store: store)
        for (shown, reacted) in [(0.0, 10.0), (100, 140), (200, 220)] {
            let id = try reactions.shown(kind: "startTask", at: t0.addingTimeInterval(shown))
            try reactions.reacted(id: id, at: t0.addingTimeInterval(reacted))
        }
        _ = try reactions.shown(kind: "reflect", at: t0.addingTimeInterval(300))

        let stats = try StatsService(store: store).stats(since: t0.addingTimeInterval(-1))
        #expect(stats == FocusStats(tasksDone: 1, sessionsStarted: 2, boundShare: 0.5, distractionCount: 2, distractionSeconds: 100, medianReactionSec: 20))
    }

    @Test
    func emptyStatsHaveNilRatios() throws {
        let stats = try StatsService(store: try FocusStore.inMemory()).stats(since: t0)
        #expect(stats == FocusStats(tasksDone: 0, sessionsStarted: 0, boundShare: nil, distractionCount: 0, distractionSeconds: 0, medianReactionSec: nil))
    }
}
```

- [ ] **Step 2: Run — FAIL** (`--filter "ResumeCommandTests|AppleScriptQuotingTests|FocusSettingsTests|FocusLogsTests"`).

- [ ] **Step 3: `Sources/FocusCore/ResumeCommand.swift`**

```swift
import Foundation

public enum ShellQuoting {
    public static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum AppleScriptQuoting {
    public static func string(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

public enum ResumeCommand {
    public static func resume(sessionID: String, cwd: String) -> String {
        "cd \(ShellQuoting.singleQuoted(cwd)) && claude --resume \(ShellQuoting.singleQuoted(sessionID))"
    }

    public static func newSession(cwd: String) -> String {
        "cd \(ShellQuoting.singleQuoted(cwd)) && claude"
    }
}
```

- [ ] **Step 4: `Sources/FocusCore/FocusSettings.swift`**

```swift
import Foundation

public enum ResumeTerminal: String, Codable, CaseIterable, Sendable, Identifiable {
    case terminal
    case iTerm
    case ghostty

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .terminal: "Terminal"
        case .iTerm: "iTerm"
        case .ghostty: "Ghostty"
        }
    }
}

public enum BoardHotKey: String, Codable, CaseIterable, Sendable, Identifiable {
    case optionCommandB
    case controlOptionB
    case off

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .optionCommandB: "⌥⌘B"
        case .controlOptionB: "⌃⌥B"
        case .off: "Выключен"
        }
    }
}

public struct FocusSettings: Codable, Equatable, Sendable {
    public static let defaultsKey = "focus.settings"

    public var nextActionEnabled = true
    public var nextActionDelay: TimeInterval = 15
    public var distractionEnabled = true
    public var distractionThreshold: TimeInterval = 20
    public var stopList: StopList = .default
    public var resumeTerminal: ResumeTerminal = .terminal
    public var boardHotKey: BoardHotKey = .optionCommandB
    public var nudgeSoundEnabled = false

    public init() {}

    public static func load(from defaults: UserDefaults) -> FocusSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(FocusSettings.self, from: data) else {
            return FocusSettings()
        }
        return settings
    }

    public func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
```

- [ ] **Step 5: `Sources/FocusCore/FocusLogs.swift`**

```swift
import Foundation
import GRDB

public final class DistractionLog: Sendable {
    private let store: FocusStore

    public init(store: FocusStore) {
        self.store = store
    }

    public func save(_ episode: DistractionEpisode) throws {
        try store.dbQueue.write { db in
            var copy = episode
            try copy.insert(db)
        }
    }

    public func episodes(since: Date) throws -> [DistractionEpisode] {
        try store.dbQueue.read { db in
            try DistractionEpisode.filter(Column("startedAt") >= since).order(Column("startedAt")).fetchAll(db)
        }
    }
}

public final class NextActionLog: Sendable {
    private let store: FocusStore

    public init(store: FocusStore) {
        self.store = store
    }

    public func shown(kind: String, at date: Date) throws -> Int64 {
        try store.dbQueue.write { db in
            var event = NextActionEvent(shownAt: date, kind: kind)
            try event.insert(db)
            return event.id ?? 0
        }
    }

    public func reacted(id: Int64, at date: Date) throws {
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE next_action_events SET reactedAt = ? WHERE id = ? AND reactedAt IS NULL", arguments: [date, id])
        }
    }
}

public struct FocusStats: Equatable, Sendable {
    public var tasksDone: Int
    public var sessionsStarted: Int
    public var boundShare: Double?
    public var distractionCount: Int
    public var distractionSeconds: Double
    public var medianReactionSec: Double?

    public init(tasksDone: Int, sessionsStarted: Int, boundShare: Double?, distractionCount: Int, distractionSeconds: Double, medianReactionSec: Double?) {
        self.tasksDone = tasksDone
        self.sessionsStarted = sessionsStarted
        self.boundShare = boundShare
        self.distractionCount = distractionCount
        self.distractionSeconds = distractionSeconds
        self.medianReactionSec = medianReactionSec
    }
}

public final class StatsService: Sendable {
    private let store: FocusStore

    public init(store: FocusStore) {
        self.store = store
    }

    public func stats(since: Date) throws -> FocusStats {
        try store.dbQueue.read { db in
            let tasksDone = try FocusTask.filter(Column("boardColumn") == BoardColumn.done.rawValue && Column("doneAt") >= since).fetchCount(db)
            let sessions = try SessionRecord.filter(Column("startedAt") >= since).fetchAll(db)
            let bound = sessions.filter { $0.taskId != nil }.count
            let episodes = try DistractionEpisode.filter(Column("startedAt") >= since).fetchAll(db)
            let seconds = episodes.reduce(0.0) { total, episode in
                total + (episode.endedAt.map { $0.timeIntervalSince(episode.startedAt) } ?? 0)
            }
            let reactions = try NextActionEvent
                .filter(Column("shownAt") >= since && Column("reactedAt") != nil)
                .fetchAll(db)
                .compactMap { event in event.reactedAt.map { $0.timeIntervalSince(event.shownAt) } }
                .sorted()
            let median: Double? = reactions.isEmpty ? nil : (reactions.count % 2 == 1
                ? reactions[reactions.count / 2]
                : (reactions[reactions.count / 2 - 1] + reactions[reactions.count / 2]) / 2)
            return FocusStats(
                tasksDone: tasksDone,
                sessionsStarted: sessions.count,
                boundShare: sessions.isEmpty ? nil : Double(bound) / Double(sessions.count),
                distractionCount: episodes.count,
                distractionSeconds: seconds,
                medianReactionSec: median
            )
        }
    }
}
```

- [ ] **Step 6: Run — PASS** (те же фильтры, 8 тестов) и весь FocusCore: `zsh scripts/test-clt.sh --filter FocusCoreTests`.

- [ ] **Step 7: Checkpoint.**

---

# Фаза C — интеграция в приложение

### Task 13: FocusCoordinator и подключение к AppModel

**Files:**
- Create: `Sources/OpenIslandApp/Focus/FocusCoordinator.swift`, `Sources/OpenIslandApp/Focus/TerminalLauncher.swift` (только протокол в этой задаче)
- Modify: `Sources/OpenIslandApp/AppModel.swift` (свойство `focus`, `state.didSet`, init)
- Test: `Tests/OpenIslandAppTests/FocusCoordinatorTests.swift`

**Interfaces:**
- Consumes: всё из FocusCore; `AgentSession`; `AppModel.jumpToSession(_:)`, `AppModel.notchOpen(reason:surface:)`.
- Produces:
  - `protocol TerminalLaunching: Sendable { func run(command: String, in terminal: ResumeTerminal) throws }`
  - `enum FocusCard: Equatable { nextAction(triggeringSessionID: String, action: NextAction, eventID: Int64?); nudge }`
  - `enum FocusCardAction: Equatable { jump(sessionID: String); startTask(taskID: String); nextTask; saveNote(taskID: String, text: String); bindTriggering(taskID: String); quickAdd(title: String); snooze(sessionID: String); dismiss; returnToWork; allowDistraction }`
  - `@MainActor @Observable final class FocusCoordinator` со свойствами `board: BoardSnapshot`, `liveRecords: [SessionRecord]`, `settings: FocusSettings`, `card: FocusCard?`, `pendingBindingSessionIDs: [String]`, `storeRecoveredBackupURL: URL?`, `currentTask: FocusTask?`, и методами `start(initialSessions:now:)`, `sessionsDidChange(_:now:)`, `tick(now:)`, `perform(_:now:)`, `bind(sessionID:taskID:)`, `createTaskForSession(sessionID:)`, `skipBinding(sessionID:)`, `createTask(title:column:projectPath:)`, `moveTask(id:to:before:)`, `updateTask(_:)`, `deleteTask(id:)`, `markDone(taskID:)`, `markSessionSeen(_:)`, `frontmostDidChange(_:)`, `resume(record:)`, `sessions(forTaskID:)`, `searchHistory(text:projectPath:)`, `knownProjectPaths()`, `stats(since:)`; колбэки `presentCard: (() -> Void)?`, `jumpToSession: ((String) -> Void)?`, `liveSessionIDs: Set<String>`.

- [ ] **Step 1: Протокол лаунчера** — `Sources/OpenIslandApp/Focus/TerminalLauncher.swift`:

```swift
import FocusCore
import Foundation

protocol TerminalLaunching: Sendable {
    func run(command: String, in terminal: ResumeTerminal) throws
}
```

- [ ] **Step 2: Failing tests** — `Tests/OpenIslandAppTests/FocusCoordinatorTests.swift`:

```swift
import FocusCore
import Foundation
import OpenIslandCore
import Testing
@testable import OpenIslandApp

final class RecordingLauncher: TerminalLaunching, @unchecked Sendable {
    var commands: [String] = []
    func run(command: String, in terminal: ResumeTerminal) throws {
        commands.append(command)
    }
}

@MainActor
struct FocusCoordinatorTests {
    let t0 = Date(timeIntervalSince1970: 70_000)

    func makeCoordinator() throws -> (FocusCoordinator, FocusStore, RecordingLauncher) {
        let store = try FocusStore.inMemory()
        let launcher = RecordingLauncher()
        let defaults = UserDefaults(suiteName: "focus-coord-\(UUID().uuidString)")!
        let coordinator = FocusCoordinator(store: store, defaults: defaults, launcher: launcher, runBackfill: false)
        return (coordinator, store, launcher)
    }

    func session(_ id: String, _ phase: SessionPhase, at date: Date, firstSeen: Date? = nil, prompt: String? = "p", cwd: String = "/tmp/proj", source: ClaudeSessionStartSource = .startup) -> AgentSession {
        var session = AgentSession(
            id: id, title: id, tool: .claudeCode, origin: .live, attachmentState: .attached, phase: phase, summary: "", updatedAt: date, firstSeenAt: firstSeen ?? date,
            jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "proj", paneTitle: "", workingDirectory: cwd),
            claudeMetadata: ClaudeSessionMetadata(initialUserPrompt: prompt, lastUserPrompt: prompt, startupSource: source)
        )
        session.isHookManaged = true
        return session
    }

    @Test
    func newSessionIsRecordedAndAsksForBinding() throws {
        let (coordinator, store, _) = try makeCoordinator()
        coordinator.start(initialSessions: [], now: t0)
        coordinator.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        #expect(coordinator.pendingBindingSessionIDs == ["s1"])
        #expect(try SessionHistory(store: store).session(id: "s1")?.status == .live)
    }

    @Test
    func restoredSessionDoesNotAskForBinding() throws {
        let (coordinator, _, _) = try makeCoordinator()
        let restored = session("old", .completed, at: t0, firstSeen: t0.addingTimeInterval(-3600))
        coordinator.start(initialSessions: [restored], now: t0)
        coordinator.sessionsDidChange([restored], now: t0)
        #expect(coordinator.pendingBindingSessionIDs.isEmpty)
    }

    @Test
    func resumedSessionDoesNotAskForBinding() throws {
        let (coordinator, _, _) = try makeCoordinator()
        coordinator.start(initialSessions: [], now: t0)
        coordinator.sessionsDidChange([session("s1", .running, at: t0, source: .resume)], now: t0)
        #expect(coordinator.pendingBindingSessionIDs.isEmpty)
    }

    @Test
    func reconcilesStaleLiveRecordsOnStart() throws {
        let (coordinator, store, _) = try makeCoordinator()
        let history = SessionHistory(store: store)
        try history.record(SessionObservation(session: session("ghost", .running, at: t0.addingTimeInterval(-100))))
        try history.record(SessionObservation(session: session("alive", .running, at: t0.addingTimeInterval(-100))))
        coordinator.start(initialSessions: [session("alive", .running, at: t0)], now: t0)
        #expect(try history.session(id: "ghost")?.status == .ended)
        #expect(try history.session(id: "alive")?.status == .live)
    }

    @Test
    func identicalObservationsAreNotRewritten() throws {
        let (coordinator, store, _) = try makeCoordinator()
        coordinator.start(initialSessions: [], now: t0)
        let s = session("s1", .running, at: t0)
        coordinator.sessionsDidChange([s], now: t0)
        try store.dbQueue.write { db in try db.execute(sql: "UPDATE sessions SET title = 'sentinel'") }
        coordinator.sessionsDidChange([s], now: t0.addingTimeInterval(1))
        #expect(try SessionHistory(store: store).session(id: "s1")?.title == "sentinel")
    }

    @Test
    func removedSessionIsMarkedEnded() throws {
        let (coordinator, store, _) = try makeCoordinator()
        coordinator.start(initialSessions: [], now: t0)
        coordinator.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        coordinator.sessionsDidChange([], now: t0.addingTimeInterval(5))
        #expect(try SessionHistory(store: store).session(id: "s1")?.status == .ended)
    }

    @Test
    func tickPresentsNextActionAfterDelay() throws {
        let (coordinator, _, _) = try makeCoordinator()
        var presented = 0
        coordinator.presentCard = { presented += 1 }
        coordinator.start(initialSessions: [], now: t0)
        coordinator.createTask(title: "Следующее", column: .todo, projectPath: "/tmp/next")
        coordinator.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        coordinator.tick(now: t0.addingTimeInterval(10))
        #expect(coordinator.card == nil)
        coordinator.tick(now: t0.addingTimeInterval(15))
        guard case let .nextAction(triggering, .startTask(taskID), _) = coordinator.card else {
            Issue.record("expected startTask card, got \(String(describing: coordinator.card))")
            return
        }
        #expect(triggering == "s1")
        #expect(coordinator.board.task(id: taskID)?.title == "Следующее")
        #expect(presented == 1)
    }

    @Test
    func startTaskMovesToInProgressAndLaunchesInProjectPath() throws {
        let (coordinator, _, launcher) = try makeCoordinator()
        coordinator.start(initialSessions: [], now: t0)
        coordinator.createTask(title: "Следующее", column: .todo, projectPath: "/tmp/next")
        let taskID = try #require(coordinator.board.tasks(in: .todo).first?.id)
        coordinator.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        coordinator.tick(now: t0.addingTimeInterval(15))
        coordinator.perform(.startTask(taskID: taskID), now: t0.addingTimeInterval(20))
        #expect(coordinator.board.task(id: taskID)?.boardColumn == .inProgress)
        #expect(launcher.commands == ["cd '/tmp/next' && claude"])
        #expect(coordinator.card == nil)
    }

    @Test
    func nextTaskSkipsToFollowingTodo() throws {
        let (coordinator, _, _) = try makeCoordinator()
        coordinator.start(initialSessions: [], now: t0)
        coordinator.createTask(title: "A", column: .todo, projectPath: nil)
        coordinator.createTask(title: "B", column: .todo, projectPath: nil)
        coordinator.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        coordinator.tick(now: t0.addingTimeInterval(15))
        coordinator.perform(.nextTask, now: t0.addingTimeInterval(16))
        guard case let .nextAction(_, .startTask(taskID), _) = coordinator.card else {
            Issue.record("expected startTask")
            return
        }
        #expect(coordinator.board.task(id: taskID)?.title == "B")
    }

    @Test
    func completedSessionStaysUnseenUntilJump() throws {
        let (coordinator, _, _) = try makeCoordinator()
        var jumped: [String] = []
        coordinator.jumpToSession = { jumped.append($0) }
        coordinator.start(initialSessions: [], now: t0)
        coordinator.sessionsDidChange([session("done", .running, at: t0), session("s1", .running, at: t0)], now: t0)
        coordinator.sessionsDidChange([session("done", .completed, at: t0.addingTimeInterval(1)), session("s1", .running, at: t0)], now: t0.addingTimeInterval(1))
        coordinator.tick(now: t0.addingTimeInterval(15))
        guard case let .nextAction(triggering, action, _) = coordinator.card else {
            Issue.record("expected nextAction card")
            return
        }
        #expect(triggering == "s1")
        #expect(action == .attendSession(sessionID: "done", reason: .unseenCompletion))
        coordinator.perform(.jump(sessionID: "done"), now: t0.addingTimeInterval(16))
        #expect(jumped == ["done"])
        #expect(coordinator.card == nil)
    }

    @Test
    func snoozeSuppressesCardsForSession() throws {
        let (coordinator, _, _) = try makeCoordinator()
        coordinator.start(initialSessions: [], now: t0)
        coordinator.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        coordinator.tick(now: t0.addingTimeInterval(15))
        coordinator.perform(.snooze(sessionID: "s1"), now: t0.addingTimeInterval(16))
        coordinator.sessionsDidChange([session("s1", .completed, at: t0.addingTimeInterval(20))], now: t0.addingTimeInterval(20))
        coordinator.sessionsDidChange([session("s1", .running, at: t0.addingTimeInterval(30), prompt: "p2")], now: t0.addingTimeInterval(30))
        coordinator.tick(now: t0.addingTimeInterval(50))
        #expect(coordinator.card == nil)
    }

    @Test
    func distractionNudgeAppearsAndEpisodeIsLogged() throws {
        let (coordinator, store, _) = try makeCoordinator()
        coordinator.start(initialSessions: [], now: t0)
        coordinator.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        coordinator.frontmostDidChange(FrontmostSample(bundleID: "ru.keepcoder.Telegram", url: nil, at: t0))
        coordinator.frontmostDidChange(FrontmostSample(bundleID: "ru.keepcoder.Telegram", url: nil, at: t0.addingTimeInterval(20)))
        #expect(coordinator.card == .nudge)
        coordinator.frontmostDidChange(FrontmostSample(bundleID: "com.apple.Terminal", url: nil, at: t0.addingTimeInterval(30)))
        #expect(coordinator.card == nil)
        #expect(try DistractionLog(store: store).episodes(since: t0).count == 1)
    }

    @Test
    func bindingFromChipMovesTaskAndClearsPrompt() throws {
        let (coordinator, _, _) = try makeCoordinator()
        coordinator.start(initialSessions: [], now: t0)
        coordinator.createTask(title: "A", column: .todo, projectPath: nil)
        let taskID = try #require(coordinator.board.tasks(in: .todo).first?.id)
        coordinator.sessionsDidChange([session("s1", .running, at: t0)], now: t0)
        coordinator.bind(sessionID: "s1", taskID: taskID)
        #expect(coordinator.pendingBindingSessionIDs.isEmpty)
        #expect(coordinator.board.task(id: taskID)?.boardColumn == .inProgress)
        #expect(coordinator.currentTask?.id == taskID)
    }
}
```

- [ ] **Step 3: Run — FAIL** (`--filter FocusCoordinatorTests`).

- [ ] **Step 4: Реализация — `Sources/OpenIslandApp/Focus/FocusCoordinator.swift`**

```swift
import FocusCore
import Foundation
import Observation
import OpenIslandCore
import os

enum FocusCard: Equatable {
    case nextAction(triggeringSessionID: String, action: NextAction, eventID: Int64?)
    case nudge
}

enum FocusCardAction: Equatable {
    case jump(sessionID: String)
    case startTask(taskID: String)
    case nextTask
    case saveNote(taskID: String, text: String)
    case bindTriggering(taskID: String)
    case quickAdd(title: String)
    case snooze(sessionID: String)
    case dismiss
    case returnToWork
    case allowDistraction
}

@MainActor
@Observable
final class FocusCoordinator {
    static let bindingPromptWindow: TimeInterval = 60
    static let snoozeDuration: TimeInterval = 300
    static let allowDistractionDuration: TimeInterval = 600

    private(set) var board = BoardSnapshot(tasks: [])
    private(set) var liveRecords: [SessionRecord] = []
    private(set) var card: FocusCard?
    private(set) var pendingBindingSessionIDs: [String] = []
    private(set) var storeRecoveredBackupURL: URL?
    var settings: FocusSettings {
        didSet {
            settings.save(to: defaults)
            turnTracker.delay = settings.nextActionDelay
            distractionTracker.threshold = settings.distractionThreshold
        }
    }

    @ObservationIgnored var presentCard: (() -> Void)?
    @ObservationIgnored var jumpToSession: ((String) -> Void)?

    @ObservationIgnored private let store: FocusStore
    @ObservationIgnored private let boardService: BoardService
    @ObservationIgnored private let history: SessionHistory
    @ObservationIgnored private let distractionLog: DistractionLog
    @ObservationIgnored private let nextActionLog: NextActionLog
    @ObservationIgnored private let statsService: StatsService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let launcher: TerminalLaunching
    @ObservationIgnored private let runBackfill: Bool
    @ObservationIgnored private var turnTracker: TurnTracker
    @ObservationIgnored private var distractionTracker: DistractionTracker
    @ObservationIgnored private var latestSessions: [AgentSession] = []
    @ObservationIgnored private var lastObservations: [String: SessionObservation] = [:]
    @ObservationIgnored private var previousPhases: [String: SessionPhase] = [:]
    @ObservationIgnored private var unseenCompleted: Set<String> = []
    @ObservationIgnored private var skippedTaskIDs: Set<String> = []
    @ObservationIgnored private var frontmostBundleID: String?
    @ObservationIgnored private var frontmostSince: Date?
    @ObservationIgnored private var frontmostIsDistracting = false
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "dev.zhanabayev.focusisland", category: "focus")

    init(store: FocusStore, backupURL: URL? = nil, defaults: UserDefaults = .standard, launcher: TerminalLaunching, runBackfill: Bool = true) {
        self.store = store
        self.storeRecoveredBackupURL = backupURL
        self.boardService = BoardService(store: store)
        self.history = SessionHistory(store: store)
        self.distractionLog = DistractionLog(store: store)
        self.nextActionLog = NextActionLog(store: store)
        self.statsService = StatsService(store: store)
        self.defaults = defaults
        self.launcher = launcher
        self.runBackfill = runBackfill
        let settings = FocusSettings.load(from: defaults)
        self.settings = settings
        self.turnTracker = TurnTracker(delay: settings.nextActionDelay)
        self.distractionTracker = DistractionTracker(threshold: settings.distractionThreshold)
    }

    var currentTask: FocusTask? {
        board.currentTask(liveSessions: liveRecords)
    }

    var liveSessionIDs: Set<String> {
        Set(latestSessions.filter { !$0.isSessionEnded }.map(\.id))
    }

    func start(initialSessions: [AgentSession], now: Date = .now) {
        attempt { try history.markAllLiveEnded(except: Set(initialSessions.filter { !$0.isSessionEnded }.map(\.id)), at: now) }
        for session in initialSessions {
            previousPhases[session.id] = session.phase
        }
        reload()
        if runBackfill {
            let store = store
            Task.detached(priority: .utility) {
                _ = try? TranscriptBackfill(store: store).run()
                await MainActor.run { [weak self] in self?.reload() }
            }
        }
    }

    func startTicking() {
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    func sessionsDidChange(_ sessions: [AgentSession], now: Date = .now) {
        let relevant = sessions.filter { !$0.isDemoSession }
        let currentIDs = Set(relevant.map(\.id))
        var changed = false

        for removedID in Set(previousPhases.keys).subtracting(currentIDs) {
            attempt { try history.markEnded(sessionID: removedID, at: now) }
            previousPhases[removedID] = nil
            lastObservations[removedID] = nil
            unseenCompleted.remove(removedID)
            pendingBindingSessionIDs.removeAll { $0 == removedID }
            turnTracker.forget(sessionID: removedID)
            changed = true
        }

        for session in relevant {
            let observation = SessionObservation(session: session)
            let isNew = previousPhases[session.id] == nil && lastObservations[session.id] == nil
            if lastObservations[session.id] != observation {
                attempt { try history.record(observation) }
                lastObservations[session.id] = observation
                changed = true
            }
            if isNew,
               session.isHookManaged,
               session.claudeMetadata?.startupSource != .resume,
               now.timeIntervalSince(session.firstSeenAt) < Self.bindingPromptWindow,
               (try? history.session(id: session.id))??.taskId == nil,
               !pendingBindingSessionIDs.contains(session.id) {
                pendingBindingSessionIDs.append(session.id)
            }
            let previous = previousPhases[session.id]
            if session.phase == .completed && previous != .completed {
                unseenCompleted.insert(session.id)
            } else if session.phase == .running {
                unseenCompleted.remove(session.id)
            }
            previousPhases[session.id] = session.phase
            turnTracker.observe(sessionID: session.id, phase: session.phase, lastUserPrompt: session.claudeMetadata?.lastUserPrompt, at: now)
        }

        latestSessions = relevant
        if changed {
            reloadLiveRecords()
        }
    }

    func tick(now: Date = .now) {
        let due = turnTracker.takeDueSessions(now: now)
        guard settings.nextActionEnabled, card == nil, let triggering = due.first else { return }
        guard FocusPresentationPolicy.shouldPresentNextAction(
            frontmostBundleID: frontmostBundleID,
            frontmostSince: frontmostSince,
            frontmostIsDistracting: frontmostIsDistracting,
            selfBundleID: Bundle.main.bundleIdentifier,
            now: now
        ) else { return }
        skippedTaskIDs = []
        presentNextAction(for: triggering, now: now)
    }

    func perform(_ action: FocusCardAction, now: Date = .now) {
        switch action {
        case let .jump(sessionID):
            markSessionSeen(sessionID)
            jumpToSession?(sessionID)
            closeCard(reacted: true, now: now)
        case let .startTask(taskID):
            guard let task = board.task(id: taskID) else { return closeCard(reacted: false, now: now) }
            attempt { try boardService.moveTask(id: taskID, to: .inProgress, beforeTaskID: nil, now: now) }
            let cwd = task.projectPath ?? triggeringSessionCWD() ?? FileManager.default.homeDirectoryForCurrentUser.path
            attempt { try launcher.run(command: ResumeCommand.newSession(cwd: cwd), in: settings.resumeTerminal) }
            reload()
            closeCard(reacted: true, now: now)
        case .nextTask:
            guard case let .nextAction(triggering, .startTask(taskID), eventID) = card else { return }
            skippedTaskIDs.insert(taskID)
            let next = NextActionEngine.evaluate(nextActionInput(triggering: triggering))
            card = .nextAction(triggeringSessionID: triggering, action: next, eventID: eventID)
        case let .saveNote(taskID, text):
            if var task = board.task(id: taskID) {
                task.note = text
                attempt { try boardService.updateTask(task, now: now) }
                reload()
            }
            closeCard(reacted: true, now: now)
        case let .bindTriggering(taskID):
            guard case let .nextAction(triggering, _, eventID) = card else { return }
            bind(sessionID: triggering, taskID: taskID)
            card = .nextAction(triggeringSessionID: triggering, action: .reflect(sessionID: triggering, taskID: taskID), eventID: eventID)
        case let .quickAdd(title):
            createTask(title: title, column: .todo, projectPath: triggeringSessionCWD())
        case let .snooze(sessionID):
            turnTracker.snooze(sessionID: sessionID, until: now.addingTimeInterval(Self.snoozeDuration))
            closeCard(reacted: false, now: now)
        case .dismiss:
            closeCard(reacted: false, now: now)
        case .returnToWork:
            if let target = latestSessions.filter({ !$0.isSessionEnded }).max(by: { $0.updatedAt < $1.updatedAt }) {
                jumpToSession?(target.id)
            }
            closeCard(reacted: false, now: now)
        case .allowDistraction:
            distractionTracker.suppress(until: now.addingTimeInterval(Self.allowDistractionDuration))
            closeCard(reacted: false, now: now)
        }
    }

    func bind(sessionID: String, taskID: String?) {
        attempt { try boardService.bindSession(sessionID: sessionID, toTaskID: taskID) }
        pendingBindingSessionIDs.removeAll { $0 == sessionID }
        reload()
    }

    func createTaskForSession(sessionID: String) {
        let record = try? history.session(id: sessionID)
        let title = record??.firstPrompt ?? record??.projectName ?? "Новая задача"
        attempt { try boardService.createTaskForSession(sessionID: sessionID, title: title, projectPath: record??.cwd) }
        pendingBindingSessionIDs.removeAll { $0 == sessionID }
        reload()
    }

    func skipBinding(sessionID: String) {
        pendingBindingSessionIDs.removeAll { $0 == sessionID }
    }

    func createTask(title: String, column: BoardColumn, projectPath: String?) {
        attempt { try boardService.createTask(title: title, column: column, projectPath: projectPath) }
        reload()
    }

    func moveTask(id: String, to column: BoardColumn, before beforeTaskID: String?) {
        attempt { try boardService.moveTask(id: id, to: column, beforeTaskID: beforeTaskID) }
        reload()
    }

    func updateTask(_ task: FocusTask) {
        attempt { try boardService.updateTask(task) }
        reload()
    }

    func deleteTask(id: String) {
        attempt { try boardService.deleteTask(id: id) }
        reload()
    }

    func markDone(taskID: String) {
        moveTask(id: taskID, to: .done, before: nil)
    }

    func markSessionSeen(_ sessionID: String) {
        unseenCompleted.remove(sessionID)
    }

    func frontmostDidChange(_ sample: FrontmostSample) {
        if sample.bundleID != frontmostBundleID {
            frontmostBundleID = sample.bundleID
            frontmostSince = sample.at
        }
        frontmostIsDistracting = DistractionClassifier.isDistracting(bundleID: sample.bundleID, url: sample.url, stopList: settings.stopList)
        guard settings.distractionEnabled else { return }
        let anyRunning = latestSessions.contains { $0.phase == .running && !$0.isSessionEnded }
        for event in distractionTracker.observe(sample, anySessionRunning: anyRunning, stopList: settings.stopList) {
            switch event {
            case .nudge:
                if card == nil || card == .nudge {
                    card = .nudge
                    presentCard?()
                }
            case let .episodeEnded(episode):
                attempt { try distractionLog.save(episode) }
                if card == .nudge {
                    card = nil
                }
            }
        }
    }

    func resume(record: SessionRecord) {
        if liveSessionIDs.contains(record.id) {
            jumpToSession?(record.id)
            return
        }
        guard let cwd = record.cwd, FileManager.default.fileExists(atPath: cwd) else { return }
        attempt { try launcher.run(command: ResumeCommand.resume(sessionID: record.id, cwd: cwd), in: settings.resumeTerminal) }
    }

    func canResume(_ record: SessionRecord) -> Bool {
        liveSessionIDs.contains(record.id) || record.cwd.map { FileManager.default.fileExists(atPath: $0) } == true
    }

    func sessions(forTaskID taskID: String) -> [SessionRecord] {
        (try? history.sessions(forTaskID: taskID)) ?? []
    }

    func searchHistory(text: String?, projectPath: String?) -> [SessionRecord] {
        (try? history.search(text: text, projectPath: projectPath, limit: 500)) ?? []
    }

    func recentHistory(limit: Int) -> [SessionRecord] {
        (try? history.recent(limit: limit)) ?? []
    }

    func knownProjectPaths() -> [String] {
        (try? history.knownProjectPaths()) ?? []
    }

    func stats(since: Date) -> FocusStats? {
        try? statsService.stats(since: since)
    }

    func sessionTitle(_ sessionID: String) -> String {
        latestSessions.first { $0.id == sessionID }?.title ?? sessionID
    }

    private func presentNextAction(for triggering: String, now: Date) {
        let action = NextActionEngine.evaluate(nextActionInput(triggering: triggering))
        let eventID = try? nextActionLog.shown(kind: action.kind, at: now)
        card = .nextAction(triggeringSessionID: triggering, action: action, eventID: eventID)
        presentCard?()
    }

    private func nextActionInput(triggering: String) -> NextActionInput {
        let bindings = Dictionary(uniqueKeysWithValues: liveRecords.compactMap { record in record.taskId.map { (record.id, $0) } })
        return NextActionInput(
            triggeringSessionID: triggering,
            sessions: latestSessions,
            unseenCompletedSessionIDs: unseenCompleted,
            board: board,
            sessionTaskBindings: bindings,
            skippedTaskIDs: skippedTaskIDs
        )
    }

    private func triggeringSessionCWD() -> String? {
        guard case let .nextAction(triggering, _, _) = card else { return nil }
        return latestSessions.first { $0.id == triggering }?.jumpTarget?.workingDirectory
    }

    private func closeCard(reacted: Bool, now: Date) {
        if reacted, case let .nextAction(_, _, eventID?) = card {
            attempt { try nextActionLog.reacted(id: eventID, at: now) }
        }
        card = nil
    }

    private func reload() {
        if let snapshot = try? boardService.snapshot() {
            board = snapshot
        }
        reloadLiveRecords()
    }

    private func reloadLiveRecords() {
        liveRecords = (try? history.liveSessions()) ?? []
    }

    private func attempt(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            logger.error("focus operation failed: \(String(describing: error), privacy: .public)")
        }
    }
}
```

Для `isDemoSession` используется `public`-свойство из Task 5.

- [ ] **Step 5: Подключить к `AppModel`**

В `Sources/OpenIslandApp/AppModel.swift`:
1. `import FocusCore`.
2. Рядом с `let hooks = HookInstallationCoordinator()` добавить `let focus: FocusCoordinator`.
3. В `state.didSet` после `bridgeServer.updateStateSnapshot(state)` добавить `focus.sessionsDidChange(state.sessions)`.
4. В `init(...)` до первого использования `state` (сразу после присваивания `self.isNotificationSessionAlreadyFrontmost`) добавить:

```swift
let (focusStore, focusBackup) = FocusStore.openWithRecovery(fileURL: FocusStore.defaultFileURL)
self.focus = FocusCoordinator(store: focusStore, backupURL: focusBackup, launcher: AppleScriptTerminalLauncher())
```

5. В конце `init` (после регистрации остальных колбэков) добавить:

```swift
focus.presentCard = { [weak self] in
    self?.notchOpen(reason: .notification, surface: .sessionList())
}
focus.jumpToSession = { [weak self] sessionID in
    guard let self, let session = self.state.session(id: sessionID) else { return }
    self.jumpToSession(session)
}
```

6. Найти место, где после старта применяется `applyStartupDiscoveryPayload` (`AppModel.swift:1676`), и в конце этой функции вызвать `focus.start(initialSessions: state.sessions)` и `focus.startTicking()`. Если `applyStartupDiscoveryPayload` вызывается несколько раз — защитить флагом `@ObservationIgnored private var focusStarted = false`.
7. В `jumpToSession(_ session:)` (`AppModel.swift:1366`) первой строкой добавить `focus.markSessionSeen(session.id)`.

`AppleScriptTerminalLauncher` реализуется в Task 14; чтобы сборка проходила уже сейчас, добавить в `TerminalLauncher.swift` минимальную реализацию:

```swift
struct AppleScriptTerminalLauncher: TerminalLaunching {
    func run(command: String, in terminal: ResumeTerminal) throws {}
}
```

- [ ] **Step 6: Run — PASS**

Run: `zsh /Users/diaszhanabayev/Projects/own/focus/scripts/test-clt.sh --filter FocusCoordinatorTests` → 13 тестов PASS. Затем полный `zsh scripts/test-clt.sh` → PASS.

- [ ] **Step 7: Ручная проверка backfill**

Запустить dev-приложение, через 60 с выполнить:

```bash
sqlite3 "$HOME/Library/Application Support/FocusIsland/focus.sqlite" "SELECT COUNT(*), SUM(status='live') FROM sessions; SELECT COUNT(*) FROM backfill_files;"
```

Expected: число сессий ≈ числу jsonl в `~/.claude/projects` (без subagents); приложение не подвисало во время импорта.

- [ ] **Step 8: Checkpoint.**

---

### Task 14: Запуск терминала (Resume / новая сессия)

**Files:**
- Modify: `Sources/OpenIslandApp/Focus/TerminalLauncher.swift`

**Interfaces:**
- Consumes: `TerminalLaunching`, `ResumeTerminal`, `AppleScriptQuoting`, `ShellQuoting`.
- Produces: `struct AppleScriptTerminalLauncher: TerminalLaunching`, `enum TerminalLaunchError: Error { scriptFailed(String) }`, `static func script(for:command:) -> String?` (для тестов).

- [ ] **Step 1: Failing test** — добавить в `Tests/OpenIslandAppTests/FocusCoordinatorTests.swift` (отдельный suite):

```swift
struct AppleScriptTerminalLauncherTests {
    @Test
    func terminalScriptQuotesCommand() {
        let script = AppleScriptTerminalLauncher.script(for: .terminal, command: "cd '/tmp/a \"b\"' && claude")
        #expect(script == "tell application \"Terminal\"\nactivate\ndo script \"cd '/tmp/a \\\"b\\\"' && claude\"\nend tell")
    }

    @Test
    func iTermScriptWritesTextIntoNewWindow() {
        let script = AppleScriptTerminalLauncher.script(for: .iTerm, command: "claude")
        #expect(script == "tell application \"iTerm\"\nactivate\nset newWindow to (create window with default profile)\ntell current session of newWindow to write text \"claude\"\nend tell")
    }

    @Test
    func ghosttyHasNoAppleScript() {
        #expect(AppleScriptTerminalLauncher.script(for: .ghostty, command: "claude") == nil)
    }
}
```

- [ ] **Step 2: Run — FAIL** (`--filter AppleScriptTerminalLauncherTests`).

- [ ] **Step 3: Реализация** — заменить заглушку в `TerminalLauncher.swift`:

```swift
import AppKit
import FocusCore
import Foundation

protocol TerminalLaunching: Sendable {
    func run(command: String, in terminal: ResumeTerminal) throws
}

enum TerminalLaunchError: Error {
    case scriptFailed(String)
}

struct AppleScriptTerminalLauncher: TerminalLaunching {
    static func script(for terminal: ResumeTerminal, command: String) -> String? {
        let quoted = AppleScriptQuoting.string(command)
        switch terminal {
        case .terminal:
            return "tell application \"Terminal\"\nactivate\ndo script \(quoted)\nend tell"
        case .iTerm:
            return "tell application \"iTerm\"\nactivate\nset newWindow to (create window with default profile)\ntell current session of newWindow to write text \(quoted)\nend tell"
        case .ghostty:
            return nil
        }
    }

    func run(command: String, in terminal: ResumeTerminal) throws {
        if let source = Self.script(for: terminal, command: command) {
            try MainActor.assumeIsolated {
                var error: NSDictionary?
                NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error {
                    throw TerminalLaunchError.scriptFailed(error.description)
                }
            }
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-na", "Ghostty", "--args", "-e", "/bin/zsh", "-lc", "\(command); exec /bin/zsh -l"]
        try process.run()
    }
}
```

Вызов `run` всегда идёт из `FocusCoordinator` (`@MainActor`), поэтому `MainActor.assumeIsolated` корректен.

- [ ] **Step 4: Run — PASS** (`--filter AppleScriptTerminalLauncherTests`, 3 теста).

- [ ] **Step 5: Checkpoint.** Ручная проверка запуска терминала — в Task 15 Step 5 («Начать» из карточки) и Task 18 Step 4 (Resume).

---

### Task 15: Island UI — карточки, чип привязки, список задач, текущая задача

**Files:**
- Create: `Sources/OpenIslandApp/Focus/Views/FocusIslandSection.swift`
- Modify: `Sources/OpenIslandApp/Views/IslandPanelView.swift` (`openedContent`, ~строка 443), `Sources/OpenIslandApp/AppModelTypes.swift` (`IslandRightSlot`, `IslandCenterLabel`), `Sources/OpenIslandApp/AppModel.swift` (`islandClosedRightSlotContent`, ~строка 923), `Sources/OpenIslandApp/Views/V6NotchContent.swift` (`IslandRightSlotContent`, `V6RightSlotView`, центр-лейбл)

**Interfaces:**
- Consumes: `FocusCoordinator` (`card`, `perform`, `pendingBindingSessionIDs`, `bind`, `createTaskForSession`, `skipBinding`, `board`, `currentTask`, `markDone`, `createTask`, `sessionTitle`, `recentHistory`, `resume`, `canResume`), `AppModel.focus`, `BoardWindowController.shared.show(model:)` (Task 17 — до неё кнопка «Доска» вызывает `NotificationCenter.default.post(name: .focusOpenBoard, object: nil)`).
- Produces: `struct FocusIslandSection: View`, `extension Notification.Name { static let focusOpenBoard }`, `IslandRightSlot.currentTask`, `IslandCenterLabel.currentTask`, `IslandRightSlotContent.text(String)`.

- [ ] **Step 1: Секция в раскрытом island** — `Sources/OpenIslandApp/Focus/Views/FocusIslandSection.swift`:

```swift
import FocusCore
import SwiftUI

extension Notification.Name {
    static let focusOpenBoard = Notification.Name("focus.openBoard")
}

struct FocusIslandSection: View {
    @Bindable var focus: FocusCoordinator
    @State private var quickAddText = ""
    @State private var noteText = ""
    @State private var showsRecent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let card = focus.card {
                cardView(card)
            }
            ForEach(focus.pendingBindingSessionIDs.prefix(1), id: \.self) { sessionID in
                bindingChip(sessionID)
            }
            tasksList
            recentSessions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func cardView(_ card: FocusCard) -> some View {
        switch card {
        case let .nextAction(triggering, action, _):
            nextActionCard(triggering: triggering, action: action)
        case .nudge:
            nudgeCard
        }
    }

    private func nextActionCard(triggering: String, action: NextAction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Что дальше?").font(.headline)
            switch action {
            case let .attendSession(sessionID, reason):
                Text(attentionText(reason, title: focus.sessionTitle(sessionID))).font(.subheadline)
                HStack {
                    Button("Перейти") { focus.perform(.jump(sessionID: sessionID)) }.keyboardShortcut(.defaultAction)
                    snoozeButtons(triggering)
                }
            case let .startTask(taskID):
                Text(focus.board.task(id: taskID)?.title ?? "").font(.subheadline)
                HStack {
                    Button("Начать") { focus.perform(.startTask(taskID: taskID)) }.keyboardShortcut(.defaultAction)
                    Button("Следующая") { focus.perform(.nextTask) }
                    snoozeButtons(triggering)
                }
            case let .reflect(_, taskID):
                if let taskID, let task = focus.board.task(id: taskID) {
                    Text("Пока Claude работает над «\(task.title)»: что сделаешь после этого шага?").font(.subheadline)
                    TextField("Заметка", text: $noteText, axis: .vertical).lineLimit(1...3)
                    HStack {
                        Button("Сохранить") { focus.perform(.saveNote(taskID: taskID, text: noteText)); noteText = "" }
                        snoozeButtons(triggering)
                    }
                } else {
                    Text("Сессия не привязана к задаче").font(.subheadline)
                    taskPicker { focus.perform(.bindTriggering(taskID: $0)) }
                    snoozeButtons(triggering)
                }
                quickAddField
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
    }

    private var nudgeCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Claude работает — ты отвлёкся").font(.headline)
            if let task = focus.currentTask {
                Text("Текущая задача: \(task.title)").font(.subheadline)
            }
            if let next = focus.board.tasks(in: .todo).first {
                Text("Дальше: \(next.title)").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Вернуться") { focus.perform(.returnToWork) }.keyboardShortcut(.defaultAction)
                Button("Мне это нужно (10 мин)") { focus.perform(.allowDistraction) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.orange.opacity(0.15)))
    }

    private func bindingChip(_ sessionID: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Привязать «\(focus.sessionTitle(sessionID))» к задаче?").font(.caption)
            HStack {
                taskPicker { focus.bind(sessionID: sessionID, taskID: $0) }
                Button("Новая задача…") { focus.createTaskForSession(sessionID: sessionID) }
                Button("Пропустить") { focus.skipBinding(sessionID: sessionID) }
            }
            .controlSize(.small)
        }
    }

    private func taskPicker(onSelect: @escaping (String) -> Void) -> some View {
        Menu("Задача") {
            ForEach(focus.board.tasks(in: .inProgress) + focus.board.tasks(in: .todo)) { task in
                Button(task.title) { onSelect(task.id) }
            }
        }
        .fixedSize()
    }

    private func snoozeButtons(_ triggering: String) -> some View {
        HStack {
            Button("Отложить 5 мин") { focus.perform(.snooze(sessionID: triggering)) }
            Button("Закрыть") { focus.perform(.dismiss) }
        }
        .controlSize(.small)
    }

    private var quickAddField: some View {
        HStack {
            TextField("+ задача в Todo", text: $quickAddText)
                .onSubmit(addQuickTask)
            Button("Добавить", action: addQuickTask).disabled(quickAddText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .controlSize(.small)
    }

    private func addQuickTask() {
        let title = quickAddText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if focus.card == nil {
            focus.createTask(title: title, column: .todo, projectPath: nil)
        } else {
            focus.perform(.quickAdd(title: title))
        }
        quickAddText = ""
    }

    private var tasksList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Задачи").font(.caption.bold())
                Spacer()
                Button("Доска ⌥⌘B") { NotificationCenter.default.post(name: .focusOpenBoard, object: nil) }
                    .controlSize(.small)
            }
            ForEach((focus.board.tasks(in: .inProgress) + focus.board.tasks(in: .todo)).prefix(6)) { task in
                HStack {
                    Image(systemName: task.boardColumn == .inProgress ? "circle.lefthalf.filled" : "circle")
                    Text(task.title).lineLimit(1)
                    Spacer()
                    Button("Готово") { focus.markDone(taskID: task.id) }.controlSize(.mini)
                }
                .font(.caption)
            }
            if focus.card == nil {
                quickAddField
            }
        }
    }

    private var recentSessions: some View {
        DisclosureGroup("Недавние сессии", isExpanded: $showsRecent) {
            ForEach(focus.recentHistory(limit: 10)) { record in
                HStack {
                    Text(record.title).lineLimit(1)
                    Spacer()
                    Button(focus.liveSessionIDs.contains(record.id) ? "Jump" : "Resume") { focus.resume(record: record) }
                        .disabled(!focus.canResume(record))
                        .controlSize(.mini)
                }
                .font(.caption)
            }
        }
        .font(.caption)
    }

    private func attentionText(_ reason: AttentionReason, title: String) -> String {
        switch reason {
        case .approval: "«\(title)» ждёт разрешения"
        case .question: "«\(title)» задал вопрос"
        case .unseenCompletion: "«\(title)» закончил — посмотри результат"
        }
    }
}
```

- [ ] **Step 2: Встроить в `IslandPanelView.openedContent`**

В `Sources/OpenIslandApp/Views/IslandPanelView.swift` в `private var openedContent` (~строка 443) найти контейнер, в котором вызывается `sessionListContent(referenceDate:)` (обе ветки — notification mode ~строка 558 и ScrollView ~строка 584), и в обеих ветках вставить `FocusIslandSection(focus: model.focus)` непосредственно перед `sessionListContent(referenceDate: referenceDate)`. Кнопка «Доска» до Task 17 только постит уведомление.

- [ ] **Step 3: Текущая задача в свёрнутом island**

- `AppModelTypes.swift`: в `IslandRightSlot` добавить `case currentTask` (первым кейсом) и сделать его значением по умолчанию: `var rightSlot: IslandRightSlot = .currentTask` (строка 57). В `IslandCenterLabel` добавить `case currentTask`.
- `V6NotchContent.swift`: в `IslandRightSlotContent` добавить `case text(String)`; в `V6RightSlotView.body` ветку:

```swift
case .text(let value):
    Text(value)
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: 140, alignment: .trailing)
```

  и в `V6RightSlotView.intrinsicWidth(of:)` для `.text(value)` вернуть `min(140, CGFloat(value.count) * 6.5)`. В `RightSlotKey` добавить соответствующий кейс, если компилятор потребует.
- `AppModel.islandClosedRightSlotContent()`: ветка

```swift
case .currentTask:
    guard let title = focus.currentTask?.title else { return nil }
    return .text(title)
```

- Центр-лейбл: в месте, где обрабатывается `IslandCenterLabel` (найти `case .sessionName` в `AppModel`/`V6NotchContent`), добавить `case .currentTask: return focus.currentTask?.title`.
- `AppearanceSettingsPane`: в пикерах правого слота и центр-лейбла появятся новые кейсы; подписи — «Текущая задача».

- [ ] **Step 4: Сборка и тесты**

Run: `swift build --package-path /Users/diaszhanabayev/Projects/own/focus && zsh /Users/diaszhanabayev/Projects/own/focus/scripts/test-clt.sh` → PASS. Тесты апстрима, проверяющие значение по умолчанию `rightSlot == .count` (`AgentsGridRightSlotTests`, `V6ClosedPillTests`), обновить на `.currentTask` либо явно задавать `.count` в тесте.

- [ ] **Step 5: Ручная проверка**

Запустить dev-приложение, раскрыть island: видна секция «Задачи», поле «+ задача в Todo» добавляет задачу; запустить `claude` → появляется чип привязки; выбрать задачу → в свёрнутом island справа виден её заголовок. Дать Claude долгую задачу («прочитай все файлы в Sources и кратко опиши каждый») → через ~15 с island раскрывается с «Что дальше?».

- [ ] **Step 6: Checkpoint.**

---

### Task 16: FrontmostAppMonitor

**Files:**
- Create: `Sources/OpenIslandApp/Focus/FrontmostAppMonitor.swift`
- Modify: `Sources/OpenIslandApp/AppModel.swift` (создание и старт монитора)

**Interfaces:**
- Consumes: `FocusCoordinator.frontmostDidChange(_:)`, `FocusCoordinator.settings.distractionEnabled`, `FocusCoordinator.liveSessionIDs`, `KnownApps.browsers`, `AppleScriptQuoting`.
- Produces: `@MainActor final class FrontmostAppMonitor { init(focus:); start(); stop(); static func browserURLScript(for bundleID: String) -> String? }`

- [ ] **Step 1: Failing test** — добавить suite в `Tests/OpenIslandAppTests/FocusCoordinatorTests.swift`:

```swift
struct FrontmostAppMonitorTests {
    @Test
    func browserScriptsCoverSupportedBrowsers() {
        #expect(FrontmostAppMonitor.browserURLScript(for: "com.apple.Safari") == "tell application id \"com.apple.Safari\" to if (count of documents) > 0 then return URL of front document")
        #expect(FrontmostAppMonitor.browserURLScript(for: "com.google.Chrome") == "tell application id \"com.google.Chrome\" to if (count of windows) > 0 then return URL of active tab of front window")
        #expect(FrontmostAppMonitor.browserURLScript(for: "company.thebrowser.Browser") == "tell application id \"company.thebrowser.Browser\" to if (count of windows) > 0 then return URL of active tab of front window")
        #expect(FrontmostAppMonitor.browserURLScript(for: "com.apple.Terminal") == nil)
    }
}
```

- [ ] **Step 2: Run — FAIL** (`--filter FrontmostAppMonitorTests`).

- [ ] **Step 3: Реализация** — `Sources/OpenIslandApp/Focus/FrontmostAppMonitor.swift`:

```swift
import AppKit
import FocusCore
import Foundation

@MainActor
final class FrontmostAppMonitor {
    static let pollInterval: TimeInterval = 5

    private let focus: FocusCoordinator
    private var activationObserver: NSObjectProtocol?
    private var timer: Timer?

    init(focus: FocusCoordinator) {
        self.focus = focus
    }

    static func browserURLScript(for bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.Safari":
            "tell application id \"com.apple.Safari\" to if (count of documents) > 0 then return URL of front document"
        case "com.google.Chrome", "company.thebrowser.Browser":
            "tell application id \"\(bundleID)\" to if (count of windows) > 0 then return URL of active tab of front window"
        default:
            nil
        }
    }

    func start() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        guard focus.settings.distractionEnabled,
              let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        var url: URL?
        if !focus.liveSessionIDs.isEmpty, let source = Self.browserURLScript(for: bundleID) {
            var error: NSDictionary?
            if let value = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue {
                url = URL(string: value)
            }
        }
        focus.frontmostDidChange(FrontmostSample(bundleID: bundleID, url: url, at: .now))
    }
}
```

URL браузера запрашивается только когда есть живые сессии — системный промпт Automation не всплывает, пока пользователь не работает с Claude.

- [ ] **Step 4: Подключить** — в `AppModel`:
- свойство `@ObservationIgnored private var frontmostMonitor: FrontmostAppMonitor?`;
- там же, где вызывается `focus.startTicking()` (Task 13 Step 5.6): `frontmostMonitor = FrontmostAppMonitor(focus: focus); frontmostMonitor?.start()`.

- [ ] **Step 5: Run — PASS** (`--filter FrontmostAppMonitorTests`) и полный прогон.

- [ ] **Step 6: Ручная проверка**

Запустить долгую задачу Claude, открыть youtube.com в Chrome на 25 с → разрешить Automation в системном диалоге → island показывает «Claude работает — ты отвлёкся». Нажать «Вернуться» → фокус в терминале. Проверить запись:

```bash
sqlite3 "$HOME/Library/Application Support/FocusIsland/focus.sqlite" "SELECT appBundleID, domain, nudged, returnedWithinSec FROM distraction_episodes ORDER BY id DESC LIMIT 1;"
```

Expected: `com.google.Chrome|youtube.com|1|<число>`.

- [ ] **Step 7: Checkpoint.**

---

### Task 17: Окно доски, drag & drop, детали задачи, хоткей

**Files:**
- Create: `Sources/OpenIslandApp/Focus/BoardWindowController.swift`, `Sources/OpenIslandApp/Focus/GlobalHotKey.swift`, `Sources/OpenIslandApp/Focus/Views/BoardView.swift`, `Sources/OpenIslandApp/Focus/Views/TaskDetailView.swift`
- Modify: `Sources/OpenIslandApp/AppModel.swift` (хоткей и подписка на `.focusOpenBoard`)

**Interfaces:**
- Consumes: `FocusCoordinator` (`board`, `createTask`, `moveTask(id:to:before:)`, `updateTask`, `deleteTask`, `sessions(forTaskID:)`, `knownProjectPaths`, `resume`, `canResume`, `liveSessionIDs`, `settings.boardHotKey`).
- Produces: `@MainActor final class BoardWindowController { static let shared; func show(focus:) }`, `@MainActor final class GlobalHotKey { init(hotKey:action:); func update(_:) }`, `struct BoardView`, `struct TaskDetailView`, `struct BoardRootView` (TabView; вкладки История/Статистика заполняются в Task 18 — в этой задаче показывать только доску).

- [ ] **Step 1: Окно** — `Sources/OpenIslandApp/Focus/BoardWindowController.swift`:

```swift
import AppKit
import SwiftUI

@MainActor
final class BoardWindowController {
    static let shared = BoardWindowController()

    private var window: NSWindow?

    func show(focus: FocusCoordinator) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Focus Island — доска"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: BoardRootView(focus: focus))
            window.center()
            window.setFrameAutosaveName("FocusBoardWindow")
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
```

- [ ] **Step 2: Хоткей** — `Sources/OpenIslandApp/Focus/GlobalHotKey.swift`:

```swift
import Carbon
import FocusCore
import Foundation

@MainActor
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: @MainActor () -> Void

    init(hotKey: BoardHotKey, action: @escaping @MainActor () -> Void) {
        self.action = action
        installHandler()
        update(hotKey)
    }

    func update(_ hotKey: BoardHotKey) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        let modifiers: UInt32
        switch hotKey {
        case .optionCommandB: modifiers = UInt32(optionKey | cmdKey)
        case .controlOptionB: modifiers = UInt32(controlKey | optionKey)
        case .off: return
        }
        let id = EventHotKeyID(signature: OSType(0x46_4F_43_53), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_B), modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &spec, context, &handlerRef)
    }
}
```

- [ ] **Step 3: Доска** — `Sources/OpenIslandApp/Focus/Views/BoardView.swift`:

```swift
import FocusCore
import SwiftUI

struct BoardRootView: View {
    @Bindable var focus: FocusCoordinator

    var body: some View {
        TabView {
            BoardView(focus: focus).tabItem { Text("Доска") }
        }
        .frame(minWidth: 900, minHeight: 520)
    }
}

struct BoardView: View {
    @Bindable var focus: FocusCoordinator
    @State private var projectFilter: String?
    @State private var editingTask: FocusTask?
    @State private var showsArchive = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Проект", selection: $projectFilter) {
                    Text("Все проекты").tag(String?.none)
                    ForEach(focus.knownProjectPaths(), id: \.self) { path in
                        Text(URL(fileURLWithPath: path).lastPathComponent).tag(String?.some(path))
                    }
                }
                .frame(maxWidth: 280)
                Spacer()
                Toggle("Архив Done", isOn: $showsArchive)
            }
            .padding(10)
            Divider()
            HStack(alignment: .top, spacing: 12) {
                ForEach(BoardColumn.allCases) { column in
                    BoardColumnView(
                        focus: focus,
                        column: column,
                        tasks: visibleTasks(in: column),
                        onOpen: { editingTask = $0 }
                    )
                }
            }
            .padding(12)
        }
        .sheet(item: $editingTask) { task in
            TaskDetailView(focus: focus, task: task)
        }
    }

    private func visibleTasks(in column: BoardColumn) -> [FocusTask] {
        var tasks = focus.board.tasks(in: column)
        if let projectFilter {
            tasks = tasks.filter { $0.projectPath == projectFilter }
        }
        if column == .done && !showsArchive {
            let cutoff = Date.now.addingTimeInterval(-7 * 86_400)
            tasks = tasks.filter { ($0.doneAt ?? .distantPast) >= cutoff }
        }
        return tasks
    }
}

struct BoardColumnView: View {
    @Bindable var focus: FocusCoordinator
    let column: BoardColumn
    let tasks: [FocusTask]
    let onOpen: (FocusTask) -> Void
    @State private var newTitle = ""
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(column.title) · \(tasks.count)").font(.headline)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(tasks) { task in
                        TaskCardView(focus: focus, task: task)
                            .onTapGesture(count: 2) { onOpen(task) }
                            .draggable(task.id)
                            .dropDestination(for: String.self) { ids, _ in
                                guard let id = ids.first, id != task.id else { return false }
                                focus.moveTask(id: id, to: column, before: task.id)
                                return true
                            }
                    }
                }
            }
            TextField("+ задача", text: $newTitle)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    focus.createTask(title: newTitle, column: column, projectPath: nil)
                    newTitle = ""
                }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10).fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08)))
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            focus.moveTask(id: id, to: column, before: nil)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

struct TaskCardView: View {
    @Bindable var focus: FocusCoordinator
    let task: FocusTask

    var body: some View {
        let sessions = focus.sessions(forTaskID: task.id)
        let hasLive = sessions.contains { focus.liveSessionIDs.contains($0.id) }
        VStack(alignment: .leading, spacing: 4) {
            Text(task.title).font(.body).lineLimit(3)
            HStack(spacing: 6) {
                if let path = task.projectPath {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .background(Capsule().fill(Color.secondary.opacity(0.2)))
                }
                if !sessions.isEmpty {
                    Label("\(sessions.count)", systemImage: "terminal").font(.caption2)
                }
                if hasLive {
                    Circle().fill(.green).frame(width: 6, height: 6)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
}
```

- [ ] **Step 4: Детали задачи** — `Sources/OpenIslandApp/Focus/Views/TaskDetailView.swift`:

```swift
import FocusCore
import SwiftUI

struct TaskDetailView: View {
    @Bindable var focus: FocusCoordinator
    @State var task: FocusTask
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Заголовок", text: $task.title).font(.title3)
            Picker("Колонка", selection: $task.boardColumn) {
                ForEach(BoardColumn.allCases) { Text($0.title).tag($0) }
            }
            Picker("Проект", selection: $task.projectPath) {
                Text("Без проекта").tag(String?.none)
                ForEach(focus.knownProjectPaths(), id: \.self) { path in
                    Text(path).tag(String?.some(path))
                }
            }
            Text("Описание").font(.caption)
            TextEditor(text: Binding(get: { task.details ?? "" }, set: { task.details = $0.isEmpty ? nil : $0 }))
                .frame(minHeight: 80)
            Text("Заметка").font(.caption)
            TextEditor(text: Binding(get: { task.note ?? "" }, set: { task.note = $0.isEmpty ? nil : $0 }))
                .frame(minHeight: 50)
            Text("Сессии").font(.caption)
            List(focus.sessions(forTaskID: task.id)) { record in
                HStack {
                    VStack(alignment: .leading) {
                        Text(record.title).lineLimit(1)
                        Text(record.lastActivityAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(focus.liveSessionIDs.contains(record.id) ? "Jump" : "Resume") { focus.resume(record: record) }
                        .disabled(!focus.canResume(record))
                }
            }
            .frame(minHeight: 100)
            HStack {
                Button("Удалить", role: .destructive) { confirmsDelete = true }
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить") {
                    let original = focus.board.task(id: task.id)
                    if original?.boardColumn != task.boardColumn {
                        focus.moveTask(id: task.id, to: task.boardColumn, before: nil)
                        var refreshed = focus.board.task(id: task.id) ?? task
                        refreshed.title = task.title
                        refreshed.details = task.details
                        refreshed.note = task.note
                        refreshed.projectPath = task.projectPath
                        focus.updateTask(refreshed)
                    } else {
                        focus.updateTask(task)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(task.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520, height: 600)
        .confirmationDialog("Удалить задачу? Сессии останутся в истории.", isPresented: $confirmsDelete) {
            Button("Удалить", role: .destructive) {
                focus.deleteTask(id: task.id)
                dismiss()
            }
        }
    }
}
```

- [ ] **Step 5: Подключить в `AppModel`**

Свойство `@ObservationIgnored private var boardHotKey: GlobalHotKey?` и `@ObservationIgnored private var openBoardObserver: NSObjectProtocol?`. Там же, где стартует Focus (Task 13 Step 5.6):

```swift
boardHotKey = GlobalHotKey(hotKey: focus.settings.boardHotKey) { [weak self] in
    guard let self else { return }
    BoardWindowController.shared.show(focus: self.focus)
}
openBoardObserver = NotificationCenter.default.addObserver(forName: .focusOpenBoard, object: nil, queue: .main) { [weak self] _ in
    MainActor.assumeIsolated {
        guard let self else { return }
        BoardWindowController.shared.show(focus: self.focus)
    }
}
```

Обновление хоткея при смене настройки — в Task 19.

- [ ] **Step 6: Сборка + ручная проверка**

`swift build` → OK; полный прогон тестов → PASS. В dev-приложении ⌥⌘B открывает доску; создать задачи в каждой колонке; перетащить карточку между колонками и внутри колонки — порядок сохраняется после перезапуска; двойной клик открывает детали; удаление задачи с привязанной сессией оставляет сессию в «Недавних сессиях» island.

- [ ] **Step 7: Checkpoint.**

---

### Task 18: История и статистика в окне доски

**Files:**
- Create: `Sources/OpenIslandApp/Focus/Views/HistoryView.swift`, `Sources/OpenIslandApp/Focus/Views/StatsView.swift`
- Modify: `Sources/OpenIslandApp/Focus/Views/BoardView.swift` (`BoardRootView` — добавить вкладки)

**Interfaces:**
- Consumes: `FocusCoordinator.searchHistory(text:projectPath:)`, `knownProjectPaths()`, `resume(record:)`, `canResume(_:)`, `liveSessionIDs`, `board.task(id:)`, `stats(since:)`.
- Produces: `struct HistoryView`, `struct StatsView`.

- [ ] **Step 1: `HistoryView.swift`**

```swift
import FocusCore
import SwiftUI

struct HistoryView: View {
    @Bindable var focus: FocusCoordinator
    @State private var query = ""
    @State private var projectFilter: String?

    var body: some View {
        let records = focus.searchHistory(text: query, projectPath: projectFilter)
        let groups = Dictionary(grouping: records) { Calendar.current.startOfDay(for: $0.lastActivityAt) }
        VStack(spacing: 0) {
            HStack {
                TextField("Поиск по заголовку и промптам", text: $query).textFieldStyle(.roundedBorder)
                Picker("Проект", selection: $projectFilter) {
                    Text("Все проекты").tag(String?.none)
                    ForEach(focus.knownProjectPaths(), id: \.self) { path in
                        Text(URL(fileURLWithPath: path).lastPathComponent).tag(String?.some(path))
                    }
                }
                .frame(maxWidth: 260)
            }
            .padding(10)
            List {
                ForEach(groups.keys.sorted(by: >), id: \.self) { day in
                    Section(day.formatted(date: .complete, time: .omitted)) {
                        ForEach(groups[day] ?? []) { record in
                            HistoryRow(focus: focus, record: record)
                        }
                    }
                }
            }
        }
    }
}

struct HistoryRow: View {
    @Bindable var focus: FocusCoordinator
    let record: SessionRecord

    var body: some View {
        let isLive = focus.liveSessionIDs.contains(record.id)
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).font(.body).lineLimit(1)
                if let prompt = record.lastPrompt ?? record.firstPrompt {
                    Text(prompt).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 8) {
                    if let project = record.projectName { Text(project) }
                    Text(record.lastActivityAt.formatted(date: .omitted, time: .shortened))
                    if let task = focus.board.task(id: record.taskId) { Text("· \(task.title)") }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(isLive ? "Jump" : "Resume") { focus.resume(record: record) }
                .disabled(!focus.canResume(record))
                .help(focus.canResume(record) ? "" : "Папка проекта больше не существует")
        }
        .padding(.vertical, 2)
    }
}
```

- [ ] **Step 2: `StatsView.swift`**

```swift
import FocusCore
import SwiftUI

struct StatsView: View {
    @Bindable var focus: FocusCoordinator

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            column(title: "Сегодня", stats: focus.stats(since: Calendar.current.startOfDay(for: .now)))
            column(title: "7 дней", stats: focus.stats(since: .now.addingTimeInterval(-7 * 86_400)))
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func column(title: String, stats: FocusStats?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3.bold())
            if let stats {
                row("Задач закрыто", "\(stats.tasksDone)")
                row("Сессий запущено", "\(stats.sessionsStarted)")
                row("Сессий с задачей", stats.boundShare.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                row("Отвлечений", "\(stats.distractionCount)")
                row("Время отвлечений", Duration.seconds(stats.distractionSeconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                row("Реакция на «Что дальше?»", stats.medianReactionSec.map { "\(Int($0.rounded())) с" } ?? "—")
            } else {
                Text("Нет данных").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 260, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit().bold()
        }
    }
}
```

- [ ] **Step 3: Вкладки** — в `BoardRootView.body`:

```swift
TabView {
    BoardView(focus: focus).tabItem { Text("Доска") }
    HistoryView(focus: focus).tabItem { Text("История") }
    StatsView(focus: focus).tabItem { Text("Статистика") }
}
.frame(minWidth: 900, minHeight: 520)
```

- [ ] **Step 4: Сборка + ручная проверка**

`swift build` → OK. Вкладка «История» показывает сессии, импортированные backfill, сгруппированные по дням; поиск по кириллице работает; Resume для завершённой сессии открывает Terminal с `cd '<cwd>' && claude --resume '<id>'` и Claude поднимает старый контекст. Вкладка «Статистика» показывает числа без падений на пустой базе.

- [ ] **Step 5: Checkpoint.**

---

### Task 19: Вкладка настроек Focus

**Files:**
- Create: `Sources/OpenIslandApp/Focus/Views/FocusSettingsPane.swift`
- Modify: `Sources/OpenIslandApp/Views/SettingsView.swift` (`SettingsTab.focus` первым кейсом, иконка `"target"`, цвет `.green`, заголовок «Focus»), `Sources/OpenIslandApp/AppModel.swift` (реакция на смену хоткея)

**Interfaces:**
- Consumes: `FocusCoordinator.settings`, `storeRecoveredBackupURL`, `GlobalHotKey.update(_:)`.
- Produces: `struct FocusSettingsPane: View`.

- [ ] **Step 1: Панель**

```swift
import FocusCore
import SwiftUI

struct FocusSettingsPane: View {
    @Bindable var focus: FocusCoordinator
    @State private var appsText = ""
    @State private var domainsText = ""

    var body: some View {
        Form {
            if let backup = focus.storeRecoveredBackupURL {
                Text("База Focus была повреждена и пересоздана. Копия: \(backup.path)")
                    .foregroundStyle(.orange)
            }
            Section("Что дальше?") {
                Toggle("Показывать подсказку, пока Claude работает", isOn: $focus.settings.nextActionEnabled)
                Stepper("Через \(Int(focus.settings.nextActionDelay)) с", value: $focus.settings.nextActionDelay, in: 5...120, step: 5)
            }
            Section("Отвлечения") {
                Toggle("Замечать отвлечения", isOn: $focus.settings.distractionEnabled)
                Stepper("Порог \(Int(focus.settings.distractionThreshold)) с", value: $focus.settings.distractionThreshold, in: 5...300, step: 5)
                Toggle("Звук напоминания", isOn: $focus.settings.nudgeSoundEnabled)
                Text("Приложения (bundle id, по одному в строке)").font(.caption)
                TextEditor(text: $appsText).frame(minHeight: 60)
                Text("Домены (по одному в строке)").font(.caption)
                TextEditor(text: $domainsText).frame(minHeight: 100)
                HStack {
                    Button("Сохранить стоп-лист") {
                        focus.settings.stopList = StopList(appBundleIDs: lines(appsText), domains: lines(domainsText))
                    }
                    Button("По умолчанию") {
                        focus.settings.stopList = .default
                        loadStopList()
                    }
                }
                Text("Для чтения адреса вкладки Safari/Chrome/Arc нужно разрешение «Автоматизация» в Системных настройках → Конфиденциальность. Без него учитываются только приложения.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Терминал и доска") {
                Picker("Терминал для Resume", selection: $focus.settings.resumeTerminal) {
                    ForEach(ResumeTerminal.allCases) { Text($0.title).tag($0) }
                }
                Picker("Хоткей доски", selection: $focus.settings.boardHotKey) {
                    ForEach(BoardHotKey.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadStopList)
    }

    private func loadStopList() {
        appsText = focus.settings.stopList.appBundleIDs.joined(separator: "\n")
        domainsText = focus.settings.stopList.domains.joined(separator: "\n")
    }

    private func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }
}
```

Bundle ID приводятся к нижнему регистру — а сравнение в `DistractionClassifier` чувствительно к регистру. Поэтому в `lines` для приложений регистр сохранять: заменить для `appsText` вызов на отдельную функцию без `.lowercased()`:

```swift
private func appLines(_ text: String) -> [String] {
    text.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}
```

и использовать `StopList(appBundleIDs: appLines(appsText), domains: lines(domainsText))`.

- [ ] **Step 2: Подключить в `SettingsView`** — добавить `case focus` в `SettingsTab`, его ветки в `title`/`icon`/`color` и в `switch` контента: `FocusSettingsPane(focus: model.focus)`. Сделать `.focus` вкладкой по умолчанию при открытии настроек.

- [ ] **Step 3: Хоткей реагирует на настройку** — в `FocusCoordinator` добавить `@ObservationIgnored var onSettingsChanged: ((FocusSettings) -> Void)?` и вызывать его в конце `settings.didSet`. В `AppModel` при старте Focus: `focus.onSettingsChanged = { [weak self] settings in self?.boardHotKey?.update(settings.boardHotKey) }`.

- [ ] **Step 4: Звук nudge** — в `FocusCoordinator.frontmostDidChange` в ветке `.nudge` после `presentCard?()` добавить `if settings.nudgeSoundEnabled { NSSound.beep() }` (`import AppKit`).

- [ ] **Step 5: Сборка, тесты, ручная проверка** — `swift build`, полный `test-clt.sh` → PASS. В настройках изменить задержку на 5 с → «Что дальше?» появляется быстрее; сменить хоткей на ⌃⌥B → доска открывается новым сочетанием, старое не работает; добавить домен `lenta.ru` → сайт считается отвлечением.

- [ ] **Step 6: Checkpoint.**

---

### Task 20: Сквозной smoke S1–S6 и документация

**Files:**
- Modify: `README.md` (кратко: что это, установка dev-сборки, лицензия GPL v3, ссылка на апстрим)
- Create: `docs/focus-smoke.md` (чек-лист ниже с отметками результата)

**Interfaces:**
- Consumes: всё выше.
- Produces: заполненный чек-лист smoke-проверки.

- [ ] **Step 1: Полный прогон**

```bash
swift build --package-path /Users/diaszhanabayev/Projects/own/focus
zsh /Users/diaszhanabayev/Projects/own/focus/scripts/test-clt.sh
zsh /Users/diaszhanabayev/Projects/own/focus/scripts/launch-dev-app.sh
```

Expected: всё зелёное, приложение запущено.

- [ ] **Step 2: Чек-лист** (в `docs/focus-smoke.md`, отметить каждый пункт ✅/❌ с комментарием):

1. S1: ⌥⌘B → создать по задаче в Backlog/Todo; «+» в island добавляет в Todo; drag & drop между колонками сохраняется после перезапуска.
2. S2: `claude` в новом терминале → чип «Привязать к задаче?»; выбор задачи из Todo переносит её в In progress; в свёрнутом island справа — её заголовок.
3. S3: долгий промпт → через 15 с карточка «Что дальше?» с задачей из Todo; «Следующая» листает; «Начать» открывает новый терминал в папке проекта и запускает `claude`.
4. S3b: две сессии; вторая просит разрешение, пока первая работает → карточка первой сессии предлагает «Перейти» ко второй.
5. S4: во время работы Claude 25 с в Telegram/YouTube → nudge; «Вернуться» переключает в терминал; эпизод в `distraction_episodes`.
6. S5: вкладка История → старая завершённая сессия → Resume → открывается терминал с `claude --resume`, контекст восстановлен.
7. S6: перетащить задачу в Done → в Статистике «Задач закрыто» увеличилось; детали задачи показывают все её сессии.
8. Перезапуск приложения при живой сессии `claude` → сессия остаётся live, чип привязки повторно не появляется.
9. Остановить приложение, поработать с `claude`, запустить снова → новые сессии появились в Истории (backfill).

- [ ] **Step 3: README** — заменить верх README на описание Focus Island (3–5 абзацев, на русском): назначение, как собрать (`zsh scripts/launch-dev-app.sh`), установка хуков из Settings → Setup, данные в `~/Library/Application Support/FocusIsland/`, форк open-vibe-island под GPL v3.

- [ ] **Step 4: Checkpoint** — `git -C /Users/diaszhanabayev/Projects/own/focus status`; сообщить пользователю, что работа готова к коммиту по его команде.
