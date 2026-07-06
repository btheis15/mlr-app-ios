import Foundation
import Supabase

// MARK: - HousesService
//
// Houses (migrations 0064–0065): an admin-assigned group with a single private
// chat room. Mirrors the committee chat portions of CommitteeService, minus the
// per-role `area` (a house is one room) and the mute toggle (house chat is
// always on). Reads are gated in the DB by is_house_member(); assignment is
// admin-only via set_member_house.

@Observable
@MainActor
final class HousesService {
    var houses: [House] = []
    /// The signed-in member's house, resolved once their profile loads (see
    /// AppEnvironment.refreshMyHouse). Home/Feed read this observed value directly
    /// so the "Your house" surfaces appear reliably — gating on it in rendered
    /// content is a tracked dependency, unlike reading houseId only in `.task(id:)`.
    var myHouse: House? = nil
    var isLoading: Bool = false
    var error: String? = nil

    private var messageChannels: [UUID: RealtimeChannelV2] = [:]
    private var stayChannels: [UUID: RealtimeChannelV2] = [:]

    // MARK: - Houses

    func fetchHouses() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let rows: [House] = try await supabase
                .from("houses")
                .select("*")
                .order("position", ascending: true)
                .execute()
                .value
            houses = rows
        } catch {
            self.error = "Couldn't load houses."
            print("[HousesService] fetchHouses error: \(error)")
        }
    }

    /// The house a user belongs to (nil for most members). Resolves against the
    /// loaded list, fetching it first if needed.
    func house(withId id: UUID?) async -> House? {
        guard let id else { return nil }
        if houses.isEmpty { await fetchHouses() }
        return houses.first { $0.id == id }
    }

    /// A house by slug — used for deep links (mlr://…?house=<slug>).
    func house(withSlug slug: String) async -> House? {
        if houses.isEmpty { await fetchHouses() }
        return houses.first { $0.slug == slug }
    }

    /// Save the house's shared "house rules" doc (any member of the house, via
    /// set_house_rules, migration 0072). Refreshes the cached house + myHouse so
    /// the Hub reflects the new text. Last write wins.
    func saveHouseRules(houseId: UUID, rules: String) async throws {
        struct Params: Encodable { let hid: String; let p_rules: String }
        try await supabase
            .rpc("set_house_rules", params: Params(hid: houseId.uuidString, p_rules: rules))
            .execute()
        await fetchHouses()
        if myHouse?.id == houseId { myHouse = houses.first { $0.id == houseId } }
    }

    /// Everyone assigned to a house (profiles.house_id). Drives the chat's
    /// "who's in this chat" sheet and @mention autocomplete.
    func fetchMembers(houseId: UUID) async -> [Profile] {
        let rows: [Profile] = (try? await supabase
            .from("profiles")
            .select("id, display_name, avatar_url, is_admin")
            .eq("house_id", value: houseId.uuidString)
            .order("display_name", ascending: true)
            .execute()
            .value) ?? []
        return rows
    }

    // MARK: - Chat messages

    func fetchMessages(houseId: UUID) async throws -> [HouseChatMessage] {
        let rows: [HouseChatRow] = try await supabase
            .from("house_messages")
            .select("""
                id, house_id, author_id, text, edited_at, deleted_at, created_at,
                profiles!author_id(display_name, avatar_url)
            """)
            .eq("house_id", value: houseId.uuidString)
            .order("created_at", ascending: true)
            .execute()
            .value
        return rows.map(\.toChatMessage)
    }

    @discardableResult
    func sendMessage(houseId: UUID, text: String, authorId: UUID, mentionedIds: [UUID] = []) async throws -> HouseChatMessage {
        let params: [String: AnyJSON] = [
            "house_id":  .string(houseId.uuidString),
            "author_id": .string(authorId.uuidString),
            "text":      .string(text),
        ]
        let row: HouseChatRow = try await supabase
            .from("house_messages")
            .insert(params)
            .select("""
                id, house_id, author_id, text, edited_at, deleted_at, created_at,
                profiles!author_id(display_name, avatar_url)
            """)
            .single()
            .execute()
            .value

        if !mentionedIds.isEmpty {
            let rows: [[String: AnyJSON]] = mentionedIds.map {
                ["message_id": .string(row.id.uuidString), "mentioned_user_id": .string($0.uuidString)]
            }
            try? await supabase.from("house_message_mentions").insert(rows).execute()
        }
        return row.toChatMessage
    }

    func editMessage(messageId: UUID, text: String) async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        try await supabase
            .from("house_messages")
            .update(["text": AnyJSON.string(text), "edited_at": AnyJSON.string(now)])
            .eq("id", value: messageId.uuidString)
            .execute()
    }

    func deleteMessage(messageId: UUID) async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        try await supabase
            .from("house_messages")
            .update(["deleted_at": AnyJSON.string(now)])
            .eq("id", value: messageId.uuidString)
            .execute()
    }

    // MARK: - Read state (unread badge)

    /// Mark the house chat read (mark_house_read, migration 0065).
    func markRead(houseId: UUID) async {
        struct Params: Encodable { let hid: String }
        _ = try? await supabase
            .rpc("mark_house_read", params: Params(hid: houseId.uuidString))
            .execute()
    }

    /// Last-message preview + unread count for the Feed conversation row.
    func fetchChannelSummary(houseId: UUID, userId: UUID) async -> ChannelSummary {
        struct LastRow: Decodable {
            let text: String?; let createdAt: Date; let deletedAt: Date?; let authorName: String?
            enum CodingKeys: String, CodingKey {
                case text; case createdAt = "created_at"; case deletedAt = "deleted_at"; case profiles
            }
            struct P: Decodable { let displayName: String?
                enum CodingKeys: String, CodingKey { case displayName = "display_name" } }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                text = try c.decodeIfPresent(String.self, forKey: .text)
                createdAt = try c.decode(Date.self, forKey: .createdAt)
                deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
                authorName = (try? c.decodeIfPresent(P.self, forKey: .profiles))?.displayName
            }
        }
        let last: [LastRow] = (try? await supabase
            .from("house_messages")
            .select("text, created_at, deleted_at, profiles!author_id(display_name)")
            .eq("house_id", value: houseId.uuidString)
            .order("created_at", ascending: false)
            .limit(1).execute().value) ?? []
        let lastRow = last.first

        struct ReadRow: Decodable { let lastReadAt: Date?
            enum CodingKeys: String, CodingKey { case lastReadAt = "last_read_at" } }
        let reads: [ReadRow] = (try? await supabase
            .from("house_reads")
            .select("last_read_at")
            .eq("house_id", value: houseId.uuidString)
            .eq("user_id", value: userId.uuidString)
            .limit(1).execute().value) ?? []
        let lastRead = reads.first?.lastReadAt

        var cq = supabase
            .from("house_messages")
            .select("id", head: true, count: .exact)
            .eq("house_id", value: houseId.uuidString)
            .neq("author_id", value: userId.uuidString)
        if let lastRead { cq = cq.gt("created_at", value: ISO8601DateFormatter().string(from: lastRead)) }
        let unread = (try? await cq.execute().count) ?? 0

        let preview: String? = {
            guard let lastRow else { return nil }
            if lastRow.deletedAt != nil { return "Message deleted" }
            let who = lastRow.authorName.map { "\($0): " } ?? ""
            return who + (lastRow.text ?? "")
        }()
        return ChannelSummary(lastText: preview, lastAt: lastRow?.createdAt, unread: unread, muted: false)
    }

    // MARK: - Realtime

    func subscribeToMessages(
        houseId: UUID,
        onInsert: @escaping (HouseChatMessage) -> Void,
        onUpdate: @escaping (HouseChatMessage) -> Void
    ) {
        guard messageChannels[houseId] == nil else { return }
        let channel = supabase.channel("house-chat-\(houseId.uuidString)")
        messageChannels[houseId] = channel

        Task {
            channel.onPostgresChange(
                AnyAction.self,
                schema: "public",
                table: "house_messages",
                filter: "house_id=eq.\(houseId.uuidString)"
            ) { action in
                Task { @MainActor in
                    let record: [String: AnyJSON]
                    let isInsert: Bool
                    switch action {
                    case .insert(let a): record = a.record; isInsert = true
                    case .update(let a): record = a.record; isInsert = false
                    case .delete: return
                    }
                    guard let idStr = record["id"]?.stringValue,
                          let id = UUID(uuidString: idStr)
                    else { return }
                    if let row: HouseChatRow = try? await supabase
                        .from("house_messages")
                        .select("""
                            id, house_id, author_id, text, edited_at, deleted_at, created_at,
                            profiles!author_id(display_name, avatar_url)
                        """)
                        .eq("id", value: id.uuidString)
                        .single()
                        .execute()
                        .value
                    {
                        let msg = row.toChatMessage
                        if isInsert { onInsert(msg) } else { onUpdate(msg) }
                    }
                }
            }
            await channel.subscribe()
        }
    }

    func unsubscribeFromMessages(houseId: UUID) {
        guard let channel = messageChannels[houseId] else { return }
        Task {
            await supabase.removeChannel(channel)
            messageChannels.removeValue(forKey: houseId)
        }
    }

    // MARK: - House calendar: stays (migration 0071)

    /// Every stay on a house's calendar (RLS-gated to the house), with the
    /// member's name + avatar. Sorted by start date ascending.
    func fetchStays(houseId: UUID) async -> [HouseStay] {
        do {
            let rows: [HouseStayRow] = try await supabase
                .from("house_stays")
                .select("""
                    id, house_id, created_by, title, start_date, end_date, guest_names, note, created_at,
                    profiles:created_by(display_name, avatar_url)
                """)
                .eq("house_id", value: houseId.uuidString)
                .order("start_date", ascending: true)
                .execute()
                .value
            return rows.map(\.toStay)
        } catch {
            print("[HousesService] fetchStays error: \(error)")
            return []
        }
    }

    /// Add my stay to a house calendar. Returns the new stay's id.
    @discardableResult
    func createStay(
        houseId: UUID,
        startDate: String,
        endDate: String,
        title: String?,
        guestNames: [String],
        note: String?
    ) async throws -> UUID {
        struct Params: Encodable {
            let p_house: String
            let p_start_date: String
            let p_end_date: String
            let p_title: String?
            let p_guest_names: [String]
            let p_note: String?
        }
        let id: UUID = try await supabase
            .rpc("create_house_stay", params: Params(
                p_house: houseId.uuidString,
                p_start_date: startDate,
                p_end_date: endDate,
                p_title: title,
                p_guest_names: guestNames,
                p_note: note
            ))
            .execute()
            .value
        return id
    }

    /// Edit a stay (author or admin — enforced server-side).
    func updateStay(
        id: UUID,
        startDate: String,
        endDate: String,
        title: String?,
        guestNames: [String],
        note: String?
    ) async throws {
        struct Params: Encodable {
            let p_id: String
            let p_start_date: String
            let p_end_date: String
            let p_title: String?
            let p_guest_names: [String]
            let p_note: String?
        }
        try await supabase
            .rpc("update_house_stay", params: Params(
                p_id: id.uuidString,
                p_start_date: startDate,
                p_end_date: endDate,
                p_title: title,
                p_guest_names: guestNames,
                p_note: note
            ))
            .execute()
    }

    /// Cancel a stay (author or admin — enforced server-side).
    func deleteStay(id: UUID) async throws {
        struct Params: Encodable { let p_id: String }
        try await supabase
            .rpc("delete_house_stay", params: Params(p_id: id.uuidString))
            .execute()
    }

    /// Live-update a house's calendar. `onChange` fires on any insert/update/
    /// delete to house_stays for this house — the view re-fetches. Mirrors the
    /// events-live channel; keyed per house so it composes with the chat channel.
    func subscribeToStays(houseId: UUID, onChange: @escaping () -> Void) {
        guard stayChannels[houseId] == nil else { return }
        let channel = supabase.channel("house-stays-\(houseId.uuidString)")
        stayChannels[houseId] = channel
        Task {
            channel.onPostgresChange(
                AnyAction.self,
                schema: "public",
                table: "house_stays",
                filter: "house_id=eq.\(houseId.uuidString)"
            ) { _ in
                Task { @MainActor in onChange() }
            }
            await channel.subscribe()
        }
    }

    func unsubscribeFromStays(houseId: UUID) {
        guard let channel = stayChannels[houseId] else { return }
        Task {
            await supabase.removeChannel(channel)
            stayChannels.removeValue(forKey: houseId)
        }
    }

    // MARK: - Admin: house management (migration 0064)

    /// Assign a member to a house, or clear it with `houseId = nil`. Admin-only.
    func setMemberHouse(target: UUID, houseId: UUID?) async throws {
        struct Params: Encodable { let target: String; let hid: String? }
        try await supabase
            .rpc("set_member_house", params: Params(target: target.uuidString, hid: houseId?.uuidString))
            .execute()
    }

    /// Create or update a house (admin-gated by RLS on the houses table).
    func saveHouse(id: UUID?, slug: String, name: String, emoji: String, description: String, position: Int) async throws {
        let row: [String: AnyJSON] = [
            "slug": .string(slug),
            "name": .string(name),
            "emoji": .string(emoji),
            "description": .string(description),
            "position": .double(Double(position)),
        ]
        if let id {
            try await supabase.from("houses").update(row).eq("id", value: id.uuidString).execute()
        } else {
            try await supabase.from("houses").insert(row).execute()
        }
        await fetchHouses()
    }

    func deleteHouse(id: UUID) async throws {
        try await supabase.from("houses").delete().eq("id", value: id.uuidString).execute()
        houses.removeAll { $0.id == id }
    }
}

