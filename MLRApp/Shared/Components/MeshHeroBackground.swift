import SwiftUI

// MARK: - MeshHeroBackground (UI/UX overhaul Phase 1.4)
//
// A dramatic mesh-gradient hero band (iOS 18 `MeshGradient`, 3×3) with a slow
// point drift — frozen to a static mesh under Reduce Motion. One mesh per
// visible hero; never place behind a scrolling `LazyVStack`. For legibility,
// overlay content with `.heroOverlayScrim()` (black-only scrim per the
// transparency rule in `Colors.swift`).

/// Which brand world the hero paints.
enum HeroTheme {
    case northwoods            // forest pines → lake glow (Home / resort surfaces)
    case fest                  // heraldic wine → gold (Family Fest)
    case accent(Color)         // single-accent wash (feature areas)

    /// Mesh color grid (9 entries, row-major 3×3), adaptive via the mlr tokens.
    var colors: [Color] {
        switch self {
        case .northwoods:
            // Deep forest greens with a soft lake-blue glow at the heart —
            // deliberately NO warm campfire/sun/dusk hues here: mixing the full
            // accent set read as a rainbow/tie-dye wash instead of "north woods".
            return [
                .mlrPrimaryDark, .mlrPrimary,     .mlrPrimaryDark,
                .mlrPrimary,     .mlrLake,        .mlrPrimary,
                .mlrPrimaryDark, .mlrPrimaryDark, .mlrPrimary,
            ]
        case .fest:
            return [
                .mlrFest,     .mlrFestGold, .mlrFest,
                .mlrFestGold, .mlrFest,     .mlrFestGold,
                .mlrFest,     .mlrFestGold, .mlrFest,
            ]
        case .accent(let c):
            return [
                c,                 c.opacity(0.85), c,
                c.opacity(0.8),    c.opacity(0.6),  c.opacity(0.9),
                c,                 c.opacity(0.75), c,
            ]
        }
    }

    /// Flat fallback for contexts that can't host a mesh (matches the existing
    /// brand gradients).
    @MainActor var fallback: LinearGradient {
        switch self {
        case .northwoods: return .northwoodsForest
        case .fest:       return .festHeraldic
        case .accent(let c):
            return LinearGradient(colors: [c, c.opacity(0.7)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

struct MeshHeroBackground: View {
    let theme: HeroTheme

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Static 3×3 grid; the two interior points drift when motion is allowed.
    private static let basePoints: [SIMD2<Float>] = [
        [0, 0],   [0.5, 0],   [1, 0],
        [0, 0.5], [0.5, 0.5], [1, 0.5],
        [0, 1],   [0.5, 1],   [1, 1],
    ]

    var body: some View {
        if reduceMotion {
            mesh(points: Self.basePoints)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                mesh(points: driftedPoints(t))
            }
        }
    }

    private func mesh(points: [SIMD2<Float>]) -> some View {
        MeshGradient(width: 3, height: 3, points: points, colors: theme.colors)
            .ignoresSafeArea(edges: .top)
    }

    /// Slow, small drift of the interior control points — enough to feel alive,
    /// never enough to distract.
    private func driftedPoints(_ t: TimeInterval) -> [SIMD2<Float>] {
        var pts = Self.basePoints
        let s = Float(sin(t * 0.35)) * 0.08
        let c = Float(cos(t * 0.28)) * 0.08
        pts[4] = [0.5 + s, 0.5 + c]          // center
        pts[1] = [0.5 + c * 0.5, 0]          // top mid drifts along the edge
        pts[7] = [0.5 - s * 0.5, 1]          // bottom mid, counter-phase
        return pts
    }
}

extension View {
    /// Bottom-to-top black scrim for text legibility over a mesh hero
    /// (black-only, per the transparency rule in `Colors.swift`).
    func heroOverlayScrim(maxOpacity: Double = 0.25) -> some View {
        background(
            LinearGradient(
                colors: [.black.opacity(maxOpacity), .black.opacity(0)],
                startPoint: .bottom, endPoint: .top)
        )
    }
}
