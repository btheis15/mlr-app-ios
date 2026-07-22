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

    @State private var members: [Profile] = []
    @State private var showMembers = false
    @State private var canOrganizeMeeting = false
    @State private var showMeetingComposer = false
    @State private var meetingRefreshID = 0
    @State private var emailData: ChatEmailData?
    @State private var messages: [HouseChatMessage] = []
    @State private var draft = ""
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var sending = false
    @State private var editingMessage: HouseChatMessage?
    @State private var subscribed = false

    // Typing indicators (#361) — its own broadcast channel, separate from messages.
    @State private var typing = ChatTypingChannel()
    // Smart auto-scroll + jump-to-bottom pill (Wave 4).
    @State private var atBottom = true
    @State private var showJumpPill = false
    @State private var didInitialScroll = false
    @State private var scrollBump = 0

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
                    } label: {
                        Image(systemName: "ellipsis.circle")
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
        .sheet(item: $emailData) { d in
            EmailMembersView(title: d.title, recipients: d.recipients, presetArea: d.area)
        }
        .task { await initialLoad() }
        .onDisappear {
            env.housesService.unsubscribeFromMessages(houseId: house.id)
            typing.stop()
        }
    }

    /// The meeting room this house chat maps to.
    private var meetingScope: MeetingScope {
        .house(houseId: house.id, slug: house.slug)
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
            ChatComposer(
                text: $draft,
                roster: members,
                isEditing: editingMessage != nil,
                sending: sending,
                onSend: { attachments in Task { await send(attachments) } },
                onCancelEdit: { cancelEdit() }
            )
        }
        .background(Color(.systemGroupedBackground))
        .onChange(of: draft) { _, new in
            if editingMessage == nil && !new.trimmingCharacters(in: .whitespaces).isEmpty {
                typing.notifyTyping()
            }
        }
    }

    private var messageScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if isLoading {
                        ForEach(0..<5, id: \.self) { _ in
                            SkeletonShape(height: 36).padding(.horizontal, 16)
                        }
                    } else if let loadError {
                        Text(loadError)
                            .font(.mlrCaption)
                            .foregroundStyle(Color.mlrDanger)
                            .padding()
                    } else if messages.isEmpty {
                        Text("No messages yet — say hello 👋")
                            .font(.mlrCaption)
                            .foregroundStyle(Color.mlrTextMuted)
                            .padding(.top, 40)
                    } else {
                        ForEach(messages) { message in
                            HouseMessageBubble(
                                message: message,
                                isOwn: message.authorId == env.currentProfile?.id,
                                myUserId: env.currentProfile?.id,
                                canEdit: canEdit(message),
                                canDelete: canDelete(message),
                                onEdit: { startEdit(message) },
                                onDelete: { Task { await deleteMessage(message) } },
                                onReact: { emoji in Task { await react(message, emoji) } },
                                onReport: { Task { await report(message) } },
                                reactorName: { reactorName($0) }
                            )
                            .id(message.id)
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
            } action: { _, distanceFromBottom in
                atBottom = distanceFromBottom < 80
                if atBottom { showJumpPill = false }
            }
            .onChange(of: messages.count) { old, new in
                guard !messages.isEmpty else { return }
                if !didInitialScroll {
                    didInitialScroll = true
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                } else if atBottom || messages.last?.authorId == env.currentProfile?.id {
                    withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                } else if new > old {
                    showJumpPill = true
                }
            }
            .onChange(of: scrollBump) {
                withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                showJumpPill = false
            }
            .overlay(alignment: .bottom) {
                if showJumpPill && !atBottom {
                    Button { scrollBump += 1 } label: {
                        Label("New messages", systemImage: "arrow.down")
                            .font(.mlrScaled(12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Color.mlrPrimary).clipShape(Capsule())
                            .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
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
        await env.housesService.markRead(houseId: house.id)
        canOrganizeMeeting = await env.meetingsService.canOrganize(scope: meetingScope)

        if let me = env.currentProfile {
            typing.start(roomKey: roomKey, uid: me.id, name: me.displayName)
        }

        guard !subscribed else { return }
        subscribed = true
        env.housesService.subscribeToMessages(
            houseId: house.id,
            onInsert: { msg in
                if !messages.contains(where: { $0.id == msg.id }) {
                    messages.append(msg)
                    Task { await env.housesService.markRead(houseId: house.id) }
                }
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

    private func send(_ attachments: [ChatAttachment] = []) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let userId = env.currentProfile?.id else { return }
        guard editingMessage != nil || !text.isEmpty || !attachments.isEmpty else { return }

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

        // Optimistic send (#348) — text-only gets an instant temp bubble; restore
        // the draft on failure. Attachments upload first, then insert.
        if attachments.isEmpty {
            let tempId = UUID()
            let temp = HouseChatMessage(
                id: tempId, houseId: house.id, authorId: userId,
                authorName: env.currentProfile?.displayName ?? "You",
                authorAvatarUrl: env.currentProfile?.avatarUrl,
                text: text, editedAt: nil, deletedAt: nil, createdAt: .now,
                media: [], reactions: [])
            messages.append(temp)
            let savedDraft = draft
            draft = ""
            do {
                let msg = try await env.housesService.sendMessage(
                    houseId: house.id, text: text, authorId: userId, mentionedIds: mentioned)
                if let idx = messages.firstIndex(where: { $0.id == tempId }) {
                    if messages.contains(where: { $0.id == msg.id }) { messages.remove(at: idx) }
                    else { messages[idx] = msg }
                }
            } catch {
                messages.removeAll { $0.id == tempId }
                draft = savedDraft
                Haptics.error()
                print("[HouseChat] send error: \(error)")
            }
            return
        }

        sending = true
        defer { sending = false }
        do {
            var uploaded: [ChatMedia] = []
            for att in attachments {
                if let res = try? await env.mediaService.uploadChatMedia(
                    data: att.data, filename: att.filename, mimeType: att.mimeType, room: house.slug) {
                    let type = att.kind == .image ? "image" : att.kind == .video ? "video" : "file"
                    uploaded.append(ChatMedia(url: res.url, type: type, name: att.kind == .file ? att.filename : nil, position: uploaded.count))
                }
            }
            let msg = try await env.housesService.sendMessage(
                houseId: house.id, text: text, authorId: userId, mentionedIds: mentioned, media: uploaded)
            if !messages.contains(where: { $0.id == msg.id }) {
                messages.append(msg)
            }
            draft = ""
        } catch {
            print("[HouseChat] send error: \(error)")
        }
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
    let canEdit: Bool
    let canDelete: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    var onReact: (String) -> Void = { _ in }
    var onReport: () -> Void = {}
    /// Resolves a reactor's user id to a display name ("You" for yourself).
    var reactorName: (UUID) -> String = { _ in "Member" }

    /// Which emoji's reactor list is expanded (tap a pill to reveal who reacted).
    @State private var expandedReaction: String? = nil

    var body: some View {
        HStack {
            if isOwn { Spacer(minLength: 50) }
            VStack(alignment: isOwn ? .trailing : .leading, spacing: 3) {
                if !isOwn && !message.isDeleted {
                    Text(message.authorName)
                        .font(.mlrScaled(11, weight: .semibold))
                        .foregroundStyle(Color.mlrTextMuted)
                        .padding(.horizontal, 4)
                }
                bubble
                if !message.reactions.isEmpty {
                    reactionPills
                }
            }
            if !isOwn { Spacer(minLength: 50) }
        }
        .padding(.horizontal, 14)
    }

    /// Tapback count pills under the bubble; tap one to reveal who reacted
    /// (reacting itself lives on the bubble's long-press palette).
    private var reactionPills: some View {
        VStack(alignment: isOwn ? .trailing : .leading, spacing: 3) {
            HStack(spacing: 4) {
                ForEach(chatReactionCounts(message.reactions), id: \.emoji) { item in
                    let mine = message.reactions.contains { $0.emoji == item.emoji && $0.userId == myUserId }
                    let expanded = expandedReaction == item.emoji
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            expandedReaction = expanded ? nil : item.emoji
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Text(item.emoji).font(.mlrScaled(12))
                            if item.count > 1 {
                                Text("\(item.count)")
                                    .font(.mlrScaled(11, weight: .semibold))
                                    .foregroundStyle(mine ? Color.mlrPrimary : Color.mlrTextMuted)
                            }
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(mine ? Color.mlrPrimaryLight : Color.mlrCard)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(expanded ? Color.mlrPrimary : (mine ? Color.mlrPrimary.opacity(0.4) : Color.mlrBorder), lineWidth: expanded ? 1.5 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("See who reacted \(item.emoji)")
                }
            }
            if let expandedReaction {
                let names = message.reactions.filter { $0.emoji == expandedReaction }.map { reactorName($0.userId) }
                if !names.isEmpty {
                    Text("\(expandedReaction) \(names.joined(separator: ", "))")
                        .font(.mlrScaled(11))
                        .foregroundStyle(Color.mlrTextMuted)
                        .multilineTextAlignment(isOwn ? .trailing : .leading)
                        .frame(maxWidth: 240, alignment: isOwn ? .trailing : .leading)
                }
            }
        }
        .padding(.horizontal, 4)
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
                if !message.media.isEmpty {
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
                    .background(isOwn ? Color.mlrPrimary : Color.mlrCard)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                } else if message.isEdited {
                    Text("edited")
                        .font(.mlrScaled(10))
                        .foregroundStyle(Color.mlrTextSubtle)
                }
            }
            .contextMenu {
                // Palette style renders the emoji as a single horizontal tapback
                // bar (iMessage-like); the current reaction shows selected.
                Picker("React", selection: Binding(
                    get: { message.reactions.first { $0.userId == myUserId }?.emoji ?? "" },
                    set: { onReact($0) }
                )) {
                    ForEach(chatReactionEmojis, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.palette)
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
