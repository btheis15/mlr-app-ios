import SwiftUI

// MARK: - CommitteeChatView
// Realtime committee chat. Own messages right (green), others left (gray).
// Soft-deleted messages render as a "message deleted" tombstone; edited
// messages show an "edited" label. Long-press an editable/deletable message
// for Edit / Delete. @mention autocomplete is scoped to the committee roster.
// Non-members are blocked by SignInWall + a membership notice.

struct CommitteeChatView: View {
    @Environment(AppEnvironment.self) private var env

    let committee: Committee
    let members: [CommitteeMember]
    /// The role channel; nil = the committee's General channel.
    var area: String? = nil
    /// Display title for this channel (e.g. "Meals", "General"); defaults to the committee name.
    var channelTitle: String? = nil
    /// Set true when opened from a place that already knows membership (the Feed
    /// conversation list / committee detail), so we don't gate on myMemberships.
    var assumeMember: Bool = false

    @State private var isMuted = false
    @State private var showMembers = false
    @State private var canOrganizeMeeting = false
    @State private var showMeetingComposer = false
    @State private var meetingRefreshID = 0
    @State private var emailData: ChatEmailData?
    @State private var channelMembers: [CommitteeRosterEntry] = []
    @State private var messages: [CommitteeChatMessage] = []
    @State private var draft = ""
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var sending = false
    @State private var editingMessage: CommitteeChatMessage?
    @State private var subscribed = false
    /// True when this committee or role is archived (migration 0112): history is
    /// readable but posting is blocked by RLS, so we render read-only.
    @State private var isArchivedChat = false

    // Typing indicators (#361) — its own broadcast channel, separate from messages.
    @State private var typing = ChatTypingChannel()
    // Smart auto-scroll + jump-to-bottom pill (Wave 4).
    @State private var atBottom = true
    @State private var showJumpPill = false
    @State private var didInitialScroll = false
    @State private var scrollBump = 0

    private static let bottomID = "__chat_bottom__"

    /// Stable per-room key for the typing broadcast channel.
    private var roomKey: String { "committee:\(committee.slug):\(area ?? "")" }

    private var rosterProfiles: [Profile] {
        members.compactMap(\.profile)
    }

    private var isMember: Bool {
        assumeMember || env.isAdmin
            || env.committeeService.myMemberships.contains { $0.committeeId == committee.id }
    }

