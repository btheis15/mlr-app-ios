import SwiftUI
import Kingfisher

// MARK: - WorkItemDetailSheet
//
// Tap a checklist item to open this sheet: title + urgency/people badges, photo/
// video grid (tap → lightbox), notes, and a comment thread with @mentions.
// Any member who can see the item can comment; the author or an admin can delete
// a comment. Admins get an Edit button (hands off to WorkItemComposer). Mirrors
// the web WorkItemSheet (comments migration 0068, media 0067).

struct WorkItemDetailSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var onChanged: () -> Void

    @State private var current: WorkItem
    @State private var comments: [WorkItemComment] = []
    @State private var roster: [Profile] = []
    @State private var draft = ""
    @State private var sending = false
    @State private var loading = true
    @State private var marking = false
    @State private var editing = false
    @State private var lightbox: LightboxData?

    init(item: WorkItem, onChanged: @escaping () -> Void = {}) {
        self.onChanged = onChanged
        _current = State(initialValue: item)
    }

    private var houseName: String? {
        guard let hid = current.houseId else { return nil }
        return env.housesService.houses.first { $0.id == hid }?.name
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        headerSection
                        if !current.media.isEmpty { mediaSection }
                        if let notes = current.notes, !notes.isEmpty { notesSection(notes) }
                        Divider()
                        commentsSection
                    }
                    .padding(20)
                }

                if env.isSignedIn {
                    ChatComposer(
                        text: $draft,
                        roster: roster,
                        sending: sending,
                        onSend: { Task { await post() } }
                    )
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Work item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if env.isAdmin {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit") { editing = true }
                    }
                }
            }
            .task { await load() }
            .sheet(isPresented: $editing) {
                WorkItemComposer(item: current) {
                    Task { await refreshItem(); onChanged() }
                }
            }
            .fullScreenCover(item: $lightbox) { data in
                LightboxView(urls: data.urls, startIndex: data.start)
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(current.title)
                .font(.mlrScaled(20, weight: .bold))
                .strikethrough(current.isDone)
                .foregroundStyle(current.isDone ? Color.mlrTextMuted : Color.mlrText)

            HStack(spacing: 6) {
                if let urgency = current.urgency {
                    badge("\(urgency.emoji) \(urgency.label)", color: urgency.uiColor)
                }
                if let needed = current.peopleNeeded {
                    badge("👥 \(needed) needed", color: Color.mlrTextMuted)
                }
                if let houseName {
                    badge("🏠 \(houseName)", color: Color.mlrPrimary)
                }
            }

            if !current.isDone && env.isSignedIn {
                Button {
                    Task { await markDone() }
                } label: {
                    Label(marking ? "Marking…" : "Mark done", systemImage: "checkmark.circle")
                        .font(.mlrScaled(14, weight: .semibold))
                        .foregroundStyle(Color.mlrPrimary)
                }
                .buttonStyle(.plain)
                .disabled(marking)
                .padding(.top, 2)
            } else if current.isDone {
                Label("Done", systemImage: "checkmark.circle.fill")
                    .font(.mlrScaled(14, weight: .semibold))
                    .foregroundStyle(Color.mlrSuccess)
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.mlrScaled(11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    // MARK: - Media

    private var mediaSection: some View {
        let urls = current.media.map(\.url)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(current.media.enumerated()), id: \.element.id) { idx, media in
                    Button {
                        lightbox = LightboxData(urls: urls, start: idx)
                    } label: {
                        ZStack {
                            if media.isVideo {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.mlrCard)
                                    .overlay(Image(systemName: "play.circle.fill").font(.mlrScaled(28)).foregroundStyle(.white))
                            } else {
                                MediaThumb(url: media.url)
                            }
                        }
                        .frame(width: 140, height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Notes

    private func notesSection(_ notes: String) -> some View {
        Text(notes)
            .font(.mlrBody)
            .foregroundStyle(Color.mlrText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Comments

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: comments.isEmpty ? "Comments" : "Comments (\(comments.count))")

            if loading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12)
            } else if comments.isEmpty {
                Text("No comments yet — start the conversation.")
                    .font(.mlrCaption)
                    .foregroundStyle(Color.mlrTextMuted)
            } else {
                ForEach(comments) { comment in
                    commentRow(comment)
                }
            }
        }
    }

    private func commentRow(_ comment: WorkItemComment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(url: comment.authorAvatarUrl, size: .small)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(comment.authorName)
                        .font(.mlrScaled(13, weight: .semibold))
                        .foregroundStyle(Color.mlrText)
                    Text(MLRFormat.relativeTime(comment.createdAt))
                        .font(.mlrScaled(11))
                        .foregroundStyle(Color.mlrTextSubtle)
                    Spacer()
                    if canDelete(comment) {
                        Button {
                            Task { await delete(comment) }
                        } label: {
                            Image(systemName: "trash")
                                .font(.mlrScaled(11))
                                .foregroundStyle(Color.mlrTextSubtle)
                        }
                        .buttonStyle(.plain)
                    }
                }
                MentionText(comment.text, baseFont: .mlrScaled(14))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Data

    private func load() async {
        loading = true
        roster = await mentionRoster()
        await refreshComments()
        loading = false
    }

    private func refreshComments() async {
        comments = (try? await env.workItemsService.fetchComments(workItemId: current.id)) ?? []
    }

    /// Refetch the item from the service list so edits (title, media, scope) show.
    private func refreshItem() async {
        await env.workItemsService.fetchItems()
        if let updated = env.workItemsService.items.first(where: { $0.id == current.id }) {
            current = updated
        }
    }

    /// Who's mentionable: for a house item, that house's members; for an MLR
    /// item, everyone (matches the mention RLS in migration 0068).
    private func mentionRoster() async -> [Profile] {
        if let hid = current.houseId {
            return await env.housesService.fetchMembers(houseId: hid)
        }
        let rows: [Profile] = (try? await supabase
            .from("profiles")
            .select("id, display_name, avatar_url, is_admin")
            .order("display_name", ascending: true)
            .execute()
            .value) ?? []
        return rows
    }

    private func canDelete(_ comment: WorkItemComment) -> Bool {
        env.isAdmin || comment.authorId == env.currentProfile?.id
    }

    private func post() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let uid = env.currentProfile?.id else { return }
        sending = true
        defer { sending = false }
        let mentioned = roster
            .filter { !$0.name.isEmpty && text.lowercased().contains("@\($0.name.lowercased())") }
            .map(\.id)
        do {
            let comment = try await env.workItemsService.addComment(
                workItemId: current.id, text: text, authorId: uid, mentionedIds: mentioned)
            comments.append(comment)
            current.commentCount += 1
            draft = ""
            onChanged()
        } catch {
            print("[WorkItemDetail] post error: \(error)")
        }
    }

    private func delete(_ comment: WorkItemComment) async {
        do {
            try await env.workItemsService.removeComment(id: comment.id)
            comments.removeAll { $0.id == comment.id }
            current.commentCount = max(0, current.commentCount - 1)
            onChanged()
        } catch {
            print("[WorkItemDetail] delete error: \(error)")
        }
    }

    private func markDone() async {
        marking = true
        defer { marking = false }
        do {
            try await env.workItemsService.markDone(id: current.id)
            current.status = .done
            await env.workItemsService.fetchItems()
            onChanged()
        } catch {
            print("[WorkItemDetail] markDone error: \(error)")
        }
    }
}

// MARK: - Lightbox presentation payload

private struct LightboxData: Identifiable {
    let id = UUID()
    let urls: [String]
    let start: Int
}
