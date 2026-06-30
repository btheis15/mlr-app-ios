import Foundation
import Supabase

// MARK: - CommitteeService

@Observable
@MainActor
final class CommitteeService {
    var committees: [Committee] = []
    var myMemberships: [CommitteeMember] = []
    var isLoading: Bool = false
    var error: String? = nil

    /// Admin-visible join requests across all committees.
    var pendingRequests: [CommitteeJoinRequest] = []

    private var messageChannels: [UUID: RealtimeChannelV2] = [:]

    // MARK: - Fetch committees

    func fetchCommittees() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let rows: [Committee] = try await supabase
                .from("committees")
                .select("*")
                .order("name", ascending: true)
                .execute()
                .value
            committees = rows
        } catch {
            self.error = "Couldn't load committees."
            print("[CommitteeService] fetchCommittees error: \(error)")
        }
    }

    // MARK: - Members

    func fetchMembers(committeeId: UUID) async throws -> [CommitteeMember] {
        let rows: [CommitteeMember] = try await supabase
            .from("committee_members")
            .select("""
                committee_id, user_id, role, areas, joined_at,
                profiles!user_id(id, display_name, contact_email, avatar_url, phone, is_admin,
                                 beta_tester, willing_to_help, intro_seen,
                                 email_alerts, push_level, push_types,
                                 notif_types, push_prompted, created_at)
            """)
            .eq("committee_id", value: committeeId.uuidString)
            .order("joined_at", ascending: true)
            .execute()
            .value
        return rows
    }

    /// The committee's roster (migration 0055): everyone listed, with their
    /// roles, each slot auto-linked to a real account (linked_user_id) once the
    /// person verifies with the matching email. Public read.
    func fetchRoster(slug: String) async throws -> [CommitteeRosterEntry] {
        try await supabase
            .from("committee_roster")
            .select("""
                id, name, email, phone, roles, position, linked_user_id,
                profiles:linked_user_id(display_name, avatar_url)
            """)
            .eq("committee_slug", value: slug)
            .order("position", ascending: true)
            .execute()
            .value
    }

    /// Committee slugs the member belongs to (roster-linked) — drives the Feed
    /// chat pills now that the roster is the membership source.
    func fetchMyCommitteeSlugs(userId: UUID) async -> Set<String> {
        struct Row: Decodable { let committeeSlug: String
            enum CodingKeys: String, CodingKey { case committeeSlug = "committee_slug" } }
        let rows: [Row] = (try? await supabase
            .from("committee_roster")
            .select("committee_slug")
            .eq("linked_user_id", value: userId.uuidString)
            .execute()
            .value) ?? []
        return Set(rows.map(\.committeeSlug))
    }

    // MARK: - Roster management (app admins; migration 0055/0057)

    /// Create or update a roster entry (admin-gated by RLS).
    func saveRosterEntry(
        id: UUID?, committeeSlug: String, name: String,
        email: String?, phone: String?, roles: [String], linkedUserId: UUID?
    ) async throws {
        let uid = try? await supabase.auth.session.user.id
        var row: [String: AnyJSON] = [
            "committee_slug": .string(committeeSlug),
            "name": .string(name),
            "email": email.map { AnyJSON.string($0) } ?? .null,
            "phone": phone.map { AnyJSON.string($0) } ?? .null,
            "roles": .array(roles.map { AnyJSON.string($0) }),
            "linked_user_id": linkedUserId.map { AnyJSON.string($0.uuidString) } ?? .null,
            "updated_at": .string(ISO8601DateFormatter().string(from: Date())),
        ]
        row["updated_by"] = uid.map { AnyJSON.string($0.uuidString) } ?? .null
        if let id {
            try await supabase.from("committee_roster").update(row).eq("id", value: id.uuidString).execute()
        } else {
            try await supabase.from("committee_roster").insert(row).execute()
        }
    }

    func deleteRosterEntry(id: UUID) async throws {
        try await supabase.from("committee_roster").delete().eq("id", value: id.uuidString).execute()
    }

    func fetchMyMemberships(userId: UUID) async {
        do {
            let rows: [CommitteeMember] = try await supabase
                .from("committee_members")
                .select("committee_id, user_id, role, areas, joined_at")
                .eq("user_id", value: userId.uuidString)
                .execute()
                .value
            myMemberships = rows
        } catch {
            print("[CommitteeService] fetchMyMemberships error: \(error)")
        }
    }

    /// Unread message count per committee for the Feed pills: messages newer than
    /// the member's last_read_at (committee_reads) and not authored by them.
    func fetchUnreadByCommittee(userId: UUID, committeeIds: [UUID]) async -> [UUID: Int] {
        guard !committeeIds.isEmpty else { return [:] }
        struct ReadRow: Decodable { let committeeId: UUID; let lastReadAt: Date?
            enum CodingKeys: String, CodingKey { case committeeId = "committee_id"; case lastReadAt = "last_read_at" } }
        let reads: [ReadRow] = (try? await supabase
            .from("committee_reads")
            .select("committee_id, last_read_at")
            .eq("user_id", value: userId.uuidString)
            .execute()
            .value) ?? []
        var lastRead: [UUID: Date] = [:]
        for r in reads { if let d = r.lastReadAt { lastRead[r.committeeId] = d } }

        let iso = ISO8601DateFormatter()
        var out: [UUID: Int] = [:]
        for cid in committeeIds {
            var query = supabase
                .from("committee_messages")
                .select("id", head: true, count: .exact)
                .eq("committee_id", value: cid.uuidString)
                .neq("author_id", value: userId.uuidString)
            if let since = lastRead[cid] {
                query = query.gt("created_at", value: iso.string(from: since))
            }
            let count = (try? await query.execute().count) ?? 0
            out[cid] = count
        }
        return out
    }

    // MARK: - Join requests

    func requestJoin(committeeId: UUID, note: String?, requestedArea: String? = nil) async throws {
        struct JoinParams: Encodable {
            let cid: String
            let msg: String?
            let requested_area: String?
        }
        try await supabase
            .rpc("request_to_join", params: JoinParams(
                cid: committeeId.uuidString,
                msg: note,
                requested_area: requestedArea
            ))
            .execute()
    }

    func approveJoin(requestId: UUID) async throws {
        try await reviewJoin(requestId: requestId, approve: true)
    }

    func declineJoin(requestId: UUID) async throws {
        try await reviewJoin(requestId: requestId, approve: false)
    }

    /// Approve or reject a join request — one RPC (migrations 0015/0051).
    private func reviewJoin(requestId: UUID, approve: Bool) async throws {
        struct ReviewParams: Encodable {
            let req_id: String
            let approve: Bool
        }
        try await supabase
            .rpc("review_join_request", params: ReviewParams(
                req_id: requestId.uuidString,
                approve: approve
            ))
            .execute()
        pendingRequests.removeAll { $0.id == requestId }
    }

    // MARK: - Lead / area management (committee leads + app admins, migration 0051)

    /// Promote or demote a member to/from Lead.
    func setCommitteeLead(committeeId: UUID, targetUserId: UUID, isLead: Bool) async throws {
        struct LeadParams: Encodable {
            let cid: String
            let target: String
            let is_lead: Bool
        }
        try await supabase
            .rpc("set_committee_lead", params: LeadParams(
                cid: committeeId.uuidString,
                target: targetUserId.uuidString,
                is_lead: isLead
            ))
            .execute()
    }

    /// Assign the set of areas a member works in.
    func setCommitteeAreas(committeeId: UUID, targetUserId: UUID, areas: [String]) async throws {
        struct AreasParams: Encodable {
            let cid: String
            let target: String
            let areas: [String]
        }
        try await supabase
            .rpc("set_committee_areas", params: AreasParams(
                cid: committeeId.uuidString,
                target: targetUserId.uuidString,
                areas: areas
            ))
            .execute()
    }

    // MARK: - Email recipients (committee member or admin, migration 0031)

    /// The committee's emailable roster ({id, name, email}), gated server-side.
    func fetchCommitteeRecipients(committeeId: UUID) async throws -> [CommitteeRecipient] {
        struct RecipientParams: Encodable { let cid: String }
        let rows: [CommitteeRecipient] = try await supabase
            .rpc("committee_member_recipients", params: RecipientParams(cid: committeeId.uuidString))
            .execute()
            .value
        return rows
    }

    func fetchPendingRequests() async throws {
        let rows: [CommitteeJoinRequest] = try await supabase
            .from("committee_join_requests")
            .select("""
                id, committee_id, user_id, status, message, requested_area, created_at,
                profiles!user_id(id, display_name, contact_email, avatar_url, phone, is_admin,
                                 beta_tester, willing_to_help, intro_seen,
                                 email_alerts, push_level, push_types,
                                 notif_types, push_prompted, created_at)
            """)
            .eq("status", value: "pending")
            .order("created_at", ascending: true)
            .execute()
            .value
        pendingRequests = rows
    }

    // MARK: - Chat messages

    func fetchMessages(committeeId: UUID) async throws -> [CommitteeChatMessage] {
        let rows: [CommitteeChatRow] = try await supabase
            .from("committee_messages")
            .select("""
                id, committee_id, author_id, text, edited_at, deleted_at, created_at,
                profiles!author_id(display_name, avatar_url)
            """)
            .eq("committee_id", value: committeeId.uuidString)
            .order("created_at", ascending: true)
            .execute()
            .value
        return rows.map(\.toChatMessage)
    }

    func sendMessage(committeeId: UUID, text: String, authorId: UUID, mentionedIds: [UUID] = []) async throws -> CommitteeChatMessage {
        let params: [String: AnyJSON] = [
            "committee_id": .string(committeeId.uuidString),
            "author_id":    .string(authorId.uuidString),
            "text":         .string(text)
        ]
        let row: CommitteeChatRow = try await supabase
            .from("committee_messages")
            .insert(params)
            .select("""
                id, committee_id, author_id, text, edited_at, deleted_at, created_at,
                profiles!author_id(display_name, avatar_url)
            """)
            .single()
            .execute()
            .value

        // Record @mentions so the server can fire chat-mention notifications.
        if !mentionedIds.isEmpty {
            let rows: [[String: AnyJSON]] = mentionedIds.map {
                ["message_id": .string(row.id.uuidString), "mentioned_user_id": .string($0.uuidString)]
            }
            try? await supabase.from("committee_message_mentions").insert(rows).execute()
        }
        return row.toChatMessage
    }

    func editMessage(messageId: UUID, text: String) async throws {
        // Editing is a direct update (stamps edited_at); RLS gates who may edit.
        let now = ISO8601DateFormatter().string(from: .now)
        try await supabase
            .from("committee_messages")
            .update([
                "text": AnyJSON.string(text),
                "edited_at": AnyJSON.string(now)
            ])
            .eq("id", value: messageId.uuidString)
            .execute()
    }

    func deleteMessage(messageId: UUID) async throws {
        // Soft delete: stamp deleted_at so the bubble becomes "message deleted".
        let now = ISO8601DateFormatter().string(from: .now)
        try await supabase
            .from("committee_messages")
            .update(["deleted_at": AnyJSON.string(now)])
            .eq("id", value: messageId.uuidString)
            .execute()
    }

    // MARK: - Realtime for messages

    /// Subscribe to live message inserts/updates in a committee chat room.
    /// The caller is responsible for supplying a mutable messages array.
    func subscribeToMessages(
        committeeId: UUID,
        onInsert: @escaping (CommitteeChatMessage) -> Void,
        onUpdate: @escaping (CommitteeChatMessage) -> Void
    ) {
        guard messageChannels[committeeId] == nil else { return }
        let channel = supabase.channel("committee-chat-\(committeeId.uuidString)")
        messageChannels[committeeId] = channel

        Task {
            channel.onPostgresChange(
                AnyAction.self,
                schema: "public",
                table: "committee_messages",
                filter: "committee_id=eq.\(committeeId.uuidString)"
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
                    if let row: CommitteeChatRow = try? await supabase
                        .from("committee_messages")
                        .select("""
                            id, committee_id, author_id, text, edited_at, deleted_at, created_at,
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

    func unsubscribeFromMessages(committeeId: UUID) {
        guard let channel = messageChannels[committeeId] else { return }
        Task {
            await supabase.removeChannel(channel)
            messageChannels.removeValue(forKey: committeeId)
        }
    }
}

// MARK: - Private row type for committee chat messages
// committee_messages has no flat author_name/author_avatar_url columns;
// author info comes from the profiles!author_id join.

private struct CommitteeChatRow: Decodable {
    let id: UUID
    let committeeId: UUID
    let authorId: UUID
    let text: String?
    let editedAt: Date?
    let deletedAt: Date?
    let createdAt: Date
    let profiles: AuthorInfo?

    enum CodingKeys: String, CodingKey {
        case id
        case committeeId = "committee_id"
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

    var toChatMessage: CommitteeChatMessage {
        CommitteeChatMessage(
            id: id,
            committeeId: committeeId,
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
