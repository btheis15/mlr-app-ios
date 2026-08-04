import SwiftUI

// MARK: - CollapsibleSection
//
// A tappable header card (emoji + title + subtitle + rotating chevron) that
// reveals its content when open, collapsed by default. Mirrors the web app's
// shared `CollapsibleSection` (used by Profile, CommitteeEmailMembers, and
// CommitteeDetail's "Reach the group" — see PR #500) — one component, reused,
// rather than a private one-off per screen. Previously duplicated privately as
// `CollapsibleHomeSection` in HomeView.swift; promoted here so
// CommitteeDetailView can share it too.

struct CollapsibleSection<Content: View>: View {
    let title: String
    let emoji: String
    /// Names what's inside while collapsed (e.g. "Chat · email · schedule a
    /// meeting") so collapsing doesn't hide that those actions live here.
    /// Pass "" to omit the subtitle line entirely.
    let subtitle: String
    let content: Content

    @State private var isOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(title: String, emoji: String, subtitle: String = "", @ViewBuilder content: () -> Content) {
        self.title = title
        self.emoji = emoji
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Text(emoji).font(.mlrScaled(20))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.mlrScaled(16, weight: .semibold))
                            .foregroundStyle(Color.mlrText)
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(Color.mlrTextMuted)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.mlrScaled(14, weight: .semibold))
                        .foregroundStyle(Color.mlrTextSubtle)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .cardStyle()
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)

            if isOpen {
                content
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity))
            }
        }
    }
}
