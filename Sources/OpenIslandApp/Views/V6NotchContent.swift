import SwiftUI
import FocusCore
import OpenIslandCore

/// Per-cell state for the closed-island agents grid. Drives tile rendering:
/// running = full color, idle = dim, waiting = opacity pulse.
enum AgentGridCellState: Equatable {
    case running
    case idle
    case waiting
}

/// One cell in the closed-island agents grid. `.session` carries the agent
/// tool's brand color and its current state. `.overflow` is a single trailing
/// cell shown when there are more sessions than the grid can display.
enum AgentGridCell: Equatable {
    case session(color: Color, state: AgentGridCellState)
    case overflow(Int)
}

/// Concrete payload for the closed island's right slot. The `AppModel`
/// computes one of these from live session state according to the user's
/// `islandRightSlot` preference; the view side is agnostic to which
/// setting produced it.
enum IslandRightSlotContent: Equatable {
    case count(Int)              // "×N" badge
    case agents([AgentGridCell]) // balanced grid, one tile per session
    case text(String)
    case alert(String)
    case hint(String)
    case status(String)
    case startFocus(Int)
}

struct PomodoroEar: Equatable, Sendable {
    let phase: PomodoroPhase
    let remainingSeconds: Int
    let progress: Double
    let isPaused: Bool
}

indirect enum IslandLeftSlotContent: Equatable {
    case focusSummary(running: Int, waiting: Int, done: Int)
    case progress(String)
    case pomodoro(PomodoroEar, base: IslandLeftSlotContent?)
    case waitingOutside(Int, quiet: Bool)
}

enum FocusEars {
    nonisolated static func leftSlot(rows: [HubRow]) -> IslandLeftSlotContent? {
        let live = rows.filter { !$0.group.isSettled }
        if live.count >= 2 {
            return .focusSummary(
                running: live.filter { $0.group == .running }.count,
                waiting: live.filter { $0.group == .waiting }.count,
                done: live.filter { $0.group == .review }.count
            )
        }
        guard let progress = live.first?.progress, progress.total > 0 else { return nil }
        let step = min(progress.total, progress.completed + 1)
        return .progress("шаг \(step)/\(progress.total)")
    }

    nonisolated static func leftSlot(preference: IslandRightSlot, rows: [HubRow]) -> IslandLeftSlotContent? {
        guard preference != .none else { return nil }
        return leftSlot(rows: rows)
    }

    nonisolated static func leftSlot(preference: IslandRightSlot, rows: [HubRow], pomodoro: PomodoroSnapshot?) -> IslandLeftSlotContent? {
        guard preference != .none else { return nil }
        let base = leftSlot(rows: rows)
        guard let pomodoro else { return base }
        let ear = PomodoroEar(
            phase: pomodoro.phase,
            remainingSeconds: pomodoro.remainingSeconds,
            progress: pomodoro.progress,
            isPaused: pomodoro.isPaused
        )
        return .pomodoro(ear, base: base)
    }

    nonisolated static func leftSlot(preference: IslandRightSlot, rows: [HubRow], pomodoro: PomodoroSnapshot?, waitingOutside: Int) -> IslandLeftSlotContent? {
        guard waitingOutside > 0 else { return leftSlot(preference: preference, rows: rows, pomodoro: pomodoro) }
        guard preference != .none else { return nil }
        guard let pomodoro else { return .waitingOutside(waitingOutside, quiet: false) }
        let ear = PomodoroEar(
            phase: pomodoro.phase,
            remainingSeconds: pomodoro.remainingSeconds,
            progress: pomodoro.progress,
            isPaused: pomodoro.isPaused
        )
        return .pomodoro(ear, base: .waitingOutside(waitingOutside, quiet: true))
    }

    nonisolated static func yourTurnText(_ count: Int) -> String {
        "\(count) твой ход"
    }

    nonisolated static func waitingOutsideText(_ count: Int, quiet: Bool) -> String {
        quiet ? "\(count)" : "\(count) ждут"
    }

