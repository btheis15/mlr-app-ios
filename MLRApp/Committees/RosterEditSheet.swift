import SwiftUI

// MARK: - RosterEditSheet
// App-admin editor for a committee roster entry (migration 0055/0057): add a new
// person or edit an existing one — link a real account or enter a name + email
// (shows as "Pending verification" until they verify), set phone, and assign the
// roles they own. Each area can have any number of Leads (toggle "Lead of …");
// everyone else in an area is a volunteer with no special call-out. Roster writes
// are admin-gated by RLS. "Remove" deletes the entry (and thus their membership).

struct RosterEditSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let committee: Committee
    let entry: CommitteeRosterEntry?       // nil = adding a new person
    let areas: [String]
    let roleBased: Bool
    let onSaved: () -> Void

    @State private var name = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var linkedUserId: UUID?
    @State private var linkedName: String?
    @State private var selectedAreas: Set<String> = []
    @State private var leadAreas: Set<String> = []

    @State private var showPicker = false
    @State private var saving = false
    @State private var error: String?

    private var isNew: Bool { entry == nil }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !saving }

    var body: some View {
        NavigationStack {
            Form {
                Section("Person") {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()

                    if linkedUserId != nil {
                        HStack {
                            Label(linkedName ?? "Linked account", systemImage: "link")
                                .foregroundStyle(Color.mlrPrimary)
                            Spacer()
                            Button("Unlink") {
                                linkedUserId = nil
                                linkedName = nil
                            }
                            .foregroundStyle(Color.mlrDanger)
                        }
                    } else {
                        Button {
                            showPicker = true
                        } label: {
                            Label("Link a member account", systemImage: "person.crop.circle.badge.plus")
                        }
                    }

                    TextField("Email (for invite / contact)", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Phone (optional)", text: $phone)
                        .keyboardType(.phonePad)
                }

                if roleBased {
                    Section {
                        ForEach(areas, id: \.self) { area in
                            VStack(spacing: 6) {
                                Toggle(area, isOn: Binding(
                                    get: { selectedAreas.contains(area) },
                                    set: { on in
                                        if on { selectedAreas.insert(area) }
                                        else { selectedAreas.remove(area); leadAreas.remove(area) }
                                    }
                                ))
                                .tint(Color.mlrPrimary)
                                if selectedAreas.contains(area) {
                                    Toggle("Lead of \(area)", isOn: Binding(
                                        get: { leadAreas.contains(area) },
                                        set: { on in if on { leadAreas.insert(area) } else { leadAreas.remove(area) } }
                                    ))
                                    .tint(Color.mlrPrimary)
                                    .font(.system(size: 13))
                                    .padding(.leading, 12)
                                }
                            }
                        }
                    } header: {
                        Text("Roles")
                    } footer: {
                        Text("Pick the areas this person helps with. Mark any as Lead (a role can have more than one lead); everyone else is a volunteer.")
                    }
                }

                if let error {
                    Text(error).foregroundStyle(Color.mlrDanger).font(.footnote)
                }

                if !isNew {
                    Section {
                        Button(role: .destructive) {
                            Task { await remove() }
                        } label: {
                            Label("Remove from committee", systemImage: "person.badge.minus")
                        }
                        .disabled(saving)
                    }
                }
            }
            .navigationTitle(isNew ? "Add member" : "Edit member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(!canSave)
                }
            }
            .sheet(isPresented: $showPicker) {
                FestMemberPicker { profile in
                    linkedUserId = profile.id
                    linkedName = profile.name
                    if name.trimmingCharacters(in: .whitespaces).isEmpty { name = profile.name }
                    if email.trimmingCharacters(in: .whitespaces).isEmpty, !profile.email.isEmpty {
                        email = profile.email
                    }
                }
            }
            .onAppear(perform: seed)
        }
    }

    private func seed() {
        guard let entry, name.isEmpty, selectedAreas.isEmpty else { return }
        name = entry.name
        email = entry.email ?? ""
        phone = entry.phone ?? ""
        linkedUserId = entry.linkedUserId
        linkedName = entry.profile?.displayName
        for role in entry.roles {
            if role.hasSuffix(" · Lead") {
                let area = String(role.dropLast(" · Lead".count))
                selectedAreas.insert(area); leadAreas.insert(area)
            } else {
                selectedAreas.insert(role)
            }
        }
    }

    private func roles() -> [String] {
        areas.compactMap { area in
            guard selectedAreas.contains(area) else { return nil }
            return leadAreas.contains(area) ? "\(area) · Lead" : area
        }
    }

    private func save() async {
        saving = true; error = nil
        defer { saving = false }
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        let trimmedPhone = phone.trimmingCharacters(in: .whitespaces)
        do {
            try await env.committeeService.saveRosterEntry(
                id: entry?.id,
                committeeSlug: committee.slug,
                name: name.trimmingCharacters(in: .whitespaces),
                email: trimmedEmail.isEmpty ? nil : trimmedEmail,
                phone: trimmedPhone.isEmpty ? nil : trimmedPhone,
                roles: roles(),
                linkedUserId: linkedUserId
            )
            onSaved()
            dismiss()
        } catch {
            self.error = "Couldn't save. \(error.localizedDescription)"
        }
    }

    private func remove() async {
        guard let entry else { return }
        saving = true; error = nil
        defer { saving = false }
        do {
            try await env.committeeService.deleteRosterEntry(id: entry.id)
            onSaved()
            dismiss()
        } catch {
            self.error = "Couldn't remove. \(error.localizedDescription)"
        }
    }
}
