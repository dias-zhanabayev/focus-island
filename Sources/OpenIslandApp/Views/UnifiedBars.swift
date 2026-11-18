import AppKit
import SwiftUI

/// v6 `UnifiedBars` glyph — three vertical bars that share the same geometry
/// across all three notch states (idle / running / waiting). Active states are
/// animated by Core Animation layers so SwiftUI does not invalidate every frame.
///
/// Canonical geometry (from the design handoff): 24×24 box, 3 bars of width
/// 2.5 centered on columns x = 5.25 / 10.75 / 16.25, rounded to a pill.
struct UnifiedBars: View {
    enum Mode: Equatable {
        case idle       // rest — 3 short static bars
        case running    // active — static tall wave frame
        case waiting    // pause — static outer bars, middle hidden

        var timelineInterval: TimeInterval? {
            nil
        }

        var usesLayerAnimation: Bool {
            switch self {
            case .idle:
                false
            case .running, .waiting:
                true
            }
        }
    }

    var mode: Mode
    var size: CGFloat = 24
    /// Ink color for bars / tick. Defaults to the v6 paper ink.
    var tint: Color = Color(red: 0xf1 / 255.0, green: 0xea / 255.0, blue: 0xd9 / 255.0)

    private static let box: CGFloat = 24
    private static let barWidth: CGFloat = 2.5
    private static let center: CGFloat = 12

    private static let columns: [Column] = [
        Column(x: 5.25,  idleH: 3, runH: 10, waitH: 10),
        Column(x: 10.75, idleH: 5, runH: 14, waitH: 0),
        Column(x: 16.25, idleH: 3, runH: 10, waitH: 10),
    ]

    @ViewBuilder
    var body: some View {
        LayerRepresentable(mode: mode, tint: tint)
            .frame(width: size, height: size)
    }

    private struct LayerRepresentable: NSViewRepresentable {
        let mode: Mode
        let tint: Color

        func makeNSView(context: Context) -> LayerView {
            let view = LayerView()
            view.update(mode: mode, tint: NSColor(tint))
            return view
        }

        func updateNSView(_ nsView: LayerView, context: Context) {
            nsView.update(mode: mode, tint: NSColor(tint))
        }
    }

    private final class LayerView: NSView {
        private let barLayers = [CAShapeLayer(), CAShapeLayer(), CAShapeLayer()]
        private var mode: Mode = .idle
        private var tintColor = NSColor.white

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = CALayer()
            layer?.masksToBounds = false
            barLayers.forEach { barLayer in
                barLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                barLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
                layer?.addSublayer(barLayer)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(mode: Mode, tint: NSColor) {
            self.mode = mode
            tintColor = tint
            needsLayout = true
        }

        override func layout() {
            super.layout()
            configureLayers()
        }

        private func configureLayers() {
            let side = min(bounds.width, bounds.height)
            guard side > 0 else { return }

            let scale = side / UnifiedBars.box
            let dx = (bounds.width - side) / 2
            let dy = (bounds.height - side) / 2

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (index, column) in UnifiedBars.columns.enumerated() {
                let barLayer = barLayers[index]
                let baseHeight = self.baseHeight(for: column)
                let width = UnifiedBars.barWidth * scale
                let height = baseHeight * scale
                let center = CGPoint(
                    x: dx + ((column.x + UnifiedBars.barWidth / 2) * scale),
                    y: dy + (UnifiedBars.center * scale)
                )

                barLayer.isHidden = baseHeight <= 0
                barLayer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
                barLayer.position = center
                barLayer.fillColor = tintColor.cgColor
                barLayer.path = CGPath(
                    roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
                    cornerWidth: width / 2,
                    cornerHeight: width / 2,
                    transform: nil
                )
                barLayer.transform = CATransform3DIdentity
                barLayer.opacity = initialOpacity(for: column)
                configureAnimations(for: barLayer, column: column)
            }
            CATransaction.commit()
        }

        private func baseHeight(for column: Column) -> CGFloat {
            switch mode {
            case .idle:
                column.idleH
            case .running:
                column.runH
            case .waiting:
                column.waitH
            }
        }

        private func initialOpacity(for column: Column) -> Float {
            switch mode {
            case .idle, .running:
                1
            case .waiting:
                column.waitH > 0 ? 0.55 : 0
            }
        }

        private func configureAnimations(for barLayer: CAShapeLayer, column: Column) {
            barLayer.removeAllAnimations()
            guard mode.usesLayerAnimation, !barLayer.isHidden else { return }

            switch mode {
            case .idle:
                return
            case .running:
                addRunningAnimation(to: barLayer, column: column)
            case .waiting:
                addWaitingAnimation(to: barLayer, column: column)
            }
        }

        private func addRunningAnimation(to barLayer: CAShapeLayer, column: Column) {
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = [1.0, 0.35, 1.0]
            animation.keyTimes = [0, 0.5, 1]
            animation.duration = 1.4
            animation.repeatCount = .infinity
            animation.timingFunctions = [
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
            ]
            barLayer.add(animation, forKey: "running-opacity")
        }

        private func addWaitingAnimation(to barLayer: CAShapeLayer, column: Column) {
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = [0.55, 1.0, 0.55]
            animation.keyTimes = [0, 0.5, 1]
            animation.duration = 1.8
            animation.beginTime = CACurrentMediaTime() + (column.x < UnifiedBars.center ? 0 : 0.9)
            animation.repeatCount = .infinity
            animation.timingFunctions = [
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
            ]
            barLayer.add(animation, forKey: "waiting-opacity")
        }
    }

    private struct Column: Equatable {
        let x: CGFloat
        let idleH: CGFloat
        let runH: CGFloat
        let waitH: CGFloat
    }
}
