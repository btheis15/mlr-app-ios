import SwiftUI
import FoundationModels

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
    @State private var channelMembers: [CommitteeRosterEntry] = []
    @State private var messages: [CommitteeChatMessage] = []
    @State private var draft = ""
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var sending = false
    @State private var editingMessage: CommitteeChatMessage?
    @State private var subscribed = false
    @State private var summary: String?
    @State private var summarizing = false
    @State private var showSummary = false

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
                        Button {
                            Task { await loadMembers() }
                            showMembers = true
                        } label: {
                            Label("See members", systemImage: "person.2.fill")
                        }
                        Button {
                            Task { await toggleMute() }
                        } label: {
                            Label(isMuted ? "Unmute" : "Mute", systemImage: isMuted ? "bell" : "bell.slash")
                        }
                        if ChatSummarizer.isAvailable && messages.count >= 3 {
                            Button { Task { await catchUp() } } label: {
                                Label("Catch me up", systemImage: "sparkles")
                            }
                            .disabled(summarizing)
                        }
                    } label: {
                        Image(systemName: isMuted ? "bell.slash.fill" : "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showSummary) { summarySheet }
        .sheet(isPresented: $showMembers) { membersSheet }
        .task { await initialLoad() }
        .onDisappear {
            env.committeeService.unsubscribeFromMessages(committeeId: committee.id, area: area)
        }
    }

    private func toggleMute() async {
        isMuted.toggle()
        await env.committeeService.setAreaMute(committeeId: committee.id, area: area, muted: isMuted)
        Haptics.tap()
    }

    // MARK: - Catch me up (on-device summary)

    private var summarySheet: some View {
        NavigationStack {
            ScrollView {
                Text(summary ?? "Nothing to summarize yet.")
                    .font(.mlrBody)
                    .foregroundStyle(Color.mlrText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .navigationTitle("Catch me up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showSummary = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func catchUp() async {
        summarizing = true
        defer { summarizing = false }
        summary = await ChatSummarizer.summarize(committee: committee.name, messages: messages)
        showSummary = summary != nil
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

    private var chatScaffold: some View {
        VStack(spacing: 0) {
            messageScroll
            ChatComposer(
                text: $draft,
                roster: rosterProfiles,
                isEditing: editingMessage != nil,
                sending: sending,
                onSend: { attachments in Task { await send(attachments) } },
                onCancelEdit: { cancelEdit() }
            )
        }
        .background(Color(.systemGroupedBackground))
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
                                canEdit: canEdit(message),
                                canDelete: canDelete(message),
                                onEdit: { startEdit(message) },
                                onDelete: { Task { await deleteMessage(message) } }
                            )
                            .id(message.id)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) {
                if let last = messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
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
        isMuted = await env.committeeService.isAreaMuted(committeeId: committee.id, area: area)
        await env.committeeService.markAreaRead(committeeId: committee.id, area: area)

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
                    messages[idx] = msg
                }
            }
        )
    }

    private func send(_ attachments: [ChatAttachment] = []) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let userId = env.currentProfile?.id else { return }
        // Need either text or an attachment (editing only touches text).
        guard editingMessage != nil || !text.isEmpty || !attachments.isEmpty else { return }
        sending = true
        defer { sending = false }

        do {
            if let editing = editingMessage {
                try await env.committeeService.editMessage(messageId: editing.id, text: text)
                if let idx = messages.firstIndex(where: { $0.id == editing.id }) {
                    messages[idx].text = text
                    messages[idx].editedAt = .now
                }
                cancelEdit()
            } else {
                // Upload attachments to the mini first so a failure never leaves an
                // empty message.
                var uploaded: [ChatMedia] = []
                for att in attachments {
                    if let res = try? await env.mediaService.uploadChatMedia(
                        data: att.data, filename: att.filename, mimeType: att.mimeType, room: committee.slug) {
                        // Trust the local kind (we know it) rather than the server echo,
                        // so photos/videos render right even before the mini redeploys.
                        let type = att.kind == .image ? "image" : att.kind == .video ? "video" : "file"
                        uploaded.append(ChatMedia(url: res.url, type: type, name: att.kind == .file ? att.filename : nil, position: uploaded.count))
                    }
                }
                let mentioned = rosterProfiles
                    .filter { !$0.name.isEmpty && text.lowercased().contains("@\($0.name.lowercased())") }
                    .map(\.id)
                let msg = try await env.committeeService.sendMessage(
                    committeeId: committee.id, area: area, text: text, authorId: userId, mentionedIds: mentioned, media: uploaded)
                if !messages.contains(where: { $0.id == msg.id }) {
                    messages.append(msg)
                }
                draft = ""
            }
        } catch {
            print("[CommitteeChat] send error: \(error)")
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

// MARK: - ChatSummarizer (on-device Apple Intelligence)
// "Catch me up" — summarizes recent committee chat with the on-device model.
// Availability-gated; the button only appears when the model is ready.

enum ChatSummarizer {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static func summarize(committee: String, messages: [CommitteeChatMessage]) async -> String? {
        guard isAvailable else { return nil }
        let recent = messages.suffix(40).filter { !$0.isDeleted && !$0.text.isEmpty }
        guard !recent.isEmpty else { return nil }
        let transcript = recent.map { "\($0.authorName): \($0.text)" }.joined(separator: "\n")

        let session = LanguageModelSession(instructions: """
            You summarize a family committee group chat so someone can catch up fast.
            Given the recent messages, write 2–4 short bullet points covering: decisions made,
            open questions that still need answers, and anything actionable (who's doing what).
            Warm and concise. No preamble, no restating that it's a summary.
            """)
        do {
            let response = try await session.respond(
                to: "Committee: \(committee)\nRecent messages:\n\(transcript)\n\nCatch me up.")
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            print("[ChatSummarizer] error: \(error)")
            return nil
        }
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let message: CommitteeChatMessage
    let isOwn: Bool
    let canEdit: Bool
    let canDelete: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

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
            }
            if !isOwn { Spacer(minLength: 50) }
        }
        .padding(.horizontal, 14)
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
                if canEdit {
                    Button { onEdit() } label: { Label("Edit", systemImage: "pencil") }
                }
                if canDelete {
                    Button(role: .destructive) { onDelete() } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }
}
