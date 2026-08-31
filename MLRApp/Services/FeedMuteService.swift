import Foundation
import Supabase

// MARK: - Muting the Family Feed (migration 0214)
//
// Committee and house rooms have had their own bell since 0155; the Family Feed
// — the noisiest surface in the app — had no way to turn down. This is the same
// shape, one row per member.
//
// ⚠️ THE muted / muted_until SPLIT. Exactly one is ever set:
//
//     permanent  → muted = true,  muted_until = null
//     timed      → muted = false, muted_until = <when>
//     unmuted    → muted = false, muted_until = null
//
// A timer expires by going STALE — no cron, no sweep. Writing both (which every
// caller used to do) makes the `muted` half match unconditionally forever, so
// the timestamp beside it never gets a chance to lapse. "Mute for 1 day" muted
// chats permanently for months before 0215 fixed the writers, and the UI went
// on cheerfully saying "Muted until <date>" the whole time.
//
// The RPC now enforces the split, so callers pass the duration and let it
// decide — but the READER has to honour both halves, which is what `isMuted`
// below does.

@Observable
@MainActor
final class FeedMuteService {

    private(set) var muted = false
    private(set) var mutedUntil: Date?

    /// Effectively muted: a permanent mute, OR a timer still in the future.
    var isMuted: Bool {
        if muted { return true }
        if let mutedUntil { return mutedUntil > .now }
        return false
    }

    /// A label the bell can show — nil when not muted.
    var muteLabel: String? {
        guard isMuted else { return nil }
        if muted { return "Muted" }
        guard let mutedUntil else { return "Muted" }
        return "Muted until \(mutedUntil.formatted(date: .abbreviated, time: .shortened))"
    }

    func load() async {
        struct Row: Decodable {
            let muted: Bool?
            let mutedUntil: Date?
            enum CodingKeys: String, CodingKey {
                case muted
                case mutedUntil = "muted_until"
            }
        }
        // Own-row RLS means at most one row comes back, and none at all is the
        // normal "never muted anything" state — not an error.
        let rows: [Row] = (try? await supabase
            .from("feed_mutes").select("muted, muted_until").limit(1)
            .execute().value) ?? []
        muted = rows.first?.muted ?? false
        mutedUntil = rows.first?.mutedUntil
    }

    /// Mute permanently (`until` nil), mute until a date, or unmute.
    ///
    /// ⚠️ Pass the duration through `until` — never emulate a timer by muting
    /// permanently and remembering the date locally. The senders read the
    /// server's two columns, so a client-side timer would silently never expire.
    func setMuted(_ value: Bool, until: Date? = nil) async {
        struct P: Encodable { let p_muted: Bool; let p_muted_until: String? }
        let iso = until.map { ISO8601DateFormatter().string(from: $0) }
        _ = try? await supabase
            .rpc("set_feed_mute", params: P(p_muted: value, p_muted_until: iso))
            .execute()
        await load()
    }
}
