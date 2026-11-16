import SwiftUI
import Supabase

// MARK: - Event chats (migrations 0216–0218)
//
// A private room per event, for the people actually going. Most talk about a
// work weekend concerns the dozen people who'll be there — posting it to the
// Family Feed bombards everyone else with logistics they have no use for.
//
// Membership is resolved LIVE, never snapshotted: someone who RSVPs three weeks
// later just appears in the room, with the full history readable from their
// first visit. Seven days after the event ends the chat archives itself and
// becomes read-only, so the record survives without cluttering anything.
//
// ⚠️⚠️ THERE IS NO APP-ADMIN OVERRIDE. This is the app's first genuinely
// admin-blind room and that is the point — you only see the room if you RSVP'd.
// It DIFFERS from every other chat: `is_committee_member` and `is_house_member`
// both return true for any admin. Do not "fix" the inconsistency by assuming an
// admin can read these; the server won't let them, and the UI shouldn't imply
// otherwise. (Moderation still works — an admin can read a message only while
// it's HELD, so they see the item to rule on and never the conversation.)

struct EventChatSummary: Decodable, Identifiable {
    let eventId: String
    let title: String?
    let emoji: String?
    let startDate: String?
    let endDate: String?
    let archived: Bool
    /// ⚠️ Distinct from membership. A Maybe can READ the room (they're often the
    /// person most in need of the detail that would settle it) but can't POST
    /// until they've actually said they're going (0217).
    let canPost: Bool
    let lastText: String?
    let lastAt: Date?
    let lastAuthor: String?
    let lastMedia: String?
    let unread: Int
    let muted: Bool
    let mutedUntil: Date?

    var id: String { eventId }

    /// Effectively muted: permanent, or a timer still in the future. Both halves
    /// matter — see FeedMuteService for what happens when only one is checked.
    var isMuted: Bool {
        if muted { return true }
        if let mutedUntil { return mutedUntil > .now }
        return false
    }

    enum CodingKeys: String, CodingKey {
        case title, emoji, archived, unread, muted
        case eventId = "event_id"
        case startDate = "start_date"
        case endDate = "end_date"
        case canPost = "can_post"
        case lastText = "last_text"
        case lastAt = "last_at"
        case lastAuthor = "last_author"
        case lastMedia = "last_media"
        case mutedUntil = "muted_until"
    }
}


struct EventChatMessage: Identifiable, Equatable {
    let id: UUID
    let eventId: String
    let authorId: UUID
    var authorName: String
    var authorAvatarUrl: String?
    var text: String?
    var status: String        // "visible" | "pending" | "hidden"
    var createdAt: Date
    var editedAt: Date?
    var deletedAt: Date?
    var replyToId: UUID?
    var media: [ChatMedia] = []
    var reactions: [ChatReaction] = []

    /// Held by the content checker. Its author sees it with a note; nobody else
    /// sees it at all.
    var isHeld: Bool { status == "pending" }
    var isHidden: Bool { status == "hidden" }
    var isDeleted: Bool { deletedAt != nil }
    var isEdited: Bool { editedAt != nil }

    /// RLS (0216): the author within 24h, or an app admin any time.
    func canModify(userId: UUID, isAdmin: Bool, now: Date = .now) -> Bool {
        guard !isDeleted else { return false }
        if isAdmin { return true }
        return authorId == userId && now.timeIntervalSince(createdAt) < 86_400
    }
}

/// An archived room as the admin reopen screen sees it. Never any content.
struct ArchivedEventChat: Decodable, Identifiable {
    let eventId: String
    let title: String?
    let emoji: String?
    let startDate: String?
    let endDate: String?
    let messageCount: Int
    let reopenedUntil: Date?

    var id: String { eventId }

    /// Reopened and the window hasn't passed yet.
    var openUntil: Date? {
        guard let reopenedUntil, reopenedUntil > .now else { return nil }
        return reopenedUntil
    }

    enum CodingKeys: String, CodingKey {
        case title, emoji
        case eventId = "event_id"
        case startDate = "start_date"
        case endDate = "end_date"
        case messageCount = "message_count"
        case reopenedUntil = "reopened_until"
    }
}

@Observable
@MainActor
final class EventChatService {

    var chats: [EventChatSummary] = []
    var messages: [String: [EventChatMessage]] = [:]
    var loading = false

    /// Set while an admin previews as a specific member: the list then comes
    /// from `preview_event_chats` (no previews, never writes). Assigned by
    /// AppEnvironment.reloadPreviewScopedData.
    var previewUserId: UUID?

    private var channels: [String: RealtimeChannelV2] = [:]
    /// Optimistic temp bubbles not yet confirmed; a refetch must not drop them.
    private var pendingIds: Set<UUID> = []

    /// Live rooms, most recent activity first.
    var liveChats: [EventChatSummary] { chats.filter { !$0.archived } }
    /// Archived rooms live behind a collapsed line at the foot of the Feed.
    var archivedChats: [EventChatSummary] { chats.filter(\.archived) }

