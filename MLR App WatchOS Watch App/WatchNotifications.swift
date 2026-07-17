import Foundation
import UserNotifications

// MARK: - WatchNotificationController
//
// Handles notifications on the watch. iOS forwards the paired iPhone's APNs
// pushes to the watch automatically (when the watch is the active device), so we
// don't register or receive pushes here — we only need to (a) keep showing them
// while the watch app is foreground, and (b) route a TAP to the right screen by
// reading the same `target_type` / `target_id` payload the iPhone app uses.
//
// Action-button handling (On my way / RSVP / Reply) is a follow-up — it needs
// the shared write services; for now a body tap opens the watch app + routes.

@MainActor
final class WatchNotificationController: NSObject {
    static let shared = WatchNotificationController()
    private override init() { super.init() }

    func activate() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Map the push payload's target to a watch route (nil = just open home).
    private func route(for userInfo: [AnyHashable: Any]) -> WatchRoute? {
        guard let target = userInfo["target_type"] as? String else { return nil }
        switch target {
        case "work_item", "work": return .work
        // Chats / Fest routes are added as those screens land.
        default: return nil
        }
    }
}

extension WatchNotificationController: UNUserNotificationCenterDelegate {
    // Show forwarded notifications even while the watch app is in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // A tap (or action) on a forwarded notification launches the watch app here.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        await MainActor.run {
            if let r = route(for: info) { WatchRouter.shared.route = r }
        }
    }
}
