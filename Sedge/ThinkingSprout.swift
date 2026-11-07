//
//  ThinkingSprout.swift
//  Sedge
//

import SwiftUI

/// The thinking row's sprout. It is drawn as four separate strokes so each can draw itself in
/// turn: the ground, the stem from the bottom up, the right leaf, then the left leaf. It holds,
/// erases in the same order, and repeats. The strokes are the parts of `chat-sedge`'s sprout.svg,
/// on the same 16-point grid, so the still sprout looks exactly like the image.
struct ThinkingSprout: View {
    /// Seconds for one draw, hold and erase, as in the design's key frames.
    static let cycleSeconds = 3.4

    /// False with Reduce Motion: the sprout stays fully drawn and still.
    let draws: Bool
    /// When this sprout appeared, so each question's sprout starts drawing from nothing.
    @State private var start = Date.now

    /// One stroke, and where in the cycle (0 to 1) it draws on and erases. `fromEnd` draws it from
    /// its last point back to its first, which is how the stem grows up out of the ground.
    struct Part {
        let path: Path
        let on: ClosedRange<Double>
        let off: ClosedRange<Double>
        var fromEnd = false

        /// How much of the stroke shows at `t`, a point in the cycle from 0 to 1: it eases from
        /// none to all across `on`, stays drawn, then eases back to none across `off`.
        func shown(at t: Double) -> Double {
            func eased(over range: ClosedRange<Double>) -> Double {
                let x = min(max((t - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
                return x * x * (3 - 2 * x) // smoothstep: close to the design's ease-in-out
            }
            return t < off.lowerBound ? eased(over: on) : 1 - eased(over: off)
        }

        /// How opaque the stroke is at `t`: fully while it draws and holds, then fading with what
        /// is left of it while it erases, so it never ends as a solid round-cap dot.
        func opacity(at t: Double) -> Double {
            let shown = shown(at: t)
            return t < off.lowerBound ? (shown > 0 ? 1 : 0) : shown
        }
    }

    /// The design's key frames, as fractions of the 3.4-second cycle.
    static let parts = [
        Part(path: ground, on: 0...0.14, off: 0.78...0.92),
        Part(path: stem, on: 0.12...0.34, off: 0.80...0.94, fromEnd: true),
        Part(path: rightLeaf, on: 0.32...0.52, off: 0.82...0.96),
        Part(path: leftLeaf, on: 0.50...0.70, off: 0.84...0.98),
    ]

    var body: some View {
        // Redraws every frame while drawing; paused (no redraws at all) with Reduce Motion.
        TimelineView(.animation(paused: !draws)) { context in
            // 0.75 is in the hold, where every part is fully drawn: what Reduce Motion shows.
            let t = draws ? context.date.timeIntervalSince(start)
                .truncatingRemainder(dividingBy: Self.cycleSeconds) / Self.cycleSeconds : 0.75
            ZStack {
                ForEach(Self.parts.indices, id: \.self) { index in
                    let part = Self.parts[index]
                    let shown = part.shown(at: t)
                    part.path
                        .trim(from: part.fromEnd ? 1 - shown : 0, to: part.fromEnd ? 1 : shown)
                        .stroke(Color.accent, style: StrokeStyle(lineWidth: 1.33333, lineCap: .round, lineJoin: .round))
                        .opacity(part.opacity(at: t))
                }
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }

    // The sprout.svg paths, split at the point where the stem meets the right leaf.
    private static let ground = Path {
        $0.move(to: CGPoint(x: 3.33333, y: 14))
        $0.addLine(to: CGPoint(x: 12.6667, y: 14))
    }
    private static let stem = Path {
        $0.move(to: CGPoint(x: 9.33333, y: 6.35726))
        $0.addCurve(to: CGPoint(x: 8.78105, y: 6.78105), control1: CGPoint(x: 9.1332, y: 6.47279), control2: CGPoint(x: 8.94728, y: 6.61481))
        $0.addCurve(to: CGPoint(x: 8, y: 8.66667), control1: CGPoint(x: 8.28095, y: 7.28115), control2: CGPoint(x: 8, y: 7.95942))
        $0.addCurve(to: CGPoint(x: 8.66667, y: 12), control1: CGPoint(x: 8, y: 10), control2: CGPoint(x: 8.66667, y: 10.6667))
        $0.addCurve(to: CGPoint(x: 8, y: 14), control1: CGPoint(x: 8.66667, y: 12.7212), control2: CGPoint(x: 8.43274, y: 13.423))
    }
    private static let rightLeaf = Path {
        $0.move(to: CGPoint(x: 9.33333, y: 6.35726))
        $0.addLine(to: CGPoint(x: 9.33333, y: 4.66667))
        $0.addCurve(to: CGPoint(x: 10.1144, y: 2.78105), control1: CGPoint(x: 9.33333, y: 3.95942), control2: CGPoint(x: 9.61428, y: 3.28115))
        $0.addCurve(to: CGPoint(x: 12, y: 2), control1: CGPoint(x: 10.6145, y: 2.28095), control2: CGPoint(x: 11.2928, y: 2))
        $0.addLine(to: CGPoint(x: 13, y: 2))
        $0.addCurve(to: CGPoint(x: 13.2357, y: 2.09763), control1: CGPoint(x: 13.0884, y: 2), control2: CGPoint(x: 13.1732, y: 2.03512))
        $0.addCurve(to: CGPoint(x: 13.3333, y: 2.33333), control1: CGPoint(x: 13.2982, y: 2.16014), control2: CGPoint(x: 13.3333, y: 2.24493))
        $0.addLine(to: CGPoint(x: 13.3333, y: 3.33333))
        $0.addCurve(to: CGPoint(x: 12.5523, y: 5.21895), control1: CGPoint(x: 13.3333, y: 4.04058), control2: CGPoint(x: 13.0524, y: 4.71885))
        $0.addCurve(to: CGPoint(x: 10.6667, y: 6), control1: CGPoint(x: 12.0522, y: 5.71905), control2: CGPoint(x: 11.3739, y: 6))
        $0.addCurve(to: CGPoint(x: 9.33333, y: 6.35726), control1: CGPoint(x: 10.1945, y: 6), control2: CGPoint(x: 9.73527, y: 6.12522))
        $0.closeSubpath()
    }
    private static let leftLeaf = Path {
        $0.move(to: CGPoint(x: 2.66667, y: 6))
        $0.addCurve(to: CGPoint(x: 4.36731, y: 5.3468), control1: CGPoint(x: 3.1619, y: 5.62858), control2: CGPoint(x: 3.75078, y: 5.4024))
        $0.addCurve(to: CGPoint(x: 6.15738, y: 5.68524), control1: CGPoint(x: 4.98385, y: 5.29121), control2: CGPoint(x: 5.60369, y: 5.4084))
        $0.addCurve(to: CGPoint(x: 7.50217, y: 6.91423), control1: CGPoint(x: 6.71106, y: 5.96209), control2: CGPoint(x: 7.17672, y: 6.38764))
        $0.addCurve(to: CGPoint(x: 8, y: 8.66667), control1: CGPoint(x: 7.82762, y: 7.44082), control2: CGPoint(x: 8, y: 8.04763))
        $0.addCurve(to: CGPoint(x: 6.29935, y: 9.31986), control1: CGPoint(x: 7.50477, y: 9.03809), control2: CGPoint(x: 6.91589, y: 9.26427))
        $0.addCurve(to: CGPoint(x: 4.50929, y: 8.98142), control1: CGPoint(x: 5.68281, y: 9.37546), control2: CGPoint(x: 5.06297, y: 9.25827))
        $0.addCurve(to: CGPoint(x: 3.1645, y: 7.75244), control1: CGPoint(x: 3.9556, y: 8.70458), control2: CGPoint(x: 3.48995, y: 8.27902))
        $0.addCurve(to: CGPoint(x: 2.66667, y: 6), control1: CGPoint(x: 2.83905, y: 7.22585), control2: CGPoint(x: 2.66667, y: 6.61904))
        $0.closeSubpath()
    }
}
