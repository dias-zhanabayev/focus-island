import FocusCore
import SwiftUI

enum SessionDoneFormat {
    nonisolated static func showsDoneButton(group: HubGroup) -> Bool {
        group == .idle || group == .review
    }

    nonisolated static func sectionTitle(count: Int, expanded: Bool) -> String {
        "Готовые · \(count) " + (expanded ? "▾" : "▸")
    }

    nonisolated static func noticeText(_ title: String) -> String {
        "«\(title)» готова"
    }
}

struct DoneSessionItem: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String?
}

struct SessionDoneButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Готово", systemImage: "checkmark")
        }
        .buttonStyle(FocusButtonStyle(kind: .done, height: 28))
        .accessibilityLabel("Сессия готова")
    }
}

struct SessionMoreMenu: View {
    @Bindable var focus: FocusCoordinator
    let sessionID: String
    let taskID: String

    var body: some View {
        Menu {
            Button("✓ Сессия готова") { focus.markSessionDone(sessionID: sessionID) }
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
                Text("Все сессии задачи готовы")
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
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(FocusStyle.working)
                .accessibilityHidden(true)
            HStack(spacing: 4) {
                Text(item.title)
                    .font(.system(size: 13))
                    .foregroundStyle(FocusStyle.secondaryText)
                if let detail = item.detail {
                    Text("· " + detail)
                        .font(FocusStyle.secondaryFont)
                        .foregroundStyle(FocusStyle.captionText)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Вернуть") { onReopen(item.id) }
                .buttonStyle(FocusButtonStyle(kind: .quiet, height: 26, horizontalPadding: 8))
            if let onOpen {
                Button("Открыть") { onOpen(item.id) }
                    .buttonStyle(FocusButtonStyle(kind: .secondary, height: 26))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: FocusStyle.smallRadius)
                .stroke(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }
}
