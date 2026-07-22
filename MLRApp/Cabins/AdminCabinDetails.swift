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
                                            .background(Color.mlrLake.opacity(0.15)).clipShape(Capsule())
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
                    .tint(Color.mlrPrimary)
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

    @State private var name: String
    @State private var roomCount: Int
    @State private var bedCount: Int
    @State private var notes: String
    @State private var active: Bool
    @State private var isSaving = false
    @State private var saveError: String?

    @State private var rooms: [CabinRoom] = []
    @State private var loadingRooms = true
    @State private var addingRoom = false

    @State private var approverUserId: UUID?
    @State private var approverName: String?
    @State private var showApproverPicker = false

    init(cabin: Cabin, onChanged: @escaping () async -> Void) {
        self.cabin = cabin
        self.onChanged = onChanged
        _name = State(initialValue: cabin.name)
        _roomCount = State(initialValue: cabin.roomCount)
        _bedCount = State(initialValue: cabin.bedCount ?? 0)
        _notes = State(initialValue: cabin.notes ?? "")
        _active = State(initialValue: cabin.active)
        _approverUserId = State(initialValue: cabin.approverUserId)
    }

    var body: some View {
        Form {
            Section("Cabin") {
                TextField("Name", text: $name)
                Stepper("\(roomCount) room\(roomCount == 1 ? "" : "s")", value: $roomCount, in: 0...40)
                Stepper(bedStepperLabel, value: $bedCount, in: 0...80)
                Toggle("Active (visible to members)", isOn: $active).tint(Color.mlrPrimary)
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
                Text("The approver reviews stay requests and can message guests for this place — they need not be an app admin.")
            }

            Section {
                TextField("Member-facing notes (optional)", text: $notes, axis: .vertical)
                    .lineLimit(2...6)
            } header: { Text("Notes") }

            if let saveError {
                Section { Text(saveError).font(.mlrScaled(13)).foregroundStyle(Color.mlrDanger) }
            }

            Section {
                Button {
                    Task { await saveCabin() }
                } label: {
                    HStack { Spacer()
                        if isSaving { ProgressView() } else { Text("Save cabin").fontWeight(.semibold) }
                        Spacer() }
                }
                .disabled(isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // Inline room CRUD.
            Section {
                if loadingRooms {
                    HStack { ProgressView(); Text("Loading rooms…").foregroundStyle(Color.mlrTextMuted) }
                } else {
                    ForEach(rooms) { room in
                        RoomEditRow(room: room,
                                    onSave: { await saveRoom($0) },
                                    onDelete: { await deleteRoom(room) })
                    }
                    if addingRoom {
                        RoomEditRow(room: CabinRoom(id: UUID(), cabinId: cabin.id, name: "",
                                                    beds: 1, active: true,
                                                    sortOrder: rooms.count, description: nil),
                                    isNew: true,
                                    onSave: { await saveRoom($0, isNew: true) },
                                    onDelete: { addingRoom = false })
                    }
                    Button { addingRoom = true } label: {
                        Label("Add a room", systemImage: "plus.circle.fill")
                            .foregroundStyle(Color.mlrPrimary)
                    }
                    .disabled(addingRoom)
                }
            } header: {
                Text("Rooms")
            } footer: {
                Text("Break the cabin into named rooms so members pick a specific one. Leave empty to use a plain room count.")
            }
        }
        .navigationTitle(cabin.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showApproverPicker) {
            FestMemberPicker { profile in Task { await setApprover(profile) } }
        }
        .task { await loadRooms(); await resolveApproverName() }
    }

    /// Once a cabin has named rooms, the count is "extra beds" not in a room.
    private var bedStepperLabel: String {
        let noun = rooms.isEmpty ? "bed" : "extra bed"
        return bedCount == 0 ? (rooms.isEmpty ? "Beds: not set" : "Extra beds: none")
                             : "\(bedCount) \(noun)\(bedCount == 1 ? "" : "s")"
    }

    private func loadRooms() async {
        loadingRooms = true
        defer { loadingRooms = false }
        rooms = await env.cabinService.fetchCabinRooms(cabinId: cabin.id)
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
            await onChanged()
        } catch {
            saveError = "Couldn't update the approver."
        }
    }

    private func saveCabin() async {
        isSaving = true; saveError = nil
        defer { isSaving = false }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await env.cabinService.saveCabin(
                id: cabin.id,
                name: name.trimmingCharacters(in: .whitespaces),
                roomCount: roomCount,
                bedCount: bedCount == 0 ? nil : bedCount,
                notes: trimmed.isEmpty ? nil : trimmed,
                active: active
            )
            await onChanged()
        } catch {
            saveError = "Couldn't save the cabin."
        }
    }

    private func saveRoom(_ room: CabinRoom, isNew: Bool = false) async {
        do {
            try await env.cabinService.saveCabinRoom(
                id: isNew ? nil : room.id,
                cabinId: cabin.id,
                name: room.name.trimmingCharacters(in: .whitespaces),
                beds: room.beds,
                description: room.description?.isEmpty == true ? nil : room.description,
                active: room.active,
                sortOrder: room.sortOrder
            )
            addingRoom = false
            await loadRooms()
        } catch {
            saveError = "Couldn't save the room."
        }
    }

    private func deleteRoom(_ room: CabinRoom) async {
        do {
            try await env.cabinService.deleteCabinRoom(id: room.id)
            await loadRooms()
        } catch {
            saveError = "Couldn't delete the room."
        }
    }
}

