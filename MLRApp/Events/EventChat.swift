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
    var mediaUrls: [String]

    /// Held by the content checker. Its author sees it with a note; nobody else
    /// sees it at all.
    var isHeld: Bool { status == "pending" }
    var isHidden: Bool { status == "hidden" }
}

@Observable
@MainActor
final class EventChatService {

    var chats: [EventChatSummary] = []
    var messages: [String: [EventChatMessage]] = [:]
    var loading = false

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
        chats = (try? await supabase.rpc("my_event_chats").execute().value) ?? []
    }

    func loadMessages(eventId: String) async {
        struct Row: Decodable {
            let id: UUID
            let eventId: String
            let authorId: UUID
            let text: String?
            let status: String?
            let createdAt: Date
            let editedAt: Date?
            let author: Author?
            let media: [Media]?
            struct Author: Decodable {
                let displayName: String?
                let avatarUrl: String?
                enum CodingKeys: String, CodingKey {
                    case displayName = "display_name"
                    case avatarUrl = "avatar_url"
                }
            }
            struct Media: Decodable {
                let storagePath: String?
                let thumbnailUrl: String?
                enum CodingKeys: String, CodingKey {
                    case storagePath = "storage_path"
                    case thumbnailUrl = "thumbnail_url"
                }
            }
            enum CodingKeys: String, CodingKey {
                case id, text, status, author
                case eventId = "event_id"
                case authorId = "author_id"
                case createdAt = "created_at"
                case editedAt = "edited_at"
                case media = "event_chat_message_media"
            }
        }

        let rows: [Row] = (try? await supabase
            .from("event_chat_messages")
            .select("""
                id, event_id, author_id, text, status, created_at, edited_at,
                author:author_id(display_name, avatar_url),
                event_chat_message_media(storage_path, thumbnail_url)
            """)
            .eq("event_id", value: eventId)
            .is("deleted_at", value: nil)
            .order("created_at", ascending: true)
            .execute().value) ?? []

        messages[eventId] = rows.map { r in
            EventChatMessage(
                id: r.id, eventId: r.eventId, authorId: r.authorId,
                authorName: r.author?.displayName ?? "Someone",
                authorAvatarUrl: r.author?.avatarUrl,
                text: r.text,
                status: r.status ?? "visible",
                createdAt: r.createdAt,
                editedAt: r.editedAt,
                // Grids render the thumbnail; the original loads on tap-through.
                mediaUrls: (r.media ?? []).compactMap { $0.thumbnailUrl ?? $0.storagePath }
            )
        }
    }

    /// ⚠️ A plain INSERT, gated by RLS — `can_post_in_event_chat` checks
    /// membership, a going RSVP, and that the room isn't archived. There is no
    /// send RPC to route around it.
    func send(eventId: String, text: String) async throws {
        guard let uid = supabase.auth.currentUser?.id else { return }
        struct Row: Encodable {
            let event_id: String
            let author_id: String
            let text: String
        }
        try await supabase.from("event_chat_messages")
            .insert(Row(event_id: eventId, author_id: uid.uuidString, text: text))
            .execute()
        await loadMessages(eventId: eventId)
        await markRead(eventId: eventId)
    }

    func markRead(eventId: String) async {
        struct P: Encodable { let p_event_id: String }
        _ = try? await supabase.rpc("mark_event_chat_read", params: P(p_event_id: eventId)).execute()
    }

    /// Durations write only `muted_until` server-side, so a timer expires by
    /// going stale.
    func setMute(eventId: String, muted: Bool, until: Date? = nil) async {
        struct P: Encodable { let p_event_id: String; let p_muted: Bool; let p_muted_until: String? }
        let iso = until.map { ISO8601DateFormatter().string(from: $0) }
        _ = try? await supabase.rpc("set_event_chat_mute",
                                    params: P(p_event_id: eventId, p_muted: muted, p_muted_until: iso))
            .execute()
        await loadChats()
    }
}

// MARK: - The room

struct EventChatView: View {
    @Environment(AppEnvironment.self) private var env
    let chat: EventChatSummary

    @State private var draft = ""
    @State private var sending = false
    @State private var error: String?

    private var service: EventChatService { env.eventChatService }
    private var messages: [EventChatMessage] { service.messages[chat.eventId] ?? [] }
    private var myId: UUID? { env.currentProfile?.id }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        header
                        ForEach(messages) { message in
                            bubble(message)
                                .id(message.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            composer
        }
        .background(Color.mlrSurface)
        .navigationTitle(chat.title ?? "Event chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if chat.isMuted {
                        Button("Unmute") {
                            Task { await service.setMute(eventId: chat.eventId, muted: false) }
                        }
                    } else {
                        Button("Mute for a day") {
                            Task {
                                await service.setMute(
                                    eventId: chat.eventId, muted: true,
                                    until: Calendar.current.date(byAdding: .hour, value: 24, to: .now))
                            }
                        }
                        Button("Mute until I turn it back on") {
                            Task { await service.setMute(eventId: chat.eventId, muted: true) }
                        }
                    }
                } label: {
                    Image(systemName: chat.isMuted ? "bell.slash.fill" : "bell")
                }
            }
        }
        .task {
            await service.loadMessages(eventId: chat.eventId)
            await service.markRead(eventId: chat.eventId)
        }
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func bubble(_ message: EventChatMessage) -> some View {
        let mine = message.authorId == myId
        VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            if !mine {
                Text(message.authorName)
                    .font(.mlrScaled(11, weight: .semibold))
                    .foregroundStyle(Color.mlrTextMuted)
            }
            if let text = message.text, !text.isEmpty {
                Text(text)
                    .font(.mlrScaled(15))
                    .foregroundStyle(mine ? .white : Color.mlrText)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(mine ? Color.mlrPrimary : Color.mlrCard)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            ForEach(message.mediaUrls, id: \.self) { url in
                // Every media URL goes through the token store — reading its
                // token in the body is also what re-renders these the moment it
                // arrives.
                if let signed = env.mediaTokenService.url(url)?.absoluteString {
                    MediaThumb(url: signed)
                        .frame(width: 160, height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
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
            Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.mlrScaled(10))
                .foregroundStyle(Color.mlrTextSubtle)
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    @ViewBuilder
    private var composer: some View {
        Divider()
        if chat.archived {
            Text("This chat is archived.")
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
            HStack(spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await send() }
                } label: {
                    if sending {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up.circle.fill").font(.mlrScaled(26))
                    }
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || sending)
            }
            .padding(12)
            if let error {
                Text(error).font(.mlrScaled(11)).foregroundStyle(.red).padding(.bottom, 8)
            }
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        sending = true
        error = nil
        defer { sending = false }
        do {
            try await service.send(eventId: chat.eventId, text: text)
            draft = ""
        } catch {
            self.error = "Couldn't send that."
        }
    }
}
