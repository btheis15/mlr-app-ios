import Foundation

// MARK: - Watch read layer
//
// Lean, read-only queries the watch app uses. Distinct minimal DTOs (not the
// full app models) keep the watch payloads small and the package self-contained.
// All reads go through the shared `supabase` client, authenticated via the
// session the phone pushed over WatchConnectivity (RLS applies as usual).

public struct WatchWorkItem: Identifiable, Decodable, Sendable {
    public let id: UUID
    public let title: String
    public let urgency: String?   // "asap" | "this_year" | "nice_to_have" | nil

    enum CodingKeys: String, CodingKey { case id, title, urgency }

    /// 🔴 / 🟡 / 🟢 / ⚪️ dot by urgency (matches the iOS app's WorkUrgency).
    public var urgencyEmoji: String {
        switch urgency {
        case "asap":         return "🔴"
        case "this_year":    return "🟡"
        case "nice_to_have": return "🟢"
        default:             return "⚪️"
        }
    }

    /// Lower = more urgent; unrated sorts last (mirrors WorkUrgency.rank).
    var rank: Int {
        switch urgency {
        case "asap":         return 0
        case "this_year":    return 1
        case "nice_to_have": return 2
        default:             return 3
        }
    }
}

public enum WatchData {
    /// Open resort work-checklist items, most urgent first.
    public static func openWorkItems() async -> [WatchWorkItem] {
        let rows: [WatchWorkItem] = (try? await supabase
            .from("work_items")
            .select("id, title, urgency")
            .eq("status", value: "open")
            .order("created_at", ascending: false)
            .execute()
            .value) ?? []
        return rows.sorted { $0.rank < $1.rank }
    }
}
