import SwiftUI
import UIKit

// MARK: - HomeHero (UI/UX overhaul Phase 4)
//
// Full-bleed northwoods mesh hero: centered logo + the Yellowtail script
// wordmark + a time-of-day greeting, with translucent glass circle buttons for
// search and the admin date preview. Stretchy parallax on overscroll (classic
// GeometryReader header — frozen under Reduce Motion).

struct HomeHero: View {
    let isAdmin: Bool
    let previewingDate: Bool
    var onSearch: () -> Void
    var onDatePreview: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12:  return "Good morning, Up North"
        case 12..<17: return "Good afternoon, Up North"
        case 17..<21: return "Good evening, Up North"
        default:      return "Goodnight, Up North"
        }
    }

    /// Real top safe-area inset of the key window. GeometryReaders inside
    /// `ScrollView` content report zero safe-area insets, so the resting scroll
    /// offset (and the notch clearance for the glass buttons) must come from
    /// the window instead.
    private var windowTopInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.safeAreaInsets.top ?? 59
    }

    var body: some View {
        GeometryReader { geo in
            // Scroll content rests BELOW the top safe area, so the hero's
            // resting global minY equals the window's top inset — measure
            // overscroll stretch relative to that, not to 0. (Measuring
            // against 0 permanently applied a phantom stretch that shoved the
            // glass buttons offscreen above the notch.)
            let topInset = windowTopInset
            let minY = geo.frame(in: .global).minY
            let stretch = (!reduceMotion && minY > topInset) ? minY - topInset : 0

            ZStack(alignment: .bottom) {
                // Mesh fills the whole band, including the safe-area extension
                // under the status bar (drawn even with Reduce Motion on).
                MeshHeroBackground(theme: .northwoods)

                // Content floats over the mesh, above the scrim.
                VStack(spacing: 6) {
                    SiteImage(key: SiteImageKey.homeLogo, fallback: "brand-logo-green")
                        .scaledToFit()
                        .frame(maxWidth: 150)
                        .shadow(.medium)
                    Text("Muskellunge Lake Resort")
                        .font(.script(30))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(greeting)
                        .font(.mlrScaled(13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .tracking(0.4)
                }
                .padding(.bottom, 22)
                .frame(maxWidth: .infinity)
                .heroOverlayScrim()

                // Glass circle actions pinned to the top corners, just below
                // the status bar (the band's top edge sits at screen y = 0).
                VStack {
                    HStack {
                        if isAdmin {
                            heroCircleButton(
                                icon: previewingDate ? "calendar.badge.exclamationmark" : "calendar.badge.clock",
                                tint: previewingDate ? .orange : .white,
                                label: "View Home as a date",
                                action: onDatePreview)
                        }
                        Spacer()
                        heroCircleButton(icon: "magnifyingglass", tint: .white,
                                         label: "Search Up North", action: onSearch)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, topInset + 6)
                    Spacer()
                }
            }
            // Band = 270pt of hero + the safe-area extension + any overscroll
            // stretch; bottom-pinned to the 270pt layout slot so the extra
            // height grows upward, keeping the top edge at screen y = 0.
            .frame(height: 270 + topInset + stretch)
            .frame(height: 270, alignment: .bottom)
        }
        .frame(height: 270)
    }

    private func heroCircleButton(icon: String, tint: Color, label: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: icon)
                .font(.mlrScaled(16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(label)
    }
}
