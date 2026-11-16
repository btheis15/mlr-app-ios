import SwiftUI

// MARK: - MLRBackdrop (Northwoods lodge atmosphere)
//
// Static, drawn once: birch-to-sage vertical gradient, a soft lake-blue glow at
// the top and a pine glow at the bottom. `.fest` uses the ACTIVE fest theme
// (parchment background + a glow in the theme primary). Colours are adaptive
// tokens, so light/dark and the fest theme resolve at render time.

struct MLRBackdrop: View {
    enum Kind { case standard, fest }
    var kind: Kind

    init(_ kind: Kind = .standard) { self.kind = kind }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                switch kind {
                case .standard:
                    LinearGradient(colors: [.mlrBackdropTop, .mlrBackdropBottom],
                                   startPoint: .top, endPoint: .bottom)
                    glow(.mlrLake, opacity: 0.10, size: geo.size, atTop: true)
                    glow(.mlrPrimary, opacity: 0.08, size: geo.size, atTop: false)
                case .fest:
                    // Parchment from the active theme background, easing slightly
                    // darker toward the bottom; glow in the theme primary.
                    LinearGradient(colors: [.mlrFestParchment, .mlrFestParchment.opacity(0.94)],
                                   startPoint: .top, endPoint: .bottom)
                    glow(.mlrFest, opacity: 0.10, size: geo.size, atTop: true)
                    glow(.mlrFest, opacity: 0.06, size: geo.size, atTop: false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(kind == .fest ? Color.mlrFestParchment : Color.mlrBackdropTop)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func glow(_ color: Color, opacity: Double, size: CGSize, atTop: Bool) -> some View {
        let r = max(size.width, 320) * 0.85
        return RadialGradient(colors: [color.opacity(opacity), color.opacity(0)],
                              center: atTop ? UnitPoint(x: 0.5, y: 0) : UnitPoint(x: 0.5, y: 1),
                              startRadius: 0, endRadius: r)
    }
}

extension View {
    /// Puts the MLR backdrop behind a screen: hides list/scroll/form system
    /// backgrounds, makes the navigation bar transparent, and (iOS 18
    /// `containerBackground`) lets pushed screens inherit the backdrop.
    /// Apply on a `NavigationStack` (all pushes inherit) or on a screen root.
    func mlrBackdrop(_ kind: MLRBackdrop.Kind = .standard) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background { MLRBackdrop(kind).ignoresSafeArea() }
            .containerBackground(for: .navigation) { MLRBackdrop(kind).ignoresSafeArea() }
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}