    nonisolated static func clickShowsWaitingOutside(leftSlot: IslandLeftSlotContent?) -> Bool {
        switch leftSlot {
        case .waitingOutside?: true
        case let .pomodoro(_, base)?: clickShowsWaitingOutside(leftSlot: base)
        default: false
        }
    }

    nonisolated static func pomodoroText(_ ear: PomodoroEar) -> String {
        switch ear.phase {
        case .focus: return PomodoroFormat.timerText(remainingSeconds: ear.remainingSeconds)
        case .break: return "Перерыв \(FocusText.clock(TimeInterval(ear.remainingSeconds)))"
        }
    }

    nonisolated static func taskSlot(
        taskTitle: String?,
        elapsedMinutes: Int?,
        todoCount: Int,
        isOnBreak: Bool,
        runningCount: Int,
        pomodoroActive: Bool = false,
        inProgressCount: Int = 0,
        focusMinutes: Int? = nil,
        newSessionPending: Bool = false
    ) -> IslandRightSlotContent? {
        if isOnBreak && runningCount > 0 {
            return .status("Claude работает · \(runningCount)")
        }
        guard taskTitle != nil else {
            if pomodoroActive { return nil }
            if newSessionPending { return .hint(newSessionHint) }
            if todoCount > 0 { return .hint("Выбрать задачу · Todo \(todoCount)") }
            return .hint(inProgressCount > 0 ? "Выбрать задачу" : "Доска пуста")
        }
        if !pomodoroActive, let focusMinutes {
            return .startFocus(focusMinutes)
        }
        return rightSlot(toast: nil, stalled: nil, taskTitle: taskTitle, elapsedMinutes: elapsedMinutes)
    }

    nonisolated static func animationKey(_ content: IslandLeftSlotContent?) -> String {
        switch content {
        case nil:
            return ""
        case let .focusSummary(running, waiting, done)?:
            return "summary:\(running):\(waiting):\(done)"
        case let .progress(value)?:
            return "progress:\(value)"
        case let .pomodoro(ear, base)?:
            return "pomodoro:\(ear.phase):\(ear.isPaused)|" + animationKey(base)
        case let .waitingOutside(count, quiet)?:
            return "waiting:\(count):\(quiet)"
        }
    }

    nonisolated static func clickOpensPickTask(rightSlot: IslandRightSlotContent?) -> Bool {
        if case .hint? = rightSlot { return true }
        return false
    }

    nonisolated static func clickStartsFocus(rightSlot: IslandRightSlotContent?) -> Int? {
        if case let .startFocus(minutes)? = rightSlot { return minutes }
        return nil
    }

    nonisolated static func startFocusText(_ minutes: Int) -> String {
        "▶ Фокус \(minutes)"
    }

    nonisolated static func opensIsland(after result: PickTaskOpenResult) -> Bool {
        result != .openedBoard
    }

    nonisolated static func alertOverride(
        preference: IslandRightSlot,
        toast: String?,
        stalled: StalledBadge?,
        card: FocusCard? = nil,
        breakCountdown: Int? = nil,
        breakMinutes: Int = 10,
        focusMinutes: Int = 50
    ) -> IslandRightSlotContent? {
        guard preference != .none else { return nil }
        if let toast { return .alert(toast) }
        if let slot = pomodoroCardSlot(card, breakCountdown: breakCountdown, breakMinutes: breakMinutes, focusMinutes: focusMinutes) { return slot }
        guard stalled != nil else { return nil }
        return rightSlot(toast: nil, stalled: stalled, taskTitle: nil, elapsedMinutes: nil)
    }

    nonisolated static func pomodoroCardSlot(_ card: FocusCard?, breakCountdown: Int?, breakMinutes: Int, focusMinutes: Int) -> IslandRightSlotContent? {
        switch card {
        case .pomodoroEnd?:
            if let breakCountdown { return .alert("☕ Перерыв через \(breakCountdown)") }
            return .alert("☕ Перерыв \(breakMinutes)")
        case .breakEnd?:
            return .startFocus(focusMinutes)
        default:
            return nil
        }
    }

    nonisolated static let newSessionHint = "✦ Новая сессия · задача?"

