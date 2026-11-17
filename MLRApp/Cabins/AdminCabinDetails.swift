import SwiftUI

// MARK: - AdminCabinDetails
//
// Admin editor for the cabins themselves (not bookings): edit a cabin's name,
// room/bed counts, member-facing notes, and active state (direct `cabins`
// update, migration 0089), plus inline CRUD of its named rooms (`cabin_rooms`,
// migration 0092). Mirrors the web AdminCabinDetails + CabinRoomsEditor. Each
// room row saves independently. Reached from Admin → Bookings → "Cabins".

struct AdminCabinDetails: View {
    @Environment(AppEnvironment.self) private var env
    @State private var cabins: [Cabin] = []
    @State private var isLoading = true
    @State private var addingPlace = false

    var body: some View {
        List {
            if isLoading && cabins.isEmpty {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonShape(height: 44, cornerRadius: 8).listRowSeparator(.hidden)
                }
            } else {
                ForEach(cabins) { cabin in
                    NavigationLink {
                        AdminCabinEditor(cabin: cabin) { await load() }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: cabin.active ? "house.lodge.fill" : "house.lodge")
                                .foregroundStyle(cabin.active ? Color.mlrPrimary : Color.mlrTextSubtle)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(cabin.name).font(.mlrScaled(15, weight: .semibold))
                                    if cabin.kind == "house" {
                                        Text("House").font(.mlrScaled(10, weight: .bold))
                                            .foregroundStyle(Color.mlrLake)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Color.mlrLake.mlrTint(0.15)).clipShape(Capsule())
                                    }
                                }
                                Text("\(cabin.roomCount) room\(cabin.roomCount == 1 ? "" : "s")"
                                     + (cabin.bedCount.map { " · \($0) beds" } ?? ""))
                                    .font(.caption).foregroundStyle(Color.mlrTextMuted)
                            }
                            Spacer()
                            if !cabin.active {
                                Text("Closed").font(.mlrScaled(11, weight: .semibold))
                                    .foregroundStyle(Color.mlrDanger)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Places to stay")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { addingPlace = true } label: { Image(systemName: "plus") }
                    .tint(Color.mlrPineText)
            }
        }
        .sheet(isPresented: $addingPlace) {
            AddPlaceSheet { Task { await load() } }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        cabins = await env.cabinService.fetchCabinsAdmin()
    }
}

// MARK: - Per-cabin editor

private struct AdminCabinEditor: View {
    @Environment(AppEnvironment.self) private var env
    let cabin: Cabin
    let onChanged: () async -> Void

    struct Values: Equatable {
        var name: String
        var kind: String
        var roomCount: Int
        var bedCount: Int
        var notes: String
        var active: Bool
    }

    @State private var draft: EditorDraft<Values>
    @State private var isSaving = false
    @State private var saveError: String?

    @State private var model = EditorListModel<CabinRoom>()
    @State private var loadingRooms = true
    @State private var editingRoom: CabinRoom?

    @State private var approverUserId: UUID?
    @State private var approverName: String?
    @State private var showApproverPicker = false

    init(cabin: Cabin, onChanged: @escaping () async -> Void) {
        self.cabin = cabin
        self.onChanged = onChanged
        _draft = State(initialValue: EditorDraft(Values(
            name: cabin.name, kind: cabin.kind, roomCount: cabin.roomCount,
            bedCount: cabin.bedCount ?? 0, notes: cabin.notes ?? "", active: cabin.active)))
        _approverUserId = State(initialValue: cabin.approverUserId)
    }

