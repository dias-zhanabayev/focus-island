import FocusCore
import SwiftUI

struct FocusSettingsPane: View {
    @Bindable var focus: FocusCoordinator
    var hooksInstalled = false
    var hooksConfigPath: String?
    var install: () -> Void = {}
    var uninstall: () -> Void = {}
    @State private var confirmingUninstall = false
    @State private var appsText = ""
    @State private var domainsText = ""

    static let maxParallelRange = FocusSettings.maxParallelRange
    static let stalledReminderRange = FocusSettings.stalledReminderRange

    nonisolated static func hooksTitle(installed: Bool) -> String {
        installed ? "Хуки Claude Code установлены" : "Хуки Claude Code не установлены"
    }

    nonisolated static func hooksPathText(path: String, home: String) -> String {
        if path == home { return "~" }
        let prefix = home.hasSuffix("/") ? home : home + "/"
        return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
    }

    nonisolated static func hooksActionTitle(installed: Bool) -> String {
        installed ? "Удалить хуки" : "Установить хуки"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: hooksInstalled ? "checkmark" : "exclamationmark.triangle")
                        .foregroundStyle(hooksInstalled ? FocusStyle.working : FocusStyle.waiting)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.hooksTitle(installed: hooksInstalled)).fontWeight(.semibold)
                        if hooksInstalled, let hooksConfigPath {
                            Text(Self.hooksPathText(path: hooksConfigPath, home: FileManager.default.homeDirectoryForCurrentUser.path))
                                .font(FocusStyle.secondaryFont)
                                .foregroundStyle(FocusStyle.secondaryText)
                        }
                    }
                    Spacer()
                    Button(Self.hooksActionTitle(installed: hooksInstalled)) {
                        if hooksInstalled { confirmingUninstall = true } else { install() }
                    }
                }
            }
            if let backup = focus.storeRecoveredBackupURL {
                Text("База Focus была повреждена и пересоздана. Копия: \(backup.path)")
                    .foregroundStyle(.orange)
            }
            if focus.storeIsInMemoryFallback {
                Text("Не удалось открыть базу Focus — изменения не сохранятся после выхода")
                    .foregroundStyle(.orange)
            }
            Section("Что дальше?") {
                Toggle("Показывать подсказку, пока Claude работает", isOn: $focus.settings.nextActionEnabled)
                Stepper("Через \(Int(focus.settings.nextActionDelay)) с", value: $focus.settings.nextActionDelay, in: 5...120, step: 5)
            }
            Section("Сессии") {
                Stepper("Комфортно держу параллельно: \(focus.settings.maxParallelSessions)", value: $focus.settings.maxParallelSessions, in: Self.maxParallelRange)
                Stepper("Напомнить о ждущей сессии через \(focus.settings.stalledReminderMinutes) мин", value: $focus.settings.stalledReminderMinutes, in: Self.stalledReminderRange)
                Toggle("Утренний экран «Начало дня»", isOn: $focus.settings.dayStartEnabled)
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
                        focus.settings.stopList = StopList(appBundleIDs: appLines(appsText), domains: lines(domainsText))
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
        .confirmationDialog("Удалить хуки Claude Code?", isPresented: $confirmingUninstall) {
            Button("Удалить хуки", role: .destructive, action: uninstall)
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Focus Island перестанет получать события Claude Code.")
        }
        .onAppear(perform: loadStopList)
    }

    private func loadStopList() {
        appsText = focus.settings.stopList.appBundleIDs.joined(separator: "\n")
        domainsText = focus.settings.stopList.domains.joined(separator: "\n")
    }

    private func appLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { line -> String in
                var value = line.trimmingCharacters(in: .whitespaces).lowercased()
                if value.hasPrefix("www.") { value.removeFirst(4) }
                while value.hasSuffix(".") { value.removeLast() }
                return value
            }
            .filter { !$0.isEmpty }
    }
}
