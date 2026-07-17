// swift-tools-version: 6.0
import PackageDescription

// MLRCore — shared, UIKit-free core for the MLR iOS app. Holds the Supabase
// client (a watchOS companion was deferred to a later version).
let package = Package(
    name: "MLRCore",
    platforms: [
        .iOS(.v18),
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
