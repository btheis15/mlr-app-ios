import SwiftUI

// MARK: - FestDinnerEditSheet
// Lets a dinner's head chef or an assigned crew member (migration 0099) edit
// the operational details for their night: menu, when it's served, where it's
// served, and when/where the crew should prep. Deliberately narrower than the
// Planner's full dinner editor — day, title, chef, houses, and crew assignment
// stay admin/committee-managed there; this is just "the stuff you fill in the
// week-of." RLS on the server authorises the update (chef_user_id or any
// crew_user_ids match auth.uid()).

struct FestDinnerEditSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let dinner: FestDinner
    /// Called after a successful save so the caller can refresh content.
    let onSaved: () async -> Void

    @State private var menu: String = ""
    @State private var servedTime: String = ""
    @State private var servedLocation: String = ""
    @State private var prepTime: String = ""
    @State private var prepLocation: String = ""
    @State private var isSaving = false
    @State private var saveError: String? = nil

    var body: some View {
        Form {
            Section("Menu") {
                TextField("What's cooking (blank = TBD)", text: $menu, axis: .vertical)
                    .lineLimit(3...6)
            }

            Section("Served") {
                LabeledContent("Time") {
                    TextField("e.g. 6:00 PM", text: $servedTime)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                }
                LabeledContent("Location") {
                    TextField("e.g. Pavilion", text: $servedLocation)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                }
            }

            Section {
                LabeledContent("Time") {
                    TextField("e.g. 4:30 PM", text: $prepTime)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                }
                LabeledContent("Location") {
                    TextField("Same as served if blank", text: $prepLocation)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("Crew Prep")
            } footer: {
                Text("Leave Prep Location blank if the crew meets at the same spot as dinner.")
                    .font(.caption)
            }

            if let error = saveError {
                Section {
                    Text(error)
                        .font(.mlrScaled(13))
                        .foregroundStyle(Color.mlrDanger)
                }
            }
        }
        .navigationTitle("🍽️ Edit \(dinner.title)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Save") { Task { await save() } }
                        .fontWeight(.semibold)
                }
            }
        }
        .onAppear { seed() }
    }

    private func seed() {
        menu         = dinner.menu == "TBD" ? "" : dinner.menu
        servedTime   = dinner.time == "TBD" ? "" : dinner.time
        servedLocation = dinner.location ?? ""
        // prepTime / prepLocation aren't on the display FestDinner model — start blank
        // so the user can fill them in. They'll be in the DB after saving once.
        prepTime     = ""
        prepLocation = ""
    }

    private func save() async {
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            try await env.festContentService.updateDinnerDetails(
                dinnerId: dinner.id,
                menu: menu.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                servedTime: servedTime.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                servedLocation: servedLocation.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                prepTime: prepTime.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                prepLocation: prepLocation.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            )
            await onSaved()
            dismiss()
        } catch {
            saveError = "Save failed. Check your connection and try again."
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
