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
    func cardStyle() -> some View {
        self
            .background(Color.mlrCard)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.mlrBorder, lineWidth: 1)
            )
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