    nonisolated static func rightSlot(
        toast: String?,
        stalled: StalledBadge?,
        taskTitle: String?,
        elapsedMinutes: Int?
    ) -> IslandRightSlotContent? {
        if let toast { return .alert(toast) }
        if let stalled { return .alert("\(stalled.title) ждёт \(stalled.minutes)м") }
        guard let taskTitle else { return nil }
        if let elapsedMinutes, elapsedMinutes > 0 {
            return .text("\(taskTitle) · \(elapsedMinutes)м")
        }
        return .text(taskTitle)
    }
}

// MARK: - Right-slot renderers

struct V6RightSlotView: View {
    let content: IslandRightSlotContent

    var body: some View {
        switch content {
        case .count(let n):
            Text("×\(n)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(V6Palette.paper.opacity(0.72))
        case .agents(let cells):
            AgentsGridBody(cells: cells)
        case .text(let value):
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 140, alignment: .trailing)
                .foregroundStyle(V6Palette.paper.opacity(0.72))
        case .alert(let value):
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: V6RightSlotView.alertMaxWidth, alignment: .trailing)
                .foregroundStyle(FocusStyle.waitingText)
        case .hint(let value):
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .underline(color: FocusStyle.secondaryText.opacity(0.4))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: V6RightSlotView.alertMaxWidth, alignment: .trailing)
                .foregroundStyle(FocusStyle.secondaryText)
        case .startFocus(let minutes):
            Text(FocusEars.startFocusText(minutes))
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(FocusStyle.link)
                .accessibilityLabel("Начать фокус \(minutes) минут")
        case .status(let value):
            HStack(spacing: 6) {
                Circle().fill(FocusStyle.working).frame(width: 6, height: 6)
                Text(value)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(FocusStyle.secondaryText)
            }
            .frame(maxWidth: V6RightSlotView.alertMaxWidth, alignment: .trailing)
        }
    }

    static let alertMaxWidth: CGFloat = 170

    /// Intrinsic width used by the fluid-layout math. Values are slightly
    /// padded beyond the raw text measurement so the pill always reserves
    /// enough room for the `.fixedSize()` content to render on one line,
    /// without HStack compression forcing a wrap.
    static func intrinsicWidth(of content: IslandRightSlotContent) -> CGFloat {
        switch content {
        case .count(let n):
            let digits = Double(max(1, String(n).count))
            // "×" + digits at 11pt mono ≈ 7.2pt/char.
            return CGFloat(14.4 + max(0.0, digits - 1.0) * 7.2)
        case .text(let value):
            return min(140, CGFloat(value.count) * 6.5)
        case .alert(let value), .hint(let value):
            return min(alertMaxWidth, CGFloat(value.count) * 6.5)
        case .status(let value):
            return min(alertMaxWidth, 12 + CGFloat(value.count) * 6.5)
        case .startFocus(let minutes):
            return CGFloat(FocusEars.startFocusText(minutes).count) * 6.8
        case .agents(let cells):
            let n = cells.count
            guard n > 0 else { return 0 }
            let rows = balancedRows(n)
            let maxRow = rows.max() ?? 0
            let geom = cellGeometry(rowCount: rows.count)
            return CGFloat(maxRow) * geom.cell + CGFloat(max(0, maxRow - 1)) * geom.gap
        }
    }

    // MARK: Balanced layout algorithm
    //
    // For each n from 1 to 9, we hand-tune the per-row cell counts so the
    // matrix reads as a deliberate shape instead of a wrap-at-4-columns grid.
    // For n >= 10 the AppModel caps the list at 7 sessions + 1 overflow cell,
    // which lays out as [4,4] — so balancedRows(8) is what actually renders
    // for all high-count cases in production.
    static func balancedRows(_ n: Int) -> [Int] {
        switch n {
        case ..<1: return []
        case 1: return [1]
        case 2: return [2]
        case 3: return [3]
        case 4: return [2, 2]
        case 5: return [3, 2]
        case 6: return [3, 3]
        case 7: return [4, 3]
        case 8: return [4, 4]
        case 9: return [3, 3, 3]
        default: return [4, 4]
        }
    }

    /// Cell size shrinks when the matrix has 3 rows so total height still
    /// fits inside the pill's internal vertical budget (~20pt).
    static func cellGeometry(rowCount: Int) -> (cell: CGFloat, gap: CGFloat, radius: CGFloat) {
        if rowCount >= 3 { return (cell: 6, gap: 1.5, radius: 1.0) }
        return (cell: 8, gap: 2, radius: 1.5)
    }

    static func splitIntoRows(_ cells: [AgentGridCell], rowSizes: [Int]) -> [[AgentGridCell]] {
        var out: [[AgentGridCell]] = []
        var idx = 0
        for size in rowSizes {
            let end = min(idx + size, cells.count)
            out.append(Array(cells[idx..<end]))
            idx = end
            if idx >= cells.count { break }
        }
        return out
    }
}