    private var canSave: Bool { !draft.value.name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Form {
            Section("Cabin") {
                EditorTextField("Name", text: $draft.value.name, limit: 80, required: true)
                Picker("Type", selection: $draft.value.kind) {
                    Text("Cabin").tag("cabin")
                    Text("House").tag("house")
                }
                Stepper("\(draft.value.roomCount) room\(draft.value.roomCount == 1 ? "" : "s")",
                        value: $draft.value.roomCount, in: 0...40)
                Stepper(bedStepperLabel, value: $draft.value.bedCount, in: 0...80)
                EditorToggle("Active (visible to members)", isOn: $draft.value.active)
            }

            Section {
                Button { showApproverPicker = true } label: {
                    HStack {
                        Text(approverUserId == nil ? "All admins" : (approverName ?? "Loading…"))
                            .foregroundStyle(Color.mlrText)
                        Spacer()
                        Image(systemName: "chevron.right").font(.mlrScaled(13)).foregroundStyle(Color.mlrTextSubtle)
                    }
                }
                if approverUserId != nil {
                    Button(role: .destructive) { Task { await setApprover(nil) } } label: {
                        Text("Clear — all admins approve")
                    }
                }
            } header: {
                Text("Who approves stays here")
            } footer: {
                Text("The approver reviews stay requests and can message guests for this place — they need not be an app admin. Changing the approver saves right away.")
            }

            Section("Notes") {
                EditorLongText("Member-facing notes (optional)", text: $draft.value.notes, lines: 2...6)
            }

            // Rooms: drag to reorder (Edit), swipe to delete, tap to edit.
            if loadingRooms {
                Section("Rooms") {
                    HStack { ProgressView(); Text("Loading rooms…").foregroundStyle(Color.mlrTextMuted) }
                }
            } else {
                EditorListSection(model, header: "Rooms") { room in
                    Button { editingRoom = room } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(room.name).foregroundStyle(Color.mlrText)
                                if !room.active {
                                    Text("Closed").font(.mlrScaled(11, weight: .semibold)).foregroundStyle(Color.mlrDanger)
                                }
                            }
                            Text("\(room.beds) bed\(room.beds == 1 ? "" : "s")"
                                 + ((room.description?.isEmpty ?? true) ? "" : " · \(room.description ?? "")"))
                                .font(.caption).foregroundStyle(Color.mlrTextMuted).lineLimit(1)
                        }
                    }
                }
                Section {
                    Button { editingRoom = newRoom() } label: {
                        Label("Add a room", systemImage: "plus.circle.fill").foregroundStyle(Color.mlrPineText)
                    }
                } footer: {
                    Text("Break the cabin into named rooms so members pick a specific one. Leave empty to use a plain room count. Room changes save right away.")
                }
            }
        }
        .editorListChrome(model, editButton: !model.items.isEmpty)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let saveError {
                EditorErrorBanner(message: saveError) { Task { await saveCabin() } }
            }
        }
        .navigationTitle(cabin.name)
        .navigationBarTitleDisplayMode(.inline)
        .editorUnsavedGuard(isDirty: draft.isDirty)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Save") { Task { await saveCabin() } }
                        .fontWeight(.semibold)
                        .disabled(!(draft.isDirty && canSave))
                }
            }
        }
        .sheet(isPresented: $showApproverPicker) {
            FestMemberPicker { profile in Task { await setApprover(profile) } }
        }
        .sheet(item: $editingRoom, onDismiss: { Task { await loadRooms() } }) { room in
            RoomEditSheet(room: room, isNew: !model.items.contains(where: { $0.id == room.id }))
        }
        .task {
            model.title = { $0.name }
            model.persistOrder = { ids in
                do { try await env.cabinService.saveCabinRoomOrder(ids: ids) }
                catch { await loadRooms(); throw error }
                await loadRooms()
            }
            model.commitDelete = { room in
                try await env.cabinService.deleteCabinRoom(id: room.id)
                await loadRooms()
            }
            await loadRooms(); await resolveApproverName()
        }
    }

    /// Once a cabin has named rooms, the count is "extra beds" not in a room.
    private var bedStepperLabel: String {
        let noun = model.items.isEmpty ? "bed" : "extra bed"
        let n = draft.value.bedCount
        return n == 0 ? (model.items.isEmpty ? "Beds: not set" : "Extra beds: none")
                      : "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    /// New rooms go at the end of the order.
    private func newRoom() -> CabinRoom {
        let next = (model.items.map(\.sortOrder).max() ?? -1) + 1
        return CabinRoom(id: UUID(), cabinId: cabin.id, name: "", beds: 1, active: true,
                         sortOrder: next, description: nil)
    }

    private func loadRooms() async {
        model.replace(await env.cabinService.fetchCabinRooms(cabinId: cabin.id))
        loadingRooms = false
    }

    private func resolveApproverName() async {
        guard let uid = approverUserId else { approverName = nil; return }
        let profile: Profile? = try? await supabase
            .from("profiles").select("*").eq("id", value: uid.uuidString).single().execute().value
        approverName = profile?.displayName
    }

    private func setApprover(_ profile: Profile?) async {
        do {
            try await env.cabinService.setCabinApprover(cabinId: cabin.id, approverUserId: profile?.id)
            approverUserId = profile?.id
            approverName = profile?.displayName
            saveError = nil
            Haptics.success()
            await onChanged()
        } catch {
            saveError = "Couldn\u{2019}t update the approver. \(EditorError.message(error))"
            Haptics.error()
        }
    }

    private func saveCabin() async {
        guard !isSaving, draft.isDirty, canSave else { return }   // no double submit
        isSaving = true; saveError = nil
        defer { isSaving = false }
        let v = draft.value
        let trimmed = v.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await env.cabinService.saveCabin(
                id: cabin.id,
                name: v.name.trimmingCharacters(in: .whitespaces),
                kind: v.kind,
                roomCount: v.roomCount,
                bedCount: v.bedCount == 0 ? nil : v.bedCount,
                notes: trimmed.isEmpty ? nil : trimmed,
                active: v.active
            )
            draft.markSaved()
            Haptics.success()
            await onChanged()
        } catch {
            saveError = "Couldn\u{2019}t save the cabin. \(EditorError.message(error))"
            Haptics.error()
        }
    }
}

