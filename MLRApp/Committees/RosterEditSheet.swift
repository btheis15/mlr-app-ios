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
                // Primary path: pick someone who already has an app account.
                Section {
                    if linkedUserId != nil {
                        HStack {
                            Label(linkedName ?? "Linked account", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Color.mlrPrimary)
                            Spacer()
                            Button("Change") {
                                linkedUserId = nil
                                linkedName = nil
                            }
                        }
                    } else {
                        Button {
                            showPicker = true
                        } label: {
                            Label("Choose a member", systemImage: "person.crop.circle.badge.checkmark")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.mlrPrimary)
                        }
                    }
                } header: {
                    Text("Member")
                } footer: {
                    Text("Pick someone who has an account — their name, photo, and chat access come with it. Only type the fields below for someone not in the app yet (a one-off).")
                }

                Section("Details") {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
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
                            HStack(spacing: 10) {
                                Text(area)
                                Spacer(minLength: 8)
                                // The ★ Lead pill only appears once the area is on;
                                // tap to toggle lead (a role can have many leads).
                                if selectedAreas.contains(area) {
                                    leadPill(for: area)
                                }
                                Toggle("", isOn: Binding(
                                    get: { selectedAreas.contains(area) },
                                    set: { on in
                                        if on { selectedAreas.insert(area) }
                                        else { selectedAreas.remove(area); leadAreas.remove(area) }
                                    }
                                ))
                                .labelsHidden()
                                .tint(Color.mlrPrimary)
                            }
                        }
                    } header: {
                        Text("Roles")
                    } footer: {
                        Text("Turn on the areas this person helps with. Tap ★ Lead to make them a lead of that area (a role can have more than one lead); everyone else is a volunteer.")
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

    /// Compact "★ Lead" toggle pill shown beside an active area.
    private func leadPill(for area: String) -> some View {
        let isLead = leadAreas.contains(area)
        return Button {
            if isLead { leadAreas.remove(area) } else { leadAreas.insert(area) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: isLead ? "star.fill" : "star")
                Text("Lead")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isLead ? Color.mlrPrimary : Color.mlrTextMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((isLead ? Color.mlrPrimary : Color.mlrTextMuted).opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
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
