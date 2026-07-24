import SwiftUI
import UIKit

// MARK: - Typography
// Yellowtail (script/wordmark) and Cinzel (Family Fest serif) must be added
// to the Xcode project: drag the .ttf files into the bundle and declare them
// in Info.plist under "Fonts provided by application".

extension Font {
    // Resort script wordmark (Yellowtail)
    static func script(_ size: CGFloat) -> Font {
        .custom("Yellowtail-Regular", size: size)
    }

    // Family Fest serif (Cinzel)
    static func festSerif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch weight {
        case .bold, .heavy, .black:
            return .custom("Cinzel-Bold", size: size)
        default:
            return .custom("Cinzel-Regular", size: size)
        }
    }

    // System scale aliases (respect Dynamic Type via scaled variants)
    static let mlrTitle    = Font.system(.title,    design: .rounded, weight: .bold)
    static let mlrHeadline = Font.system(.headline, design: .rounded, weight: .semibold)
    static let mlrBody     = Font.system(.body)
    static let mlrCaption  = Font.system(.caption)
    static let mlrFootnote = Font.system(.footnote)

    /// A system font at a fixed base `size` that still scales with Dynamic Type
    /// (via UIFontMetrics) — preserves the app's exact visual sizing at the
    /// default text size while honoring the user's preferred content size.
    /// The app-wide replacement for the non-scaling `.system(size:)`.
    static func mlrScaled(_ size: CGFloat,
                          weight: Font.Weight = .regular,
                          design: Font.Design = .default,
                          relativeTo style: UIFont.TextStyle = .body) -> Font {
        let scaled = UIFontMetrics(forTextStyle: style).scaledValue(for: size)
        return .system(size: scaled, weight: weight, design: design)
    }
}

// MARK: - Text style modifiers

extension Text {
    func scriptStyle(size: CGFloat = 28) -> Text {
        self.font(.script(size)).foregroundStyle(Color.mlrPrimary)
    }

    func festSerifStyle(size: CGFloat = 22, weight: Font.Weight = .regular) -> Text {
        self.font(.festSerif(size, weight: weight))
    }
}

// MARK: - Semantic view modifiers
//
// Prefer the Liquid Glass button styles in LiquidGlass.swift for prominent CTAs.
// These solid-fill helpers remain for non-glass contexts; both adapt to dark mode
// because the tokens adapt. (Kept here rather than in Colors.swift so the color
// tokens stay dependency-free and shareable with the widget extension.)

extension View {
    func primaryButton() -> some View {
        self
            .font(.mlrScaled(16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.mlrPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    func secondaryButton() -> some View {
        self
            .font(.mlrScaled(16, weight: .semibold))
            .foregroundStyle(Color.mlrPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.mlrPrimaryLight)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Opaque adaptive card with a soft hairline border — matches the web app's
    /// `bg-card rounded-2xl ring-1 ring-border` tile pattern.
    ///
    /// Overhaul Phase 1.5: default elevation is bumped so cards read raised
    /// app-wide with zero call-site edits — `elevated:false` → `.low`,
    /// `elevated:true` → `.medium`. Use the `elevation:` overload (incl. `.none`
    /// for grouped-list rows) for explicit control.
    func cardStyle(cornerRadius: CGFloat = 16, elevated: Bool = false) -> some View {
        cardStyle(cornerRadius: cornerRadius, elevation: elevated ? .medium : .low)
    }

    /// `cardStyle` with an explicit elevation from the `MLRElevation` ramp.
    func cardStyle(cornerRadius: CGFloat = 16, elevation: MLRElevation) -> some View {
        self
            .background(Color.mlrCard)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.mlrBorder, lineWidth: 1)
            )
            .shadow(elevation)
    }

    /// Accent-washed card: tinted hairline + a faint top-edge gradient wash of
    /// the accent, over the normal card surface. Use for per-feature identity
    /// (e.g. lake-blue weather, campfire who's-up-north).
    func cardStyle(tint: Color, cornerRadius: CGFloat = 16, elevation: MLRElevation = .low) -> some View {
        self
            .background(
                ZStack {
                    Color.mlrCard
                    LinearGradient(colors: [tint.opacity(0.10), tint.opacity(0)],
                                   startPoint: .top, endPoint: .center)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(tint.opacity(0.35), lineWidth: 1)
            )
            .shadow(elevation)
    }

    /// Full-gradient card fill (brand gradients) — for hero CTAs like the
    /// tournament card. Content should be white/near-white for contrast.
    func gradientCard(_ gradient: LinearGradient, cornerRadius: CGFloat = 16, elevation: MLRElevation = .medium) -> some View {
        self
            .background(gradient)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(elevation)
    }

    /// Composes `Button` + `.pressable` + `cardStyle` (+ optional staggered
    /// entrance) — the drop-in for `Button { … }.buttonStyle(.plain).cardStyle()`.
    func interactiveCard(cornerRadius: CGFloat = 16,
                         elevation: MLRElevation = .medium,
                         entranceIndex: Int? = nil,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            self.cardStyle(cornerRadius: cornerRadius, elevation: elevation)
        }
        .buttonStyle(.pressable)
        .modifier(OptionalEntrance(index: entranceIndex))
    }

    /// `interactiveCard`, but on the Fest parchment recipe.
    func interactiveFestCard(cornerRadius: CGFloat = 16,
                             entranceIndex: Int? = nil,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            self.festCardStyle(cornerRadius: cornerRadius)
        }
        .buttonStyle(.pressable)
        .modifier(OptionalEntrance(index: entranceIndex))
    }

    /// Family Fest card surface — raised parchment card with an aged-gold hairline
    /// and a warm soft shadow. Use for day-section cards, info cards, and utility
    /// links inside the Fest section so they read as gilded manuscript panels
    /// rather than flat tiles.
    func festCardStyle(cornerRadius: CGFloat = 16) -> some View {
        self
            .background(Color.mlrFestCard)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.mlrFestGold.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 4)
    }
}

/// Applies `.cardEntrance(index:)` only when an index is provided.
private struct OptionalEntrance: ViewModifier {
    let index: Int?
    func body(content: Content) -> some View {
        if let index { content.cardEntrance(index: index) } else { content }
    }
}

// MARK: - Brand gradients
//
// Reusable multi-stop gradients for hero banners and layered surfaces. Kept as
// static factories so call sites read declaratively (`.northwoodsSunset`).

@MainActor
extension LinearGradient {
    /// Warm→cool "campfire → sun → dusk" sweep for Home / section heroes.
    static var northwoodsSunset: LinearGradient {
        LinearGradient(
            colors: [.mlrCampfire, .mlrSun, .mlrDusk],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Heraldic wine→gold gradient for the Family Fest hero banner.
    static var festHeraldic: LinearGradient {
        LinearGradient(
            colors: [.mlrFest, .mlrFestGold],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Section label

struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.mlrScaled(11, weight: .semibold))
            .foregroundStyle(Color.mlrTextMuted)
            .tracking(0.8)
    }
}
