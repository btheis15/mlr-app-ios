import SwiftUI

// MARK: - Confetti (web #347 native analog)
//
// A one-shot particle burst driven by a `trigger` counter — bump it to fire.
// Purely decorative and self-contained; renders nothing at rest. Callers should
// only fire it when Reduce Motion is off (the burst is skipped for accessibility
// either way). Pair with Haptics.success() at the call site.

private struct ConfettiPiece: Identifiable {
    let id: Int
    let dx: CGFloat
    let dy: CGFloat
    let rotation: Double
    let emoji: String
    let delay: Double
}

struct ConfettiView: View {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pieces: [ConfettiPiece] = []
    @State private var animate = false

    private static let emojis = ["🎉", "✨", "🎊", "🥳", "⭐️"]

    var body: some View {
        ZStack {
            ForEach(pieces) { piece in
                Text(piece.emoji)
                    .font(.system(size: 20))
                    .offset(x: animate ? piece.dx : 0, y: animate ? piece.dy : 0)
                    .rotationEffect(.degrees(animate ? piece.rotation : 0))
                    .opacity(animate ? 0 : 1)
                    .animation(.easeOut(duration: 0.9).delay(piece.delay), value: animate)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in fire() }
    }

    private func fire() {
        guard !reduceMotion, trigger > 0 else { return }
        pieces = (0..<14).map { i in
            ConfettiPiece(
                id: i,
                dx: .random(in: -110...110),
                dy: .random(in: -150 ... -40),
                rotation: .random(in: -220...220),
                emoji: Self.emojis[i % Self.emojis.count],
                delay: .random(in: 0...0.12))
        }
        animate = false
        // Kick the animation on the next runloop tick so the reset lands first.
        DispatchQueue.main.async {
            withAnimation { animate = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            pieces = []
        }
    }
}
