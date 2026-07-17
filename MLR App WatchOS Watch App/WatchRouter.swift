import Foundation

// MARK: - WatchRouter
//
// Drives deep navigation on the watch — set from a tapped (forwarded)
// notification. iOS forwards the iPhone's APNs pushes to the watch
// automatically; WatchNotificationController maps the tapped payload's
// `target_type` to a route here, and ContentView navigates to it. New routes
// are added as their screens land (Chats, Fest schedule, …).

enum WatchRoute: Hashable {
    case work
    case chats
    // case fest            // added when the Fest schedule screen lands
}

@MainActor
@Observable
final class WatchRouter {
    static let shared = WatchRouter()
    var route: WatchRoute?
    private init() {}
}
