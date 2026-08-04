import Foundation

// MARK: - Owner-only infrastructure gate
//
// The single account allowed to touch owner-only infrastructure controls
// (right now: remotely restarting the mac mini's media server) — deliberately
// narrower than `profiles.is_admin`, since every app admin doesn't need
// access to a "restart the server" button. Mirrored server-side by the
// media-server's own `requireOwner` check — this client-side check only
// decides whether to SHOW the control; the server re-verifies against the
// caller's actual signed-in Supabase session either way, so hiding the UI is
// a convenience, not the real gate. Mirrors web's lib/owner.ts verbatim.

let OWNER_EMAIL = "brian.theis15@gmail.com"

func isOwner(_ email: String?) -> Bool {
    (email ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == OWNER_EMAIL
}
