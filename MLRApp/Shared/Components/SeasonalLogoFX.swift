import SwiftUI
import UIKit

// MARK: - Seasonal logo FX
//
// Native port of the web's SeasonalLogoFX (PR #597). Everything is drawn in the
// logo artwork's own 1340x896 coordinate space and scaled to the view, so each
// element lands on the same feature of the artwork at any size. `progress`
// runs 0...1 and 1 is the final still state: the header renders progress 1;
// the splash animates 0 -> 1 over ~2.4 s. Particle motion is derived from the
// index (no randomness) so the final frame is identical everywhere.

enum Season: String, CaseIterable {
    case winter, spring, summer, fall

    /// Meteorological seasons, northern hemisphere (the resort is in WI).
    static func current(_ date: Date = Date()) -> Season {
        let m = Calendar.current.component(.month, from: date)
        switch m {
        case 12, 1, 2: return .winter
        case 3...5: return .spring
        case 6...8: return .summer
        default: return .fall
        }
    }
}

// MARK: Still / scrubbed drawing

struct SeasonalLogoFX: View {
    let season: Season
    /// 0...1, 1 = final still snapshot.
    let progress: Double
    /// false = skip the falling leaves/flakes (a live FallingParticlesFX draws them).
    var particles: Bool = true

    var body: some View {
        Canvas { ctx, size in
            let k = size.width / SeasonalArt.width
            var c = ctx
            c.scaleBy(x: k, y: k)
            SeasonalArt.draw(&c, season: season, p: min(max(progress, 0), 1), particles: particles)
        }
        .aspectRatio(SeasonalArt.width / SeasonalArt.height, contentMode: .fit)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: Animated (splash)

/// Plays the effect once over `duration`, then stops the TimelineView and
/// fires `onSettle` (single haptic is the caller's choice). Reduce Motion
/// shows the final state immediately.
struct SeasonalLogoAnimatedFX: View {
    let season: Season
    var duration: Double = 2.4
    var delay: Double = 0.25
    var onSettle: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var finished = false

    var body: some View {
        Group {
            if reduceMotion || finished {
                SeasonalLogoFX(season: season, progress: 1)
            } else {
                TimelineView(.animation(paused: finished)) { tl in
                    let raw = (tl.date.timeIntervalSince(start) - delay) / duration
                    SeasonalLogoFX(season: season, progress: max(0, min(raw, 1)))
                        .onChange(of: raw >= 1) { _, done in if done { settle() } }
                }
            }
        }
        .onAppear {
            start = Date()
            if reduceMotion { finished = true }
        }
    }

    private func settle() {
        guard !finished else { return }
        finished = true
        onSettle()
    }
}

// MARK: - Art

private enum SeasonalArt {
    static let width: CGFloat = 1340
    static let height: CGFloat = 896

    static func ease(_ t: Double) -> Double { let u = 1 - min(max(t, 0), 1); return 1 - u * u * u }
    static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
    /// Local 0...1 progress of an element that starts at `delay` and takes `len`.
    static func local(_ p: Double, delay: Double, len: Double) -> Double { clamp((p - delay) / len) }

    static func draw(_ c: inout GraphicsContext, season: Season, p: Double, particles: Bool = true) {
        switch season {
        case .fall: if particles { fall(&c, p) }
        case .winter: winter(&c, p, particles: particles)
        case .spring: spring(&c, p)
        case .summer: summer(&c, p)
        }
    }

    // MARK: Fall

    private struct Leaf { let x, y, r: Double; let c: UInt32; let s: Double }
    private static let leaves: [Leaf] = [
        .init(x: 430, y: 478, r: -60, c: 0xd9531e, s: 1),
        .init(x: 520, y: 500, r: -30, c: 0xe8a317, s: 1.15),
        .init(x: 660, y: 522, r: 10, c: 0xb5341c, s: 1),
        .init(x: 760, y: 506, r: 20, c: 0xc9771a, s: 1.1),
        .init(x: 900, y: 476, r: 50, c: 0xe8a317, s: 1),
        .init(x: 1010, y: 568, r: 75, c: 0xd9531e, s: 1.15),
        .init(x: 300, y: 590, r: -20, c: 0xb5341c, s: 1),
        .init(x: 850, y: 622, r: 35, c: 0xd9531e, s: 1),
        .init(x: 570, y: 410, r: 25, c: 0xe8a317, s: 0.9),
        .init(x: 1090, y: 330, r: -40, c: 0xc9771a, s: 0.9),
        .init(x: 250, y: 330, r: 55, c: 0xd9531e, s: 0.9),
    ]

    private static let leafPath: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: -34))
        p.addCurve(to: CGPoint(x: 0, y: 34), control1: CGPoint(x: 24, y: -24), control2: CGPoint(x: 28, y: 10))
        p.addCurve(to: CGPoint(x: 0, y: -34), control1: CGPoint(x: -28, y: 10), control2: CGPoint(x: -24, y: -24))
        return p
    }()
    private static let leafVein: Path = {
        var p = Path(); p.move(to: CGPoint(x: 0, y: -30)); p.addLine(to: CGPoint(x: 0, y: 40)); return p
    }()

    private static func fall(_ c: inout GraphicsContext, _ p: Double) {
        for (i, l) in leaves.enumerated() {
            let t = local(p, delay: Double(i) * 0.035, len: 0.6)
            let e = ease(t)
            let dir: Double = i % 2 == 0 ? -1 : 1
            let amp = 60 + Double(i % 4) * 25
            // Drift down with a damped side-to-side sway; lands exactly on (x, y).
            let sway = sin(t * .pi * 3 + Double(i)) * amp * (1 - e)
            let dx = dir * amp * 0.5 * (1 - e) + sway * 0.4
            let dy = -(420 + Double(i % 3) * 60) * (1 - e)
            let spin = dir * (1 - e) * (140 + Double(i % 3) * 40)
            var g = c
            g.opacity = clamp(t * 5)
            g.translateBy(x: l.x + dx, y: l.y + dy)
            g.rotate(by: .degrees(l.r + spin))
            let s = l.s * 1.35
            g.scaleBy(x: s, y: s)
            g.fill(leafPath, with: .color(rgb(l.c)))
            g.stroke(leafVein, with: .color(.black.opacity(0.2)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
    }

    // MARK: Winter

    private static let flakes: [(Double, Double, Double)] = [
        (300, 200, 11), (430, 120, 9), (560, 80, 12), (700, 150, 9), (830, 90, 11),
        (960, 180, 7), (1090, 250, 9), (220, 380, 7), (1160, 430, 8), (390, 320, 6),
        (1000, 360, 6), (140, 520, 8), (1250, 560, 7), (660, 60, 6),
    ]
    private static let caps: [(Double, Double, Double)] = [
        (607, 232, 1.1), (547, 268, 1), (802, 248, 1.2), (500, 342, 0.9), (862, 330, 0.9), (607, 338, 1.3),
    ]
    private static let snowStroke = Color(red: 0xa9 / 255, green: 0xc4 / 255, blue: 0xda / 255)

    private static let ridge: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 385, y: 530))
        p.addQuadCurve(to: CGPoint(x: 965, y: 550), control: CGPoint(x: 660, y: 468))
        p.addQuadCurve(to: CGPoint(x: 660, y: 512), control: CGPoint(x: 905, y: 522))
        p.addQuadCurve(to: CGPoint(x: 385, y: 530), control: CGPoint(x: 500, y: 508))
        p.closeSubpath()
        return p
    }()
    private static let capPath: Path = {
        var p = Path()
        p.move(to: CGPoint(x: -28, y: 16))
        p.addQuadCurve(to: CGPoint(x: 0, y: -18), control: CGPoint(x: -12, y: -6))
        p.addQuadCurve(to: CGPoint(x: 28, y: 16), control: CGPoint(x: 12, y: -6))
        p.addQuadCurve(to: CGPoint(x: 0, y: 13), control: CGPoint(x: 12, y: 22))
        p.addQuadCurve(to: CGPoint(x: -28, y: 16), control: CGPoint(x: -12, y: 22))
        p.closeSubpath()
        return p
    }()

    private static func winter(_ c: inout GraphicsContext, _ p: Double, particles: Bool = true) {
        // Snow settles into caps over the second half.
        let settle = ease(local(p, delay: 0.45, len: 0.5))
        if settle > 0 {
            var g = c
            g.opacity = settle
            g.translateBy(x: 0, y: (1 - settle) * -14)
            g.fill(ridge, with: .color(.white))
            g.stroke(ridge, with: .color(snowStroke), style: StrokeStyle(lineWidth: 4, lineJoin: .round))
            for (x, y, s) in caps {
                var h = g
                h.translateBy(x: x, y: y)
                h.scaleBy(x: s * 1.7 * (0.6 + 0.4 * settle), y: s * 1.7 * (0.6 + 0.4 * settle))
                h.fill(capPath, with: .color(.white))
                h.stroke(capPath, with: .color(snowStroke), style: StrokeStyle(lineWidth: 3, lineJoin: .round))
            }
        }
        for (i, f) in flakes.enumerated() where particles {
            let t = local(p, delay: Double(i) * 0.03, len: 0.62)
            let e = ease(t)
            let dir: Double = i % 2 == 0 ? -1 : 1
            let sway = sin(t * .pi * 4 + Double(i) * 1.3) * 40 * (1 - e)
            let x = f.0 + dir * 40 * (1 - e) + sway
            let y = f.1 - 380 * (1 - e)
            let r = f.2 * 1.3
            var g = c
            g.opacity = clamp(t * 6)
            let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
            g.fill(Path(ellipseIn: rect), with: .color(.white))
            g.stroke(Path(ellipseIn: rect), with: .color(snowStroke), lineWidth: 3)
        }
    }

    // MARK: Spring

    private static let flowers: [(x: Double, h: Double, c: UInt32)] = [
        (90, 120, 0xec6fa0), (190, 90, 0xf6c445), (290, 60, 0xa97bd8), (560, 34, 0xffffff),
        (790, 40, 0xf6c445), (1050, 62, 0xec6fa0), (1150, 100, 0xa97bd8), (1250, 140, 0xf6c445),
    ]

    private static func spring(_ c: inout GraphicsContext, _ p: Double) {
        let base = 884.0
        let green = Color(red: 0x3f / 255, green: 0x8f / 255, blue: 0x4a / 255)
        let leafGreen = Color(red: 0x56 / 255, green: 0xa8 / 255, blue: 0x5f / 255)
        for (i, f) in flowers.enumerated() {
            let sign: Double = i % 2 == 0 ? -1 : 1
            let grow = ease(local(p, delay: Double(i) * 0.06, len: 0.55))
            let bloom = ease(local(p, delay: Double(i) * 0.06 + 0.4, len: 0.4))
            let h = f.h * grow
            guard h > 0.5 else { continue }
            var g = c
            g.translateBy(x: f.x, y: base)
            var stem = Path()
            stem.move(to: .zero)
            stem.addCurve(to: CGPoint(x: 0, y: -h),
                          control1: CGPoint(x: -sign * 14, y: -h * 0.4),
                          control2: CGPoint(x: sign * 10, y: -h * 0.75))
            g.stroke(stem, with: .color(green), style: StrokeStyle(lineWidth: 7, lineCap: .round))
            var lf = g
            lf.translateBy(x: -sign * 16, y: -h * 0.45)
            lf.rotate(by: .degrees(sign * 30))
            lf.scaleBy(x: grow, y: grow)
            lf.fill(Path(ellipseIn: CGRect(x: -16, y: -7, width: 32, height: 14)), with: .color(leafGreen))
            guard bloom > 0.01 else { continue }
            var b = g
            b.translateBy(x: 0, y: -f.h)
            b.scaleBy(x: bloom, y: bloom)
            b.rotate(by: .degrees((1 - bloom) * 50))
            for a in stride(from: 0.0, to: 360, by: 72) {
                var pe = b
                pe.rotate(by: .degrees(a))
                let r = CGRect(x: -10, y: -33, width: 20, height: 32)
                pe.fill(Path(ellipseIn: r), with: .color(rgb(f.c)))
                pe.stroke(Path(ellipseIn: r), with: .color(.black.opacity(0.13)), lineWidth: 1.5)
            }
            let center: UInt32 = f.c == 0xf6c445 ? 0xd9822b : 0xf6c445
            b.fill(Path(ellipseIn: CGRect(x: -8, y: -8, width: 16, height: 16)), with: .color(rgb(center)))
        }
    }

    // MARK: Summer

    private static func summer(_ c: inout GraphicsContext, _ p: Double) {
        let e = ease(local(p, delay: 0, len: 0.8))
        let glowT = ease(local(p, delay: 0.3, len: 0.7))
        var g = c
        g.opacity = clamp(e * 3)
        // Rises from below the artwork into its resting spot.
        g.translateBy(x: 1180, y: 150 + (1 - e) * 420)
        g.rotate(by: .degrees((1 - e) * -40))
        let rect = { (r: Double) in CGRect(x: -r, y: -r, width: r * 2, height: r * 2) }
        // Soft glow: a few concentric translucent discs.
        for (r, a) in [(150.0, 0.07), (120.0, 0.11), (92.0, 0.18)] {
            g.fill(Path(ellipseIn: rect(r * (0.85 + 0.15 * glowT))),
                   with: .color(Color(red: 1, green: 0.83, blue: 0.30).opacity(a * glowT + a * 0.3)))
        }
        for a in stride(from: 0.0, to: 360, by: 30) {
            var ray = Path()
            ray.move(to: CGPoint(x: 0, y: -76)); ray.addLine(to: CGPoint(x: 0, y: -98))
            var rg = g
            rg.rotate(by: .degrees(a))
            rg.stroke(ray, with: .color(rgb(0xf6a81a)), style: StrokeStyle(lineWidth: 9, lineCap: .round))
        }
        g.fill(Path(ellipseIn: rect(58)), with: .color(rgb(0xffc933)))
        g.stroke(Path(ellipseIn: rect(58)), with: .color(rgb(0xf6a81a)), lineWidth: 5)
    }

    private static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

// MARK: - Previews

#Preview("Fall") { previewLogo(.fall) }
#Preview("Winter") { previewLogo(.winter) }
#Preview("Spring") { previewLogo(.spring) }
#Preview("Summer") { previewLogo(.summer) }

private func previewLogo(_ s: Season) -> some View {
    Image("brand-logo-green")
        .resizable().scaledToFit()
        .overlay { SeasonalLogoFX(season: s, progress: 1) }
        .padding(24)
        .background(Color.mlrPrimary.mlrTint(0.2))
}
