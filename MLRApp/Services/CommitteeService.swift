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
                committee_id, user_id, role, joined_at,
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
                .select("committee_id, user_id, role, joined_at")
                .eq("user_id", value: userId.uuidString)
                .execute()
                .value
            myMemberships = rows
        } catch {
            print("[CommitteeService] fetchMyMemberships error: \(error)")
        }
    }

    // MARK: - Join requests

    func requestJoin(committeeId: UUID, note: String?) async throws {
        struct JoinParams: Encodable {
            let p_committee_id: String
            let p_note: String?
        }
        try await supabase
            .rpc("request_committee_join", params: JoinParams(
                p_committee_id: committeeId.uuidString,
                p_note: note
            ))
            .execute()
    }

    func approveJoin(requestId: UUID) async throws {
        struct ApproveParams: Encodable { let p_request_id: String }
        try await supabase
            .rpc("approve_committee_join", params: ApproveParams(
                p_request_id: requestId.uuidString
            ))
            .execute()
        pendingRequests.removeAll { $0.id == requestId }
    }

    func declineJoin(requestId: UUID) async throws {
        struct DeclineParams: Encodable { let p_request_id: String }
        try await supabase
            .rpc("decline_committee_join", params: DeclineParams(
                p_request_id: requestId.uuidString
            ))
            .execute()
        pendingRequests.removeAll { $0.id == requestId }
    }

    func fetchPendingRequests() async throws {
        let rows: [CommitteeJoinRequest] = try await supabase
            .from("committee_join_requests")
            .select("""
                id, committee_id, user_id, status, note, created_at,
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
            .from("committee_chat_messages")
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

    func sendMessage(committeeId: UUID, text: String, authorId: UUID) async throws -> CommitteeChatMessage {
        let params: [String: AnyJSON] = [
            "committee_id": .string(committeeId.uuidString),
            "author_id":    .string(authorId.uuidString),
            "text":         .string(text)
        ]
        let row: CommitteeChatRow = try await supabase
            .from("committee_chat_messages")
            .insert(params)
            .select("""
                id, committee_id, author_id, text, edited_at, deleted_at, created_at,
                profiles!author_id(display_name, avatar_url)
            """)
            .single()
            .execute()
            .value
        return row.toChatMessage
    }

    func editMessage(messageId: UUID, text: String) async throws {
        struct EditParams: Encodable {
            let p_message_id: String
            let p_text: String
        }
        try await supabase
            .rpc("edit_committee_message", params: EditParams(
                p_message_id: messageId.uuidString,
                p_text: text
            ))
            .execute()
    }

    func deleteMessage(messageId: UUID) async throws {
        struct DeleteParams: Encodable { let p_message_id: String }
        try await supabase
            .rpc("delete_committee_message", params: DeleteParams(
                p_message_id: messageId.uuidString
            ))
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
                table: "committee_chat_messages",
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
                        .from("committee_chat_messages")
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
// committee_chat_messages has no flat author_name/author_avatar_url columns;
// author info comes from the profiles!author_id join.

private struct CommitteeChatRow: Decodable {
    let id: UUID
    let committeeId: UUID
    let authorId: UUID
    let text: String
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
            text: text,
            editedAt: editedAt,
            deletedAt: deletedAt,
            createdAt: createdAt
        )
    }
}
