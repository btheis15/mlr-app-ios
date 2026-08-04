import SwiftUI

// MARK: - MyCommitteeAreasSheet
//
// Self-service editor for the areas *I* work in on a role-based committee.
// Mirrors web's MyCommitteeCard.save(): a plain member goes through
// `set_my_committee_areas` (migration 0073 — no lead/admin, no approval, and
// that RPC can't touch Lead status at all), but a LEAD or ADMIN writes the
// roster row directly via `saveRosterEntry` so their own "· Lead" standing on
// any area they KEEP is preserved. Getting this branch wrong is what used to
// let a lead accidentally self-demote just by editing their areas — never
// route a lead's save through `set_my_committee_areas`.

struct MyCommitteeAreasSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let committee: Committee
    let entry: CommitteeRosterEntry
    let allAreas: [String]
    /// True for an admin or this committee's own lead — saves preserve
    /// "· Lead" via `saveRosterEntry` instead of stripping it.
    let canManageRoster: Bool
    let onSaved: () -> Void

    @State private var selected: Set<String>
    @State private var isSaving = false
    @State private var saveError: String?

    private var leadAreas: [String] {
        entry.roles.filter { $0.hasSuffix(" · Lead") }.map { String($0.dropLast(" · Lead".count)) }
    }

    init(committee: Committee, entry: CommitteeRosterEntry, allAreas: [String], canManageRoster: Bool, onSaved: @escaping () -> Void) {
        self.committee = committee
        self.entry = entry
        self.allAreas = allAreas
        self.canManageRoster = canManageRoster
        self.onSaved = onSaved
        let current = entry.roles.map { $0.hasSuffix(" · Lead") ? String($0.dropLast(" · Lead".count)) : $0 }
        _selected = State(initialValue: Set(current))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(allAreas, id: \.self) { area in
                        Button {
                            if selected.contains(area) { selected.remove(area) } else { selected.insert(area) }
                        } label: {
                            HStack {
                                Text(area).foregroundStyle(Color.mlrText)
                                if leadAreas.contains(area) {
                                    Text("· Lead").font(.mlrScaled(12)).foregroundStyle(Color.mlrTextMuted)
                                }
                                Spacer()
                                if selected.contains(area) {
                                    Image(systemName: "checkmark").foregroundStyle(Color.mlrPrimary).fontWeight(.semibold)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Your areas")
                } footer: {
                    Text(leadAreas.isEmpty
                         ? "Pick the areas you want to help with. You can change these anytime — no approval needed."
                         : "Pick the areas you want to help with. Areas marked \"· Lead\" keep your Lead standing as long as you stay on them.")
                }

                if let saveError {
                    Section { Text(saveError).font(.mlrScaled(13)).foregroundStyle(Color.mlrDanger) }
                }
            }
            .navigationTitle("Your areas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving { ProgressView() }
                    else { Button("Save") { Task { await save() } }.fontWeight(.semibold) }
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        let orderedSelected = allAreas.filter { selected.contains($0) }   // keep canonical order
        do {
            if canManageRoster {
                // Keep "· Lead" on any area I still lead AND still have selected.
                let roles = orderedSelected.map { leadAreas.contains($0) ? "\($0) · Lead" : $0 }
                try await env.committeeService.saveRosterEntry(
                    id: entry.id, committeeSlug: committee.slug, name: entry.name,
                    email: entry.email, phone: entry.phone, roles: roles,
                    linkedUserId: entry.linkedUserId, isCommitteeLead: entry.isCommitteeLead
                )
            } else {
                try await env.committeeService.setMyCommitteeAreas(
                    committeeId: committee.id, areas: orderedSelected
                )
            }
            onSaved()
            dismiss()
        } catch {
            saveError = "Couldn't save your areas. Please try again."
        }
    }
}