// MARK: - Room editor sheet

private struct RoomEditSheet: View {
    @Environment(AppEnvironment.self) private var env
    @State private var draft: EditorDraft<CabinRoom>
    private let isNew: Bool

    init(room: CabinRoom, isNew: Bool) {
        self.isNew = isNew
        _draft = State(initialValue: EditorDraft(room))
    }

    var body: some View {
        EditorSheet(title: isNew ? "Add room" : "Edit room",
                    isDirty: draft.isDirty,
                    canSave: !draft.value.name.trimmingCharacters(in: .whitespaces).isEmpty,
                    save: { try await save() }) {
            Section {
                EditorTextField("Room name", text: $draft.value.name, limit: 60, required: true)
                Stepper("\(draft.value.beds) bed\(draft.value.beds == 1 ? "" : "s")",
                        value: $draft.value.beds, in: 1...12)
                EditorLongText("Description (optional)", text: Binding(
                    get: { draft.value.description ?? "" },
                    set: { draft.value.description = $0.isEmpty ? nil : $0 }), lines: 1...3)
                EditorToggle("Open for booking", isOn: $draft.value.active)
            }
        }
    }

    private func save() async throws {
        let r = draft.value
        try await env.cabinService.saveCabinRoom(
            id: isNew ? nil : r.id,
            cabinId: r.cabinId,
            name: r.name.trimmingCharacters(in: .whitespaces),
            beds: r.beds,
            description: r.description?.isEmpty == true ? nil : r.description,
            active: r.active,
            sortOrder: r.sortOrder
        )
    }
}

// MARK: - Add a place (create_cabin, migration 0114)

private struct AddPlaceSheet: View {
    @Environment(AppEnvironment.self) private var env
    let onCreated: () -> Void

    struct Values: Equatable {
        var name = ""
        var kind = "cabin"
        var roomCount = 1
        var bedCount = 0
        var notes = ""
    }

    @State private var draft = EditorDraft(Values())
    @State private var approver: Profile?
    @State private var showApproverPicker = false

    var body: some View {
        EditorSheet(title: "Add a place",
                    isDirty: draft.isDirty || approver != nil,
                    canSave: !draft.value.name.trimmingCharacters(in: .whitespaces).isEmpty,
                    save: { try await create() }) {
            Section("Place") {
                EditorTextField("Name", text: $draft.value.name, limit: 80, required: true)
                Picker("Type", selection: $draft.value.kind) {
                    Text("Cabin").tag("cabin")
                    Text("House").tag("house")
                }
                Stepper("\(draft.value.roomCount) room\(draft.value.roomCount == 1 ? "" : "s")",
                        value: $draft.value.roomCount, in: 0...40)
                Stepper(draft.value.bedCount == 0 ? "Beds: not set"
                        : "\(draft.value.bedCount) bed\(draft.value.bedCount == 1 ? "" : "s")",
                        value: $draft.value.bedCount, in: 0...80)
            }
            Section {
                Button { showApproverPicker = true } label: {
                    HStack {
                        Text(approver?.displayName ?? "All admins").foregroundStyle(Color.mlrText)
                        Spacer()
                        Image(systemName: "chevron.right").font(.mlrScaled(13)).foregroundStyle(Color.mlrTextSubtle)
                    }
                }
                if approver != nil {
                    Button(role: .destructive) { approver = nil } label: { Text("Clear — all admins approve") }
                }
            } header: {
                Text("Who approves stays here")
            } footer: {
                Text("Optional. The approver need not be an app admin.")
            }
            .sheet(isPresented: $showApproverPicker) {
                FestMemberPicker { approver = $0 }
            }
            Section("Notes") {
                EditorLongText("Member-facing notes (optional)", text: $draft.value.notes, lines: 2...6)
            }
        }
    }

    private func create() async throws {
        let v = draft.value
        let trimmedNotes = v.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await env.cabinService.createCabin(
            name: v.name.trimmingCharacters(in: .whitespaces),
            kind: v.kind, roomCount: v.roomCount,
            bedCount: v.bedCount == 0 ? nil : v.bedCount,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            approverUserId: approver?.id)
        onCreated()
    }
}
