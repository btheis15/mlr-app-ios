import SwiftUI
import UIKit

// MARK: - MLR Color Tokens (adaptive light + dark)
//
// The app supports BOTH light and dark mode. Every brand token below is an
// ADAPTIVE color: it resolves to a light value in light mode and a dark value in
// dark mode via a UIColor dynamic provider. Surface/text tokens use Apple's
// semantic system colors, which already adapt.
//
// ⚠️ Transparency rule (read before adding any translucent surface):
//   • For a *surface/card background*, prefer an opaque adaptive token
//     (`mlrCard`, `mlrSurface`) or a `Material` — NOT a translucent solid color.
//     A solid color at low opacity goes muddy grey on light AND washed-out on
//     dark. The brand "tint card" fills (e.g. `mlrFest.opacity(0.1)`) are only OK
//     because they sit over an adaptive surface and the tint token itself adapts.
//   • `Color.black.opacity(...)` is allowed ONLY as a modal scrim / lightbox bg.
//   • Never put a translucent layer over a hardcoded `Color.white` — use
//     `mlrSurface` so the backdrop is correct in dark mode.
//   • Liquid Glass (`.glassEffect`) must sit over real content/an adaptive
//     surface, never over literal white, or it can't read the backdrop.

extension Color {
    // Primary brand — forest green (the logo)
    static let mlrPrimary      = Color(light: "#15503a", dark: "#46A578")
    static let mlrPrimaryDark  = Color(light: "#0f3d2b", dark: "#2E7D5B")
    /// Pale fill used behind secondary buttons / tint chips. Dim green in dark.
    static let mlrPrimaryLight = Color(light: "#e8f2ec", dark: "#16352A")

    // Accent — campfire orange (was a dull chestnut #804020, which read muddy).
    // The warm orange gives CTAs/highlights the "Northwoods sunset" energy the web
    // app has, and reads cleanly on both the birch light bg and OLED dark.
    static let mlrAccent       = Color(light: "#c2410c", dark: "#F08A4B")

    // MARK: Northwoods accent palette
    // A small warm→cool set used for gradient heroes, garnish icons, and status
    // pops. Each is an adaptive pair (brightened on dark for OLED contrast).
    static let mlrLake         = Color(light: "#0e7490", dark: "#5FB0D4")  // deep lake blue
    static let mlrCampfire     = Color(light: "#c2410c", dark: "#F08A4B")  // campfire orange
    static let mlrSun          = Color(light: "#b45309", dark: "#FACC46")  // afternoon sun gold
    static let mlrDusk         = Color(light: "#6d28d9", dark: "#A78BFA")  // twilight violet

    // Family Fest heraldic wine + parchment (the FF section's identity).
    // Parchment becomes a dark warm brown in dark mode so the section still reads
    // as a distinct "Renaissance" world rather than the resort's pure-black canvas.
    static let mlrFest          = Color(light: "#8b2e2e", dark: "#E0708A", festSlot: .primary)
    static let mlrFestLight     = Color(light: "#F6E4CF", dark: "#3A2A22")
    static let mlrFestParchment = Color(light: "#f4ecd8", dark: "#1E1712", festSlot: .background)
    /// Raised card surface inside the Fest section — white on parchment (light),
    /// clearly elevated warm brown in dark mode. Use for day-section cards, info
    /// cards, and utility links so they stand out against the parchment page bg.
    static let mlrFestCard      = Color(light: "#fdfaf1", dark: "#40332A", festSlot: .card)
    /// Fest BODY text — warm sepia ink on light parchment, warm cream on dark.
    /// Reserve `mlrFest` (wine) for headings/accents; body should use this so it
    /// stops reading as low-contrast tinted grey. (Renaissance manuscript ink.)
    static let mlrFestInk       = Color(light: "#3a2a18", dark: "#F1E7D6", festSlot: .ink)
    /// Aged-gold heraldic accent — ornamental dividers, crest motifs, gilt rules.
    /// Fest card/divider stroke: the year's border colour, else gold at 60%.
    static let mlrFestBorder = Color(uiColor: UIColor { traits in
        let isDark = traits.userInterfaceStyle == .dark
        if let hex = FestThemeStore.active.hex(.border, dark: isDark) { return UIColor(Color(hex: hex)) }
        return isDark ? UIColor(Color(hex: "#E7C05A")).withAlphaComponent(0.6) : UIColor(Color(hex: "#d8c7a3"))
    })
    static let mlrFestGold      = Color(light: "#C29A2E", dark: "#E7C05A", festSlot: .accent)

