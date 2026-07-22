import SwiftUI

// MARK: - AdminFamilyRosterView (migration 0123)
//
// Admin editor for the family roster — people not on the app yet. Add someone
// with a name + email (+ optional phone/house); when they later verify with that
// email, a server trigger auto-links their new account. Hosted under Admin →
// Members. Mirrors the web AdminFamilyRoster.

struct AdminFamilyRosterView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var entries: [FamilyRosterEntry] = []
    @State private var houses: [House] = []
    @State private var loading = true
    @State private var editing: FamilyRosterEntry?
    @State private var addingNew = false

    private func houseName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return houses.first { $0.id == id }.map { "\($0.emoji) \($0.name)" }
    }

    var body: some View {
        List {
            if loading && entries.isEmpty {
                ForEach(0..<5, id: \.self) { _ in SkeletonShape(height: 40, cornerRadius: 8).listRowSeparator(.hidden) }
            } else if entries.isEmpty {
                Section {
                    Text("No one on the family roster yet. Add family members who aren't on the app so they still get house emails — their account auto-links when they sign in with the same email.")
                        .font(.mlrCaption).foregroundStyle(Color.mlrTextMuted)
                }
            } else {
                Section {
                    ForEach(entries) { entry in
                        Button { editing = entry } label: { row(entry) }.buttonStyle(.plain)
                    }
                } footer: {
                    Text("\(entries.count) on the roster")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Family Roster")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { addingNew = true } label: { Image(systemName: "plus") }.tint(Color.mlrPrimary)
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $editing) { entry in
            RosterEntryEditor(entry: entry, houses: houses) { Task { await load() } }
        }
        .sheet(isPresented: $addingNew) {
            RosterEntryEditor(entry: nil, houses: houses) { Task { await load() } }
        }
    }

    private func row(_ entry: FamilyRosterEntry) -> some View {
        HStack(spacing: 12) {
            AvatarView(url: entry.isLinked ? entry.linkedAvatarUrl : nil, size: .small)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName).font(.mlrScaled(15, weight: .medium)).foregroundStyle(Color.mlrText)
                if let email = entry.email, !email.isEmpty {
                    Text(email).font(.caption).foregroundStyle(Color.mlrTextMuted)
                }
                if let h = houseName(entry.houseId) {
                    Text(h).font(.caption2).foregroundStyle(Color.mlrTextSubtle)
                }
            }
            Spacer()
            if entry.isLinked {
                Text("On the app").font(.mlrScaled(10, weight: .bold))
                    .foregroundStyle(Color.mlrSuccess)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.mlrSuccess.opacity(0.15)).clipShape(Capsule())
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        if env.housesService.houses.isEmpty { await env.housesService.fetchHouses() }
        houses = env.housesService.houses
        entries = await env.familyRosterService.fetchRoster()
    }
}

// MARK: - Roster entry editor

private struct RosterEntryEditor: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let entry: FamilyRosterEntry?
    let houses: [House]
    let onSaved: () -> Void

    @State private var name: String
    @State private var email: String
    @State private var phone: String
    @State private var houseId: UUID?
    @State private var saving = false
    @State private var confirmDelete = false
    @State private var errorText: String?

    init(entry: FamilyRosterEntry?, houses: [House], onSaved: @escaping () -> Void) {
        self.entry = entry
        self.houses = houses
        self.onSaved = onSaved
        _name = State(initialValue: entry?.name ?? "")
        _email = State(initialValue: entry?.email ?? "")
        _phone = State(initialValue: entry?.phone ?? "")
        _houseId = State(initialValue: entry?.houseId)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Person") {
                    TextField("Name", text: $name)
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
                    TextField("Phone (optional)", text: $phone).keyboardType(.phonePad)
                }
                Section("House (optional)") {
                    Picker("House", selection: $houseId) {
                        Text("No house").tag(UUID?.none)
                        ForEach(houses) { h in Text("\(h.emoji) \(h.name)").tag(UUID?.some(h.id)) }
                    }
                }
                if entry != nil {
                    Section {
                        Button(role: .destructive) { confirmDelete = true } label: { Text("Remove from roster") }
                    }
                }
                if let errorText {
                    Section { Text(errorText).font(.mlrScaled(13)).foregroundStyle(Color.mlrDanger) }
                }
            }
            .navigationTitle(entry == nil ? "Add family member" : "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Remove \(name) from the roster?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { Task { await remove() } }
            }
        }
    }

    private func save() async {
        saving = true; errorText = nil
        defer { saving = false }
        do {
            try await env.familyRosterService.saveEntry(
                id: entry?.id,
                name: name,
                email: email.trimmingCharacters(in: .whitespaces).isEmpty ? nil : email,
                phone: phone.trimmingCharacters(in: .whitespaces).isEmpty ? nil : phone,
                houseId: houseId)
            onSaved()
            dismiss()
        } catch {
            errorText = "Couldn't save. Check the email isn't already used."
        }
    }

    private func remove() async {
        guard let id = entry?.id else { return }
        saving = true
        defer { saving = false }
        do { try await env.familyRosterService.deleteEntry(id: id); onSaved(); dismiss() }
        catch { errorText = "Couldn't remove." }
    }
}