    var totalUnread: Int { liveChats.filter { !$0.isMuted }.reduce(0) { $0 + $1.unread } }

    func loadChats() async {
        loading = true
        defer { loading = false }
        // Empty on failure is correct here: `my_event_chats` returns nothing for
        // someone who isn't going to anything, which is the common case.
        if let previewUserId {
            // `my_event_chats` reads auth.uid(), i.e. the ADMIN's own rooms.
            struct P: Encodable { let p_user: UUID }
            chats = (try? await supabase.rpc("preview_event_chats", params: P(p_user: previewUserId))
                .execute().value) ?? []
        } else {
            chats = (try? await supabase.rpc("my_event_chats").execute().value) ?? []
        }
    }

    // MARK: Reading

    private struct Row: Decodable {
        let id: UUID
        let eventId: String
        let authorId: UUID
        let text: String?
        let status: String?
        let createdAt: Date
        let editedAt: Date?
        let deletedAt: Date?
        let replyToId: UUID?
        let author: Author?
        let media: [ChatMedia]?
        let reactions: [ChatReaction]?
        struct Author: Decodable {
            let displayName: String?
            let avatarUrl: String?
            enum CodingKeys: String, CodingKey {
                case displayName = "display_name"
                case avatarUrl = "avatar_url"
            }
        }
        enum CodingKeys: String, CodingKey {
            case id, text, status, author
            case eventId = "event_id"
            case authorId = "author_id"
            case createdAt = "created_at"
            case editedAt = "edited_at"
            case deletedAt = "deleted_at"
            case replyToId = "reply_to_id"
            case media = "event_chat_message_media"
            case reactions = "event_chat_message_reactions"
        }

        var message: EventChatMessage {
            EventChatMessage(
                id: id, eventId: eventId, authorId: authorId,
                authorName: author?.displayName ?? "Someone",
                authorAvatarUrl: author?.avatarUrl,
                text: text,
                status: status ?? "visible",
                createdAt: createdAt, editedAt: editedAt, deletedAt: deletedAt,
                replyToId: replyToId,
                media: (media ?? []).sorted { $0.position < $1.position },
                reactions: reactions ?? [])
        }
    }

    private static let select = """
        id, event_id, author_id, text, status, created_at, edited_at, deleted_at, reply_to_id,
        author:author_id(display_name, avatar_url),
        event_chat_message_media(storage_path, media_type, file_name, width, height, thumbnail_url, position),
        event_chat_message_reactions(user_id, emoji)
        """

    /// Soft-deleted rows stay in the list (rendered as a tombstone).
    func loadMessages(eventId: String) async {
        let rows: [Row]? = try? await supabase
            .from("event_chat_messages")
            .select(Self.select)
            .eq("event_id", value: eventId)
            .order("created_at", ascending: true)
            .execute().value
        guard let rows else { return }
        let pending = (messages[eventId] ?? []).filter { pendingIds.contains($0.id) }
        messages[eventId] = rows.map(\.message) + pending
    }

    private func fetchOne(id: UUID) async -> EventChatMessage? {
        let row: Row? = try? await supabase
            .from("event_chat_messages")
            .select(Self.select)
            .eq("id", value: id.uuidString)
            .single()
            .execute().value
        return row?.message
    }

    /// People who can be @mentioned: going or maybe.
    func fetchRoster(eventId: String) async -> [Profile] {
        struct A: Decodable {
            let userId: UUID
            enum CodingKeys: String, CodingKey { case userId = "user_id" }
        }
        let att: [A] = (try? await supabase
            .from("event_attendance")
            .select("user_id")
            .eq("event_id", value: eventId)
            .in("status", values: ["going", "maybe"])
            .execute().value) ?? []
        guard !att.isEmpty else { return [] }
        return (try? await supabase
            .from("profiles")
            .select("id, display_name, avatar_url, is_admin")
            .in("id", values: att.map { $0.userId.uuidString })
            .order("display_name", ascending: true)
            .execute().value) ?? []
    }

    // MARK: Realtime

