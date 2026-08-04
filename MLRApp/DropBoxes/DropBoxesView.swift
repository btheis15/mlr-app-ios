import SwiftUI
import PhotosUI

// MARK: - DropBoxesView
// Shared photo/video folders (migration 0171) — the app's account-free
// alternative to a Google Drive shared folder. Any signed-in member opens a
// box, adds as many photos/videos as they want, and browses everything
// anyone else dropped in. Reached from the Home Quick Actions grid. Mirrors
// web's /drop → DropBoxes.

struct DropBoxesView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var creating = false

    private var live: [DropBox] { env.dropBoxesService.boxes.filter { !$0.isArchived } }
    private var archived: [DropBox] { env.dropBoxesService.boxes.filter(\.isArchived) }

    var body: some View {
        Group {
            if env.dropBoxesService.isLoading && env.dropBoxesService.boxes.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if live.isEmpty && archived.isEmpty {
                emptyState
            } else {
                List {
                    Section {
                        ForEach(live) { box in
                            NavigationLink(destination: DropBoxDetailView(boxId: box.id)) {
                                row(box)
                            }
                        }
                    }
                    if !archived.isEmpty {
                        Section("Archived") {
                            ForEach(archived) { box in
                                NavigationLink(destination: DropBoxDetailView(boxId: box.id)) {
                                    row(box)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Drop Box")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { creating = true } label: { Image(systemName: "plus") }
            }
        }
        .task {
            await env.dropBoxesService.fetchBoxes()
            env.dropBoxesService.subscribe { Task { await env.dropBoxesService.fetchBoxes() } }
        }
        .onDisappear { env.dropBoxesService.unsubscribe() }
        .refreshable { await env.dropBoxesService.fetchBoxes() }
        .sheet(isPresented: $creating) {
            DropBoxEditSheet(box: nil) { await env.dropBoxesService.fetchBoxes() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("📸").font(.mlrScaled(40))
            Text("No folders yet").font(.mlrScaled(17, weight: .semibold))
            Text("Start a shared folder — everyone can drop in photos & videos and browse what's there.")
                .font(.mlrCaption).foregroundStyle(Color.mlrTextMuted)
                .multilineTextAlignment(.center)
            Button { creating = true } label: {
                Label("New folder", systemImage: "plus")
                    .font(.mlrScaled(15, weight: .semibold))
                    .foregroundStyle(Color.mlrPrimary)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.mlrPrimary.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.pressable)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ box: DropBox) -> some View {
        HStack(spacing: 12) {
            Text(box.emoji?.nilIfBlank ?? "📸").font(.mlrScaled(24))
            VStack(alignment: .leading, spacing: 2) {
                Text(box.title).font(.mlrScaled(16, weight: .semibold)).foregroundStyle(Color.mlrText)
                Text("\(box.count) item\(box.count == 1 ? "" : "s") · by \(box.createdByName)")
                    .font(.mlrCaption).foregroundStyle(Color.mlrTextMuted)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - DropBoxDetailView

/// Not `private` — also opened directly from a Home callout deep-link
/// (migration 0172, see HomeCalloutCard's "📸 Add & see photos" button).
struct DropBoxDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let boxId: UUID

    // A stored `private var` on any property forces Swift's synthesized
    // memberwise init to be file-private too — so an explicit init is needed
    // for the cross-file deep-link call site above.
    init(boxId: UUID) { self.boxId = boxId }

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var uploading = false
    @State private var uploadedCount = 0
    @State private var uploadTotal = 0
    @State private var lightbox: LightboxData?
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var selectMode = false
    @State private var selectedIds: Set<UUID> = []
    @State private var confirmBulkDelete = false
    @State private var bulkDeleting = false
    @State private var error: String?

    private let columns = [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)]

    // Read straight off the observed service value (matching HouseHubView's
    // idiom) — @Observable makes this a tracked dependency, so the grid
    // re-renders live as realtime/refetch updates `boxes`, no Binding needed.
    private var box: DropBox? { env.dropBoxesService.boxes.first { $0.id == boxId } }
    private var myId: UUID? { env.currentProfile?.id }

    var body: some View {
        Group {
            if let box {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if box.isArchived {
                            Label("Archived — no new uploads", systemImage: "archivebox")
                                .font(.mlrScaled(12, weight: .semibold))
                                .foregroundStyle(Color.mlrWarning)
                                .padding(.horizontal, 12)
                        }

                        PhotosPicker(selection: $pickerItems, matching: .any(of: [.images, .videos])) {
                            Label(uploading ? "Uploading \(uploadedCount)/\(uploadTotal)…" : "Add photos & videos",
                                  systemImage: "plus.circle.fill")
                                .font(.mlrScaled(15, weight: .semibold))
                                .foregroundStyle(Color.mlrPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.mlrPrimary.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(uploading || box.isArchived)
                        .padding(.horizontal, 12)
                        .onChange(of: pickerItems) { _, items in
                            guard !items.isEmpty else { return }
                            Task { await upload(items) }
                        }

                        if let error {
                            Text(error).font(.mlrCaption).foregroundStyle(Color.mlrDanger).padding(.horizontal, 12)
                        }

                        if box.items.isEmpty {
                            Text("Nothing dropped in here yet.")
                                .font(.mlrCaption).foregroundStyle(Color.mlrTextMuted)
                                .padding(.horizontal, 12)
                        } else {
                            LazyVGrid(columns: columns, spacing: 2) {
                                ForEach(box.sortedItems) { item in
                                    thumb(item, in: box)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 12)
                }
                .navigationTitle(box.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        if selectMode {
                            HStack(spacing: 16) {
                                if !selectedIds.isEmpty {
                                    Button(role: .destructive) { confirmBulkDelete = true } label: {
                                        Text(bulkDeleting ? "Deleting…" : "Delete \(selectedIds.count)")
                                            .font(.mlrScaled(14, weight: .semibold))
                                    }
                                    .disabled(bulkDeleting)
                                }
                                Button("Done") {
                                    selectMode = false
                                    selectedIds = []
                                }
                                .font(.mlrScaled(14, weight: .semibold))
                            }
                        } else {
                            HStack(spacing: 16) {
                                if !box.items.isEmpty {
                                    Button("Select") { selectMode = true }
                                        .font(.mlrScaled(14))
                                }
                                Menu {
                                    Button { editing = true } label: { Label("Rename", systemImage: "pencil") }
                                    Button { Task { await toggleArchive(box) } } label: {
                                        Label(box.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox")
                                    }
                                    Button(role: .destructive) { confirmDelete = true } label: {
                                        Label("Delete folder", systemImage: "trash")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                            }
                        }
                    }
                }
                .fullScreenCover(item: $lightbox) { data in
                    LightboxView(urls: data.urls, isVideo: data.isVideo, startIndex: data.start)
                }
                .sheet(isPresented: $editing) {
                    DropBoxEditSheet(box: box) { await reload() }
                }
                .alert("Delete this folder?", isPresented: $confirmDelete) {
                    Button("Delete", role: .destructive) { Task { await deleteBox(box) } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Every photo and video in \"\(box.title)\" is removed for everyone — no undo.")
                }
                .alert("Delete \(selectedIds.count) item\(selectedIds.count == 1 ? "" : "s")?", isPresented: $confirmBulkDelete) {
                    Button("Delete", role: .destructive) { Task { await removeBatch() } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("These photos and videos are removed for everyone — no undo.")
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Deep-linked here directly (a Home callout, migration 0172) can land
        // before DropBoxesView's own `.task` has ever fetched — make sure this
        // detail view can always self-load rather than spinning forever.
        .task {
            if env.dropBoxesService.boxes.isEmpty {
                await env.dropBoxesService.fetchBoxes()
            }
        }
    }

    @ViewBuilder
    private func thumb(_ item: DropBoxMedia, in box: DropBox) -> some View {
        let canManage = box.canManage(isAdmin: env.isAdmin, viewerId: myId) || item.uploadedBy == myId
        let held = item.status == .pending
        let isSelected = selectedIds.contains(item.id)
        Button {
            if selectMode {
                if isSelected { selectedIds.remove(item.id) } else { selectedIds.insert(item.id) }
            } else {
                openLightbox(item, in: box)
            }
        } label: {
            ZStack(alignment: .bottomLeading) {
                MediaThumb(url: item.displayUrl)
                    .scaledToFill()
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
                if item.isVideo && !selectMode {
                    Image(systemName: "play.circle.fill")
                        .font(.mlrScaled(18))
                        .foregroundStyle(.white)
                        .padding(6)
                }
                if held {
                    Text("Pending review")
                        .font(.mlrScaled(9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.mlrWarning)
                        .clipShape(Capsule())
                        .padding(4)
                }
                if selectMode {
                    ZStack {
                        if isSelected {
                            Color.black.opacity(0.3)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if selectMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.mlrScaled(20))
                        .foregroundStyle(isSelected ? Color.mlrPrimary : .white)
                        .shadow(radius: 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(6)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipped()
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !selectMode {
                if held && env.isAdmin {
                    Button { Task { await setStatus(item, .visible) } } label: { Label("Approve", systemImage: "checkmark.circle") }
                    Button(role: .destructive) { Task { await setStatus(item, .hidden) } } label: { Label("Hide", systemImage: "eye.slash") }
                }
                if canManage {
                    Button(role: .destructive) { Task { await remove(item) } } label: { Label("Remove", systemImage: "trash") }
                }
            }
        }
    }

    private func openLightbox(_ item: DropBoxMedia, in box: DropBox) {
        // RLS already scoped `box.items` to what this viewer may see (visible
        // to everyone, or pending/held items visible only to their uploader +
        // admins) — no extra client-side filtering needed.
        let items = box.sortedItems
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        lightbox = LightboxData(urls: items.map(\.url), isVideo: items.map(\.isVideo), start: idx)
    }

    private func reload() async {
        await env.dropBoxesService.fetchBoxes()
    }

    private func upload(_ items: [PhotosPickerItem]) async {
        guard let box else { return }
        uploading = true; uploadTotal = items.count; uploadedCount = 0; error = nil
        defer { uploading = false; pickerItems = [] }
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            do {
                if let image = UIImage(data: data) {
                    let res = try await env.mediaService.uploadDropBoxImage(image: image, boxId: box.id)
                    try await env.dropBoxesService.addMedia(boxId: box.id, url: res.url, thumbnailUrl: res.thumbnailUrl, type: "image")
                } else {
                    let res = try await env.mediaService.uploadDropBoxVideo(data: data, boxId: box.id)
                    try await env.dropBoxesService.addMedia(boxId: box.id, url: res.url, thumbnailUrl: res.thumbnailUrl, type: "video")
                }
                uploadedCount += 1
                await reload()
            } catch {
                self.error = "Couldn't upload everything. Check your connection and try again."
            }
        }
    }

    private func remove(_ item: DropBoxMedia) async {
        do { try await env.dropBoxesService.removeMedia(id: item.id); await reload() }
        catch { self.error = "Couldn't remove that item." }
    }

    private func removeBatch() async {
        let ids = Array(selectedIds)
        bulkDeleting = true
        defer { bulkDeleting = false }
        do {
            try await env.dropBoxesService.removeMediaBatch(ids: ids)
            selectedIds = []
            selectMode = false
            await reload()
        } catch {
            self.error = "Couldn't delete all selected items."
        }
    }

    private func setStatus(_ item: DropBoxMedia, _ status: DropBoxMediaStatus) async {
        do { try await env.dropBoxesService.setMediaStatus(id: item.id, status: status); await reload() }
        catch { self.error = "Couldn't update that item." }
    }

    private func toggleArchive(_ box: DropBox) async {
        do { try await env.dropBoxesService.setArchived(id: box.id, archived: !box.isArchived); await reload() }
        catch { self.error = "Couldn't update this folder." }
    }

    private func deleteBox(_ box: DropBox) async {
        do { try await env.dropBoxesService.deleteBox(id: box.id); await reload(); dismiss() }
        catch { self.error = "Couldn't delete this folder." }
    }

    private struct LightboxData: Identifiable {
        let id = UUID()
        let urls: [String]
        let isVideo: [Bool]
        let start: Int
    }
}

// MARK: - DropBoxEditSheet (create or rename/re-emoji a box)

private struct DropBoxEditSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let box: DropBox?     // nil = creating a new box
    let onSaved: () async -> Void

    @State private var title: String
    @State private var emoji: String
    @State private var saving = false
    @State private var error: String?

    init(box: DropBox?, onSaved: @escaping () async -> Void) {
        self.box = box
        self.onSaved = onSaved
        _title = State(initialValue: box?.title ?? "")
        _emoji = State(initialValue: box?.emoji ?? "📸")
    }

    private var isNew: Bool { box == nil }
    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty && !saving }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("e.g. Family Fest 2026", text: $title) }
                Section("Emoji") {
                    TextField("📸", text: $emoji)
                        .onChange(of: emoji) { _, new in if let f = new.first { emoji = String(f) } }
                }
                if let error {
                    Text(error).font(.mlrCaption).foregroundStyle(Color.mlrDanger)
                }
            }
            .navigationTitle(isNew ? "New folder" : "Rename folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Create" : "Save") { Task { await save() } }.disabled(!canSave)
                }
            }
        }
    }

    private func save() async {
        saving = true; error = nil
        defer { saving = false }
        let t = title.trimmingCharacters(in: .whitespaces)
        let e = emoji.isEmpty ? "📸" : emoji
        do {
            if let box {
                try await env.dropBoxesService.updateBox(id: box.id, title: t, emoji: e)
            } else {
                try await env.dropBoxesService.createBox(title: t, emoji: e)
            }
            await onSaved()
            dismiss()
        } catch {
            self.error = "Couldn't save. Try again."
        }
    }
}
