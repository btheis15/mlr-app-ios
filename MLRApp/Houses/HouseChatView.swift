import SwiftUI

// MARK: - HouseChatView
//
// Private per-house chat (migration 0065) — the single-room house analogue of
// CommitteeChatView. Own messages right (green), others left (gray). Soft-deleted
// messages render as a tombstone; edited messages show an "edited" label.
// Long-press an editable/deletable message for Edit / Delete. @mention
// autocomplete is scoped to the house's members. Non-members are blocked by the
// DB (is_house_member RLS) and a members-only notice here.

struct HouseChatView: View {
    @Environment(AppEnvironment.self) private var env

    let house: House
    /// Set true when opened from a place that already knows membership (the Feed
    /// conversation list), so we don't gate on the profile's house_id.
    var assumeMember: Bool = false
    /// Opened from a notification about one message (a chat @mention) — scroll to
    /// it on first load instead of jumping to the newest.
    var focusMessageId: UUID? = nil

    @State private var members: [Profile] = []
    @State private var showMembers = false
    @State private var isMuted = false
    @State private var canOrganizeMeeting = false
    @State private var showMeetingComposer = false
    @State private var meetingRefreshID = 0
    @State private var emailData: ChatEmailData?
    @State private var messages: [HouseChatMessage] = []
    // Quick polls in this house room, merged into the timeline by createdAt (#390).
    @State private var polls: [ChatPoll] = []
    @State private var showCreatePoll = false
    @State private var draft = ""
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var sending = false
    @State private var editingMessage: HouseChatMessage?
    @State private var replyingTo: HouseChatMessage?
    @State private var subscribed = false

    // Typing indicators (#361) — its own broadcast channel, separate from messages.
    @State private var typing = ChatTypingChannel()
    // Smart auto-scroll + jump-to-bottom pill (Wave 4).
    @State private var atBottom = true
    @State private var showJumpPill = false
    @State private var didInitialScroll = false
    @State private var scrollBump = 0
    // Unconfirmed outgoing messages (sending / "Not delivered"), keyed by temp bubble id.
    @State private var outbox: [UUID: ChatOutboxEntry] = [:]
    // Messages that arrived while scrolled up (jump-pill count).
    @State private var unreadWhileUp = 0
    // First message from someone else since this device last closed the room ("New" divider).
    @State private var firstUnreadId: String?

    private static let bottomID = "__chat_bottom__"
    private var roomKey: String { "house:\(house.slug)" }

    private var isMember: Bool {
        assumeMember || env.isAdmin || env.currentProfile?.houseId == house.id
    }

