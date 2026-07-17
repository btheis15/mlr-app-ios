// MLRCore — shared, UIKit-free core for the MLR iOS app.
//
// Holds the Supabase client (see MLRSupabase.swift) so the app gets it via
// `@_exported import MLRCore`. (Originally seeded for a watchOS companion, which
// has been deferred to a later version; kept as the app's Supabase client home.)

import Foundation

enum MLRCore {
    /// Package marker; replaced as real shared types are moved in.
    static let version = "0.1.0"
}