struct V6LeftSlotView: View {
    let content: IslandLeftSlotContent

    var body: some View {
        switch content {
        case .progress(let value):
            HStack(spacing: 4) {
                Circle().fill(FocusStyle.working).frame(width: 6, height: 6)
                Text(value)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(V6Palette.paper.opacity(0.72))
            }
            .fixedSize()
        case .focusSummary(let running, let waiting, let done):
            HStack(spacing: 4) {
                Circle().fill(FocusStyle.working).frame(width: 6, height: 6)
                Text("\(running)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(V6Palette.paper.opacity(0.72))
                if waiting > 0 {
                    Circle()
                        .stroke(FocusStyle.waiting, lineWidth: 1.5)
                        .frame(width: 8, height: 8)
                        .padding(.leading, 4)
                    Text("\(waiting) ждёт")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(FocusStyle.waitingText)
                }
                if done > 0 {
                    Circle()
                        .fill(FocusStyle.link)
                        .frame(width: 6, height: 6)
                        .padding(.leading, 4)
                    Text(FocusEars.yourTurnText(done))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(FocusStyle.link)
                }
            }
            .lineLimit(1)
            .fixedSize()
        case .pomodoro(let ear, let base):
            HStack(spacing: 8) {
                PomodoroEarTimerView(ear: ear)
                if let base {
                    V6LeftSlotView(content: base)
                }
            }
            .fixedSize()
        case .waitingOutside(let count, let quiet):
            HStack(spacing: 4) {
                Circle()
                    .stroke(quiet ? FocusStyle.captionText : FocusStyle.waiting, lineWidth: 1.5)
                    .frame(width: 7, height: 7)
                Text(FocusEars.waitingOutsideText(count, quiet: quiet))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(quiet ? FocusStyle.captionText : FocusStyle.waitingText)
            }
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel("Ждут вне задачи: \(count)")
        }
    }

    static func timerWidth(of ear: PomodoroEar) -> CGFloat {
        let text = CGFloat(FocusEars.pomodoroText(ear).count) * 7
        switch ear.phase {
        case .focus: return 18 + text
        case .break: return text
        }
    }

    static let pomodoroMaxWidth: CGFloat = 240

    static func intrinsicWidth(of content: IslandLeftSlotContent) -> CGFloat {
        switch content {
        case .pomodoro(let ear, let base):
            let timer = timerWidth(of: ear)
            guard let base else { return timer }
            return min(pomodoroMaxWidth, timer + 8 + intrinsicWidth(of: base))
        case .progress(let value):
            return min(V6RightSlotView.alertMaxWidth, CGFloat(value.count) * 6.5 + 10)
        case .waitingOutside(let count, let quiet):
            return 12 + CGFloat(FocusEars.waitingOutsideText(count, quiet: quiet).count) * 6.8
        case .focusSummary(let running, let waiting, let done):
            var width: CGFloat = 10 + CGFloat(String(running).count) * 7
            if waiting > 0 {
                width += 16 + CGFloat("\(waiting) ждёт".count) * 6.5
            }
            if done > 0 {
                width += 14 + CGFloat(FocusEars.yourTurnText(done).count) * 6.5
            }
            return min(V6RightSlotView.alertMaxWidth, width)
        }
    }
}

struct PomodoroEarTimerView: View {
    let ear: PomodoroEar

