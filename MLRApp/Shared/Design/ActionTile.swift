import SwiftUI

// MARK: - ActionTile
//
// A compact 2-across grid tile for a screen's action entry points (chat,
// schedule a meeting, email members, …) — the replacement for a column of
// full-width pill bars, which cost a full screen of chrome before the actual
// content (a roster, a feed) came into view. Mirrors the web app's
// `ActionTile` (CommitteeDetail.tsx) but leans on the native motion kit
// (`.pressable`, `.cardEntrance`) for spring press + staggered entrance.
//
// Usage: wrap the label in whatever makes it tappable (`Button`/`NavigationLink`)
// so this stays a pure content view:
//
//   Button { showEmail = true } label: {
//       ActionTileLabel(systemImage: "envelope.fill", title: "Email members")
//   }
//   .buttonStyle(.pressable)
//   .actionTileEntrance(index: i)

// MARK: - Equal height across the whole grid, not just within a row
//
// `LazyVGrid` only equalizes height WITHIN a row — a tile several rows down
// whose label wraps to a 2nd line can make just THAT row taller than the
// others, so the grid reads as uneven even though no single tile looks wrong
// on its own. This is the same defect class web's PR #501 fixed for its CSS
// grid (there, `min-h` only set a floor; the fix was a fixed height). A fixed
// point-value isn't safe here — a longer label at a large Dynamic Type size
// could clip — so instead every tile reports its own natural (unconstrained)
// height upward, `ActionTileGrid` takes the max, and feeds it back down so
// every tile — regardless of row — locks to the tallest one actually needed.

private struct ActionTileHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ActionTileEqualHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

private extension EnvironmentValues {
    var actionTileEqualHeight: CGFloat? {
        get { self[ActionTileEqualHeightKey.self] }
        set { self[ActionTileEqualHeightKey.self] = newValue }
    }
}

struct ActionTileLabel: View {
    enum Tone { case primary, neutral, danger }

    let systemImage: String
    let title: String
    var tone: Tone = .neutral
    var badge: String? = nil

    @Environment(\.actionTileEqualHeight) private var equalHeight

    var body: some View {
        VStack(alignment: .leading, spacing: MLRSpacing.sm) {
            HStack(alignment: .top) {
                Image(systemName: systemImage)
                    .font(.mlrScaled(19, weight: .semibold))
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.mlrScaled(11, weight: .bold))
                        .foregroundStyle(tone == .primary ? .white : Color.mlrPrimary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background((tone == .primary ? Color.white : Color.mlrPrimary).opacity(0.22))
                        .clipShape(Capsule())
                }
            }
            Spacer(minLength: 0)
            Text(title)
                .font(.mlrScaled(14, weight: .semibold))
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(foreground)
        .padding(MLRSpacing.md)
        .frame(minHeight: 78, maxWidth: .infinity, alignment: .topLeading)
        // Once ActionTileGrid has measured every tile's natural height, this
        // pins ALL of them to the tallest — never below it, so nothing clips.
        .frame(height: equalHeight)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ActionTileHeightKey.self, value: proxy.size.height)
            }
        )
        .background(background)
    }

    private var foreground: Color {
        switch tone {
        case .primary: return .white
        case .neutral: return Color.mlrPrimary
        case .danger:  return Color.mlrDanger
        }
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: MLRRadius.card)
        switch tone {
        case .primary:
            shape.fill(Color.mlrPrimary).shadow(.low)
        case .neutral:
            shape.fill(Color.mlrPrimary.opacity(0.1))
        case .danger:
            shape.fill(Color.mlrDanger.opacity(0.1))
        }
    }
}

/// Staggered spring entrance for a grid of `ActionTile`s — same recipe as
/// `.cardEntrance(index:)` but named for call-site clarity in a `LazyVGrid`.
extension View {
    func actionTileEntrance(index: Int) -> some View {
        cardEntrance(index: index)
    }
}

/// A 2-column grid of already-wrapped (Button/NavigationLink) action tiles.
/// Renders nothing when empty so callers don't need their own `if !empty`.
struct ActionTileGrid<Content: View>: View {
    let count: Int
    let content: () -> Content

    @State private var tileHeight: CGFloat?

    private let columns = [GridItem(.flexible(), spacing: MLRSpacing.sm),
                            GridItem(.flexible(), spacing: MLRSpacing.sm)]

    init(count: Int, @ViewBuilder content: @escaping () -> Content) {
        self.count = count
        self.content = content
    }

    var body: some View {
        if count > 0 {
            LazyVGrid(columns: columns, spacing: MLRSpacing.sm) {
                content()
            }
            .environment(\.actionTileEqualHeight, tileHeight)
            .onPreferenceChange(ActionTileHeightKey.self) { measured in
                if measured > 0 { tileHeight = measured }
            }
        }
    }
}