    var body: some View {
        Group {
            if !env.isSignedIn {
                SignInWall { chatScaffold }
            } else if !isMember {
                notMemberState
            } else {
                chatScaffold
            }
        }
        .navigationTitle(house.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isMember {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if canOrganizeMeeting {
                            Button {
                                showMeetingComposer = true
                            } label: {
                                Label("Schedule a meeting", systemImage: "calendar.badge.plus")
                            }
                        }
                        Button {
                            showCreatePoll = true
                        } label: {
                            Label("Create a poll", systemImage: "chart.bar")
                        }
                        Button {
                            showMembers = true
                        } label: {
                            Label("See members", systemImage: "person.2.fill")
                        }
                        Button {
                            Task {
                                let recips = await env.familyRosterService.houseRecipients(houseId: house.id)
                                emailData = ChatEmailData(title: "Email \(house.name)", recipients: recips, area: nil)
                            }
                        } label: {
                            Label("Email members", systemImage: "envelope")
                        }
                        if isMuted {
                            Button {
                                Task { await setMute(false) }
                            } label: {
                                Label("Unmute", systemImage: "bell")
                            }
                        } else {
                            Menu {
                                Button("For 1 day") { Task { await setMute(true, until: .now.addingTimeInterval(86_400)) } }
                                Button("For 3 days") { Task { await setMute(true, until: .now.addingTimeInterval(3 * 86_400)) } }
                                Button("For 7 days") { Task { await setMute(true, until: .now.addingTimeInterval(7 * 86_400)) } }
                                Button("Until I unmute") { Task { await setMute(true) } }
                            } label: {
                                Label("Mute", systemImage: "bell.slash")
                            }
                        }
                    } label: {
                        Image(systemName: isMuted ? "bell.slash.fill" : "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showMembers) { membersSheet }
        .sheet(isPresented: $showMeetingComposer) {
            MeetingComposer(scope: meetingScope, roomLabel: house.name) {
                meetingRefreshID += 1
            }
        }
        .sheet(isPresented: $showCreatePoll) {
            CreateChatPollSheet(scope: pollScope) { Task { await loadPolls() } }
        }
        .sheet(item: $emailData) { d in
            EmailMembersView(title: d.title, recipients: d.recipients, presetArea: d.area)
        }
        .task { await initialLoad() }
        .onDisappear {
            if !env.isPreviewing, let me = env.currentProfile?.id {
                ChatReadMarker.markSeen(room: roomKey, user: me)
            }
            env.housesService.unsubscribeFromMessages(houseId: house.id)
            env.chatPollsService.unsubscribeFromPolls(scope: pollScope)
            typing.stop()
        }
    }

    /// Mute for a duration (web #409), permanently (until nil), or unmute.
    private func setMute(_ muted: Bool, until: Date? = nil) async {
        isMuted = muted
        await env.housesService.setHouseMute(houseId: house.id, muted: muted, mutedUntil: until)
        Haptics.tap()
    }

    /// The meeting room this house chat maps to.
    private var meetingScope: MeetingScope {
        .house(houseId: house.id, slug: house.slug)
    }

    /// Poll room scope (same room as the chat).
    private var pollScope: ChatPollScope {
        .house(houseId: house.id, slug: house.slug)
    }

    /// Messages + polls merged and ordered by creation time for inline rendering.
    private var timeline: [ChatTimelineEntry] {
        let msgs = messages.map { ChatTimelineEntry.message($0) }
        let pollEntries = polls.map { ChatTimelineEntry.poll($0) }
        return (msgs + pollEntries).sorted { $0.createdAt < $1.createdAt }
    }

    private enum ChatTimelineEntry: Identifiable {
        case message(HouseChatMessage)
        case poll(ChatPoll)
        var id: String {
            switch self {
            case .message(let m): return "m-\(m.id.uuidString)"
            case .poll(let p):    return "p-\(p.id.uuidString)"
            }
        }
        var createdAt: Date {
            switch self {
            case .message(let m): return m.createdAt
            case .poll(let p):    return p.createdAt
            }
        }
    }

    private func loadPolls() async {
        polls = await env.chatPollsService.fetchPolls(scope: pollScope)
    }
    private func setPollVotes(_ poll: ChatPoll, _ ids: [UUID], _ other: String?) async {
        try? await env.chatPollsService.setVotes(pollId: poll.id, optionIds: ids, otherText: other)
        await loadPolls()
    }
    private func closePoll(_ poll: ChatPoll) async {
        try? await env.chatPollsService.closePoll(pollId: poll.id); await loadPolls()
    }
    private func deletePoll(_ poll: ChatPoll) async {
        try? await env.chatPollsService.deletePoll(pollId: poll.id); await loadPolls()
    }

    /// House members for meeting name-resolution + the "everyone can make it" count.
    private var meetingMembers: [MeetingMember] {
        members.map { MeetingMember(id: $0.id, name: $0.displayName) }
    }


    // MARK: - Members ("who's in this chat")

    private var membersSheet: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(members) { member in
                        HStack(spacing: 12) {
                            AvatarView(profile: member, size: .small)
                            Text(member.name)
                                .font(.mlrScaled(15, weight: .medium))
                                .foregroundStyle(Color.mlrText)
                            Spacer()
                            if member.isAdmin {
                                Text("Admin")
                                    .font(.mlrScaled(11, weight: .bold))
                                    .foregroundStyle(Color.mlrPrimary)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color.mlrPrimaryLight)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    if members.isEmpty {
                        Text("No one here yet.")
                            .font(.mlrCaption)
                            .foregroundStyle(Color.mlrTextMuted)
                    }
                } header: {
                    Text("\(members.count) \(members.count == 1 ? "person" : "people")")
                }
            }
            .navigationTitle(house.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showMembers = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Scaffold

    private var chatScaffold: some View {
        VStack(spacing: 0) {
            MeetingSectionBar(scope: meetingScope, members: meetingMembers, surface: .chat, refreshID: meetingRefreshID)
            messageScroll
            TypingIndicator(names: typing.typers)
            // "Replying to …" bar above the composer.
            if let replyingTo, editingMessage == nil {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1).fill(Color.mlrPrimary).frame(width: 2.5, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Replying to \(replyContext(replyingTo.id)?.author ?? replyingTo.authorName)")
                            .font(.mlrScaled(12, weight: .semibold))
                            .foregroundStyle(Color.mlrPrimary)
                        Text(replyingTo.text.isEmpty ? "📎 Attachment" : replyingTo.text)
                            .font(.mlrScaled(12))
                            .foregroundStyle(Color.mlrTextMuted)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button { self.replyingTo = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.mlrTextSubtle)
                    }
                    .buttonStyle(.pressable)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Color.mlrCard)
                .overlay(alignment: .top) { Divider() }
            }
            ChatComposer(
                text: $draft,
                roster: members,
                isEditing: editingMessage != nil,
                sending: sending,
                onSend: { attachments in Task { await send(attachments) } },
                onCancelEdit: { cancelEdit() }
            )
        }
        .mlrBackdrop()
        .chatDraftPersistence(text: $draft, roomKey: roomKey,
                              userId: env.isPreviewing ? nil : env.currentProfile?.id,
                              paused: editingMessage != nil)
        .onChange(of: draft) { _, new in
            if editingMessage == nil && !new.trimmingCharacters(in: .whitespaces).isEmpty {
                typing.notifyTyping()
            }
        }
    }

    /// Timeline rows -> grouping input (polls never join a group).
    private static func groupItems(_ entries: [ChatTimelineEntry]) -> [ChatGroupItem] {
        entries.map { entry in
            switch entry {
            case .message(let m): return ChatGroupItem(id: entry.id, authorId: m.authorId, date: m.createdAt)
            case .poll(let p):    return ChatGroupItem(id: entry.id, authorId: nil, date: p.createdAt)
            }
        }
    }

    private var messageScroll: some View {
        let entries = timeline
        let metas = ChatGrouping.meta(for: Self.groupItems(entries), firstUnreadId: firstUnreadId)
        let canReply = true
        let canTapback = !env.isPreviewing
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if isLoading {
                        ForEach(0..<5, id: \.self) { _ in
                            SkeletonShape(height: 36).padding(.horizontal, 16).padding(.top, 10)
                        }
                    } else if let loadError {
                        Text(loadError)
                            .font(.mlrCaption)
                            .foregroundStyle(Color.mlrDanger)
                            .padding()
                    } else if entries.isEmpty {
                        Text("No messages yet — say hello 👋")
                            .font(.mlrCaption)
                            .foregroundStyle(Color.mlrTextMuted)
                            .padding(.top, 40)
                    } else {
                        ForEach(entries) { entry in
                            switch entry {
                            case .message(let message):
                                let meta = metas[entry.id] ?? ChatRowMeta()
                                let pending = outbox[message.id]
                                ChatMessageRow(
                                    meta: meta,
                                    isOwn: message.authorId == env.currentProfile?.id,
                                    authorName: message.authorName,
                                    avatarUrl: message.authorAvatarUrl,
                                    createdAt: message.createdAt,
                                    isDeleted: message.isDeleted,
                                    delivery: pending?.delivery,
                                    onReply: (canReply && !message.isDeleted) ? { replyingTo = message } : nil,
                                    onDoubleTap: (canTapback && !message.isDeleted) ? { quickTapback(message) } : nil,
                                    onRetry: { Task { await deliver(message.id) } },
                                    onDeleteUnsent: { discardUnsent(message.id) }
                                ) {
                                    HouseMessageBubble(
                                        message: message,
                                        isOwn: message.authorId == env.currentProfile?.id,
                                        myUserId: env.currentProfile?.id,
                                        tail: meta.endsGroup,
                                        pending: pending,
                                        canEdit: canEdit(message),
                                        canDelete: canDelete(message),
                                        onEdit: { startEdit(message) },
                                        onDelete: { Task { await deleteMessage(message) } },
                                        onReact: { emoji in Task { await react(message, emoji) } },
                                        onReport: { Task { await report(message) } },
                                        replyPreview: replyContext(message.replyToId),
                                        onReply: { replyingTo = message },
                                        onTapReply: {
                                            if let rid = message.replyToId {
                                                withAnimation { proxy.scrollTo("m-\(rid.uuidString)", anchor: .center) }
                                            }
                                        },
                                        reactorName: { reactorName($0) }
                                    )
                                }
                                .id(entry.id)
                                .transition(.asymmetric(
                                    insertion: .offset(y: 16).combined(with: .opacity),
                                    removal: .opacity
                                ))
                            case .poll(let poll):
                                ChatPollCard(
                                    poll: poll,
                                    onSetVotes: { ids, other in await setPollVotes(poll, ids, other) },
                                    onClose: { await closePoll(poll) },
                                    onDelete: { await deletePoll(poll) },
                                    fetchVoters: { await env.chatPollsService.fetchVoters(pollId: poll.id) }
                                )
                                .padding(.horizontal, 12)
                                .padding(.top, 10)
                                .id(entry.id)
                                .transition(.asymmetric(
                                    insertion: .offset(y: 16).combined(with: .opacity),
                                    removal: .opacity
                                ))
                            }
                        }
                    }
                    // Bottom sentinel — the scroll target for jump-to-bottom.
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.vertical, 12)
            }
            .chatScrollBehavior(atBottom: $atBottom)
            .onChange(of: atBottom) { _, now in
                if now { showJumpPill = false; unreadWhileUp = 0 }
            }
            .onChange(of: messages.count) { old, new in
                guard !messages.isEmpty else { return }
                if !didInitialScroll {
                    // Newest on first open (the bottom anchor already put us there) —
                    // or the message a notification pointed at, when it loaded.
                    didInitialScroll = true
                    if let focusMessageId, messages.contains(where: { $0.id == focusMessageId }) {
                        proxy.scrollTo("m-\(focusMessageId.uuidString)", anchor: .center)
                    } else {
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                } else if atBottom || messages.last?.authorId == env.currentProfile?.id {
                    // Smooth-follow only when already at bottom, and always for my own sends.
                    withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                } else if new > old {
                    showJumpPill = true
                    unreadWhileUp += new - old
                }
            }
            .onChange(of: polls.count) { old, new in
                if new > old && (atBottom || didInitialScroll == false) {
                    withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
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

    private var notMemberState: some View {
        ContentUnavailableView {
            Label("Members only", systemImage: "lock.fill")
        } description: {
            Text("This chat is just for \(house.name) members.")
        }
    }

    /// Display name for a reactor's user id — "You" for yourself, the house
    /// member's name otherwise, falling back to "Member" for anyone unresolved.
    private func reactorName(_ id: UUID) -> String {
        if id == env.currentProfile?.id { return "You" }
        return members.first { $0.id == id }?.displayName ?? "Member"
    }

    // MARK: - Permission helpers

    private func canEdit(_ message: HouseChatMessage) -> Bool {
        guard let userId = env.currentProfile?.id else { return false }
        return message.canEdit(userId: userId, isAdmin: env.isAdmin)
    }

    private func canDelete(_ message: HouseChatMessage) -> Bool {
        guard let userId = env.currentProfile?.id else { return false }
        return message.canDelete(userId: userId, isAdmin: env.isAdmin)
    }

    // MARK: - Actions

    private func initialLoad() async {
        isLoading = true
        loadError = nil
        members = await env.housesService.fetchMembers(houseId: house.id)
        do {
            messages = try await env.housesService.fetchMessages(houseId: house.id)
        } catch {
            loadError = "Couldn't load messages."
            print("[HouseChat] load error: \(error)")
        }
        isLoading = false
        if let me = env.currentProfile?.id, !env.isPreviewing {
            firstUnreadId = ChatReadMarker.firstUnreadId(
                in: Self.groupItems(timeline),
                lastSeen: ChatReadMarker.lastSeen(room: roomKey, user: me), me: me)
        }
        await env.housesService.markRead(houseId: house.id)
        canOrganizeMeeting = await env.meetingsService.canOrganize(scope: meetingScope)
        isMuted = await env.housesService.isHouseMuted(houseId: house.id)
        await loadPolls()
        env.chatPollsService.subscribeToPolls(scope: pollScope) { Task { await loadPolls() } }

        if let me = env.currentProfile {
            typing.start(roomKey: roomKey, uid: me.id, name: me.displayName)
        }

        guard !subscribed else { return }
        subscribed = true
        env.housesService.subscribeToMessages(
            houseId: house.id,
            onInsert: { msg in
                guard !messages.contains(where: { $0.id == msg.id }) else { return }
                if MLRMotion.reduceMotion {
                    messages.append(msg)
                } else {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.72)) {
                        messages.append(msg)
                    }
                }
                Task { await env.housesService.markRead(houseId: house.id) }
            },
            onUpdate: { msg in
                if let idx = messages.firstIndex(where: { $0.id == msg.id }) {
                    messages[idx] = msg
                }
            },
            onReactionsChanged: {
                Task {
                    if let fresh = try? await env.housesService.fetchMessages(houseId: house.id) {
                        messages = fresh
                    }
                }
            }
        )
    }

    /// Toggle my tapback on a message — optimistic local update, then persist.
    private func react(_ message: HouseChatMessage, _ emoji: String) async {
        guard let userId = env.currentProfile?.id else { return }
        if let idx = messages.firstIndex(where: { $0.id == message.id }) {
            var rs = messages[idx].reactions
            if let mine = rs.firstIndex(where: { $0.userId == userId }) {
                if rs[mine].emoji == emoji { rs.remove(at: mine) }
                else { rs[mine] = ChatReaction(userId: userId, emoji: emoji) }
            } else {
                rs.append(ChatReaction(userId: userId, emoji: emoji))
            }
            messages[idx].reactions = rs
        }
        Haptics.tap()
        await env.housesService.toggleReaction(messageId: message.id, emoji: emoji, userId: userId)
    }

    /// Quoted context for a reply bubble — author + a short text preview.
    private func replyContext(_ id: UUID?) -> (author: String, text: String)? {
        guard let id, let m = messages.first(where: { $0.id == id }) else { return nil }
        let text = m.isDeleted ? "Message deleted" : (m.text.isEmpty ? "📎 Attachment" : m.text)
        return (m.authorId == env.currentProfile?.id ? "You" : m.authorName, text)
    }

    private func send(_ attachments: [ChatAttachment] = []) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let userId = env.currentProfile?.id else { return }
        // Need either text or an attachment (editing only touches text).
        guard editingMessage != nil || !text.isEmpty || !attachments.isEmpty else { return }

        // Edit path — a direct update, unchanged.
        if let editing = editingMessage {
            sending = true
            defer { sending = false }
            do {
                try await env.housesService.editMessage(messageId: editing.id, text: text)
                if let idx = messages.firstIndex(where: { $0.id == editing.id }) {
                    messages[idx].text = text
                    messages[idx].editedAt = .now
                }
                cancelEdit()
            } catch {
                print("[HouseChat] edit error: \(error)")
            }
            return
        }

        let mentioned = members
            .filter { !$0.name.isEmpty && text.lowercased().contains("@\($0.name.lowercased())") }
            .map(\.id)

        // Optimistic send (#348): every message (text or attachments) gets an
        // instant local bubble and the composer clears right away. While
        // unconfirmed it shows a subtle sending state; on failure it STAYS,
        // marked "Not delivered", with Retry / Delete — the draft is not restored.
        let replyTo = replyingTo
        let tempId = UUID()
        var temp = HouseChatMessage(
            id: tempId, houseId: house.id, authorId: userId,
            authorName: env.currentProfile?.displayName ?? "You",
            authorAvatarUrl: env.currentProfile?.avatarUrl,
            text: text, editedAt: nil, deletedAt: nil, createdAt: .now,
            media: [], reactions: [])
        temp.replyToId = replyTo?.id
        outbox[tempId] = ChatOutboxEntry(
            delivery: .sending,
            payload: ChatOutgoing(text: text, replyToId: replyTo?.id, mentionedIds: mentioned, attachments: attachments))
        if MLRMotion.reduceMotion {
            messages.append(temp)
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.72)) {
                messages.append(temp)
            }
        }
        draft = ""
        replyingTo = nil
        await deliver(tempId)
    }

    /// Upload (if any attachments) then send the unconfirmed bubble `tempId`.
    /// Used by the first attempt and by Retry.
    private func deliver(_ tempId: UUID) async {
        guard let userId = env.currentProfile?.id, var entry = outbox[tempId] else { return }
        entry.delivery = .sending
        entry.progress = 0
        outbox[tempId] = entry
        let p = entry.payload
        do {
            var uploaded: [ChatMedia] = []
            for (i, att) in p.attachments.enumerated() {
                let res = try await env.mediaService.uploadChatMedia(
                    data: att.data, filename: att.filename, mimeType: att.mimeType, room: house.slug)
                let type = att.kind == .image ? "image" : att.kind == .video ? "video" : "file"
                uploaded.append(ChatMedia(url: res.url, type: type, name: att.kind == .file ? att.filename : nil, position: uploaded.count))
                outbox[tempId]?.progress = Double(i + 1) / Double(p.attachments.count)
            }
            let msg = try await env.housesService.sendMessage(
                houseId: house.id, text: p.text, authorId: userId, mentionedIds: p.mentionedIds, media: uploaded, replyToId: p.replyToId)
            if let idx = messages.firstIndex(where: { $0.id == tempId }) {
                if messages.contains(where: { $0.id == msg.id }) { messages.remove(at: idx) }
                else { messages[idx] = msg }
            } else if !messages.contains(where: { $0.id == msg.id }) {
                messages.append(msg)
            }
            outbox[tempId] = nil
        } catch {
            outbox[tempId]?.delivery = .failed
            Haptics.error()
            print("[HouseChat] send error: \(error)")
        }
    }

    /// Delete an unsent ("Not delivered") bubble.
    private func discardUnsent(_ id: UUID) {
        chatWithAnimation {
            messages.removeAll { $0.id == id }
            outbox[id] = nil
        }
    }

    /// Double-tap: quick ❤️ tapback (toggles). Returns true when it added one.
    private func quickTapback(_ message: HouseChatMessage) -> Bool {
        guard let me = env.currentProfile?.id else { return false }
        let adding = message.reactions.first { $0.userId == me }?.emoji != "❤️"
        Task { await react(message, "❤️") }
        return adding
    }

    /// Report a chat message for moderator review (#344).
    private func report(_ message: HouseChatMessage) async {
        do {
            try await env.postsService.reportContent(targetType: "house_message", targetId: message.id, reason: nil)
            Haptics.success()
        } catch {
            print("[HouseChat] report error: \(error)")
        }
    }

    private func startEdit(_ message: HouseChatMessage) {
        editingMessage = message
        draft = message.text
    }

    private func cancelEdit() {
        editingMessage = nil
        draft = ""
    }

    private func deleteMessage(_ message: HouseChatMessage) async {
        do {
            try await env.housesService.deleteMessage(messageId: message.id)
            if let idx = messages.firstIndex(where: { $0.id == message.id }) {
                messages[idx].deletedAt = .now
            }
        } catch {
            print("[HouseChat] delete error: \(error)")
        }
    }
}

