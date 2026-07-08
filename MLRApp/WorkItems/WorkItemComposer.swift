import SwiftUI
import PhotosUI
import Kingfisher

// MARK: - WorkItemComposer
//
// Add/edit sheet for a work checklist item. Any signed-in member can add items,
// and can edit an item they created (admins can edit any); admins additionally
// get the status toggle + delete when editing. Items can be scoped to the
// resort (MLR) or a house you belong to (migration 0066), carry an urgency
// rating (0069), and attach photos/video (0067). Mirrors the web WorkItemComposer.

struct WorkItemComposer: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let item: WorkItem?
    let preLinkedEventId: String?
    let onSaved: () -> Void

    @State private var title: String
    @State private var notes: String
    @State private var peopleNeeded: Int
    @State private var status: WorkItemStatus
    @State private var urgency: WorkUrgency
    @State private var scopeHouseId: UUID?
    @State private var selectedEventId: String?

    // Media
    @State private var existingMedia: [WorkItemMedia]
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var newImages: [UIImage] = []
    @State private var selectedVideo: PhotosPickerItem?
    @State private var videoData: Data?

    @State private var pending = false
    @State private var uploading = false
    @State private var errorText: String?

    init(item: WorkItem? = nil, preLinkedEventId: String? = nil,
         prefillTitle: String? = nil, prefillNotes: String? = nil,
         onSaved: @escaping () -> Void) {
        self.item = item
        self.preLinkedEventId = preLinkedEventId
        self.onSaved = onSaved
        _title        = State(initialValue: item?.title ?? prefillTitle ?? "")
        _notes        = State(initialValue: item?.notes ?? prefillNotes ?? "")
        _peopleNeeded = State(initialValue: item?.peopleNeeded ?? 0)
        _status       = State(initialValue: item?.status ?? .open)
        _urgency      = State(initialValue: item?.urgency ?? .thisYear)
        _scopeHouseId = State(initialValue: item?.houseId)
        _existingMedia = State(initialValue: item?.media ?? [])
        _selectedEventId = State(initialValue: preLinkedEventId)
    }

    private var editing: Bool { item != nil }
    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !pending && !uploading
    }
    private var linkableEvents: [ResortEvent] {
        guard !editing, preLinkedEventId == nil else { return [] }
        return env.eventsService.upcomingEvents
    }

    /// Houses the user may scope an item to: their own house (members) or all
    /// houses (admins). Empty → no scope picker (a plain MLR item).
    private var availableHouses: [House] {
        if env.isAdmin { return env.housesService.houses }
        if let hid = env.currentProfile?.houseId {
            return env.housesService.houses.filter { $0.id == hid }
        }
        return []
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    taskSection
                    urgencySection
                    if !availableHouses.isEmpty { scopeSection }
                    peopleSection
                    photosSection
                    if !linkableEvents.isEmpty { eventLinkSection }
                    if editing && env.isAdmin { statusSection }

                    Button {
                        Task { await submit() }
                    } label: {
                        Text(saveLabel)
                            .primaryButton()
                    }
                    .disabled(!canSubmit)
                    .opacity(canSubmit ? 1 : 0.5)

                    if editing && env.isAdmin {
                        Button {
                            Task { await remove() }
                        } label: {
                            Text("Remove from checklist")
                                .font(.mlrScaled(14, weight: .semibold))
                                .foregroundStyle(Color.mlrDanger)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.mlrDanger.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(pending)
                    }

                    if let errorText {
                        Text(errorText)
                            .font(.mlrCaption)
                            .foregroundStyle(Color.mlrDanger)
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(editing ? "Edit item" : "Add work item")
            .navigationBarTitleDisplayMode(.inline)
            .tint(Color.mlrPrimary)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(pending || uploading)
                }
            }
            .task { if env.housesService.houses.isEmpty { await env.housesService.fetchHouses() } }
            .onChange(of: selectedPhotos) { _, items in Task { await loadPhotos(items) } }
            .onChange(of: selectedVideo) { _, item in
                Task {
                    guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
                    await MainActor.run { videoData = data }
                }
            }
        }
    }

    private var saveLabel: String {
        if uploading { return "Uploading…" }
        if pending { return "Saving…" }
        return editing ? "Save changes" : "Add to checklist"
    }

    // MARK: - Sections

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Task")
            TextField("e.g. \"Caulk windows on the red & white cabin\"", text: $title)
                .fieldStyle()
            TextField("Extra details (optional)", text: $notes, axis: .vertical)
                .lineLimit(3...6)
                .fieldStyle()
        }
    }

    private var urgencySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "How urgent?")
            HStack(spacing: 8) {
                ForEach(WorkUrgency.allCases, id: \.self) { u in
                    Button {
                        urgency = u
                    } label: {
                        Text("\(u.emoji) \(u.label)")
                            .font(.mlrScaled(13, weight: .semibold))
                            .foregroundStyle(urgency == u ? .white : Color.mlrTextMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(urgency == u ? Color.mlrPrimary : Color.mlrCard)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Who's this for?")
            VStack(spacing: 6) {
                scopeRow(id: nil, emoji: "🏕️", label: "Whole resort (MLR)")
                ForEach(availableHouses) { house in
                    scopeRow(id: house.id, emoji: house.emoji, label: house.name)
                }
            }
        }
    }

    private func scopeRow(id: UUID?, emoji: String, label: String) -> some View {
        let selected = scopeHouseId == id
        return Button {
            scopeHouseId = id
        } label: {
            HStack(spacing: 10) {
                Text(emoji)
                Text(label)
                    .font(.mlrScaled(14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.mlrPrimary : Color.mlrText)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.mlrScaled(12, weight: .bold))
                        .foregroundStyle(Color.mlrPrimary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(selected ? Color.mlrPrimary.opacity(0.1) : Color.mlrCard)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? Color.mlrPrimary.opacity(0.3) : Color.mlrBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "How many people needed? (optional)")
            HStack {
                Text("People needed")
                    .font(.mlrBody)
                    .foregroundStyle(Color.mlrTextMuted)
                Spacer()
                HStack(spacing: 16) {
                    stepperButton("minus", enabled: peopleNeeded > 0) {
                        peopleNeeded = max(0, peopleNeeded - 1)
                    }
                    Text(peopleNeeded == 0 ? "Any" : "\(peopleNeeded)")
                        .font(.mlrScaled(15, weight: .semibold))
                        .monospacedDigit()
                        .frame(minWidth: 36)
                    stepperButton("plus", enabled: peopleNeeded < 20) {
                        peopleNeeded = min(20, peopleNeeded + 1)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .cardStyle()
        }
    }

    private func stepperButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.mlrScaled(14, weight: .bold))
                .foregroundStyle(enabled ? Color.mlrPrimary : Color.mlrTextSubtle)
                .frame(width: 32, height: 32)
                .background(Color.mlrSurface)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.mlrBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var photosSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Photos (optional)")

            if !existingMedia.isEmpty || !newImages.isEmpty || videoData != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(existingMedia) { media in
                            ZStack(alignment: .topTrailing) {
                                thumb(for: media)
                                removeBadge { Task { await removeExisting(media) } }
                            }
                        }
                        ForEach(Array(newImages.enumerated()), id: \.offset) { idx, image in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: image)
                                    .resizable().scaledToFill()
                                    .frame(width: 96, height: 96)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                removeBadge {
                                    newImages.remove(at: idx)
                                    if idx < selectedPhotos.count { selectedPhotos.remove(at: idx) }
                                }
                            }
                        }
                        if videoData != nil {
                            ZStack(alignment: .topTrailing) {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.mlrCard)
                                    .frame(width: 96, height: 96)
                                    .overlay(Image(systemName: "film").font(.mlrScaled(22)).foregroundStyle(Color.mlrPrimary))
                                removeBadge { videoData = nil; selectedVideo = nil }
                            }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 5, matching: .images) {
                    Label("Add photos", systemImage: "photo.on.rectangle")
                        .font(.mlrScaled(14, weight: .medium))
                        .foregroundStyle(Color.mlrPrimary)
                }
                .disabled(pending || uploading)
                PhotosPicker(selection: $selectedVideo, matching: .videos) {
                    Label("Video", systemImage: "video.badge.plus")
                        .font(.mlrScaled(14, weight: .medium))
                        .foregroundStyle(Color.mlrPrimary)
                }
                .disabled(pending || uploading)
            }
        }
    }

    private func thumb(for media: WorkItemMedia) -> some View {
        Group {
            if media.isVideo {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.mlrCard)
                    .overlay(Image(systemName: "film").font(.mlrScaled(22)).foregroundStyle(Color.mlrPrimary))
            } else {
                MediaThumb(url: media.url)
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func removeBadge(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.mlrScaled(18))
                .foregroundStyle(.white)
                .shadow(radius: 2)
                .padding(4)
        }
    }

    private var eventLinkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Link to an event (optional)")
            VStack(spacing: 6) {
                ForEach(linkableEvents) { ev in
                    Button {
                        selectedEventId = selectedEventId == ev.id ? nil : ev.id
                    } label: {
                        HStack(spacing: 10) {
                            Text(ev.emoji ?? "📅")
                            Text(ev.title)
                                .font(.mlrScaled(14, weight: selectedEventId == ev.id ? .semibold : .regular))
                                .foregroundStyle(selectedEventId == ev.id ? Color.mlrPrimary : Color.mlrText)
                            Spacer()
                            if selectedEventId == ev.id {
                                Image(systemName: "checkmark")
                                    .font(.mlrScaled(12, weight: .bold))
                                    .foregroundStyle(Color.mlrPrimary)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(selectedEventId == ev.id ? Color.mlrPrimary.opacity(0.1) : Color.mlrCard)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(selectedEventId == ev.id ? Color.mlrPrimary.opacity(0.3) : Color.mlrBorder, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Status")
            HStack(spacing: 8) {
                ForEach([WorkItemStatus.open, .done], id: \.self) { s in
                    Button {
                        status = s
                    } label: {
                        Text(s == .open ? "⬜ Open" : "✅ Done")
                            .font(.mlrScaled(14, weight: .semibold))
                            .foregroundStyle(status == s ? .white : Color.mlrTextMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(status == s ? Color.mlrPrimary : Color.mlrCard)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Actions

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        var loaded: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                loaded.append(img)
            }
        }
        await MainActor.run { newImages = loaded }
    }

    private func removeExisting(_ media: WorkItemMedia) async {
        do {
            try await env.workItemsService.removeMedia(id: media.id)
            existingMedia.removeAll { $0.id == media.id }
        } catch {
            errorText = "Couldn't remove that photo."
        }
    }

    private func submit() async {
        guard canSubmit else { return }
        guard env.isSignedIn, let userId = env.currentProfile?.id else { env.authService.promptSignIn(); return }
        pending = true
        errorText = nil
        defer { pending = false }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let needed = peopleNeeded > 0 ? peopleNeeded : nil

        do {
            let itemId: UUID
            if let item {
                try await env.workItemsService.updateItem(
                    id: item.id,
                    title: trimmedTitle,
                    notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                    category: item.category,
                    status: status,
                    peopleNeeded: needed,
                    houseId: scopeHouseId,
                    urgency: urgency
                )
                itemId = item.id
            } else {
                itemId = try await env.workItemsService.createItem(
                    title: trimmedTitle,
                    notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                    category: nil,
                    peopleNeeded: needed,
                    houseId: scopeHouseId,
                    urgency: urgency
                )
                if let eventId = selectedEventId {
                    try await env.workItemsService.addToEvent(eventId: eventId, itemId: itemId)
                }
            }

            // Upload any newly-picked media and attach it (position appended).
            if !newImages.isEmpty || videoData != nil {
                uploading = true
                var position = existingMedia.count
                for image in newImages {
                    let url = try await env.mediaService.uploadPostImage(image: image, userId: userId)
                    try await env.workItemsService.addMedia(workItemId: itemId, url: url, mediaType: "image", position: position)
                    position += 1
                }
                if let videoData {
                    let url = try await env.mediaService.uploadPostVideo(data: videoData, userId: userId)
                    try await env.workItemsService.addMedia(workItemId: itemId, url: url, mediaType: "video", position: position)
                }
                uploading = false
                await env.workItemsService.fetchItems()
            }

            onSaved()
            dismiss()
        } catch {
            uploading = false
            errorText = "Couldn't save. Check your connection and try again."
            print("[WorkItemComposer] submit error: \(error)")
        }
    }

    private func remove() async {
        guard let item else { return }
        pending = true
        errorText = nil
        defer { pending = false }
        do {
            try await env.workItemsService.deleteItem(id: item.id)
            onSaved()
            dismiss()
        } catch {
            errorText = "Couldn't remove the item. Please try again."
            print("[WorkItemComposer] remove error: \(error)")
        }
    }
}

// MARK: - MediaThumb
// A small Kingfisher-cached image thumbnail for work-item media.

struct MediaThumb: View {
    let url: String

    var body: some View {
        if let u = URL(string: url) {
            KFImage(u)
                .fade(duration: 0.2)
                .resizable()
                .scaledToFill()
        } else {
            Rectangle().fill(Color.mlrCard)
        }
    }
}
