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

    private var messageChannels: [String: RealtimeChannelV2] = [:]
    private var rosterChannels: [String: RealtimeChannelV2] = [:]
    private var mgmtChannels: [String: RealtimeChannelV2] = [:]

    // MARK: - Fetch committees

    func fetchCommittees() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let rows: [Committee] = try await supabase
                .from("committees")
                .select("*")
                .order("position", ascending: true)
                .order("name", ascending: true)
                .execute()
                .value
            committees = rows
        } catch {
            self.error = "Couldn't load committees."
            print("[CommitteeService] fetchCommittees error: \(error)")
        }
    }

    /// A committee by id — returns the already-loaded one if present, else fetches.
    func fetchCommittee(byId id: UUID) async -> Committee? {
        if let c = committees.first(where: { $0.id == id }) { return c }
        return try? await supabase
            .from("committees").select("*").eq("id", value: id.uuidString)
            .single().execute().value
    }

    /// The committee a pending join request belongs to — used to deep-link an
    /// admin from a join-request notification straight to that committee.
    func fetchCommittee(forRequestId requestId: UUID) async -> Committee? {
        struct Row: Decodable {
            let committeeId: UUID
            enum CodingKeys: String, CodingKey { case committeeId = "committee_id" }
        }
        guard let row: Row = try? await supabase
            .from("committee_join_requests").select("committee_id")
            .eq("id", value: requestId.uuidString)
            .single().execute().value
        else { return nil }
        return await fetchCommittee(byId: row.committeeId)
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
                profiles:linked_user_id(display_name, avatar_url, phone, contact_email)
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

    func requestJoin(committeeId: UUID, note: String?, requestedAreas: [String] = []) async throws {
        struct JoinParams: Encodable {
            let cid: String
            let msg: String?
            let requested_areas: [String]
        }
        try await supabase
            .rpc("request_to_join", params: JoinParams(
                cid: committeeId.uuidString,
                msg: note,
                requested_areas: requestedAreas
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

    /// Self-service: set the areas *I* work in — no lead/admin, no approval
    /// (migration 0073). Distinct from `setCommitteeAreas`, which acts on another
    /// member and requires a Lead/admin.
    func setMyCommitteeAreas(committeeId: UUID, areas: [String]) async throws {
        struct Params: Encodable {
            let cid: String
            let areas: [String]
        }
        try await supabase
            .rpc("set_my_committee_areas", params: Params(cid: committeeId.uuidString, areas: areas))
            .execute()
    }

    /// Leave a committee (self-service) — clears my membership AND unlinks my
    /// roster row so roster-based chat access is revoked too (migration 0073).
    func leaveCommittee(committeeId: UUID) async throws {
        struct Params: Encodable { let cid: String }
        try await supabase
            .rpc("leave_committee", params: Params(cid: committeeId.uuidString))
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
                id, committee_id, user_id, status, message, requested_area, requested_areas, created_at,
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

    func fetchMessages(committeeId: UUID, area: String? = nil) async throws -> [CommitteeChatMessage] {
        var query = supabase
            .from("committee_messages")
            .select("""
                id, committee_id, author_id, text, edited_at, deleted_at, created_at, area,
                profiles!author_id(display_name, avatar_url),
                committee_message_media(storage_path, media_type, width, height, file_name, position),
                committee_message_reactions(user_id, emoji)
            """)
            .eq("committee_id", value: committeeId.uuidString)
        // nil area = the General channel (area IS NULL); else the role channel.
        if let area { query = query.eq("area", value: area) } else { query = query.is("area", value: nil) }
        let rows: [CommitteeChatRow] = try await query
            .order("created_at", ascending: true)
            .execute()
            .value
        return rows.map(\.toChatMessage)
    }

    func sendMessage(committeeId: UUID, area: String? = nil, text: String, authorId: UUID, mentionedIds: [UUID] = [], media: [ChatMedia] = []) async throws -> CommitteeChatMessage {
        let params: [String: AnyJSON] = [
            "committee_id": .string(committeeId.uuidString),
            "author_id":    .string(authorId.uuidString),
            "text":         .string(text),
            "area":         area.map { AnyJSON.string($0) } ?? .null
        ]
        let row: CommitteeChatRow = try await supabase
            .from("committee_messages")
            .insert(params)
            .select("""
                id, committee_id, author_id, text, edited_at, deleted_at, created_at, area,
                profiles!author_id(display_name, avatar_url)
            """)
            .single()
            .execute()
            .value

        // Persist any attachments (already uploaded to the mini) as media rows.
        if !media.isEmpty {
            try await supabase.from("committee_message_media")
                .insert(chatMediaRows(messageId: row.id, media: media)).execute()
        }
        // Record @mentions so the server can fire chat-mention notifications.
        if !mentionedIds.isEmpty {
            let rows: [[String: AnyJSON]] = mentionedIds.map {
                ["message_id": .string(row.id.uuidString), "mentioned_user_id": .string($0.uuidString)]
            }
            try? await supabase.from("committee_message_mentions").insert(rows).execute()
        }
        var msg = row.toChatMessage
        msg.media = media   // render immediately without a round-trip
        return msg
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

    /// Toggle the caller's tapback on a message: tapping the same emoji removes
    /// it, a different one replaces it (one reaction per member per message).
    func toggleReaction(messageId: UUID, emoji: String, userId: UUID) async {
        struct Row: Decodable { let emoji: String }
        let existing: [Row] = (try? await supabase
            .from("committee_message_reactions")
            .select("emoji")
            .eq("message_id", value: messageId.uuidString)
            .eq("user_id", value: userId.uuidString)
            .limit(1).execute().value) ?? []
        do {
            if existing.first?.emoji == emoji {
                try await supabase.from("committee_message_reactions").delete()
                    .eq("message_id", value: messageId.uuidString)
                    .eq("user_id", value: userId.uuidString)
                    .execute()
            } else {
                try await supabase.from("committee_message_reactions").upsert(
                    ["message_id": messageId.uuidString, "user_id": userId.uuidString, "emoji": emoji],
                    onConflict: "message_id,user_id"
                ).execute()
            }
        } catch {
            print("[CommitteeChat] toggleReaction error: \(error)")
        }
    }

    // MARK: - Realtime for messages

    /// Subscribe to live message inserts/updates in a committee chat room.
    /// The caller is responsible for supplying a mutable messages array.
    func subscribeToMessages(
        committeeId: UUID,
        area: String? = nil,
        onInsert: @escaping (CommitteeChatMessage) -> Void,
        onUpdate: @escaping (CommitteeChatMessage) -> Void,
        onReactionsChanged: @escaping () -> Void = {}
    ) {
        let key = channelKey(committeeId, area)
        guard messageChannels[key] == nil else { return }
        let channel = supabase.channel("committee-chat-\(key)")
        messageChannels[key] = channel

        Task {
            // Realtime filters on one column, so we filter by committee server-side
            // and match the area client-side (a role channel vs the General one).
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
                    // Only this channel's area (treat missing/null as General).
                    let rowArea = record["area"]?.stringValue
                    guard rowArea == area else { return }
                    guard let idStr = record["id"]?.stringValue,
                          let id = UUID(uuidString: idStr)
                    else { return }
                    if let row: CommitteeChatRow = try? await supabase
                        .from("committee_messages")
                        .select("""
                            id, committee_id, author_id, text, edited_at, deleted_at, created_at, area,
                            profiles!author_id(display_name, avatar_url),
                            committee_message_media(storage_path, media_type, width, height, file_name, position)
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
            // Reactions live on their own table (no committee column to filter on),
            // so listen table-wide and let the view reconcile with a light refetch.
            channel.onPostgresChange(
                AnyAction.self,
                schema: "public",
                table: "committee_message_reactions"
            ) { _ in
                Task { @MainActor in onReactionsChanged() }
            }
            await channel.subscribe()
        }
    }

    func unsubscribeFromMessages(committeeId: UUID, area: String? = nil) {
        let key = channelKey(committeeId, area)
        guard let channel = messageChannels[key] else { return }
        Task {
            await supabase.removeChannel(channel)
            messageChannels.removeValue(forKey: key)
        }
    }

    private func channelKey(_ committeeId: UUID, _ area: String?) -> String {
        "\(committeeId.uuidString)|\(area ?? "")"
    }

    /// Mark a channel read (per-area unread state, migration 0063).
    func markAreaRead(committeeId: UUID, area: String?) async {
        struct Params: Encodable { let cid: String; let p_area: String? }
        _ = try? await supabase
            .rpc("mark_area_read", params: Params(cid: committeeId.uuidString, p_area: area))
            .execute()
    }

    /// Mute or unmute a channel's push notifications (migration 0063).
    func setAreaMute(committeeId: UUID, area: String?, muted: Bool) async {
        struct Params: Encodable { let cid: String; let p_area: String?; let p_muted: Bool }
        _ = try? await supabase
            .rpc("set_area_mute", params: Params(cid: committeeId.uuidString, p_area: area, p_muted: muted))
            .execute()
    }

    /// Whether the caller has muted a channel.
    func isAreaMuted(committeeId: UUID, area: String?) async -> Bool {
        struct Row: Decodable { let muted: Bool }
        let rows: [Row] = (try? await supabase
            .from("committee_area_reads")
            .select("muted")
            .eq("committee_id", value: committeeId.uuidString)
            .eq("area", value: area ?? "")
            .limit(1).execute().value) ?? []
        return rows.first?.muted ?? false
    }

    // MARK: - Chat channels (Messages-style conversation list)

    /// The chat channels the member sees on the Feed: for each committee they're
    /// in, a General channel, plus one per role/area they hold (Family Fest →
    /// "Meals", …). A committee where they hold no role shows a single chat.
    func fetchMyChannels(userId: UUID) async -> [ChatChannel] {
        if committees.isEmpty { await fetchCommittees() }
        let mySlugs = await fetchMyCommitteeSlugs(userId: userId)
        let mine = committees.filter { mySlugs.contains($0.slug) }.sorted { $0.name < $1.name }
        var channels: [ChatChannel] = []
        for committee in mine {
            let roster = (try? await fetchRoster(slug: committee.slug)) ?? []
            let myAreas = Self.areas(forUser: userId, in: roster)
            if myAreas.isEmpty {
                // No assigned role → a single committee chat (the General/NULL channel).
                channels.append(ChatChannel(committee: committee, area: nil,
                                            title: committee.name, subtitle: nil))
            } else {
                // Committee-wide channel: title carries the committee name (e.g.
                // "Family Fest General") so it's clear which committee's General
                // this is once real messages replace the subtitle fallback.
                channels.append(ChatChannel(committee: committee, area: nil,
                                            title: "\(committee.name) General", subtitle: nil))
                for area in myAreas {
                    channels.append(ChatChannel(committee: committee, area: area,
                                                title: area, subtitle: committee.name))
                }
            }
        }
        return channels
    }

    /// Distinct areas a user holds in a committee's roster (role " · Lead" suffix stripped).
    static func areas(forUser userId: UUID, in roster: [CommitteeRosterEntry]) -> [String] {
        var seen = Set<String>(); var ordered: [String] = []
        for entry in roster where entry.linkedUserId == userId {
            for role in entry.roles {
                let area = role.hasSuffix(" · Lead") ? String(role.dropLast(" · Lead".count)) : role
                if !area.isEmpty && !seen.contains(area) { seen.insert(area); ordered.append(area) }
            }
        }
        return ordered
    }

    /// Last-message preview + unread count for a channel (drives the list rows).
    func fetchChannelSummary(committeeId: UUID, area: String?, userId: UUID) async -> ChannelSummary {
        struct LastRow: Decodable {
            let text: String?; let createdAt: Date; let deletedAt: Date?; let authorName: String?
            enum CodingKeys: String, CodingKey {
                case text; case createdAt = "created_at"; case deletedAt = "deleted_at"
                case profiles
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
        var lastQ = supabase
            .from("committee_messages")
            .select("text, created_at, deleted_at, profiles!author_id(display_name)")
            .eq("committee_id", value: committeeId.uuidString)
        if let area { lastQ = lastQ.eq("area", value: area) } else { lastQ = lastQ.is("area", value: nil) }
        let last: [LastRow] = (try? await lastQ.order("created_at", ascending: false).limit(1).execute().value) ?? []
        let lastRow = last.first

        struct ReadRow: Decodable { let lastReadAt: Date?; let muted: Bool?
            enum CodingKeys: String, CodingKey { case lastReadAt = "last_read_at"; case muted } }
        let reads: [ReadRow] = (try? await supabase
            .from("committee_area_reads")
            .select("last_read_at, muted")
            .eq("committee_id", value: committeeId.uuidString)
            .eq("user_id", value: userId.uuidString)
            .eq("area", value: area ?? "")
            .limit(1).execute().value) ?? []
        let lastRead = reads.first?.lastReadAt
        let muted = reads.first?.muted ?? false

        var cq = supabase
            .from("committee_messages")
            .select("id", head: true, count: .exact)
            .eq("committee_id", value: committeeId.uuidString)
            .neq("author_id", value: userId.uuidString)
        if let area { cq = cq.eq("area", value: area) } else { cq = cq.is("area", value: nil) }
        if let lastRead { cq = cq.gt("created_at", value: ISO8601DateFormatter().string(from: lastRead)) }
        let unread = (try? await cq.execute().count) ?? 0

        let preview: String? = {
            guard let lastRow else { return nil }
            if lastRow.deletedAt != nil { return "Message deleted" }
            let who = lastRow.authorName.map { "\($0): " } ?? ""
            return who + (lastRow.text ?? "")
        }()
        return ChannelSummary(lastText: preview, lastAt: lastRow?.createdAt, unread: unread, muted: muted)
    }

    // MARK: - Realtime for roster

    /// Subscribe to live roster changes for a committee so newly added members
    /// appear without a manual refresh — matching the web app, which re-fetches
    /// the roster on any committee_roster change. `onChange` should reload the
    /// roster; it fires on insert/update/delete.
    func subscribeToRoster(slug: String, onChange: @escaping () -> Void) {
        guard rosterChannels[slug] == nil else { return }
        let channel = supabase.channel("committee-roster-\(slug)")
        rosterChannels[slug] = channel

        Task {
            channel.onPostgresChange(
                AnyAction.self,
                schema: "public",
                table: "committee_roster",
                filter: "committee_slug=eq.\(slug)"
            ) { _ in
                Task { @MainActor in onChange() }
            }
            await channel.subscribe()
        }
    }

    func unsubscribeFromRoster(slug: String) {
        guard let channel = rosterChannels[slug] else { return }
        Task {
            await supabase.removeChannel(channel)
            rosterChannels.removeValue(forKey: slug)
        }
    }

    /// Subscribe to live membership changes for a committee — join requests and
    /// committee_members — so a manager's pending-request list and roster update
    /// without a manual refresh, matching the web app. `onChange` should reload.
    func subscribeToManagement(slug: String, committeeId: UUID, onChange: @escaping () -> Void) {
        guard mgmtChannels[slug] == nil else { return }
        let channel = supabase.channel("committee-mgmt-\(slug)")
        mgmtChannels[slug] = channel

        Task {
            for table in ["committee_join_requests", "committee_members"] {
                channel.onPostgresChange(
                    AnyAction.self,
                    schema: "public",
                    table: table,
                    filter: "committee_id=eq.\(committeeId.uuidString)"
                ) { _ in
                    Task { @MainActor in onChange() }
                }
            }
            await channel.subscribe()
        }
    }

    func unsubscribeFromManagement(slug: String) {
        guard let channel = mgmtChannels[slug] else { return }
        Task {
            await supabase.removeChannel(channel)
            mgmtChannels.removeValue(forKey: slug)
        }
    }
}

// MARK: - Chat channel + summary (conversation list)

/// One row in the Feed conversation list: a committee's General channel or one
/// of its role channels. `area == nil` = the General / whole-committee chat.
struct ChatChannel: Identifiable, Equatable {
    let committee: Committee
    let area: String?
    let title: String
    let subtitle: String?
    var id: String { "\(committee.id.uuidString)|\(area ?? "")" }
}

/// Preview state for a channel row: last message, its time, and unread count.
struct ChannelSummary: Equatable {
    var lastText: String?
    var lastAt: Date?
    var unread: Int
    var muted: Bool = false
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
    let area: String?
    let profiles: AuthorInfo?
    let media: [ChatMedia]?
    let reactions: [ChatReaction]?

    enum CodingKeys: String, CodingKey {
        case id
        case committeeId = "committee_id"
        case authorId = "author_id"
        case text
        case editedAt = "edited_at"
        case deletedAt = "deleted_at"
        case createdAt = "created_at"
        case area
        case profiles
        case media = "committee_message_media"
        case reactions = "committee_message_reactions"
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
            createdAt: createdAt,
            area: area,
            media: (media ?? []).sorted { $0.position < $1.position },
            reactions: reactions ?? []
        )
    }
}