    // Payment brand colors (Fest pay rows, member pay links). Brand-fixed hues,
    // nudged lighter on dark so the pills stay legible on OLED.
    static let mlrVenmo        = Color(light: "#3d95ce", dark: "#4FA8DE")
    static let mlrPaypal       = Color(light: "#003087", dark: "#4DA8E0")

    // Surfaces — match the web app's palette in light mode (warm birch page /
    // white raised cards / soft hairline border); fall back to Apple semantics
    // in dark mode so the app adapts cleanly to OLED black.
    static let mlrSurface     = Color(light: "#f6f6f1", dark: "#0f1613")  // warm birch bg
    static let mlrCard        = Color(light: "#ffffff", dark: "#1a2420")  // raised white card
    static let mlrGroupedCard = Color(.tertiarySystemBackground)
    static let mlrBorder      = Color(light: "#e5e4da", dark: "#2c3a33")  // soft warm hairline

    // Text — semantic, auto-adapting
    static let mlrText         = Color(light: "#14241c", dark: "#F2F5F3")  // foreground
    static let mlrTextMuted    = Color(light: "#4b5b52", dark: "#A8B4AD")
    static let mlrTextSubtle   = Color(light: "#64716a", dark: "#8A978F")  // "faint"
    static let mlrTextFaint    = mlrTextSubtle

    // Revamp additions
    /// Logo green (brand mark only).
    static let mlrLogoGreen    = Color(light: "#0c4029", dark: "#4fae8a")
    /// Pine as TEXT/tint on dark surfaces (lightened); same as mlrPrimary on light.
    static let mlrPineText     = Color(light: "#15503a", dark: "#4fae8a")
    /// Fest azure accent (theme accent slot).
    static let mlrFestAzure    = Color(light: "#1e3a8a", dark: "#8fa8f0", festSlot: .accent)
    /// Fest wine (theme primary slot); alias of mlrFest.
    static let mlrFestWine     = mlrFest
    /// Backdrop gradient stops (birch to sage) and glows.
    static let mlrBackdropTop    = Color(light: "#f3f4ee", dark: "#0f1613")
    static let mlrBackdropBottom = Color(light: "#e6ebe1", dark: "#0b110e")

    // Status — brightened in dark for contrast on black
    static let mlrSuccess      = Color(light: "#16a34a", dark: "#34D17F")
    static let mlrWarning      = Color(light: "#d97706", dark: "#F59E42")
    static let mlrDanger       = Color(light: "#dc2626", dark: "#F26B6B")
    static let mlrInfo         = Color(light: "#2563eb", dark: "#5B9BFF")
}

// MARK: - Initializers

extension Color {
    /// Solid hex color (used for the per-mode values below).
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        switch hex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8)  & 0xFF) / 255
            b = Double(int         & 0xFF) / 255
        default:
            r = 1; g = 1; b = 1
        }
        self.init(red: r, green: g, blue: b)
    }

    /// Fest palette color: resolves the active year's look (`FestThemeStore`)
    /// first, else the built-in pair. Dark mode only takes primary and accent.
    init(light: String, dark: String, festSlot: FestTheme.Slot) {
        self.init(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            if let hex = FestThemeStore.active.hex(festSlot, dark: isDark) {
                return UIColor(Color(hex: hex))
            }
            return UIColor(Color(hex: isDark ? dark : light))
        })
    }

    /// Adaptive color resolving per the active interface style.
    init(light: String, dark: String) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(Color(hex: dark))
                : UIColor(Color(hex: light))
        })
    }
}
