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
