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

// MARK: - Fest cover (per-year, app-wide fallback)

/// The fest cover. Priority matches web's FestCover: THIS YEAR's own
/// `fest_config.cover_url` first, then the app-wide `app_images.fest_cover`,
/// then the bundled art. A year's cover failing to load also falls back to the
/// app-wide image so the header is never blank. `tint`/`gold` default to the
/// active look; the editor preview passes its draft colours instead.
private struct CoverFit: ViewModifier {
    let fillHeight: CGFloat?
    func body(content: Content) -> some View {
        if let h = fillHeight {
            content.scaledToFill().frame(maxWidth: .infinity).frame(height: h).clipped()
        } else {
            content.scaledToFit().frame(maxWidth: .infinity)
        }
    }
}

struct FestYearCover: View {
    let coverUrl: String?
    var tint: Color = .mlrFest
    var gold: Color = .mlrFestGold
    var accessibilityText = "Family Fest cover"
    /// Fixed-height banner that fills and crops instead of letterboxing (editor preview).
    var fillHeight: CGFloat? = nil

    private var yearURL: URL? {
        guard let s = coverUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return URL(string: s)
    }

    private var fallback: some View {
        SiteImage(key: SiteImageKey.festCover, fallback: "family-fest-cover")
    }

    var body: some View {
        Group {
            if let url = yearURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable() } else { fallback }
                }
            } else {
                fallback
            }
        }
        .modifier(CoverFit(fillHeight: fillHeight))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(LinearGradient(colors: [tint, gold],
                                             startPoint: .topLeading, endPoint: .bottomTrailing),
                              lineWidth: 1.5)
        )
        .shadow(color: tint.opacity(0.18), radius: 16, x: 0, y: 8)
        .accessibilityLabel(accessibilityText)
    }
}

// MARK: - Draft look preview (editor)

/// Renders a DRAFT look without touching `FestThemeStore.active`: the real fest
/// pieces (cover, card, heading, background treatment) are drawn from the draft's
/// own resolved colours and font, so the app-wide look never changes while editing.
/// Light-mode values, like web's editor (dark mode only takes primary and accent).
struct FestLookPreview: View {
    let look: FestTheme
    let coverUrl: String?
    let themeLine: String?

    private func color(_ slot: FestTheme.Slot, _ builtIn: String) -> Color {
        Color(hex: look.hex(slot, dark: false) ?? builtIn)
    }
    // Built-in values mirror Colors.swift (light).
    private var primary: Color { color(.primary, "#6B0F24") }
    private var gold: Color { color(.accent, "#C29A2E") }
    private var parchment: Color { color(.background, "#ECDCBE") }
    private var card: Color { color(.card, "#FBF3E1") }
    private var ink: Color { color(.ink, "#33240F") }
    private var border: Color {
        look.hex(.border, dark: false).map { Color(hex: $0) } ?? Color(hex: "#C29A2E").opacity(0.6)
    }

    private func serif(_ size: CGFloat) -> Font {
        switch look.font {
        case "playfair": return .system(size: size, weight: .bold, design: .serif)
        case "sans": return .system(size: size, weight: .bold)
        default: return .custom("Cinzel-Bold", size: size)
        }
    }

    private var headline: String {
        let t = themeLine?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? "Family Fest" : t
    }

    var body: some View {
        ZStack {
            parchment
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
            VStack(spacing: 12) {
                FestYearCover(coverUrl: coverUrl, tint: primary, gold: gold, fillHeight: 120)
                Text(headline)
                    .font(serif(15))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(primary)
                    .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Wednesday")
                        .font(serif(14))
                        .foregroundStyle(primary)
                    Text("Sample card text on the card colour.")
                        .font(.mlrScaled(12))
                        .foregroundStyle(ink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(card)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(border, lineWidth: 1))
                Text("Button")
                    .font(.mlrScaled(13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(primary, in: Capsule())
            }
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of this year's look")
    }
}
