import SwiftUI
import FoundationModels

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
    @State private var messages: [HouseChatMessage] = []
    @State private var draft = ""
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var sending = false
    @State private var editingMessage: HouseChatMessage?
    @State private var subscribed = false
    @State private var summary: String?
    @State private var summarizing = false
    @State private var showSummary = false

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
                        Button {
                            showMembers = true
                        } label: {
                            Label("See members", systemImage: "person.2.fill")
                        }
                        if ChatSummarizer.isAvailable && messages.count >= 3 {
                            Button { Task { await catchUp() } } label: {
                                Label("Catch me up", systemImage: "sparkles")
                            }
                            .disabled(summarizing)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showSummary) { summarySheet }
        .sheet(isPresented: $showMembers) { membersSheet }
        .task { await initialLoad() }
        .onDisappear {
            env.housesService.unsubscribeFromMessages(houseId: house.id)
        }
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
        summary = await Self.summarize(house: house.name, messages: messages)
        showSummary = summary != nil
    }

    /// On-device "catch me up" for the house room (mirrors ChatSummarizer).
    private static func summarize(house: String, messages: [HouseChatMessage]) async -> String? {
        guard ChatSummarizer.isAvailable else { return nil }
        let recent = messages.suffix(40).filter { !$0.isDeleted && !$0.text.isEmpty }
        guard !recent.isEmpty else { return nil }
        let transcript = recent.map { "\($0.authorName): \($0.text)" }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: """
            You summarize a family house group chat so someone can catch up fast.
            Given the recent messages, write 2–4 short bullet points covering: decisions made,
            open questions that still need answers, and anything actionable (who's doing what).
            Warm and concise. No preamble, no restating that it's a summary.
            """)
        do {
            let response = try await session.respond(
                to: "House: \(house)\nRecent messages:\n\(transcript)\n\nCatch me up.")
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            print("[HouseChat] summarize error: \(error)")
            return nil
        }
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
            messageScroll
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

    private var notMemberState: some View {
        ContentUnavailableView {
            Label("Members only", systemImage: "lock.fill")
        } description: {
            Text("This chat is just for \(house.name) members.")
        }
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
            }
        )
    }

    private func send(_ attachments: [ChatAttachment] = []) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let userId = env.currentProfile?.id else { return }
        guard editingMessage != nil || !text.isEmpty || !attachments.isEmpty else { return }
        sending = true
        defer { sending = false }

        do {
            if let editing = editingMessage {
                try await env.housesService.editMessage(messageId: editing.id, text: text)
                if let idx = messages.firstIndex(where: { $0.id == editing.id }) {
                    messages[idx].text = text
                    messages[idx].editedAt = .now
                }
                cancelEdit()
            } else {
                var uploaded: [ChatMedia] = []
                for att in attachments {
                    if let res = try? await env.mediaService.uploadChatMedia(
                        data: att.data, filename: att.filename, mimeType: att.mimeType, room: house.slug) {
                        // Trust the local kind (we know it) rather than the server echo,
                        // so photos/videos render right even before the mini redeploys.
                        let type = att.kind == .image ? "image" : att.kind == .video ? "video" : "file"
                        uploaded.append(ChatMedia(url: res.url, type: type, name: att.kind == .file ? att.filename : nil, position: uploaded.count))
                    }
                }
                let mentioned = members
                    .filter { !$0.name.isEmpty && text.lowercased().contains("@\($0.name.lowercased())") }
                    .map(\.id)
                let msg = try await env.housesService.sendMessage(
                    houseId: house.id, text: text, authorId: userId, mentionedIds: mentioned, media: uploaded)
                if !messages.contains(where: { $0.id == msg.id }) {
                    messages.append(msg)
                }
                draft = ""
            }
        } catch {
            print("[HouseChat] send error: \(error)")
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