    /// Messages filtered by event; reactions have no event column, so listen
    /// table-wide and refetch (same as the house/committee rooms).
    func subscribe(eventId: String) {
        guard channels[eventId] == nil else { return }
        let channel = supabase.channel("event-chat-\(eventId)")
        channels[eventId] = channel

        Task {
            channel.onPostgresChange(
                AnyAction.self,
                schema: "public",
                table: "event_chat_messages",
                filter: "event_id=eq.\(eventId)"
            ) { action in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let record: [String: AnyJSON]
                    switch action {
                    case .insert(let a): record = a.record
                    case .update(let a): record = a.record
                    case .delete: await self.loadMessages(eventId: eventId); return
                    }
                    guard let idStr = record["id"]?.stringValue, let id = UUID(uuidString: idStr),
                          let msg = await self.fetchOne(id: id) else { return }
                    var list = self.messages[eventId] ?? []
                    if let i = list.firstIndex(where: { $0.id == id }) { list[i] = msg }
                    else { list.append(msg) }
                    self.messages[eventId] = list
                }
            }
            channel.onPostgresChange(
                AnyAction.self,
                schema: "public",
                table: "event_chat_message_reactions"
            ) { _ in
                Task { @MainActor [weak self] in await self?.loadMessages(eventId: eventId) }
            }
            await channel.subscribe()
        }
    }

    func unsubscribe(eventId: String) {
        guard let channel = channels[eventId] else { return }
        channels.removeValue(forKey: eventId)
        Task { await supabase.removeChannel(channel) }
    }

    // MARK: Writing

    /// ⚠️ A plain INSERT, gated by RLS — `can_post_in_event_chat` checks
    /// membership, a going RSVP, and that the room isn't archived. There is no
    /// send RPC to route around it. Text-only sends show an optimistic bubble
    /// and rethrow on failure so the caller can restore the draft.
    ///
    /// `optimistic: false` lets the room view own the unconfirmed bubble (so a
    /// failed send can stay on screen as "Not delivered"); `onProgress` reports
    /// completed/total uploads and `onPersisted` fires the moment the confirmed
    /// message replaces it in `messages`.
    func send(eventId: String, text: String, replyToId: UUID?, mentionedIds: [UUID],
              attachments: [ChatAttachment], me: Profile?, mediaService: MediaService,
              optimistic: Bool = true,
              onProgress: ((Double) -> Void)? = nil,
              onPersisted: (() -> Void)? = nil) async throws {
        guard previewUserId == nil, let uid = supabase.auth.currentUser?.id else { return }

        var tempId: UUID?
        if attachments.isEmpty && optimistic {
            let t = UUID()
            tempId = t
            pendingIds.insert(t)
            messages[eventId, default: []].append(EventChatMessage(
                id: t, eventId: eventId, authorId: uid,
                authorName: me?.displayName ?? "You", authorAvatarUrl: me?.avatarUrl,
                text: text, status: "visible", createdAt: .now, replyToId: replyToId))
        }
        defer { if let tempId { pendingIds.remove(tempId) } }

        do {
            // Upload first (category "chat", room = eventId), then insert.
            var uploaded: [ChatMedia] = []
            for att in attachments {
                let res = try await mediaService.uploadChatMedia(
                    data: att.data, filename: att.filename, mimeType: att.mimeType, room: eventId)
                let type = att.kind == .image ? "image" : att.kind == .video ? "video" : "file"
                uploaded.append(ChatMedia(url: res.url, type: type,
                                          name: att.kind == .file ? att.filename : nil,
                                          position: uploaded.count))
                onProgress?(Double(uploaded.count) / Double(attachments.count))
            }

            struct Insert: Encodable {
                let event_id: String
                let author_id: String
                let text: String?
                let reply_to_id: String?
            }
            struct Inserted: Decodable { let id: UUID }
            let inserted: Inserted = try await supabase.from("event_chat_messages")
                .insert(Insert(event_id: eventId, author_id: uid.uuidString,
                               text: text.isEmpty ? nil : text,
                               reply_to_id: replyToId?.uuidString))
                .select("id").single().execute().value

            if !uploaded.isEmpty {
                struct MediaRow: Encodable {
                    let message_id: String
                    let storage_path: String
                    let media_type: String
                    let file_name: String?
                    let position: Int
                }
                try await supabase.from("event_chat_message_media")
                    .insert(uploaded.map {
                        MediaRow(message_id: inserted.id.uuidString, storage_path: $0.url,
                                 media_type: $0.type, file_name: $0.name, position: $0.position)
                    }).execute()
            }
            if !mentionedIds.isEmpty {
                struct MentionRow: Encodable { let message_id: String; let mentioned_user_id: String }
                try await supabase.from("event_chat_message_mentions")
                    .insert(mentionedIds.map {
                        MentionRow(message_id: inserted.id.uuidString, mentioned_user_id: $0.uuidString)
                    }).execute()
            }

            if let tempId { messages[eventId]?.removeAll { $0.id == tempId } }
            if let msg = await fetchOne(id: inserted.id) {
                var list = messages[eventId] ?? []
                if let i = list.firstIndex(where: { $0.id == msg.id }) { list[i] = msg } else { list.append(msg) }
                messages[eventId] = list
            }
            onPersisted?()
            await markRead(eventId: eventId)
        } catch {
            if let tempId { messages[eventId]?.removeAll { $0.id == tempId } }
            throw error
        }
    }

    func edit(eventId: String, messageId: UUID, text: String) async throws {
        guard previewUserId == nil else { return }
        struct P: Encodable { let text: String; let edited_at: String }
        let now = Date.now
        try await supabase.from("event_chat_messages")
            .update(P(text: text, edited_at: ISO8601DateFormatter().string(from: now)))
            .eq("id", value: messageId.uuidString).execute()
        if let i = messages[eventId]?.firstIndex(where: { $0.id == messageId }) {
            messages[eventId]?[i].text = text
            messages[eventId]?[i].editedAt = now
        }
    }

    /// Soft delete — the row stays so the room shows "message deleted".
    func delete(eventId: String, messageId: UUID) async throws {
        guard previewUserId == nil else { return }
        struct P: Encodable { let deleted_at: String }
        let now = Date.now
        try await supabase.from("event_chat_messages")
            .update(P(deleted_at: ISO8601DateFormatter().string(from: now)))
            .eq("id", value: messageId.uuidString).execute()
        if let i = messages[eventId]?.firstIndex(where: { $0.id == messageId }) {
            messages[eventId]?[i].deletedAt = now
        }
    }

    /// Same emoji again removes my row; a different one replaces it (PK is
    /// message_id + user_id). Optimistic, reconciled by realtime.
    func react(eventId: String, messageId: UUID, emoji: String, userId: UUID) async {
        guard previewUserId == nil else { return }
        var removing = false
        if let i = messages[eventId]?.firstIndex(where: { $0.id == messageId }),
           let list = messages[eventId]?[i].reactions {
            var rs = list
            if let mine = rs.firstIndex(where: { $0.userId == userId }) {
                if rs[mine].emoji == emoji { rs.remove(at: mine); removing = true }
                else { rs[mine] = ChatReaction(userId: userId, emoji: emoji) }
            } else {
                rs.append(ChatReaction(userId: userId, emoji: emoji))
            }
            messages[eventId]?[i].reactions = rs
        }
        do {
            if removing {
                try await supabase.from("event_chat_message_reactions").delete()
                    .eq("message_id", value: messageId.uuidString)
                    .eq("user_id", value: userId.uuidString).execute()
            } else {
                struct R: Encodable { let message_id: String; let user_id: String; let emoji: String }
                try await supabase.from("event_chat_message_reactions")
                    .upsert(R(message_id: messageId.uuidString, user_id: userId.uuidString, emoji: emoji),
                            onConflict: "message_id,user_id").execute()
            }
        } catch {
            await loadMessages(eventId: eventId)
        }
    }

    func markRead(eventId: String) async {
        // A read receipt while previewing would be written as the admin.
        guard previewUserId == nil else { return }
        struct P: Encodable { let p_event_id: String }
        _ = try? await supabase.rpc("mark_event_chat_read", params: P(p_event_id: eventId)).execute()
    }

    /// Durations write only `muted_until` server-side, so a timer expires by
    /// going stale.
    func setMute(eventId: String, muted: Bool, until: Date? = nil) async {
        guard previewUserId == nil else { return }
        struct P: Encodable { let p_event_id: String; let p_muted: Bool; let p_muted_until: String? }
        let iso = until.map { ISO8601DateFormatter().string(from: $0) }
        _ = try? await supabase.rpc("set_event_chat_mute",
                                    params: P(p_event_id: eventId, p_muted: muted, p_muted_until: iso))
            .execute()
        await loadChats()
    }

    // MARK: Admin

    func fetchArchived() async -> [ArchivedEventChat] {
        (try? await supabase.rpc("admin_archived_event_chats").execute().value) ?? []
    }

    /// `days` 1 or 7 reopens; nil re-archives now. Returns the server's error text.
    func setReopened(eventId: String, days: Int?) async -> String? {
        struct P: Encodable {
            let p_event_id: String
            let p_days: Int?
            // The function has no default for p_days, so null must be sent
            // explicitly (the synthesized encoder would omit the key).
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: Keys.self)
                try c.encode(p_event_id, forKey: .p_event_id)
                try c.encode(p_days, forKey: .p_days)
            }
            enum Keys: String, CodingKey { case p_event_id, p_days }
        }
        do {
            try await supabase.rpc("set_event_chat_reopened", params: P(p_event_id: eventId, p_days: days)).execute()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: - The room

struct EventChatView: View {
    @Environment(AppEnvironment.self) private var env
    let chat: EventChatSummary

    @State private var draft = ""
    @State private var sending = false
    @State private var error: String?
    @State private var roster: [Profile] = []
    @State private var replyingTo: EventChatMessage?
    @State private var editing: EventChatMessage?
    // Typing indicator (same broadcast helper as the committee + house rooms).
    @State private var typing = ChatTypingChannel()
    // Unconfirmed outgoing messages: the local bubbles + their send state.
    @State private var unsent: [EventChatMessage] = []
    @State private var outbox: [UUID: ChatOutboxEntry] = [:]
    // Smart auto-scroll + jump pill with unread count.
    @State private var atBottom = true
    @State private var showJumpPill = false
    @State private var unreadWhileUp = 0
    @State private var didInitialScroll = false
    @State private var scrollBump = 0
    // First message from someone else since this device last closed the room.
    @State private var firstUnreadId: String?

    private static let bottomID = "__event_chat_bottom__"

    private var service: EventChatService { env.eventChatService }
    private var messages: [EventChatMessage] { service.messages[chat.eventId] ?? [] }
    private var myId: UUID? { env.currentProfile?.id }
    private var roomKey: String { "event:\(chat.eventId)" }
    /// Mute state comes from the refreshed summary, not the snapshot we opened with.
    private var current: EventChatSummary { service.chats.first { $0.eventId == chat.eventId } ?? chat }
    /// A reaction counts as speaking, so it follows the composer's gate.
    private var canSpeak: Bool { chat.canPost && !chat.archived && !env.isPreviewing }

    /// What the room shows: confirmed messages (held ones only to their author)
    /// then my unconfirmed local bubbles.
    private var visibleMessages: [EventChatMessage] {
        messages.filter { !$0.isHidden || $0.authorId == myId } + unsent
    }

    private static func groupItems(_ list: [EventChatMessage]) -> [ChatGroupItem] {
        list.map { ChatGroupItem(id: $0.id.uuidString, authorId: $0.authorId, date: $0.createdAt) }
    }

    var body: some View {
        VStack(spacing: 0) {
            messageScroll
            TypingIndicator(names: typing.typers)
            composerArea
        }
        .background(Color.mlrSurface)
        .navigationTitle(chat.title ?? "Event chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !env.isPreviewing {
                ToolbarItem(placement: .topBarTrailing) { muteMenu }
            }
        }
        .chatDraftPersistence(text: $draft, roomKey: roomKey,
                              userId: env.isPreviewing ? nil : myId,
                              paused: editing != nil)
        .onChange(of: draft) { _, new in
            if canSpeak && editing == nil && !new.trimmingCharacters(in: .whitespaces).isEmpty {
                typing.notifyTyping()
            }
        }
        .task {
            // Previewing as someone else: no reads, no subscription, no receipts.
            guard !env.isPreviewing else { return }
            await service.loadMessages(eventId: chat.eventId)
            if let me = myId {
                firstUnreadId = ChatReadMarker.firstUnreadId(
                    in: Self.groupItems(visibleMessages),
                    lastSeen: ChatReadMarker.lastSeen(room: roomKey, user: me), me: me)
            }
            await service.markRead(eventId: chat.eventId)
            roster = await service.fetchRoster(eventId: chat.eventId)
            service.subscribe(eventId: chat.eventId)
            if canSpeak, let me = env.currentProfile {
                typing.start(roomKey: roomKey, uid: me.id, name: me.displayName)
            }
        }
        .onDisappear {
            if !env.isPreviewing, let me = myId {
                ChatReadMarker.markSeen(room: roomKey, user: me)
            }
            service.unsubscribe(eventId: chat.eventId)
            typing.stop()
        }
    }

    private var messageScroll: some View {
        let list = visibleMessages
        let metas = ChatGrouping.meta(for: Self.groupItems(list), firstUnreadId: firstUnreadId)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    header
                        .padding(.horizontal, 16)
                    ForEach(list) { message in
                        row(message, meta: metas[message.id.uuidString] ?? ChatRowMeta(), proxy: proxy)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.vertical, 12)
            }
            .chatScrollBehavior(atBottom: $atBottom)
            .onChange(of: atBottom) { _, now in
                if now { showJumpPill = false; unreadWhileUp = 0 }
            }
            .onChange(of: list.count) { old, new in
                guard new != old, new > 0 else { return }
                if !didInitialScroll {
                    didInitialScroll = true
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                } else if atBottom || list.last?.authorId == myId {
                    withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                } else if new > old {
                    showJumpPill = true
                    unreadWhileUp += new - old
                }
            }
            .onChange(of: scrollBump) {
                withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                showJumpPill = false
                unreadWhileUp = 0
            }
            .chatJumpPill(visible: showJumpPill && !atBottom, unread: unreadWhileUp) { scrollBump += 1 }
        }
    }

    // MARK: Mute (same menu as the feed bell)

    private var muteMenu: some View {
        Menu {
            if current.isMuted {
                Button("Unmute") { setMute(muted: false) }
            } else {
                Button("Mute for 1 hour") { setMute(muted: true, hours: 1) }
                Button("Mute for 8 hours") { setMute(muted: true, hours: 8) }
                Button("Mute for 1 day") { setMute(muted: true, hours: 24) }
                Button("Mute for a week") { setMute(muted: true, hours: 24 * 7) }
                Divider()
                Button("Mute until I turn it back on") { setMute(muted: true) }
            }
        } label: {
            Image(systemName: current.isMuted ? "bell.slash.fill" : "bell")
        }
        .accessibilityLabel(current.isMuted ? "Chat muted" : "Mute this chat")
    }

    private func setMute(muted: Bool, hours: Int? = nil) {
        let until = hours.map { Date.now.addingTimeInterval(TimeInterval($0) * 3600) }
        Task { await service.setMute(eventId: chat.eventId, muted: muted, until: until) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Just the people going to \(chat.title ?? "this")")
                .font(.mlrScaled(12))
                .foregroundStyle(Color.mlrTextMuted)
            if chat.archived {
                Label("This event's over — the chat is kept as a record.",
                      systemImage: "archivebox")
                    .font(.mlrScaled(11))
                    .foregroundStyle(Color.mlrTextSubtle)
            }
            if env.isPreviewing {
                Text("Previewing — messages in a private room aren't shown.")
                    .font(.mlrScaled(11))
                    .foregroundStyle(Color.mlrTextSubtle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }

    // MARK: Bubble

    private func quote(for id: UUID?) -> (author: String, text: String)? {
        guard let id, let m = messages.first(where: { $0.id == id }) else { return nil }
        let text = m.isDeleted ? "Message deleted" : ((m.text ?? "").isEmpty ? "📎 Attachment" : (m.text ?? ""))
        return (m.authorId == myId ? "You" : m.authorName, text)
    }

    private func reactorName(_ id: UUID) -> String {
        if id == myId { return "You" }
        return roster.first { $0.id == id }?.displayName
            ?? messages.first { $0.authorId == id }?.authorName ?? "Member"
    }

    /// Media URLs go through the token store; reading its token in the body is
    /// also what re-renders them the moment it arrives.
    private func signed(_ media: [ChatMedia]) -> [ChatMedia] {
        media.map { m in
            var c = m
            if let u = env.mediaTokenService.url(m.url)?.absoluteString { c = ChatMedia(url: u, type: m.type, width: m.width, height: m.height, name: m.name, position: m.position) }
            return c
        }
    }

    @ViewBuilder
    private func row(_ message: EventChatMessage, meta: ChatRowMeta, proxy: ScrollViewProxy) -> some View {
        let mine = message.authorId == myId
        let pending = outbox[message.id]
        ChatMessageRow(
            meta: meta,
            isOwn: mine,
            authorName: message.authorName,
            avatarUrl: message.authorAvatarUrl,
            createdAt: message.createdAt,
            isDeleted: message.isDeleted,
            delivery: pending?.delivery,
            onReply: (canSpeak && !message.isDeleted) ? { replyingTo = message; editing = nil } : nil,
            onDoubleTap: (canSpeak && !message.isDeleted) ? { quickTapback(message) } : nil,
            onRetry: { Task { await deliver(message.id) } },
            onDeleteUnsent: { discardUnsent(message.id) }
        ) {
            bubble(message, mine: mine, pending: pending, tail: meta.endsGroup, proxy: proxy)
        }
    }

    @ViewBuilder
    private func bubble(_ message: EventChatMessage, mine: Bool, pending: ChatOutboxEntry?,
                        tail: Bool, proxy: ScrollViewProxy) -> some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            if message.isDeleted {
                Label("message deleted", systemImage: "trash")
                    .font(.mlrScaled(13))
                    .italic()
                    .foregroundStyle(Color.mlrTextMuted)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.mlrCard.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                content(message, mine: mine, pending: pending, tail: tail, proxy: proxy)
                    .contextMenu {
                        // Unsent bubbles have no server id yet.
                        if pending == nil { menu(message, mine: mine) }
                    }
                ChatReactionPills(reactions: message.reactions, myUserId: myId, isOwn: mine,
                                  reactorName: { reactorName($0) })
            }
        }
    }

    @ViewBuilder
    private func content(_ message: EventChatMessage, mine: Bool, pending: ChatOutboxEntry?,
                         tail: Bool, proxy: ScrollViewProxy) -> some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            if let q = quote(for: message.replyToId) {
                Button {
                    if let rid = message.replyToId { withAnimation { proxy.scrollTo(rid, anchor: .center) } }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(q.author)
                            .font(.mlrScaled(11, weight: .semibold))
                            .foregroundStyle(Color.mlrPrimary)
                        Text(q.text)
                            .font(.mlrScaled(12))
                            .foregroundStyle(Color.mlrTextMuted)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: 240, alignment: .leading)
                    .background(Color.mlrPrimary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1).fill(Color.mlrPrimary).frame(width: 2.5).padding(.vertical, 4)
                    }
                }
                .buttonStyle(.pressable)
            }
            if let pending, !pending.payload.attachments.isEmpty {
                ChatPendingAttachments(entry: pending, isOwn: mine)
            } else if !message.media.isEmpty {
                ChatMediaView(media: signed(message.media), isOwn: mine)
            }
            if let text = message.text, !text.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    MentionText(
                        text,
                        baseColor: mine ? .white : Color.mlrText,
                        mentionColor: mine ? Color.mlrPrimaryLight : Color.mlrPrimary
                    )
                    if message.isEdited {
                        Text("edited")
                            .font(.mlrScaled(10))
                            .foregroundStyle(mine ? Color.white.opacity(0.7) : Color.mlrTextSubtle)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .chatBubbleBackground(isOwn: mine, tail: tail)
            } else if message.isEdited {
                Text("edited")
                    .font(.mlrScaled(10))
                    .foregroundStyle(Color.mlrTextSubtle)
            }
            // ⚠️ A held message is shown to ITS AUTHOR with a reason. Everyone
            // else can't see it at all (RLS), so vanishing without explanation
            // would read to the author as "my message didn't send".
            if message.isHeld {
                Label("Held for review — only you and admins can see this.",
                      systemImage: "clock.badge.exclamationmark")
                    .font(.mlrScaled(10))
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func menu(_ message: EventChatMessage, mine: Bool) -> some View {
        if canSpeak {
            Picker("React", selection: Binding(
                get: { message.reactions.first { $0.userId == myId }?.emoji ?? "" },
                set: { emoji in react(message, emoji) }
            )) {
                ForEach(chatReactionEmojis, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.palette)
            Button { replyingTo = message; editing = nil } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
        }
        if let myId, message.canModify(userId: myId, isAdmin: env.isAdmin), !env.isPreviewing {
            if !chat.archived {
                Button { startEdit(message) } label: { Label("Edit", systemImage: "pencil") }
            }
            Button(role: .destructive) { delete(message) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    // MARK: Composer

    @ViewBuilder
    private var composerArea: some View {
        Divider()
        if chat.archived {
            Text("This chat is archived.")
                .font(.mlrScaled(12))
                .foregroundStyle(Color.mlrTextMuted)
                .frame(maxWidth: .infinity)
                .padding(14)
        } else if env.isPreviewing {
            // The message would post as the REAL account while the screen is
            // pretending to be someone else.
            Text("You're previewing as someone else — posting is off.")
                .font(.mlrScaled(12))
                .foregroundStyle(Color.mlrTextMuted)
                .frame(maxWidth: .infinity)
                .padding(14)
        } else if !chat.canPost {
            // ⚠️ A Maybe can read but not post (0217). Say why, and what to do
            // about it — "you can't type here" with no reason is the version
            // that generates a support question.
            VStack(spacing: 4) {
                Text("RSVP that you're going to join in")
                    .font(.mlrScaled(13, weight: .semibold))
                Text("You can read along either way — posting is for the people who've said they're coming.")
                    .font(.mlrScaled(11))
                    .foregroundStyle(Color.mlrTextMuted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(14)
        } else {
            if let replyingTo, editing == nil {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1).fill(Color.mlrPrimary).frame(width: 2.5, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Replying to \(quote(for: replyingTo.id)?.author ?? replyingTo.authorName)")
                            .font(.mlrScaled(12, weight: .semibold))
                            .foregroundStyle(Color.mlrPrimary)
                        Text(quote(for: replyingTo.id)?.text ?? "")
                            .font(.mlrScaled(12))
                            .foregroundStyle(Color.mlrTextMuted)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button { self.replyingTo = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Color.mlrTextSubtle)
                    }
                    .buttonStyle(.pressable)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Color.mlrCard)
            }
            if let error {
                Text(error).font(.mlrScaled(11)).foregroundStyle(.red).padding(.top, 6)
            }
            ChatComposer(
                text: $draft,
                roster: roster,
                isEditing: editing != nil,
                sending: sending,
                onSend: { attachments in Task { await send(attachments) } },
                onCancelEdit: { editing = nil; draft = "" }
            )
        }
    }

    // MARK: Actions

    private func react(_ message: EventChatMessage, _ emoji: String) {
        guard canSpeak, let myId, !emoji.isEmpty else { return }
        Haptics.tap()
        Task { await service.react(eventId: chat.eventId, messageId: message.id, emoji: emoji, userId: myId) }
    }

    /// Double-tap: quick ❤️ tapback (toggles). Returns true when it added one.
    private func quickTapback(_ message: EventChatMessage) -> Bool {
        guard canSpeak, let myId else { return false }
        let adding = message.reactions.first { $0.userId == myId }?.emoji != "❤️"
        react(message, "❤️")
        return adding
    }

    private func startEdit(_ message: EventChatMessage) {
        editing = message
        replyingTo = nil
        draft = message.text ?? ""
    }

    private func delete(_ message: EventChatMessage) {
        Task {
            do { try await service.delete(eventId: chat.eventId, messageId: message.id) }
            catch { self.error = "Couldn't delete that." }
        }
    }

    private func send(_ attachments: [ChatAttachment]) async {
        guard !env.isPreviewing else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard editing != nil || !text.isEmpty || !attachments.isEmpty else { return }
        error = nil

        if let editing {
            sending = true
            defer { sending = false }
            do {
                try await service.edit(eventId: chat.eventId, messageId: editing.id, text: text)
                self.editing = nil
                draft = ""
            } catch {
                self.error = "Couldn't save that edit."
            }
            return
        }

        guard let uid = myId else { return }
        let mentioned = roster
            .filter { !$0.name.isEmpty && $0.id != myId && text.lowercased().contains("@\($0.name.lowercased())") }
            .map(\.id)
        let reply = replyingTo

        // Optimistic: an instant local bubble (text or attachments), composer clears
        // right away. If the send fails the bubble stays as "Not delivered" with
        // Retry / Delete — the draft is not restored.
        let tempId = UUID()
        let temp = EventChatMessage(
            id: tempId, eventId: chat.eventId, authorId: uid,
            authorName: env.currentProfile?.displayName ?? "You",
            authorAvatarUrl: env.currentProfile?.avatarUrl,
            text: text.isEmpty ? nil : text, status: "visible", createdAt: .now, replyToId: reply?.id)
        outbox[tempId] = ChatOutboxEntry(
            delivery: .sending,
            payload: ChatOutgoing(text: text, replyToId: reply?.id, mentionedIds: mentioned, attachments: attachments))
        if MLRMotion.reduceMotion {
            unsent.append(temp)
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.72)) { unsent.append(temp) }
        }
        draft = ""
        replyingTo = nil
        await deliver(tempId)
    }

    /// Send (or re-send) the unconfirmed bubble `tempId`.
    private func deliver(_ tempId: UUID) async {
        guard var entry = outbox[tempId] else { return }
        entry.delivery = .sending
        entry.progress = 0
        outbox[tempId] = entry
        let p = entry.payload
        do {
            try await service.send(eventId: chat.eventId, text: p.text, replyToId: p.replyToId,
                                   mentionedIds: p.mentionedIds, attachments: p.attachments,
                                   me: env.currentProfile, mediaService: env.mediaService,
                                   optimistic: false,
                                   onProgress: { outbox[tempId]?.progress = $0 },
                                   onPersisted: { finishUnsent(tempId) })
            finishUnsent(tempId)
        } catch {
            outbox[tempId]?.delivery = .failed
            Haptics.error()
        }
    }

    /// The confirmed message is now in the service's list — drop the local bubble.
    private func finishUnsent(_ id: UUID) {
        unsent.removeAll { $0.id == id }
        outbox[id] = nil
    }

    /// Delete an unsent ("Not delivered") bubble.
    private func discardUnsent(_ id: UUID) {
        chatWithAnimation { finishUnsent(id) }
    }
}

// MARK: - Admin: archived event chats (mirrors web AdminEventChats)
//
// ⚠️ Lives in Admin because an event chat has no app-admin override: an admin
// who wasn't going never sees the room in their own Feed. Reopening lets the
// people who were in it post again; it does NOT let the admin read it.

struct AdminEventChatsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var rows: [ArchivedEventChat]?
    @State private var busy: String?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What reopening does").font(.mlrScaled(13, weight: .semibold))
                    Text("An event chat becomes read-only 7 days after the event ends. Reopening lets the people who were in it post again for a day or a week, then it closes itself.")
                    Text("It does not let you read it. Event chats are only visible to the people who were going — that includes admins.")
                }
                .font(.mlrScaled(12))
                .foregroundStyle(Color.mlrTextMuted)
            }
            if let error {
                Section { Text(error).font(.mlrScaled(12)).foregroundStyle(Color.mlrDanger) }
            }
            if let rows {
                if rows.isEmpty {
                    Section {
                        Text("No archived event chats yet. A chat lands here 7 days after its event ends.")
                            .font(.mlrCaption).foregroundStyle(Color.mlrTextMuted)
                    }
                }
                ForEach(rows) { r in
                    Section { row(r) }
                }
            } else {
                Section { ProgressView() }
            }
        }
        .navigationTitle("Event chats")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func row(_ r: ArchivedEventChat) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(r.emoji ?? "📅")
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title ?? "(event deleted)").font(.mlrScaled(15, weight: .semibold))
                Text("\(r.endDate ?? r.startDate ?? "no dates") · \(r.messageCount == 1 ? "1 message" : "\(r.messageCount) messages")")
                    .font(.mlrScaled(12)).foregroundStyle(Color.mlrTextMuted)
                if let until = r.openUntil {
                    Text("Reopened until \(until.formatted(date: .abbreviated, time: .shortened))")
                        .font(.mlrScaled(12, weight: .semibold)).foregroundStyle(Color.mlrAccent)
                }
            }
        }
        HStack {
            Button("Reopen 1 day") { Task { await act(r, days: 1) } }
            Button("Reopen 7 days") { Task { await act(r, days: 7) } }
            if r.openUntil != nil {
                Button("Close it now", role: .destructive) { Task { await act(r, days: nil) } }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(busy == r.eventId)
    }

    private func load() async { rows = await env.eventChatService.fetchArchived() }

    private func act(_ r: ArchivedEventChat, days: Int?) async {
        busy = r.eventId
        error = await env.eventChatService.setReopened(eventId: r.eventId, days: days)
        await load()
        busy = nil
    }
}