    var body: some View {
        HStack(spacing: 4) {
            if ear.phase == .focus {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.2), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: max(0, min(1, ear.progress)))
                        .stroke(FocusStyle.link, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
            }
            Text(FocusEars.pomodoroText(ear))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(ear.phase == .focus ? FocusStyle.link : FocusStyle.working)
        }
        .lineLimit(1)
        .opacity(ear.isPaused ? 0.5 : 1)
        .fixedSize()
    }
}

// MARK: - Agents grid body

/// V1a Dense Grid renderer. 2D matrix of 8×8 rounded squares (6×6 when 3 rows),
/// each row horizontally centered around the widest row. Running = full color,
/// idle = 22% alpha, waiting = opacity 0.35 ↔ 1 breathing pulse.
private struct AgentsGridBody: View {
    let cells: [AgentGridCell]

    var body: some View {
        let rowSizes = V6RightSlotView.balancedRows(cells.count)
        let geom = V6RightSlotView.cellGeometry(rowCount: rowSizes.count)
        let rows = V6RightSlotView.splitIntoRows(cells, rowSizes: rowSizes)

        VStack(spacing: geom.gap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: geom.gap) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        AgentsGridTileView(cell: cell, size: geom.cell, radius: geom.radius)
                    }
                }
            }
        }
        .fixedSize()
    }
}

private struct AgentsGridTileView: View {
    let cell: AgentGridCell
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        switch cell {
        case .session(let color, let state):
            switch state {
            case .running:
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(color)
                    .frame(width: size, height: size)
            case .idle:
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(color.opacity(0.22))
                    .frame(width: size, height: size)
            case .waiting:
                AgentsGridWaitingTile(color: color, size: size, radius: radius)
            }
        case .overflow(let n):
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(V6Palette.paper.opacity(0.14))
                Text("+\(n)")
                    .font(.system(size: max(5, size * 0.55), weight: .bold, design: .monospaced))
                    .foregroundStyle(V6Palette.paper)
            }
            .frame(width: size, height: size)
        }
    }
}

private struct AgentsGridWaitingTile: View {
    let color: Color
    let size: CGFloat
    let radius: CGFloat
    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
            .opacity(pulse ? 1.0 : 0.35)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

// MARK: - Center label renderer

struct V6CenterLabelView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(V6Palette.paper)
    }

    static func intrinsicWidth(of text: String) -> CGFloat {
        CGFloat(Double(text.count) * 7.3 + 10)
    }
}

// MARK: - Closed-pill layouts

/// The canonical v6 closed-island pill rendered inside a fixed-height frame.
/// Pure view — takes all parameters explicitly so it can be reused for the
/// live settings preview and the real island.
struct V6ClosedPill: View {
    var mode: UnifiedBars.Mode
    var label: String?          // suppressed automatically in MacBook layout
    var rightSlot: IslandRightSlotContent?
    var leftSlot: IslandLeftSlotContent?
    var layout: V6ClosedLayout
    var height: CGFloat = 32

    /// MacBook mode only — width of the physical notch cutout to wrap.
    var physicalNotchWidth: CGFloat = 0

    /// External mode only — minimum pill width (locked). Defaults to the
    /// width that fits just the glyph.
    var minWidth: CGFloat = 70

    var body: some View {
        switch layout {
        case .external: externalBody
        case .macbook:  macbookBody
        }
    }

    // Horizontal edge padding is identical left/right — canonical v6 pill
    // has r = h/2 semicircular bottoms, so edge inset = r keeps content
    // clear of the curve.
    private var pad: CGFloat { height / 2 }

    // Minimum breathing room between the center label (or glyph, when no
    // label) and the right-slot content so they never touch at small widths.
    private static let innerGap: CGFloat = 6

    static func macbookEarWidth(for rightSlot: IslandRightSlotContent?, leftSlot: IslandLeftSlotContent? = nil) -> CGFloat {
        var need: CGFloat = 0
        switch rightSlot {
        case .text?, .alert?, .hint?, .status?, .startFocus?:
            need = V6RightSlotView.intrinsicWidth(of: rightSlot!)
        default:
            break
        }
        if let leftSlot {
            need = max(need, 30 + V6LeftSlotView.intrinsicWidth(of: leftSlot))
        }
        guard need > 0 else { return 44 }
        return max(44, need + 16)
    }

