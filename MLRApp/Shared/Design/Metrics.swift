import SwiftUI

// MARK: - Layout metric tokens (UI/UX overhaul Phase 1.1)
//
// Single source of truth for spacing, corner radii, and elevation so values stop
// living inline at ~150 call sites. Adopt in new/refactored code; the broad sweep
// migrates existing literals gradually.

/// Spacing scale (pt). `page`/`cardInset`/`stack` are semantic aliases.
enum MLRSpacing {
    static let xs: CGFloat  = 4
    static let sm: CGFloat  = 8
    static let md: CGFloat  = 12
    static let lg: CGFloat  = 16
    static let xl: CGFloat  = 24
    static let xxl: CGFloat = 32

    /// Default screen edge padding.
    static let page: CGFloat = 16
    /// Default padding inside a card.
    static let cardInset: CGFloat = 16
    /// Default spacing between stacked cards/sections.
    static let stack: CGFloat = 12
}

/// Corner radius scale (pt).
enum MLRRadius {
    static let sm: CGFloat     = 8
    static let button: CGFloat = 14
    static let card: CGFloat   = 16
    static let lg: CGFloat     = 18
    static let xl: CGFloat     = 24
    static let pill: CGFloat   = 999
}

/// Elevation ramp — a warm-neutral black ambient shadow. Intentionally
/// near-invisible on the OLED-black dark canvas (borders + tint/gradient washes
/// + press-scale carry the lift there instead of heavier shadows).
enum MLRElevation {
    case none, low, medium, high, hero

    var opacity: Double {
        switch self {
        case .none:   return 0
        case .low:    return 0.06   // == the legacy `cardStyle(elevated: true)` recipe
        case .medium: return 0.10
        case .high:   return 0.14
        case .hero:   return 0.20
        }
    }
    var radius: CGFloat {
        switch self {
        case .none: return 0
        case .low: return 10
        case .medium: return 16
        case .high: return 22
        case .hero: return 30
        }
    }
    var y: CGFloat {
        switch self {
        case .none: return 0
        case .low: return 4
        case .medium: return 8
        case .high: return 12
        case .hero: return 18
        }
    }
}

extension View {
    /// Applies the MLR elevation ramp as an ambient shadow.
    func shadow(_ level: MLRElevation) -> some View {
        shadow(color: .black.opacity(level.opacity), radius: level.radius, x: 0, y: level.y)
    }
}
