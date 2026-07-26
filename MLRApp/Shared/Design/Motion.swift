import SwiftUI
import UIKit

// MARK: - Motion tokens + entrance/press modifiers (UI/UX overhaul Phase 1.2)
//
// Shared springs, scroll/staggered entrances, and the app-wide `.pressable`
// button style. EVERY path here degrades under Reduce Motion (matches the
// SkeletonPulseModifier / ExpandableScheduleRow convention): entrances become
// static, press-scale becomes opacity-only.

enum MLRMotion {
    /// Standard interactive spring (presses, toggles, reorder snaps).
    static let spring = Animation.spring(response: 0.34, dampingFraction: 0.72)
    /// Softer entrance spring (cards fading/rising in).
    static let entrance = Animation.spring(response: 0.45, dampingFraction: 0.8)
    /// Delay between staggered siblings.
    static let staggerStep: Double = 0.05
    /// Stagger delays cap here so long lists don't crawl.
    static let maxStaggerIndex = 8

    /// Reduce-Motion bridge (UIKit-backed so non-View code can check too).
    static var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }
}

// MARK: - Scroll entrance

/// Fades/scales/rises content as it scrolls into view — generalizes the
/// existing `.scrollTransition` recipe in `FestOverviewView`. No-op under
/// Reduce Motion.
private struct ScrollEntranceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var scale: CGFloat = 0.96
    var rise: CGFloat = 14

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.scrollTransition { inner, phase in
                inner
                    .opacity(phase.isIdentity ? 1 : 0.3)
                    .scaleEffect(phase.isIdentity ? 1 : scale)
                    .offset(y: phase.isIdentity ? 0 : rise)
            }
        }
    }
}

// MARK: - One-shot staggered card entrance

/// Staggered fade+rise for non-lazy content on first appearance. Delay is
/// `index * staggerStep`, capped at `maxStaggerIndex`. No-op (instant) under
/// Reduce Motion.
private struct CardEntranceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let index: Int
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 14)
            .onAppear {
                guard !appeared else { return }
                if reduceMotion {
                    appeared = true
                } else {
                    let delay = Double(min(index, MLRMotion.maxStaggerIndex)) * MLRMotion.staggerStep
                    withAnimation(MLRMotion.entrance.delay(delay)) { appeared = true }
                }
            }
    }
}

extension View {
    /// Fade/scale/rise as this view scrolls into view. Reduce Motion → no-op.
    func scrollEntrance(scale: CGFloat = 0.96, rise: CGFloat = 14) -> some View {
        modifier(ScrollEntranceModifier(scale: scale, rise: rise))
    }

    /// One-shot staggered entrance for the `index`-th sibling (non-lazy stacks).
    /// Reduce Motion → appears instantly.
    func cardEntrance(index: Int) -> some View {
        modifier(CardEntranceModifier(index: index))
    }
}

// MARK: - Pressable button style

/// Spring press-scale + light impact haptic — the drop-in replacement for
/// `.buttonStyle(.plain)` on tappable cards/rows. Under Reduce Motion the
/// scale is suppressed (opacity dip only).
struct MLRPressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(MLRMotion.spring, value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { _, pressed in pressed }
    }
}

extension ButtonStyle where Self == MLRPressableButtonStyle {
    /// `Button { … } label: { … }.buttonStyle(.pressable)`
    static var pressable: MLRPressableButtonStyle { MLRPressableButtonStyle() }
}
