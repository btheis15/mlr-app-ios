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
    @State private var images: [ComposerImage] = []
    /// Per-photo upload state (MediaService reports no byte progress, so each
    /// thumbnail shows waiting / uploading / done and the footer shows "n of m").
    @State private var uploadStatus: [UUID: ComposerUploadStatus] = [:]
    @State private var uploadedCount = 0
    @State private var uploadTotal = 0
    @State private var draggingId: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    /// Display URLs of existing media marked for removal (edit mode).
    @State private var removedUrls: Set<String> = []

    private let softLimit = 140
    private let maxPhotos = 5
    private var isEditing: Bool { editing != nil }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    composeArea
                    Divider()
                    toolbar   // photo/video/tag pickers — editing can add media too
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
        // A light half-height card (drag up for more), not a full-screen takeover.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            allProfiles = (try? await fetchMemberList()) ?? []
            if let editing {
                text = editing.text ?? ""
                tagIds = Set(editing.tags.map(\.id))
                if let occurred = editing.occurredAt { occurredAt = occurred; hasBackdate = true }
            }
        }
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
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
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    AvatarView(url: env.currentProfile?.avatarUrl, size: .small)
                    Text(env.currentProfile?.name ?? "")
                        .font(.mlrScaled(14, weight: .semibold))
                        .foregroundStyle(Color.mlrText)
                    Spacer()
                    // Char counter only surfaces as you near/pass the limit — no clutter otherwise.
                    if text.count > softLimit - 20 {
                        Text("\(softLimit - text.count)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(text.count > softLimit ? Color.mlrDanger : Color.mlrWarning)
                    }
                }

                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("What's on your mind?")
                            .foregroundStyle(Color.mlrTextSubtle)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                    }
                    TextEditor(text: $text)
                        .frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                        .onChange(of: text) { _, v in detectMentionTrigger(in: v) }
                }

                if isEditing && !keptExistingMedia.isEmpty { existingMediaStrip }

                if !images.isEmpty { imageStrip }

                if videoData != nil { videoChip }

                if !tagIds.isEmpty { taggedSummary }

                if hasBackdate {
                    DatePicker("Posted on", selection: $occurredAt,
                               in: ...Date.now, displayedComponents: .date)
                        .font(.mlrScaled(14))
                }

                if isUploading && uploadTotal > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: Double(uploadedCount), total: Double(uploadTotal))
                            .tint(Color.mlrPineText)
                        Text("Uploading \(min(uploadedCount + 1, uploadTotal)) of \(uploadTotal)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(Color.mlrTextMuted)
                            .contentTransition(.numericText())
                    }
                    .animation(reduceMotion ? nil : MLRMotion.spring, value: uploadedCount)
                }
                if let err = errorMessage {
                    Text(err).font(.caption).foregroundStyle(Color.mlrDanger)
                }
            }
            .padding(16)
        }
    }

    /// Existing media on the post being edited, minus anything marked removed.
    private var keptExistingMedia: [(url: String, isVideo: Bool)] {
        guard let editing else { return [] }
        return zip(editing.mediaUrls, editing.mediaIsVideo + Array(repeating: false, count: max(0, editing.mediaUrls.count - editing.mediaIsVideo.count)))
            .filter { !removedUrls.contains($0.0) }
            .map { (url: $0.0, isVideo: $0.1) }
    }

    /// Thumbnails of the post's current media with a remove ✕ (edit mode).
    private var existingMediaStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(keptExistingMedia, id: \.url) { item in
                    ZStack(alignment: .topTrailing) {
                        if item.isVideo {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.mlrCard)
                                .frame(width: 120, height: 120)
                                .overlay(Image(systemName: "play.circle.fill").font(.mlrScaled(28)).foregroundStyle(Color.mlrTextMuted))
                        } else {
                            MediaThumb(url: item.url)
                                .frame(width: 120, height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        Button {
                            removedUrls.insert(item.url)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.mlrScaled(20)).foregroundStyle(.white).shadow(radius: 2).padding(4)
                        }
                    }
                }
            }
        }
    }

    private var imageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images) { item in
                    thumbnail(item)
                }
            }
            .animation(reduceMotion ? nil : MLRMotion.spring, value: images.map(\.id))
        }
    }

    /// A photo thumbnail: upload-state overlay, ✕ to remove, long-press drag to
    /// reorder (plus Move earlier/later in the context menu for accessibility).
    private func thumbnail(_ item: ComposerImage) -> some View {
        let status = uploadStatus[item.id]
        return ZStack(alignment: .topTrailing) {
            Image(uiImage: item.image)
                .resizable().scaledToFill()
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    switch status {
                    case .waiting:
                        RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.35))
                            .overlay(Image(systemName: "clock").foregroundStyle(.white))
                    case .uploading:
                        RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.4))
                            .overlay(ProgressView().tint(.white))
                    case .done:
                        RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.25))
                            .overlay(Image(systemName: "checkmark.circle.fill")
                                .font(.mlrScaled(26)).foregroundStyle(.white)
                                .transition(.scale.combined(with: .opacity)))
                    case nil:
                        EmptyView()
                    }
                }
                .opacity(draggingId == item.id ? 0.45 : 1)
            if status == nil {
                Button {
                    Haptics.tap()
                    if reduceMotion { removeImage(item.id) } else { withAnimation(MLRMotion.spring) { removeImage(item.id) } }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.mlrScaled(20)).foregroundStyle(.white).shadow(radius: 2).padding(4)
                }
                .accessibilityLabel("Remove photo")
            }
        }
        .animation(reduceMotion ? nil : MLRMotion.spring, value: status)
        .draggable(item.id.uuidString) {
            Image(uiImage: item.image).resizable().scaledToFill()
                .frame(width: 80, height: 80).clipShape(RoundedRectangle(cornerRadius: 10))
                .onAppear { draggingId = item.id }
        }
        .dropDestination(for: String.self) { ids, _ in
            defer { draggingId = nil }
            guard let raw = ids.first, let from = UUID(uuidString: raw) else { return false }
            moveImage(from, before: item.id)
            return true
        }
        .contextMenu {
            if let idx = images.firstIndex(where: { $0.id == item.id }), status == nil {
                if idx > 0 {
                    Button { swapImage(idx, idx - 1) } label: { Label("Move earlier", systemImage: "arrow.left") }
                }
                if idx < images.count - 1 {
                    Button { swapImage(idx, idx + 1) } label: { Label("Move later", systemImage: "arrow.right") }
                }
                Button(role: .destructive) { removeImage(item.id) } label: { Label("Remove", systemImage: "trash") }
            }
        }
    }

    private func removeImage(_ id: UUID) {
        images.removeAll { $0.id == id }
    }

    private func swapImage(_ a: Int, _ b: Int) {
        guard images.indices.contains(a), images.indices.contains(b) else { return }
        Haptics.select()
        if reduceMotion { images.swapAt(a, b) } else { withAnimation(MLRMotion.spring) { images.swapAt(a, b) } }
    }

    private func moveImage(_ id: UUID, before target: UUID) {
        guard id != target,
              let from = images.firstIndex(where: { $0.id == id }),
              let to = images.firstIndex(where: { $0.id == target }) else { return }
        Haptics.select()
        let apply = {
            let moved = images.remove(at: from)
            images.insert(moved, at: to)
        }
        if reduceMotion { apply() } else { withAnimation(MLRMotion.spring, apply) }
    }

    private var videoChip: some View {
        HStack(spacing: 8) {
            Image(systemName: "film").foregroundStyle(Color.mlrPineText)
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
            .foregroundStyle(Color.mlrPineText)
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            // Append mode: picked photos are added (and the selection cleared) so a
            // manual reorder is never undone by the picker re-delivering its list.
            PhotosPicker(selection: $selectedPhotos, maxSelectionCount: max(1, maxPhotos - images.count), matching: .images) {
                Label("Photos", systemImage: "photo.on.rectangle").font(.mlrScaled(14, weight: .medium))
            }
            .disabled(isPosting || isUploading || images.count >= maxPhotos)

            PhotosPicker(selection: $selectedVideo, matching: .videos) {
                Label("Video", systemImage: "video.badge.plus").font(.mlrScaled(14, weight: .medium))
            }
            .disabled(isPosting || isUploading)

            Button { showTagPicker = true } label: {
                Label("Tag", systemImage: "person.crop.circle.badge.plus").font(.mlrScaled(14, weight: .medium))
            }
            Button { withAnimation { hasBackdate.toggle() } } label: {
                Label("Date", systemImage: "calendar").font(.mlrScaled(14, weight: .medium))
                    .foregroundStyle(hasBackdate ? Color.mlrPineText : Color.mlrTextMuted)
            }
            Spacer()
        }
        .tint(Color.mlrPineText)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.mlrSurface)
    }

    private var postButton: some View {
        Button {
            Task { await post() }
        } label: {
            if isPosting || isUploading { ProgressView().tint(Color.mlrPineText) }
            else { Text(isEditing ? "Save" : "Post").fontWeight(.semibold) }
        }
        .disabled(submitDisabled)
    }

    private var submitDisabled: Bool {
        let emptyText = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // A new post needs text or at least one photo; an edit needs text.
        let nothingToPost = isEditing
            ? (emptyText && keptExistingMedia.isEmpty && images.isEmpty && videoData == nil)
            : (emptyText && images.isEmpty && videoData == nil)
        return nothingToPost || text.count > softLimit || isPosting || isUploading
    }

    // MARK: - Actions

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        var loaded: [ComposerImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                loaded.append(ComposerImage(image: img))
            }
        }
        await MainActor.run {
            let room = max(0, maxPhotos - images.count)
            let added = Array(loaded.prefix(room))
            if reduceMotion { images.append(contentsOf: added) }
            else { withAnimation(MLRMotion.spring) { images.append(contentsOf: added) } }
            selectedPhotos = []
        }
    }

    /// Upload every attachment in order, updating per-thumbnail state and the
    /// "n of m" footer as each finishes. Throws on the first failure (the
    /// caller keeps the draft and resets the thumbnails).
    @MainActor
    private func uploadAttachments(userId: UUID) async throws -> [(path: String, type: String)] {
        var media: [(path: String, type: String)] = []
        uploadTotal = images.count + (videoData == nil ? 0 : 1)
        uploadedCount = 0
        isUploading = true
        uploadStatus = Dictionary(uniqueKeysWithValues: images.map { ($0.id, ComposerUploadStatus.waiting) })
        for item in images {
            uploadStatus[item.id] = .uploading
            let url = try await env.mediaService.uploadPostImage(image: item.image, userId: userId)
            media.append((path: url, type: "image"))
            uploadStatus[item.id] = .done
            uploadedCount += 1
        }
        if let videoData {
            let url = try await env.mediaService.uploadPostVideo(data: videoData, userId: userId)
            media.append((path: url, type: "video"))
            uploadedCount += 1
        }
        isUploading = false
        return media
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
                // Media changes: drop anything ✕'d, then append new uploads.
                for url in removedUrls {
                    try await env.postsService.removePostMedia(postId: editing.id, displayUrl: url)
                }
                if !images.isEmpty || videoData != nil {
                    let newMedia = try await uploadAttachments(userId: profile.id)
                    try await env.postsService.addPostMedia(
                        postId: editing.id, media: newMedia, startPosition: editing.mediaUrls.count)
                }
                if !removedUrls.isEmpty || !images.isEmpty || videoData != nil {
                    await env.postsService.fetchPosts(userId: nil)
                }
                Haptics.success()
                dismiss()
                return
            }

            // Upload photos + optional video → media tuples.
            var media: [(path: String, type: String)] = []
            if !images.isEmpty || videoData != nil {
                media = try await uploadAttachments(userId: profile.id)
            }

            try await env.postsService.createPost(
                text: caption,
                authorId: profile.id,
                media: media,
                tagIds: Array(tagIds),
                occurredAt: date
            )
            Haptics.success()
            dismiss()
        } catch {
            // The draft (text, photos, video, tags, date) is deliberately kept so
            // the member can just tap Post again.
            isUploading = false
            uploadStatus = [:]
            Haptics.error()
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

// MARK: - Composer attachment models

/// A picked photo with a stable identity (reorder/remove/upload-state key).
struct ComposerImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

enum ComposerUploadStatus: Equatable { case waiting, uploading, done }

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
                                Image(systemName: "checkmark").foregroundStyle(Color.mlrPineText)
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
