import SwiftUI

// MARK: - MyCommitteeAreasSheet
//
// Self-service editor for the areas *I* work in on a role-based committee
// (set_my_committee_areas, migration 0073 — no lead/admin, no approval). Mirrors
// the web CommitteeJoin "Your areas" editor.

struct MyCommitteeAreasSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let committeeId: UUID
    let allAreas: [String]
    let current: [String]
    let onSaved: () -> Void

    @State private var selected: Set<String>
    @State private var isSaving = false
    @State private var saveError: String?

    init(committeeId: UUID, allAreas: [String], current: [String], onSaved: @escaping () -> Void) {
        self.committeeId = committeeId
        self.allAreas = allAreas
        self.current = current
        self.onSaved = onSaved
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
                    Text("Pick the areas you want to help with. You can change these anytime — no approval needed.")
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
        do {
            try await env.committeeService.setMyCommitteeAreas(
                committeeId: committeeId,
                areas: allAreas.filter { selected.contains($0) }   // keep canonical order
            )
            onSaved()
            dismiss()
        } catch {
            saveError = "Couldn't save your areas. Please try again."
        }
    }
}
