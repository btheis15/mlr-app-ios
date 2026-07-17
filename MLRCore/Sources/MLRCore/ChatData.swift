import Foundation

// MARK: - Watch chat read layer
//
// Conversations = the signed-in member's House + the committees they belong to.
// Each opens a read-only thread of the most recent messages (General channel for
// committees). Lean DTOs; all reads go through the shared authenticated client.

public struct WatchConversation: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case house(UUID); case committee(UUID) }
    public let id: String
    public let title: String
    public let emoji: String
    public let kind: Kind
}

public struct WatchChatMessage: Identifiable, Sendable {
    public let id: UUID
    public let authorName: String
    public let text: String
    public let createdAt: Date
}

extension WatchData {

    /// The viewer's House + committees they're a member of, as conversation rows.
    public static func conversations() async -> [WatchConversation] {
        guard let uid = supabase.auth.currentUser?.id.uuidString else { return [] }
        var out: [WatchConversation] = []

        // My house (profiles.house_id → houses).
        struct ProfileRow: Decodable { let houseId: UUID?; enum CodingKeys: String, CodingKey { case houseId = "house_id" } }
        if let prof: ProfileRow = try? await supabase.from("profiles")
            .select("house_id").eq("id", value: uid).single().execute().value,
           let houseId = prof.houseId {
            struct HouseRow: Decodable { let id: UUID; let name: String; let emoji: String? }
            if let h: HouseRow = try? await supabase.from("houses")
                .select("id, name, emoji").eq("id", value: houseId.uuidString).single().execute().value {
                out.append(WatchConversation(id: "house-\(h.id)", title: h.name,
                                             emoji: h.emoji ?? "🏠", kind: .house(h.id)))
            }
        }

        // My committees (committee_members → committees).
        struct MemberRow: Decodable { let committeeId: UUID; enum CodingKeys: String, CodingKey { case committeeId = "committee_id" } }
        let mems: [MemberRow] = (try? await supabase.from("committee_members")
            .select("committee_id").eq("user_id", value: uid).execute().value) ?? []
        if !mems.isEmpty {
            struct CommRow: Decodable { let id: UUID; let name: String; let emoji: String? }
            let ids = mems.map(\.committeeId.uuidString)
            let comms: [CommRow] = (try? await supabase.from("committees")
                .select("id, name, emoji").in("id", values: ids)
                .order("name", ascending: true).execute().value) ?? []
            out.append(contentsOf: comms.map {
                WatchConversation(id: "comm-\($0.id)", title: $0.name,
                                  emoji: $0.emoji ?? "💬", kind: .committee($0.id))
            })
        }
        return out
    }

    /// The most recent messages in a conversation (oldest → newest), deleted omitted.
    public static func messages(for convo: WatchConversation) async -> [WatchChatMessage] {
        switch convo.kind {
        case .house(let id):     return await houseMessages(houseId: id)
        case .committee(let id): return await committeeMessages(committeeId: id)
        }
    }

    private static func committeeMessages(committeeId: UUID) async -> [WatchChatMessage] {
        let rows: [ChatRow] = (try? await supabase.from("committee_messages")
            .select("id, text, deleted_at, created_at, profiles!author_id(display_name)")
            .eq("committee_id", value: committeeId.uuidString)
            .filter("area", operator: "is", value: "null")   // General channel
            .order("created_at", ascending: true)
            .limit(50)
            .execute().value) ?? []
        return rows.compactMap(\.message)
    }

    private static func houseMessages(houseId: UUID) async -> [WatchChatMessage] {
        let rows: [ChatRow] = (try? await supabase.from("house_messages")
            .select("id, text, deleted_at, created_at, profiles!author_id(display_name)")
            .eq("house_id", value: houseId.uuidString)
            .order("created_at", ascending: true)
            .limit(50)
            .execute().value) ?? []
        return rows.compactMap(\.message)
    }
}

private struct ChatRow: Decodable {
    let id: UUID
    let text: String?
    let deletedAt: Date?
    let createdAt: Date
    let profiles: NameRef?

    struct NameRef: Decodable {
        let displayName: String?
        enum CodingKeys: String, CodingKey { case displayName = "display_name" }
    }
    enum CodingKeys: String, CodingKey {
        case id, text, profiles
        case deletedAt = "deleted_at"
        case createdAt = "created_at"
    }

    var message: WatchChatMessage? {
        guard deletedAt == nil, let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return WatchChatMessage(id: id, authorName: profiles?.displayName ?? "Member", text: t, createdAt: createdAt)
    }
}
