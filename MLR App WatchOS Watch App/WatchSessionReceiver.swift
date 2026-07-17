import Foundation
import WatchConnectivity
import MLRCore

// MARK: - WatchSessionReceiver
//
// The watch app doesn't sign in on-device. The paired iPhone pushes the current
// Supabase session tokens over WatchConnectivity (as the persisted "application
// context", so it's delivered even when the watch wasn't reachable at send
// time). We hand them to MLRCore's Supabase client via `setSession`, which then
// makes authenticated queries just like the phone. `isAuthed` drives the UI.

@MainActor
@Observable
final class WatchSessionReceiver: NSObject {
    static let shared = WatchSessionReceiver()

    /// True once a session has been applied to the Supabase client.
    var isAuthed = false
    /// Set when we've received context but it carried no tokens (phone signed out).
    var awaitingPhone = true

    private override init() { super.init() }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        // Apply anything already delivered before we became the delegate.
        apply(session.receivedApplicationContext)
    }

    private func apply(_ context: [String: Any]) {
        guard let access = context["accessToken"] as? String,
              let refresh = context["refreshToken"] as? String,
              !access.isEmpty, !refresh.isEmpty
        else {
            // Empty tokens = phone is signed out; leave the watch unauthed.
            if context["accessToken"] != nil { awaitingPhone = false; isAuthed = false }
            return
        }
        Task {
            do {
                try await supabase.auth.setSession(accessToken: access, refreshToken: refresh)
                isAuthed = true
                awaitingPhone = false
            } catch {
                isAuthed = false
                awaitingPhone = false
                print("[WatchSession] setSession failed: \(error)")
            }
        }
    }
}

extension WatchSessionReceiver: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let ctx = session.receivedApplicationContext
        Task { @MainActor in self.apply(ctx) }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.apply(applicationContext) }
    }
}
