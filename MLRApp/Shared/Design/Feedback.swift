import SwiftUI

// MARK: - Declarative feedback helpers (UI/UX overhaul Phase 1.3)
//
// `.mlrFeedback` is the default for NEW code (declarative, view-scoped);
// the ~32 existing imperative `Haptics.*` call sites stay as-is.

extension View {
    /// Declarative haptic tied to a value change — thin wrapper over the
    /// iOS 17 `.sensoryFeedback` so call sites read consistently.
    func mlrFeedback<T: Equatable>(_ feedback: SensoryFeedback, trigger: T) -> some View {
        sensoryFeedback(feedback, trigger: trigger)
    }

    /// Numeric roll for counters (votes, RSVPs, totals). Pair with
    /// `.monospacedDigit()` where columns must not shift.
    func numericTransition() -> some View {
        contentTransition(.numericText())
    }
}

// MARK: - FeedbackSymbol

/// A tappable SF Symbol that bounces (Reduce Motion: no bounce) and fires a
/// selection haptic — for small delight moments like reaction/like taps.
struct FeedbackSymbol: View {
    let systemName: String
    var font: Font = .mlrScaled(16, weight: .semibold)
    var tint: Color = .mlrPrimary
    var action: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounce = 0

    var body: some View {
        Button {
            if !reduceMotion { bounce += 1 }
            action()
        } label: {
            Image(systemName: systemName)
                .font(font)
                .foregroundStyle(tint)
                .symbolEffect(.bounce, value: bounce)
        }
        .buttonStyle(.plain)
        .mlrFeedback(.selection, trigger: bounce)
    }
}