// MARK: - Private row type for house chat messages
// house_messages has no flat author columns; author comes from profiles!author_id.

// house_stays has no flat author columns; author comes from profiles!created_by.
private struct HouseStayRow: Decodable {
    let id: UUID
    let houseId: UUID
    let createdBy: UUID
    let title: String?
    let startDate: String
    let endDate: String
    let guestNames: [String]?
    let note: String?
    let createdAt: Date
    let profiles: Author?

    enum CodingKeys: String, CodingKey {
        case id
        case houseId = "house_id"
        case createdBy = "created_by"
        case title
        case startDate = "start_date"
        case endDate = "end_date"
        case guestNames = "guest_names"
        case note
        case createdAt = "created_at"
        case profiles
    }

    struct Author: Decodable {
        let name: String?
        let avatarUrl: String?
        enum CodingKeys: String, CodingKey {
            case name = "display_name"
            case avatarUrl = "avatar_url"
        }
    }

    var toStay: HouseStay {
        HouseStay(
            id: id,
            houseId: houseId,
            createdBy: createdBy,
            authorName: profiles?.name ?? "Member",
            authorAvatarUrl: profiles?.avatarUrl,
            title: title,
            startDate: startDate,
            endDate: endDate,
            guestNames: guestNames ?? [],
            note: note,
            createdAt: createdAt
        )
    }
}

private struct HouseChatRow: Decodable {
    let id: UUID
    let houseId: UUID
    let authorId: UUID
    let text: String?
    let editedAt: Date?
    let deletedAt: Date?
    let createdAt: Date
    let profiles: AuthorInfo?

    enum CodingKeys: String, CodingKey {
        case id
        case houseId = "house_id"
        case authorId = "author_id"
        case text
        case editedAt = "edited_at"
        case deletedAt = "deleted_at"
        case createdAt = "created_at"
        case profiles
    }

    struct AuthorInfo: Decodable {
        let name: String?
        let avatarUrl: String?
        enum CodingKeys: String, CodingKey {
            case name = "display_name"
            case avatarUrl = "avatar_url"
        }
    }

    var toChatMessage: HouseChatMessage {
        HouseChatMessage(
            id: id,
            houseId: houseId,
            authorId: authorId,
            authorName: profiles?.name ?? "Member",
            authorAvatarUrl: profiles?.avatarUrl,
            text: text ?? "",
            editedAt: editedAt,
            deletedAt: deletedAt,
            createdAt: createdAt
        )
    }
}