    var body: some View {
        Group {
            if !env.isSignedIn {
                SignInWall { chatScaffold }
            } else if !isMember && !env.isAdmin {
                notMemberState
            } else {
                chatScaffold
            }
        }
        .navigationTitle(channelTitle ?? committee.name)
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
                            Task { await loadMembers() }
                            showMembers = true
                        } label: {
                            Label("See members", systemImage: "person.2.fill")
                        }
                        Button {
                            Task {
                                let recips = await env.familyRosterService.committeeRecipients(committeeId: committee.id)
                                emailData = ChatEmailData(title: "Email \(channelTitle ?? committee.name)", recipients: recips, area: area)
                            }
                        } label: {
                            Label("Email members", systemImage: "envelope")
                        }
                        Button {
                            Task { await toggleMute() }
                        } label: {
                            Label(isMuted ? "Unmute" : "Mute", systemImage: isMuted ? "bell" : "bell.slash")
                        }
                    } label: {
                        Image(systemName: isMuted ? "bell.slash.fill" : "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showMembers) { membersSheet }
        .sheet(isPresented: $showMeetingComposer) {
            MeetingComposer(scope: meetingScope, roomLabel: channelTitle ?? committee.name) {
                meetingRefreshID += 1
            }
        }
        .sheet(item: $emailData) { d in
            EmailMembersView(title: d.title, recipients: d.recipients, presetArea: d.area)
        }
        .task { await initialLoad() }
        .onDisappear {
            env.committeeService.unsubscribeFromMessages(committeeId: committee.id, area: area)
            typing.stop()
        }
    }

    private func toggleMute() async {
        isMuted.toggle()
        await env.committeeService.setAreaMute(committeeId: committee.id, area: area, muted: isMuted)
        Haptics.tap()
    }

    // MARK: - Members ("who's in this chat")

    private var membersSheet: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(channelMembers) { entry in
                        HStack(spacing: 12) {
                            AvatarView(url: entry.isLinked ? entry.profile?.avatarUrl : nil, size: .small)
                            Text(entry.displayName)
                                .font(.mlrScaled(15, weight: .medium))
                                .foregroundStyle(Color.mlrText)
                            Spacer()
                            if entry.isLead {
                                Text("Lead")
                                    .font(.mlrScaled(11, weight: .bold))
                                    .foregroundStyle(Color.mlrPrimary)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color.mlrPrimaryLight)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    if channelMembers.isEmpty {
                        Text("No one here yet.")
                            .font(.mlrCaption)
                            .foregroundStyle(Color.mlrTextMuted)
                    }
                } header: {
                    Text("\(channelMembers.count) \(channelMembers.count == 1 ? "person" : "people")")
                }
            }
            .navigationTitle(area ?? committee.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showMembers = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// The people in THIS channel: for a role channel, roster members who hold
    /// that area; for General, everyone on the committee roster.
    private func loadMembers() async {
        let roster = (try? await env.committeeService.fetchRoster(slug: committee.slug)) ?? []
        if let area {
            channelMembers = roster.filter { $0.roles.contains(area) || $0.roles.contains("\(area) · Lead") }
        } else {
            channelMembers = roster
        }
    }

    // MARK: - Scaffold

    /// The meeting room this chat maps to (committee-wide General = nil area).
    private var meetingScope: MeetingScope {
        .committee(committeeId: committee.id, slug: committee.slug, area: area)
    }

    /// Roster members for meeting name-resolution + the "everyone can make it" count.
    private var meetingMembers: [MeetingMember] {
        members.compactMap { m in
            m.profile.map { MeetingMember(id: m.userId, name: $0.displayName) }
        }
    }

    private var chatScaffold: some View {
        VStack(spacing: 0) {
            MeetingSectionBar(scope: meetingScope, members: meetingMembers, surface: .chat, refreshID: meetingRefreshID)
            messageScroll
            TypingIndicator(names: typing.typers)
            if isArchivedChat {
                archivedNote
            } else {
                ChatComposer(
                    text: $draft,
                    roster: rosterProfiles,
                    isEditing: editingMessage != nil,
                    sending: sending,
                    onSend: { attachments in Task { await send(attachments) } },
                    onCancelEdit: { cancelEdit() }
                )
            }
        }
        .background(Color(.systemGroupedBackground))
        .onChange(of: draft) { _, new in
            if editingMessage == nil && !new.trimmingCharacters(in: .whitespaces).isEmpty {
                typing.notifyTyping()
            }
        }
    }

    private var archivedNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "archivebox")
            Text("This chat is archived — read-only.")
        }
        .font(.mlrScaled(13))
        .foregroundStyle(Color.mlrTextMuted)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
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
                            MessageBubble(
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
                    // Bottom sentinel — the scroll target for jump-to-bottom.
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
                    // Jump straight to the newest on first open (no animation).
                    didInitialScroll = true
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                } else if atBottom || messages.last?.authorId == env.currentProfile?.id {
                    // Smooth-follow only when already at bottom, and always for my own sends.
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

    // MARK: - Not member

    private var notMemberState: some View {
        ContentUnavailableView {
            Label("Members only", systemImage: "lock.fill")
        } description: {
            Text("Join \(committee.name) to see and post in this chat.")
        }
    }

    /// Display name for a reactor's user id — "You" for yourself, the roster
    /// profile's name otherwise, falling back to "Member" for anyone unresolved.
    private func reactorName(_ id: UUID) -> String {
        if id == env.currentProfile?.id { return "You" }
        return members.first { $0.userId == id }?.profile?.displayName ?? "Member"
    }

    // MARK: - Permission helpers

    private func canEdit(_ message: CommitteeChatMessage) -> Bool {
        guard let userId = env.currentProfile?.id else { return false }
        return message.canEdit(userId: userId, isAdmin: env.isAdmin)
    }

    private func canDelete(_ message: CommitteeChatMessage) -> Bool {
        guard let userId = env.currentProfile?.id else { return false }
        return message.canDelete(userId: userId, isAdmin: env.isAdmin)
    }

    // MARK: - Actions

    private func initialLoad() async {
        isLoading = true
        loadError = nil
        do {
            messages = try await env.committeeService.fetchMessages(committeeId: committee.id, area: area)
        } catch {
            loadError = "Couldn't load messages."
            print("[CommitteeChat] load error: \(error)")
        }
        isLoading = false
        // Archived committee → whole chat read-only; else check if THIS role is archived.
        if committee.isArchived {
            isArchivedChat = true
        } else if let area {
            let all = await env.committeeService.fetchCommitteeAreas(slug: committee.slug, includeArchived: true)
            isArchivedChat = all.contains { $0.area == area && $0.isArchived }
        }
        isMuted = await env.committeeService.isAreaMuted(committeeId: committee.id, area: area)
        await env.committeeService.markAreaRead(committeeId: committee.id, area: area)
        canOrganizeMeeting = await env.meetingsService.canOrganize(scope: meetingScope)

        if let me = env.currentProfile {
            typing.start(roomKey: roomKey, uid: me.id, name: me.displayName)
        }

        guard !subscribed else { return }
        subscribed = true
        env.committeeService.subscribeToMessages(
            committeeId: committee.id,
            area: area,
            onInsert: { msg in
                if !messages.contains(where: { $0.id == msg.id }) {
                    messages.append(msg)
                    // Keep this channel marked read while it's open.
                    Task { await env.committeeService.markAreaRead(committeeId: committee.id, area: area) }
                }
            },
            onUpdate: { msg in
                if let idx = messages.firstIndex(where: { $0.id == msg.id }) {
                    // Preserve locally-known reactions/media if the realtime row
                    // (which re-embeds them) somehow arrives thinner.
                    messages[idx] = msg
                }
            },
            onReactionsChanged: {
                Task {
                    if let fresh = try? await env.committeeService.fetchMessages(committeeId: committee.id, area: area) {
                        messages = fresh
                    }
                }
            }
        )
    }

    /// Toggle my tapback on a message — optimistic local update, then persist.
    private func react(_ message: CommitteeChatMessage, _ emoji: String) async {
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
        await env.committeeService.toggleReaction(messageId: message.id, emoji: emoji, userId: userId)
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
                try await env.committeeService.editMessage(messageId: editing.id, text: text)
                if let idx = messages.firstIndex(where: { $0.id == editing.id }) {
                    messages[idx].text = text
                    messages[idx].editedAt = .now
                }
                cancelEdit()
            } catch {
                print("[CommitteeChat] edit error: \(error)")
            }
            return
        }

        let mentioned = rosterProfiles
            .filter { !$0.name.isEmpty && text.lowercased().contains("@\($0.name.lowercased())") }
            .map(\.id)

        // Optimistic send (#348): a text-only message gets an instant temp bubble
        // and the composer clears right away; restore the draft on failure.
        // Attachments upload first (media needs a URL to render) then insert.
        if attachments.isEmpty {
            let tempId = UUID()
            let temp = CommitteeChatMessage(
                id: tempId, committeeId: committee.id, authorId: userId,
                authorName: env.currentProfile?.displayName ?? "You",
                authorAvatarUrl: env.currentProfile?.avatarUrl,
                text: text, editedAt: nil, deletedAt: nil, createdAt: .now, area: area,
                media: [], reactions: [])
            messages.append(temp)
            let savedDraft = draft
            draft = ""
            do {
                let msg = try await env.committeeService.sendMessage(
                    committeeId: committee.id, area: area, text: text, authorId: userId, mentionedIds: mentioned)
                if let idx = messages.firstIndex(where: { $0.id == tempId }) {
                    if messages.contains(where: { $0.id == msg.id }) { messages.remove(at: idx) }
                    else { messages[idx] = msg }
                }
            } catch {
                messages.removeAll { $0.id == tempId }
                draft = savedDraft
                Haptics.error()
                print("[CommitteeChat] send error: \(error)")
            }
            return
        }

        sending = true
        defer { sending = false }
        do {
            var uploaded: [ChatMedia] = []
            for att in attachments {
                if let res = try? await env.mediaService.uploadChatMedia(
                    data: att.data, filename: att.filename, mimeType: att.mimeType, room: committee.slug) {
                    let type = att.kind == .image ? "image" : att.kind == .video ? "video" : "file"
                    uploaded.append(ChatMedia(url: res.url, type: type, name: att.kind == .file ? att.filename : nil, position: uploaded.count))
                }
            }
            let msg = try await env.committeeService.sendMessage(
                committeeId: committee.id, area: area, text: text, authorId: userId, mentionedIds: mentioned, media: uploaded)
            if !messages.contains(where: { $0.id == msg.id }) {
                messages.append(msg)
            }
            draft = ""
        } catch {
            print("[CommitteeChat] send error: \(error)")
        }
    }

    /// Report a chat message for moderator review (#344). RLS then hides a held
    /// message from everyone but its author + admins on the next refetch.
    private func report(_ message: CommitteeChatMessage) async {
        do {
            try await env.postsService.reportContent(targetType: "committee_message", targetId: message.id, reason: nil)
            Haptics.success()
        } catch {
            print("[CommitteeChat] report error: \(error)")
        }
    }

    private func startEdit(_ message: CommitteeChatMessage) {
        editingMessage = message
        draft = message.text
    }

    private func cancelEdit() {
        editingMessage = nil
        draft = ""
    }

    private func deleteMessage(_ message: CommitteeChatMessage) async {
        do {
            try await env.committeeService.deleteMessage(messageId: message.id)
            if let idx = messages.firstIndex(where: { $0.id == message.id }) {
                messages[idx].deletedAt = .now
            }
        } catch {
            print("[CommitteeChat] delete error: \(error)")
        }
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let message: CommitteeChatMessage
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
