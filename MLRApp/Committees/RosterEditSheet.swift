import SwiftUI

// MARK: - RosterEditSheet
// Roster entry editor (migration 0055/0057, widened to leads by 0172/0177): add
// a new person or edit an existing one — link a real account or enter a name +
// email (shows as "Pending verification" until they verify), set phone, mark
// them a committee-level lead, and assign the roles they own. Each area can have
// any number of Leads (toggle "Lead of …"); everyone else in an area is a
// volunteer with no special call-out. Roster writes are gated by RLS to app
// admins OR this committee's own leads (never cross-committee). "Remove" deletes
// the entry (and thus their membership).

struct RosterEditSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let committee: Committee
    let entry: CommitteeRosterEntry?       // nil = adding a new person
    let areas: [String]
    let roleBased: Bool
    let onSaved: () -> Void

    struct Values: Equatable {
        var name = ""
        var email = ""
        var phone = ""
        var linkedUserId: UUID?
        var linkedName: String?
        var selectedAreas: Set<String> = []
        var leadAreas: Set<String> = []
        var isCommitteeLead = false
    }

    @State private var draft: EditorDraft<Values>
    @State private var showPicker = false
    @State private var removing = false
    @State private var confirmRemove = false
    @State private var removeError: String?

    init(committee: Committee, entry: CommitteeRosterEntry?, areas: [String], roleBased: Bool,
         onSaved: @escaping () -> Void) {
        self.committee = committee; self.entry = entry; self.areas = areas
        self.roleBased = roleBased; self.onSaved = onSaved
        var v = Values()
        if let entry {
            v.name = entry.name
            v.email = entry.email ?? ""
            v.phone = entry.phone ?? ""
            v.linkedUserId = entry.linkedUserId
            v.linkedName = entry.profile?.displayName
            v.isCommitteeLead = entry.isCommitteeLead
            for role in entry.roles {
                if role.hasSuffix(" \u{00B7} Lead") {
                    let area = String(role.dropLast(" \u{00B7} Lead".count))
                    v.selectedAreas.insert(area); v.leadAreas.insert(area)
                } else {
                    v.selectedAreas.insert(role)
                }
            }
        }
        _draft = State(initialValue: EditorDraft(v))
    }

    private var isNew: Bool { entry == nil }
    private var canSave: Bool { !draft.value.name.trimmingCharacters(in: .whitespaces).isEmpty && !removing }

    var body: some View {
        EditorSheet(title: isNew ? "Add member" : "Edit member",
                    isDirty: draft.isDirty,
                    canSave: canSave,
                    save: { try await save() }) {
            // Primary path: pick someone who already has an app account.
            Section {
                if draft.value.linkedUserId != nil {
                    HStack {
                        Label(draft.value.linkedName ?? "Linked account", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.mlrPrimary)
                        Spacer()
                        Button("Change") {
                            draft.value.linkedUserId = nil
                            draft.value.linkedName = nil
                        }
                    }
                } else {
                    Button {
                        showPicker = true
                    } label: {
                        Label("Choose a member", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.mlrScaled(16, weight: .semibold))
                            .foregroundStyle(Color.mlrPrimary)
                    }
                }
            } header: {
                Text("Member")
            } footer: {
                Text("Pick someone who has an account — their name, photo, and chat access come with it. Only type the fields below for someone not in the app yet (a one-off).")
            }

            Section("Details") {
                TextField("Name", text: $draft.value.name)
                    .autocorrectionDisabled()
                TextField("Email (for invite / contact)", text: $draft.value.email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Phone (optional)", text: $draft.value.phone)
                    .keyboardType(.phonePad)
            }

            Section {
                Toggle("Committee lead", isOn: $draft.value.isCommitteeLead)
                    .tint(Color.mlrPrimary)
            } footer: {
                Text("A lead of the whole committee — no subcommittee required. Gets the private Leads chat and can manage this committee's roster.")
            }

            if roleBased {
                Section {
                    ForEach(areas, id: \.self) { area in
                        HStack(spacing: 10) {
                            Text(area)
                            Spacer(minLength: 8)
                            // The ★ Lead pill only appears once the area is on;
                            // tap to toggle lead (a role can have many leads).
                            if draft.value.selectedAreas.contains(area) {
                                leadPill(for: area)
                            }
                            Toggle("", isOn: Binding(
                                get: { draft.value.selectedAreas.contains(area) },
                                set: { on in
                                    if on { draft.value.selectedAreas.insert(area) }
                                    else { draft.value.selectedAreas.remove(area); draft.value.leadAreas.remove(area) }
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

            if let removeError {
                Text(removeError).foregroundStyle(Color.mlrDanger).font(.footnote)
            }

            if !isNew {
                Section {
                    Button(role: .destructive) {
                        confirmRemove = true
                    } label: {
                        Label("Remove from committee", systemImage: "person.badge.minus")
                    }
                    .disabled(removing)
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            FestMemberPicker { profile in
                draft.value.linkedUserId = profile.id
                draft.value.linkedName = profile.name
                if draft.value.name.trimmingCharacters(in: .whitespaces).isEmpty { draft.value.name = profile.name }
                if draft.value.email.trimmingCharacters(in: .whitespaces).isEmpty, !profile.email.isEmpty {
                    draft.value.email = profile.email
                }
            }
        }
        .confirmationDialog("Remove from committee?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await remove() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes their roster entry and committee membership.")
        }
    }

    /// Compact "★ Lead" toggle pill shown beside an active area.
    private func leadPill(for area: String) -> some View {
        let isLead = draft.value.leadAreas.contains(area)
        return Button {
            if isLead { draft.value.leadAreas.remove(area) } else { draft.value.leadAreas.insert(area) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: isLead ? "star.fill" : "star")
                Text("Lead")
            }
            .font(.mlrScaled(12, weight: .semibold))
            .foregroundStyle(isLead ? Color.mlrPrimary : Color.mlrTextMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((isLead ? Color.mlrPrimary : Color.mlrTextMuted).opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.pressable)
    }

    private func roles() -> [String] {
        areas.compactMap { area in
            guard draft.value.selectedAreas.contains(area) else { return nil }
            return draft.value.leadAreas.contains(area) ? "\(area) · Lead" : area
        }
    }

    private func save() async throws {
        let v = draft.value
        let trimmedEmail = v.email.trimmingCharacters(in: .whitespaces)
        let trimmedPhone = v.phone.trimmingCharacters(in: .whitespaces)
        try await env.committeeService.saveRosterEntry(
            id: entry?.id,
            committeeSlug: committee.slug,
            name: v.name.trimmingCharacters(in: .whitespaces),
            email: trimmedEmail.isEmpty ? nil : trimmedEmail,
            phone: trimmedPhone.isEmpty ? nil : trimmedPhone,
            roles: roles(),
            linkedUserId: v.linkedUserId,
            isCommitteeLead: v.isCommitteeLead
        )
        onSaved()
    }

    private func remove() async {
        guard let entry, !removing else { return }
        removing = true; removeError = nil
        defer { removing = false }
        do {
            try await env.committeeService.deleteRosterEntry(id: entry.id)
            onSaved()
            Haptics.success()
            dismiss()
        } catch {
            removeError = "Couldn\u{2019}t remove. \(EditorError.message(error))"
            Haptics.error()
        }
    }
}