// MARK: - Room edit row (independent save)

private struct RoomEditRow: View {
    @State private var name: String
    @State private var beds: Int
    @State private var description: String
    @State private var active: Bool
    var isNew: Bool = false
    let onSave: (CabinRoom) async -> Void
    let onDelete: () async -> Void

    private let base: CabinRoom
    @State private var busy = false

    init(room: CabinRoom, isNew: Bool = false,
         onSave: @escaping (CabinRoom) async -> Void,
         onDelete: @escaping () async -> Void) {
        self.base = room
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        _name = State(initialValue: room.name)
        _beds = State(initialValue: room.beds)
        _description = State(initialValue: room.description ?? "")
        _active = State(initialValue: room.active)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Room name", text: $name)
                .font(.mlrScaled(14, weight: .medium))
            Stepper("\(beds) bed\(beds == 1 ? "" : "s")", value: $beds, in: 1...12)
            TextField("Description (optional)", text: $description, axis: .vertical)
                .font(.mlrScaled(13))
                .lineLimit(1...3)
            Toggle("Open for booking", isOn: $active).tint(Color.mlrPrimary).font(.mlrScaled(13))
            HStack(spacing: 16) {
                Button {
                    Task { busy = true; await onSave(edited); busy = false }
                } label: {
                    if busy { ProgressView() } else { Text(isNew ? "Add room" : "Save").fontWeight(.semibold) }
                }
                .font(.mlrScaled(13))
                .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button(role: .destructive) {
                    Task { busy = true; await onDelete(); busy = false }
                } label: {
                    Text(isNew ? "Discard" : "Delete").font(.mlrScaled(13))
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var edited: CabinRoom {
        CabinRoom(id: base.id, cabinId: base.cabinId, name: name, beds: beds,
                  active: active, sortOrder: base.sortOrder,
                  description: description.isEmpty ? nil : description)
    }
}

// MARK: - Add a place (create_cabin, migration 0114)

private struct AddPlaceSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let onCreated: () -> Void

    @State private var name = ""
    @State private var kind = "cabin"
    @State private var roomCount = 1
    @State private var bedCount = 0
    @State private var notes = ""
    @State private var approver: Profile?
    @State private var showApproverPicker = false
    @State private var saving = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Place") {
                    TextField("Name", text: $name)
                    Picker("Type", selection: $kind) {
                        Text("Cabin").tag("cabin")
                        Text("House").tag("house")
                    }
                    Stepper("\(roomCount) room\(roomCount == 1 ? "" : "s")", value: $roomCount, in: 0...40)
                    Stepper(bedCount == 0 ? "Beds: not set" : "\(bedCount) bed\(bedCount == 1 ? "" : "s")",
                            value: $bedCount, in: 0...80)
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
                Section("Notes") {
                    TextField("Member-facing notes (optional)", text: $notes, axis: .vertical).lineLimit(2...6)
                }
                if let errorText {
                    Section { Text(errorText).font(.mlrScaled(13)).foregroundStyle(Color.mlrDanger) }
                }
            }
            .navigationTitle("Add a place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Adding…" : "Add") { Task { await create() } }
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sheet(isPresented: $showApproverPicker) {
                FestMemberPicker { approver = $0 }
            }
        }
    }

    private func create() async {
        saving = true; errorText = nil
        defer { saving = false }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await env.cabinService.createCabin(
                name: name.trimmingCharacters(in: .whitespaces),
                kind: kind, roomCount: roomCount,
                bedCount: bedCount == 0 ? nil : bedCount,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                approverUserId: approver?.id)
            Haptics.success()
            onCreated()
            dismiss()
        } catch {
            errorText = "Couldn't add the place."
        }
    }
}
