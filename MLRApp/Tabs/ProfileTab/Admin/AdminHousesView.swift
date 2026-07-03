import SwiftUI

// MARK: - AdminHousesView
//
// Admin management for Houses (migration 0064): create, rename, re-emoji, and
// delete houses. Member assignment lives in AdminMembersView ("Assign house").
// Deleting a house un-assigns its members (their MLR access is unaffected) and
// removes its house-only chat + work items.

struct AdminHousesView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var editing: House?
    @State private var creating = false
    @State private var houseToDelete: House?
    @State private var showDeleteAlert = false
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.mlrDanger)
                        .font(.subheadline)
                }
            }

            Section {
                ForEach(env.housesService.houses) { house in
                    Button {
                        editing = house
                    } label: {
                        HStack(spacing: 12) {
                            Text(house.emoji).font(.mlrScaled(24))
                                .frame(width: 40, height: 40)
                                .background(Color.mlrPrimary.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(house.name)
                                    .font(.mlrScaled(15, weight: .semibold))
                                    .foregroundStyle(Color.mlrText)
                                if !house.description.isEmpty {
                                    Text(house.description)
                                        .font(.caption)
                                        .foregroundStyle(Color.mlrTextMuted)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.mlrScaled(12, weight: .semibold))
                                .foregroundStyle(Color.mlrTextSubtle)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            houseToDelete = house
                            showDeleteAlert = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                if env.housesService.houses.isEmpty {
                    Text("No houses yet — tap + to create one.")
                        .font(.mlrCaption)
                        .foregroundStyle(Color.mlrTextMuted)
                }
            } footer: {
                Text("A house is a private group with its own chat and work items. Assign members in Members → Assign house.")
            }
        }
        .navigationTitle("Houses")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { creating = true } label: { Image(systemName: "plus") }
            }
        }
        .task { await env.housesService.fetchHouses() }
        .refreshable { await env.housesService.fetchHouses() }
        .sheet(isPresented: $creating) {
            HouseEditor(house: nil, position: env.housesService.houses.count)
        }
        .sheet(item: $editing) { house in
            HouseEditor(house: house, position: house.position)
        }
        .alert("Delete house?", isPresented: $showDeleteAlert, presenting: houseToDelete) { house in
            Button("Delete \(house.name)", role: .destructive) {
                Task { await delete(house) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { house in
            Text("This un-assigns \(house.name)'s members and removes its chat and house-only work items. This can't be undone.")
        }
    }

    private func delete(_ house: House) async {
        do {
            try await env.housesService.deleteHouse(id: house.id)
        } catch {
            self.error = "Couldn't delete the house."
        }
    }
}

// MARK: - HouseEditor

private struct HouseEditor: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let house: House?
    let position: Int

    @State private var name: String
    @State private var emoji: String
    @State private var description: String
    @State private var saving = false
    @State private var error: String?

    init(house: House?, position: Int) {
        self.house = house
        self.position = position
        _name = State(initialValue: house?.name ?? "")
        _emoji = State(initialValue: house?.emoji ?? "🏠")
        _description = State(initialValue: house?.description ?? "")
    }

    private var editing: Bool { house != nil }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !saving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. MJT House", text: $name)
                }
                Section("Emoji") {
                    TextField("🏠", text: $emoji)
                        .onChange(of: emoji) { _, new in
                            // Keep just the first character (a single emoji).
                            if let first = new.first { emoji = String(first) }
                        }
                }
                Section("Description (optional)") {
                    TextField("What's this house about?", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(Color.mlrDanger)
                }
            }
            .navigationTitle(editing ? "Edit house" : "New house")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing ? "Save" : "Create") { Task { await save() } }
                        .disabled(!canSave)
                }
            }
        }
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = house?.slug ?? Self.slugify(trimmedName)
        do {
            try await env.housesService.saveHouse(
                id: house?.id,
                slug: slug,
                name: trimmedName,
                emoji: emoji.isEmpty ? "🏠" : emoji,
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                position: position
            )
            dismiss()
        } catch {
            self.error = "Couldn't save the house."
        }
    }

    /// Lowercase, spaces → hyphens, strip anything but a-z0-9 and hyphen.
    static func slugify(_ s: String) -> String {
        let lower = s.lowercased()
        var out = ""
        for ch in lower {
            if ch.isLetter || ch.isNumber { out.append(ch) }
            else if ch == " " || ch == "-" || ch == "_" { out.append("-") }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
