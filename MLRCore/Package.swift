// swift-tools-version: 6.0
import PackageDescription

// MLRCore — shared model + service layer used by BOTH the iOS app and the
// watchOS app. Contains the Supabase client, the Codable models, and the
// networking services (no UIKit/SwiftUI). UI stays in each app target.
let package = Package(
    name: "MLRCore",
    platforms: [
        .iOS(.v18),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "MLRCore", targets: ["MLRCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "MLRCore",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift"),
            ]
        ),
    ],
    // Match the apps' Swift 5 language mode so the moved @MainActor @Observable
    // services don't trip Swift 6 data-race checking during the extraction.
    swiftLanguageModes: [.v5]
)