// MARK: - House Message Bubble

private struct HouseMessageBubble: View {
    let message: HouseChatMessage
    let isOwn: Bool
    var myUserId: UUID? = nil
    /// Last bubble of a group gets the small "tail" corner.
    var tail: Bool = true
    /// Set while this is an unconfirmed (sending / failed) local bubble.
    var pending: ChatOutboxEntry? = nil
    let canEdit: Bool
    let canDelete: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    var onReact: (String) -> Void = { _ in }
    var onReport: () -> Void = {}
    /// Quoted reply context (author + text of the message this replies to).
    var replyPreview: (author: String, text: String)? = nil
    var onReply: () -> Void = {}
    var onTapReply: () -> Void = {}
    /// Resolves a reactor's user id to a display name ("You" for yourself).
    var reactorName: (UUID) -> String = { _ in "Member" }

    // Avatar, name, time, spacing and the sending state live in ChatMessageRow.
    var body: some View {
        VStack(alignment: isOwn ? .trailing : .leading, spacing: 3) {
            bubble
            ChatReactionPills(reactions: message.reactions, myUserId: myUserId, isOwn: isOwn, reactorName: reactorName)
        }
    }

    @ViewBuilder
    private var bubble: some View {
        if message.isDeleted {
            Label("Message deleted", systemImage: "trash")
                .font(.mlrScaled(13, weight: .regular))
                .italic()
                .foregroundStyle(Color.mlrTextMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.mlrCard.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 14))
        } else {
            VStack(alignment: isOwn ? .trailing : .leading, spacing: 4) {
                // Quoted reply — tap to jump to the original message.
                if let replyPreview {
                    Button(action: onTapReply) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(replyPreview.author)
                                .font(.mlrScaled(11, weight: .semibold))
                                .foregroundStyle(Color.mlrPrimary)
                            Text(replyPreview.text)
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
                    ChatPendingAttachments(entry: pending, isOwn: isOwn)
                } else if !message.media.isEmpty {
                    ChatMediaView(media: message.media, isOwn: isOwn)
                }
                if !message.text.isEmpty {
                    VStack(alignment: .trailing, spacing: 2) {
                        MentionText(
                            message.text,
                            baseColor: isOwn ? .white : Color.mlrText,
                            mentionColor: isOwn ? Color.mlrPrimaryLight : Color.mlrPrimary
                        )
                        if message.isEdited {
                            Text("edited")
                                .font(.mlrScaled(10))
                                .foregroundStyle(isOwn ? Color.white.opacity(0.7) : Color.mlrTextSubtle)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .chatBubbleBackground(isOwn: isOwn, tail: tail)
                } else if message.isEdited {
                    Text("edited")
                        .font(.mlrScaled(10))
                        .foregroundStyle(Color.mlrTextSubtle)
                }
                // Only the author + admins ever see a held row (RLS); flag it so
                // they know it's pending review / hidden from the room (#344).
                if message.isHeld {
                    Label("Held for review", systemImage: "eye.slash")
                        .font(.mlrScaled(10, weight: .medium))
                        .foregroundStyle(Color.mlrWarning)
                }
            }
            .contextMenu {
                // Unsent bubbles have no server id yet — nothing to react to, edit or report.
                if pending == nil {
                    // Palette style renders the emoji as a single horizontal tapback
                    // bar (iMessage-like); the current reaction shows selected.
                    Picker("React", selection: Binding(
                        get: { message.reactions.first { $0.userId == myUserId }?.emoji ?? "" },
                        set: { onReact($0) }
                    )) {
                        ForEach(chatReactionEmojis, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.palette)
                    if !message.isDeleted {
                        Button { onReply() } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                    }
                    if canEdit {
                        Button { onEdit() } label: { Label("Edit", systemImage: "pencil") }
                    }
                    if canDelete {
                        Button(role: .destructive) { onDelete() } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    if !isOwn && !message.isDeleted {
                        Button { onReport() } label: { Label("Report", systemImage: "flag") }
                    }
                }
            }
        }
    }
}
