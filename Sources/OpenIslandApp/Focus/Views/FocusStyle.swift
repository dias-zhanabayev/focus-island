import FocusCore
import OpenIslandCore
import SwiftUI

extension Color {
    init(focusHex hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

enum FocusStyle {
    static let accent = Color(focusHex: 0x0064E0)
    static let working = Color(focusHex: 0x30D158)
    static let waiting = Color(focusHex: 0xFF9F0A)
    static let waitingText = Color(focusHex: 0xFFB340)
    static let done = Color(focusHex: 0x64D2FF)
    static let distraction = Color(focusHex: 0xFF453A)
    static let link = Color(focusHex: 0x64A8FF)
    static let removed = Color(focusHex: 0xFF6B60)
    static let primaryText = Color(focusHex: 0xF5F5F7)
    static let secondaryText = Color(focusHex: 0xA1A1A6)
    static let captionText = Color(focusHex: 0x8E8E93)
    static let tagText = Color(focusHex: 0xC7C7CC)
    static let surface = Color.white.opacity(0.06)
    static let hairline = Color.white.opacity(0.1)
    static let buttonFill = Color.white.opacity(0.12)

    static let cardRadius: CGFloat = 14
    static let rowRadius: CGFloat = 12
    static let buttonRadius: CGFloat = 7
    static let smallRadius: CGFloat = 10
    static let chipRadius: CGFloat = 9

    static let captionFont = Font.system(size: 11, weight: .semibold)
    static let secondaryFont = Font.system(size: 12)
    static let titleFont = Font.system(size: 17, weight: .bold)
    static let monoFont = Font.system(size: 12, design: .monospaced)

    static func phaseColor(_ phase: SessionPhase) -> Color {
        switch phase {
        case .running: working
        case .waitingForApproval, .waitingForAnswer: waiting
        case .completed: done
        }
    }
}

enum FocusText {
    static let cardMessageLimit = 240
    static let rowMessageLimit = 60

    nonisolated static func truncated(_ text: String, limit: Int) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    nonisolated static func minutes(_ seconds: TimeInterval) -> Int {
        max(0, Int(seconds / 60))
    }

    nonisolated static func roundedUpMinutes(_ seconds: TimeInterval) -> Int {
        max(1, Int((seconds / 60).rounded(.up)))
    }

    nonisolated static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct FocusSectionCaption: View {
    let text: String
    var color: Color = FocusStyle.captionText

    init(_ text: String, color: Color = FocusStyle.captionText) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(FocusStyle.captionFont)
            .tracking(0.5)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}

struct PlanProgressBar: View {
    let progress: PlanProgress
    var width: CGFloat?
    var color: Color = FocusStyle.working

    nonisolated static func fraction(_ progress: PlanProgress) -> Double {
        guard progress.total > 0 else { return 0 }
        return min(1, max(0, Double(progress.completed) / Double(progress.total)))
    }

    var body: some View {
        let fraction = Self.fraction(progress)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().fill(color).frame(width: geo.size.width * fraction)
            }
        }
        .frame(width: width, height: 4)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .accessibilityElement()
        .accessibilityLabel("Прогресс плана")
        .accessibilityValue("\(progress.completed) из \(progress.total)")
    }
}

struct ProjectTag: View {
    let name: String

    init(_ name: String) {
        self.name = name
    }

    var body: some View {
        Text(name)
            .font(.system(size: 11))
            .foregroundStyle(FocusStyle.tagText)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.white.opacity(0.1)))
    }
}

struct FocusButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case quiet
        case done
        case waiting
        case rest
    }

    let kind: Kind
    var height: CGFloat = 30
    var horizontalPadding: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: FocusStyle.buttonRadius).fill(background))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: FocusStyle.buttonRadius))
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .secondary: FocusStyle.primaryText
        case .quiet: FocusStyle.secondaryText
        case .done: FocusStyle.working
        case .waiting: FocusStyle.waitingText
        case .rest: .black
        }
    }

    private var background: Color {
        switch kind {
        case .primary: FocusStyle.accent
        case .secondary: FocusStyle.buttonFill
        case .quiet: .clear
        case .done: FocusStyle.working.opacity(0.16)
        case .waiting: FocusStyle.waiting.opacity(0.14)
        case .rest: FocusStyle.working
        }
    }
}

struct FocusBox<Content: View>: View {
    var fill: Color = FocusStyle.surface
    var border: Color?
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: FocusStyle.cardRadius).fill(fill))
            .overlay {
                if let border {
                    RoundedRectangle(cornerRadius: FocusStyle.cardRadius).stroke(border, lineWidth: 1)
                }
            }
    }
}

struct CriteriaChecklist: View {
    @Bindable var focus: FocusCoordinator
    let taskID: String
    var allowsAdd = true
    var doneColor: Color = FocusStyle.working
    @State private var newText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(focus.criteria(taskID: taskID)) { criterion in
                HStack(spacing: 10) {
                    Button {
                        focus.perform(.toggleCriterion(id: criterion.id))
                    } label: {
                        Image(systemName: criterion.done ? "checkmark.square.fill" : "square")
                            .font(.system(size: 15))
                            .foregroundStyle(criterion.done ? doneColor : FocusStyle.captionText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(criterion.text)
                    .accessibilityValue(criterion.done ? "выполнено" : "не выполнено")
                    Text(criterion.text)
                        .font(.system(size: 13))
                        .foregroundStyle(criterion.done ? FocusStyle.secondaryText : FocusStyle.primaryText)
                        .strikethrough(criterion.done)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        focus.perform(.deleteCriterion(id: criterion.id))
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(FocusStyle.captionText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Удалить пункт")
                }
            }
            if allowsAdd {
                HStack(spacing: 10) {
                    TextField("+ добавить пункт", text: $newText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .onSubmit(add)
                        .padding(.leading, 25)
                }
            }
        }
    }

    private func add() {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        focus.perform(.addCriterion(taskID: taskID, text: text))
        newText = ""
    }
}