    var resolvedWidth: CGFloat {
        switch layout {
        case .external:
            let glyphWidth: CGFloat = 24
            let labelWidth = label.map { V6CenterLabelView.intrinsicWidth(of: $0) } ?? 0
            let rightWidth = rightSlot.map { V6RightSlotView.intrinsicWidth(of: $0) } ?? 0
            let leftBlock = leftSlot.map { 6 + V6LeftSlotView.intrinsicWidth(of: $0) } ?? 0
            let labelBlock = label == nil ? 0 : 6 + labelWidth
            let rightBlock = rightSlot == nil ? 0 : Self.innerGap + rightWidth
            return max(minWidth, pad * 2 + glyphWidth + leftBlock + labelBlock + rightBlock)
        case .macbook:
            let ear = Self.macbookEarWidth(for: rightSlot, leftSlot: leftSlot)
            return ear + physicalNotchWidth + ear
        }
    }

    // MARK: External (fluid)

    private var externalBody: some View {
        let glyphW: CGFloat = 24

        return ZStack {
            V6ClosedPillShape()
                .fill(V6Palette.ink)

            HStack(spacing: 0) {
                UnifiedBars(mode: mode, size: 24)
                    .frame(width: glyphW, height: 24)

                if let leftSlot {
                    V6LeftSlotView(content: leftSlot)
                        .padding(.leading, 6)
                }

                if let label {
                    V6CenterLabelView(text: label)
                        .padding(.leading, 6)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }

                Spacer(minLength: Self.innerGap)

                if let rightSlot {
                    V6RightSlotView(content: rightSlot)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .padding(.horizontal, pad)
        }
        .frame(width: resolvedWidth, height: height)
        .animation(
            .timingCurve(0.4, 0, 0.2, 1, duration: 0.45),
            value: AnyHashable([
                AnyHashable(label ?? ""),
                AnyHashable(rightSlot.map(RightSlotKey.init) ?? .none),
                AnyHashable(FocusEars.animationKey(leftSlot)),
                AnyHashable(mode),
            ])
        )
    }

    // MARK: MacBook (outer width locked)

    private var macbookBody: some View {
        return ZStack {
            V6ClosedPillShape()
                .fill(V6Palette.ink)

            HStack(spacing: 0) {
                UnifiedBars(mode: mode, size: 24)
                    .frame(width: 24, height: 24)

                if let leftSlot {
                    V6LeftSlotView(content: leftSlot)
                        .padding(.leading, 6)
                }

                Spacer(minLength: 0)

                if let rightSlot {
                    V6RightSlotView(content: rightSlot)
                }
            }
            .padding(.horizontal, pad)
        }
        .frame(width: resolvedWidth, height: height)
    }
}

enum V6ClosedLayout: Equatable {
    case external
    case macbook
}

private enum RightSlotKey: Hashable {
    case count(Int)
    case agents(Int)
    case text(String)
    case alert(String)
    case hint(String)
    case status(String)
    case startFocus(Int)

    init(_ content: IslandRightSlotContent) {
        switch content {
        case .count(let n):    self = .count(n)
        case .agents(let cs):  self = .agents(cs.count)
        case .text(let v):     self = .text(v)
        case .alert(let v):    self = .alert(v)
        case .hint(let v):     self = .hint(v)
        case .status(let v):   self = .status(v)
        case .startFocus(let m): self = .startFocus(m)
        }
    }
}

// MARK: - Settings-tab live preview

/// Fixed-width pill that mimics the real island inside the settings-tab
/// preview stage. Parameters match what the tab exposes.
struct IslandPreviewPill: View {
    let mode: UnifiedBars.Mode
    let label: String?
    let rightSlot: IslandRightSlotContent?
    let layout: V6ClosedLayout
    let physicalNotchWidth: CGFloat
    let now: Date

    var body: some View {
        V6ClosedPill(
            mode: mode,
            label: label,
            rightSlot: rightSlot,
            layout: layout,
            physicalNotchWidth: physicalNotchWidth
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
