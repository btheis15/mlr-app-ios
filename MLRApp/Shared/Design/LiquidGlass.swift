import SwiftUI

// MARK: - Liquid Glass (iOS 26) with graceful fallback

// iOS 26 introduces the Liquid Glass design language (`.glassEffect(_:in:)`,
// `Glass` configs, `GlassEffectContainer`, `.buttonStyle(.glass)`, …).
//
// The app supports OS versions BELOW iOS 26, and those glass APIs are 26-only,
// so every helper here branches on `#available(iOS 26, *)`: it renders real
// Liquid Glass on iOS 26+ and falls back to an equivalent solid/tinted surface
// on older systems. All glass in the app flows through these helpers, so call
// sites never change and never reference a 26-only symbol directly.

// MARK: - Brand glass button styles

/// Primary call-to-action — prominent Liquid Glass tinted forest green on iOS 26,
/// solid forest-green fill on older systems.
struct GlassPrimaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.mlrScaled(16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        Group {
            if #available(iOS 26.0, *) {
                label.glassEffect(.regular.tint(.mlrPineText).interactive(), in: .rect(cornerRadius: 14))
            } else {
                label.background(RoundedRectangle(cornerRadius: 14).fill(Color.mlrPrimary))
            }
        }
        .opacity(configuration.isPressed ? 0.85 : 1)
        .scaleEffect(configuration.isPressed ? 0.98 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Secondary action — neutral regular glass with green label (light fill fallback).
struct GlassSecondaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.mlrScaled(16, weight: .semibold))
            .foregroundStyle(Color.mlrPineText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        Group {
            if scheme == .dark {
                label.background(RoundedRectangle(cornerRadius: 14).fill(Color.mlrSurface3))
            } else if #available(iOS 26.0, *) {
                label.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
            } else {
                label.background(RoundedRectangle(cornerRadius: 14).fill(Color.mlrPrimaryLight))
            }
        }
        .opacity(configuration.isPressed ? 0.85 : 1)
        .scaleEffect(configuration.isPressed ? 0.98 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Family Fest accent — heraldic-wine tinted glass for fest CTAs (solid fallback).
struct GlassFestButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.mlrScaled(16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        Group {
            if scheme == .dark {
                label.background(RoundedRectangle(cornerRadius: 14).fill(Color.mlrFest))
            } else if #available(iOS 26.0, *) {
                label.glassEffect(.regular.tint(.mlrFest).interactive(), in: .rect(cornerRadius: 14))
            } else {
                label.background(RoundedRectangle(cornerRadius: 14).fill(Color.mlrFest))
            }
        }
        .opacity(configuration.isPressed ? 0.85 : 1)
        .scaleEffect(configuration.isPressed ? 0.98 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Compact circular glass button — for floating actions (new post, ask for help).
struct GlassCircleButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    var tint: Color = .mlrPrimary
    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.mlrScaled(20, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 56, height: 56)
        Group {
            if scheme == .dark {
                label.background(Circle().fill(tint))
            } else if #available(iOS 26.0, *) {
                label.glassEffect(.regular.tint(tint).interactive(), in: .circle)
            } else {
                label.background(Circle().fill(tint))
            }
        }
        .scaleEffect(configuration.isPressed ? 0.92 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == GlassPrimaryButtonStyle {
    static var glassPrimary: GlassPrimaryButtonStyle { .init() }
}
extension ButtonStyle where Self == GlassSecondaryButtonStyle {
    static var glassSecondary: GlassSecondaryButtonStyle { .init() }
}
extension ButtonStyle where Self == GlassFestButtonStyle {
    static var glassFest: GlassFestButtonStyle { .init() }
}
extension ButtonStyle where Self == GlassCircleButtonStyle {
    static func glassCircle(tint: Color = .mlrPrimary) -> GlassCircleButtonStyle { .init(tint: tint) }
}

// MARK: - Glass card surface

private struct GlassCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    @Environment(\.colorScheme) private var scheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if scheme == .dark {
            // Dark: opaque surface, never see-through glass.
            content.background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(tint?.mlrTint(0.18, over: .mlrSurface2) ?? Color.mlrSurface2))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color.mlrBorder, lineWidth: 1))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular,
                                in: .rect(cornerRadius: cornerRadius))
        } else {
            content.background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(tint?.opacity(0.18) ?? Color.mlrCard))
        }
    }
}

/// Material in light mode; opaque surface-3 in dark (chips, pills, floating bits).
struct MLRChipFill: ShapeStyle {
    var thick = false
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        if environment.colorScheme == .dark { return AnyShapeStyle(Color.mlrSurface3) }
        return thick ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.ultraThinMaterial)
    }
}

extension View {
    /// Liquid Glass card on iOS 26 (tinted material on older); opaque in dark mode.
    func glassCard(cornerRadius: CGFloat = 18, tint: Color? = nil) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, tint: tint))
    }
}

// NOTE: `PulsingLiveDot` lives in `ios/Shared/PulsingLiveDot.swift` so it can be
// shared with the widget extension target (Live Activity + countdown widget).
