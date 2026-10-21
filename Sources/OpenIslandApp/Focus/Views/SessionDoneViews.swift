import FocusCore
import SwiftUI

enum SessionDoneFormat {
    nonisolated static func showsDoneCheck(group: HubGroup) -> Bool {
        switch group {
        case .waiting, .review, .running, .idle: true
        case .unbound, .parked, .done: false
        }
    }

    nonisolated static func confirmsDone(group: HubGroup) -> Bool {
        group == .running || group == .waiting
    }

    nonisolated static let doneHelp = "Завершить сессию: она сделала своё в задаче. Уйдёт в «Завершённые», время и история останутся. Напишешь в неё — вернётся."

    nonisolated static func sectionTitle(count: Int, expanded: Bool) -> String {
        "Завершённые · \(count) " + (expanded ? "▾" : "▸")
    }

    nonisolated static func noticeText(_ title: String) -> String {
        "«\(title)» завершена"
    }
}

enum SessionStatusKind: Equatable {
    case running
    case waiting
    case yourTurn
    case ended
    case parked

    nonisolated static func of(_ group: HubGroup) -> SessionStatusKind? {
        switch group {
        case .running: .running
        case .waiting: .waiting
        case .review, .idle: .yourTurn
        case .done: .ended
        case .parked: .parked
        case .unbound: nil
        }
    }

    nonisolated var title: String {
        switch self {
        case .running: "Работает"
        case .waiting: "Ждёт ответа"
        case .yourTurn: "Твой ход"
        case .ended: "Завершена"
        case .parked: "На паузе"
        }
    }

    var color: Color {
        switch self {
        case .running: FocusStyle.working
        case .waiting: FocusStyle.waitingText
        case .yourTurn: FocusStyle.link
        case .ended, .parked: FocusStyle.secondaryText
        }
    }

    var showsDot: Bool {
        switch self {
        case .running, .waiting, .yourTurn: true
        case .ended, .parked: false
        }
    }
}

struct SessionStatusBadge: View {
    let kind: SessionStatusKind

    var body: some View {
        HStack(spacing: 6) {
            if kind.showsDot {
                Circle().fill(kind.color).frame(width: 7, height: 7)
            }
            Text(kind.title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(kind.color)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(kind.showsDot ? kind.color.opacity(0.15) : Color.white.opacity(0.08)))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Статус: \(kind.title)")
    }
}

struct DoneSessionItem: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String?
}

struct SessionDoneCheck: View {
    let group: HubGroup
    let action: () -> Void
    @State private var hovering = false
    @State private var confirming = false

    var body: some View {
        Button {
            if SessionDoneFormat.confirmsDone(group: group) {
                confirming = true
            } else {
                action()
            }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(hovering ? FocusStyle.working : Color.white.opacity(0.35), lineWidth: 1.5)
                if hovering {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(FocusStyle.working)
                }
            }
            .frame(width: 20, height: 20)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(SessionDoneFormat.doneHelp)
        .accessibilityLabel("Завершить сессию")
        .confirmationDialog("Claude ещё не закончил. Всё равно завершить сессию?", isPresented: $confirming) {
            Button("Завершить", action: action)
            Button("Отмена", role: .cancel) {}
        }
    }
}

struct SessionReopenCheck: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(FocusStyle.working)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color(focusHex: 0x08240F))
            }
            .frame(width: 20, height: 20)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Вернуть сессию в активные")
        .accessibilityLabel("Вернуть сессию")
    }
}

struct SessionMoreMenu: View {
    @Bindable var focus: FocusCoordinator
    let sessionID: String
    let taskID: String

    var body: some View {
        Menu {
            Button("Завершить сессию") { focus.markSessionDone(sessionID: sessionID) }
            Button("Отвязать от задачи") { focus.bind(sessionID: sessionID, taskID: nil) }
            let targets = focus.moveTargets(excludingTaskID: taskID)
            if !targets.isEmpty {
                Menu("Перенести в другую задачу") {
                    ForEach(targets) { target in
                        Button(target.title) { focus.bind(sessionID: sessionID, taskID: target.id) }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FocusStyle.secondaryText)
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Ещё")
    }
}

struct DoneSessionNoticeBanner: View {
    let notice: DoneSessionNotice
    let onReopen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(FocusStyle.working)
                .accessibilityHidden(true)
            Text(SessionDoneFormat.noticeText(notice.title))
                .font(FocusStyle.secondaryFont)
                .foregroundStyle(FocusStyle.tagText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Вернуть", action: onReopen)
                .buttonStyle(FocusButtonStyle(kind: .quiet, height: 24, horizontalPadding: 6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: FocusStyle.smallRadius).fill(FocusStyle.working.opacity(0.12)))
    }
}

struct BoundSessionNoticeBanner: View {
    let onUnbind: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(FocusStyle.working)
                .accessibilityHidden(true)
            Text("Новая сессия в задаче")
                .font(FocusStyle.secondaryFont)
                .foregroundStyle(FocusStyle.tagText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Отвязать", action: onUnbind)
                .buttonStyle(FocusButtonStyle(kind: .quiet, height: 24, horizontalPadding: 6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: FocusStyle.smallRadius).fill(FocusStyle.working.opacity(0.12)))
    }
}

struct AllSessionsDoneCard: View {
    let onClose: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(FocusStyle.working)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Все сессии задачи завершены")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FocusStyle.primaryText)
                Text("Закрыть задачу или открыть новую сессию?")
                    .font(FocusStyle.secondaryFont)
                    .foregroundStyle(FocusStyle.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) {
                Label("Закрыть задачу", systemImage: "checkmark")
            }
            .buttonStyle(FocusButtonStyle(kind: .done, height: 28))
            Button("Не сейчас", action: onDismiss)
                .buttonStyle(FocusButtonStyle(kind: .quiet, height: 28, horizontalPadding: 6))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: FocusStyle.rowRadius)
                .fill(FocusStyle.working.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: FocusStyle.rowRadius).stroke(FocusStyle.working.opacity(0.3), lineWidth: 1))
        )
    }
}

struct DoneSessionsSection: View {
    let items: [DoneSessionItem]
    let onReopen: (String) -> Void
    var onOpen: ((String) -> Void)?
    @State private var expanded = false

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    FocusSectionCaption(SessionDoneFormat.sectionTitle(count: items.count, expanded: expanded))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    ForEach(items) { item in
                        row(item)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private func row(_ item: DoneSessionItem) -> some View {
        HStack(spacing: 8) {
            SessionReopenCheck { onReopen(item.id) }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FocusStyle.secondaryText)
                    .strikethrough(true, color: Color.white.opacity(0.35))
                if let detail = item.detail {
                    Text(detail)
                        .font(FocusStyle.secondaryFont)
                        .foregroundStyle(FocusStyle.captionText)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            SessionStatusBadge(kind: .ended)
            if let onOpen {
                Button("Перейти") { onOpen(item.id) }
                    .buttonStyle(FocusButtonStyle(kind: .quiet, height: 26, horizontalPadding: 8))
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: FocusStyle.smallRadius).fill(Color.white.opacity(0.03)))
    }
}
