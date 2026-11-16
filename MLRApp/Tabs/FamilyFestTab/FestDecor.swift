import SwiftUI

// MARK: - Family Fest decorative components
//
// Shared heraldic ornaments that give the Fest section its "Rich Renaissance +
// modern polish" identity. Two pieces:
//   • GoldOrnamentDivider — aged-gold rule with a centered fleur-de-lis, used
//     between major sections in place of a plain Divider.
//   • FestHeroGlow — a soft wine→gold gradient wash placed behind the fest cover
//     so the poster reads as a lit centerpiece rather than a flat tile.
// Body text inside the section should use `Color.mlrFestInk` (legible sepia/cream)
// — reserve `mlrFest` (wine) for headings and `mlrFestGold` for ornament.

/// Aged-gold ornamental divider with a centered fleur-de-lis. The rules fade
/// toward the ornament so it reads as a gilded manuscript flourish.
struct GoldOrnamentDivider: View {
    var body: some View {
        HStack(spacing: 10) {
            LinearGradient(
                colors: [.mlrFestGold.opacity(0), .mlrFestGold.opacity(0.7)],
                startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
            Text("\u{269C}") // ⚜ fleur-de-lis
                .font(.mlrScaled(13))
                .foregroundStyle(Color.mlrFestGold)
            LinearGradient(
                colors: [.mlrFestGold.opacity(0.7), .mlrFestGold.opacity(0)],
                startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
        }
        .accessibilityHidden(true)
    }
}

/// A soft radial wine→gold glow, sized to sit behind the fest cover art. Gives
/// the poster a warm halo so it feels lit from within — the "modern polish"
/// layer over the heraldic palette.
struct FestHeroGlow: View {
    var body: some View {
        RadialGradient(
            colors: [.mlrFestGold.opacity(0.35), .mlrFest.opacity(0.12), .clear],
            center: .center, startRadius: 4, endRadius: 260)
        .blur(radius: 24)
        .accessibilityHidden(true)
    }
}

// MARK: - Fest heading text style

extension Text {
    /// Fest section heading — Cinzel serif, uppercase, tracked, wine. Reserve for
    /// short headings/labels; running body text should stay in a readable system
    /// font (`.mlrScaled`) colored `mlrFestInk`.
    func festHeadingStyle(size: CGFloat = 15) -> some View {
        self.font(.festSerif(size, weight: .bold))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(Color.mlrFest)
    }
}

// MARK: - Per-year look scope (migration 0219)

/// Applies a fest year's look to the screen. The fest palette resolves through
/// `FestThemeStore.active`, so this sets it before the content renders and
/// rebuilds when the look changes. `config == nil` means the CURRENT year; a
/// Past Years page passes its own year and the current look is restored on leave.
private struct FestThemeScope: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    let config: FestConfig?

    private var look: FestTheme { (config ?? env.festContentService.config)?.look ?? .builtIn }
    private var currentLook: FestTheme { env.festContentService.config?.look ?? .builtIn }

    func body(content: Content) -> some View {
        // Set during body so children resolve against the right look on first render.
        // The current year's look is kept by FestContentService; only an archived
        // year overrides it, for as long as its page is up.
        let l = look
        if config != nil { FestThemeStore.active = l }
        return content
            .id(l)
            .onAppear { if config != nil { FestThemeStore.active = look } }
            .onDisappear { if config != nil { FestThemeStore.active = currentLook } }
    }
}

/// The year's page background: parchment, plus an optional photo under it at
/// the chosen strength (web: photo beneath a veil of the background colour).
struct FestThemedBackground: View {
    @Environment(AppEnvironment.self) private var env
    var config: FestConfig?

    var body: some View {
        let look = (config ?? env.festContentService.config)?.look ?? .builtIn
        ZStack {
            Color.mlrFestParchment
            if look.bgStyle == "image", let url = look.safeImageURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        if look.bgImageMode == "tile" {
                            image.resizable(resizingMode: .tile)
                        } else {
                            image.resizable().scaledToFill()
                        }
                    }
                }
                .opacity(look.imageStrength)
                .allowsHitTesting(false)
            }
        }
        .clipped()
        .ignoresSafeArea()
    }
}

extension View {
    /// Apply this (or, with `config`, an archived) fest year's look.
    func festThemeScope(_ config: FestConfig? = nil) -> some View {
        modifier(FestThemeScope(config: config))
    }
}
