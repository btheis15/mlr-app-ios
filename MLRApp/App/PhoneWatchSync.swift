import Foundation
import WatchConnectivity

// MARK: - PhoneWatchSync
//
// The iPhone half of the watch session bridge. After sign-in (and whenever the
// app becomes active) we push the current Supabase session tokens to the watch
// via `updateApplicationContext` — a persisted, coalesced payload delivered even
// if the watch isn't reachable at send time. The watch applies them with
// `supabase.auth.setSession` so it can make authenticated queries on its own.
//
// `supabase` is visible here via the app-wide `@_exported import MLRCore`.

@MainActor
final class PhoneWatchSync: NSObject {
    static let shared = PhoneWatchSync()
    private override init() { super.init() }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Push the current session tokens to the watch (no-op if signed out).
    func pushSession() async {
        guard WCSession.isSupported() else { return }
        guard let session = try? await supabase.auth.session else { clear(); return }
        send(access: session.accessToken, refresh: session.refreshToken)
    }

    /// Tell the watch we're signed out so it drops its session.
    func clear() {
        send(access: "", refresh: "")
    }

    private func send(access: String, refresh: String) {
        guard WCSession.isSupported() else { return }
        try? WCSession.default.updateApplicationContext([
            "accessToken": access,
            "refreshToken": refresh,
        ])
    }
}

extension PhoneWatchSync: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate for a newly-paired watch.
        WCSession.default.activate()
    }
}
