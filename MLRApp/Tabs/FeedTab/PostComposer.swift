import SwiftUI
import PhotosUI

// MARK: - PostComposer
// Sheet for writing/publishing a Feed post (or editing an existing one).
// Mirrors the web PostsView composer: caption with @mention autocomplete,
// up to 5 photos and/or a video, tag members, and an optional backdated date.

struct PostComposer: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    /// Pass an existing post to edit (caption + date only); omit to create.
    var editing: Post? = nil

    @State private var text: String = ""
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var images: [UIImage] = []
    @State private var selectedVideo: PhotosPickerItem?
    @State private var videoData: Data?
    @State private var tagIds: Set<UUID> = []
    @State private var hasBackdate = false
    @State private var occurredAt: Date = .now
    @State private var isUploading = false
    @State private var isPosting = false
    @State private var errorMessage: String? = nil
    @State private var mentionQuery: String = ""
    @State private var showMentionSuggestions = false
    @State private var showTagPicker = false
    @State private var allProfiles: [Profile] = []

    private let softLimit = 140
    private let maxPhotos = 5
    private var isEditing: Bool { editing != nil }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    composeArea
                    if !isEditing {
                        Divider()
                        toolbar
                    }
                }
                if showMentionSuggestions && !mentionQuery.isEmpty {
                    VStack {
                        Spacer().frame(height: 56)
                        MentionAutocomplete(members: allProfiles, query: mentionQuery) { insertMention($0) }
                        Spacer()
                    }
                    .zIndex(10)
                }
            }
            .navigationTitle(isEditing ? "Edit Post" : "New Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isPosting || isUploading)
                }
                ToolbarItem(placement: .confirmationAction) { postButton }
            }
            .interactiveDismissDisabled(isPosting || isUploading)
            .sheet(isPresented: $showTagPicker) {
                TagPicker(members: allProfiles.filter { $0.id != env.currentProfile?.id },
                          selected: $tagIds)
            }
        }
        .task {
            allProfiles = (try? await fetchMemberList()) ?? []
            if let editing {
                text = editing.text ?? ""
                tagIds = Set(editing.tags.map(\.id))
                if let occurred = editing.occurredAt { occurredAt = occurred; hasBackdate = true }
            }
        }
        .onChange(of: selectedPhotos) { _, items in
            Task { await loadPhotos(items) }
        }
        .onChange(of: selectedVideo) { _, item in
            Task {
                guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
                await MainActor.run { videoData = data }
            }
        }
    }

    // MARK: - Compose area

    private var composeArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    AvatarView(url: env.currentProfile?.avatarUrl, size: .medium)
                    Text(env.currentProfile?.name ?? "")
                        .font(.mlrScaled(15, weight: .semibold))
                        .foregroundStyle(Color.mlrText)
                }

                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("What's on your mind?")
                            .foregroundStyle(Color.mlrTextSubtle).padding(.top, 2)
                    }
                    TextEditor(text: $text)
                        .frame(minHeight: 120)
                        .onChange(of: text) { _, v in detectMentionTrigger(in: v) }
                }

                HStack {
                    Spacer()
                    Text("\(softLimit - text.count)")
                        .font(.caption)
                        .foregroundStyle(text.count > softLimit ? Color.mlrDanger
                                         : text.count > softLimit - 20 ? Color.mlrWarning : Color.mlrTextMuted)
                }

                if !images.isEmpty { imageStrip }

                if videoData != nil { videoChip }

                if !tagIds.isEmpty { taggedSummary }

                if hasBackdate {
                    DatePicker("Posted on", selection: $occurredAt,
                               in: ...Date.now, displayedComponents: .date)
                        .font(.mlrScaled(14))
                }

                if isUploading {
                    ProgressView("Uploading…").font(.caption).tint(Color.mlrPrimary)
                }
                if let err = errorMessage {
                    Text(err).font(.caption).foregroundStyle(Color.mlrDanger)
                }
            }
            .padding(16)
        }
    }

    private var imageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.offset) { idx, image in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: image)
                            .resizable().scaledToFill()
                            .frame(width: 120, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        Button {
                            images.remove(at: idx)
                            if idx < selectedPhotos.count { selectedPhotos.remove(at: idx) }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.mlrScaled(20)).foregroundStyle(.white).shadow(radius: 2).padding(4)
                        }
                    }
                }
            }
        }
    }

    private var videoChip: some View {
        HStack(spacing: 8) {
            Image(systemName: "film").foregroundStyle(Color.mlrPrimary)
            Text("Video attached")
                .font(.mlrScaled(14))
                .foregroundStyle(Color.mlrText)
            Spacer()
            Button {
                videoData = nil
                selectedVideo = nil
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Color.mlrTextMuted)
            }
        }
        .padding(10)
        .background(Color.mlrCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var taggedSummary: some View {
        let names = allProfiles.filter { tagIds.contains($0.id) }.map(\.name)
        return Label("With \(names.joined(separator: ", "))", systemImage: "person.2.fill")
            .font(.mlrScaled(13))
            .foregroundStyle(Color.mlrPrimary)
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            PhotosPicker(selection: $selectedPhotos, maxSelectionCount: maxPhotos, matching: .images) {
                Label("Photos", systemImage: "photo.on.rectangle").font(.mlrScaled(14, weight: .medium))
            }
            .disabled(isPosting || isUploading)

            PhotosPicker(selection: $selectedVideo, matching: .videos) {
                Label("Video", systemImage: "video.badge.plus").font(.mlrScaled(14, weight: .medium))
            }
            .disabled(isPosting || isUploading)

            Button { showTagPicker = true } label: {
                Label("Tag", systemImage: "person.crop.circle.badge.plus").font(.mlrScaled(14, weight: .medium))
            }
            Button { withAnimation { hasBackdate.toggle() } } label: {
                Label("Date", systemImage: "calendar").font(.mlrScaled(14, weight: .medium))
                    .foregroundStyle(hasBackdate ? Color.mlrPrimary : Color.mlrTextMuted)
            }
            Spacer()
        }
        .tint(Color.mlrPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.mlrSurface)
    }

    private var postButton: some View {
        Button {
            Task { await post() }
        } label: {
            if isPosting || isUploading { ProgressView().tint(Color.mlrPrimary) }
            else { Text(isEditing ? "Save" : "Post").fontWeight(.semibold) }
        }
        .disabled(submitDisabled)
    }

    private var submitDisabled: Bool {
        let emptyText = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // A new post needs text or at least one photo; an edit needs text.
        let nothingToPost = isEditing ? emptyText : (emptyText && images.isEmpty && videoData == nil)
        return nothingToPost || text.count > softLimit || isPosting || isUploading
    }

    // MARK: - Actions

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        var loaded: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                loaded.append(img)
            }
        }
        await MainActor.run { images = loaded }
    }

    @MainActor
    private func post() async {
        guard let profile = env.currentProfile else { return }
        isPosting = true
        errorMessage = nil
        defer { isPosting = false }

        let caption = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let date = hasBackdate ? occurredAt : nil

        do {
            if let editing {
                try await env.postsService.updatePost(id: editing.id, text: caption, occurredAt: date)
                dismiss()
                return
            }

            // Upload photos + optional video → media tuples.
            var media: [(path: String, type: String)] = []
            if !images.isEmpty || videoData != nil {
                isUploading = true
                for image in images {
                    let url = try await env.mediaService.uploadPostImage(image: image, userId: profile.id)
                    media.append((path: url, type: "image"))
                }
                if let videoData {
                    let url = try await env.mediaService.uploadPostVideo(data: videoData, userId: profile.id)
                    media.append((path: url, type: "video"))
                }
                isUploading = false
            }

            try await env.postsService.createPost(
                text: caption,
                authorId: profile.id,
                media: media,
                tagIds: Array(tagIds),
                occurredAt: date
            )
            dismiss()
        } catch {
            isUploading = false
            errorMessage = isEditing ? "Couldn't save your changes." : "Couldn't publish your post. Please try again."
        }
    }

    // MARK: - @mention detection

    private func detectMentionTrigger(in value: String) {
        mentionQuery = detectMentionQuery(in: value) ?? ""
        showMentionSuggestions = !mentionQuery.isEmpty
    }

    private func insertMention(_ profile: Profile) {
        text = applyMention(profile, to: text)
        mentionQuery = ""
        showMentionSuggestions = false
    }

    private func fetchMemberList() async throws -> [Profile] {
        try await supabase
            .from("profiles")
            .select("id, display_name, avatar_url, is_admin, beta_tester, willing_to_help, intro_seen, email_alerts, push_level, push_types, notif_types, push_prompted, contact_email, created_at")
            .order("display_name", ascending: true)
            .execute()
            .value
    }
}

// MARK: - TagPicker

private struct TagPicker: View {
    @Environment(\.dismiss) private var dismiss
    let members: [Profile]
    @Binding var selected: Set<UUID>
    @State private var query = ""

    private var shown: [Profile] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return members }
        return members.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(shown) { m in
                    Button {
                        if selected.contains(m.id) { selected.remove(m.id) } else { selected.insert(m.id) }
                    } label: {
                        HStack {
                            AvatarView(profile: m, size: .small)
                            Text(m.name).foregroundStyle(Color.mlrText)
                            Spacer()
                            if selected.contains(m.id) {
                                Image(systemName: "checkmark").foregroundStyle(Color.mlrPrimary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query)
            .navigationTitle("Tag people")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
