// MLRCore — shared model + service layer for the MLR iOS and watchOS apps.
//
// This package holds UIKit-free code shared across targets: the Supabase client,
// Codable models, and networking services. UI (SwiftUI views) stays in each app
// target. Files are moved here incrementally from MLRApp/ during the watch-app
// extraction; this placeholder keeps the package valid until the first move.

import Foundation

enum MLRCore {
    /// Package marker; replaced as real shared types are moved in.
    static let version = "0.1.0"
}
