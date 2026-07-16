import SwiftUI

// MARK: - FestActivityEditSheet
//
// Inline edit for an "Anytime all week" Fest activity's details subset (location
// + details), the self-editable fields for a lead/crew member (migration 0110).
// Mirrors the web ActivityDetailsEditSheet. Loads the raw fest_activities row so
// editing works on the real fields (the card shows blurb + details merged).

struct FestActivityEditSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let activityId: UUID
    let title: String
    let onSaved: () async -> Void

    @State private var location = ""
    @State private var details = ""
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if loading {
                    Section { HStack { ProgressView(); Text("Loading…").foregroundStyle(Color.mlrTextMuted) } }
                } else {
                    Section("Location") {
                        TextField("Where does this happen?", text: $location)
                    }
                    Section("Details") {
                        TextField("What to know", text: $details, axis: .vertical)
                            .lineLimit(2...6)
                    }
                    if let error {
                        Section { Text(error).font(.mlrScaled(13)).foregroundStyle(Color.mlrDanger) }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() }
                    else { Button("Save") { Task { await save() } }.fontWeight(.semibold).disabled(loading) }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        if let raw = await env.festContentService.fetchActivityRaw(activityId: activityId) {
            location = raw.location ?? ""
            details = raw.details ?? ""
        }
        loading = false
    }

    private func save() async {
        saving = true; error = nil
        defer { saving = false }
        let loc = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let det = details.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await env.festContentService.updateActivityDetails(
                activityId: activityId,
                location: loc.isEmpty ? nil : loc,
                details: det.isEmpty ? nil : det
            )
            await onSaved()
            dismiss()
        } catch {
            self.error = "Couldn't save. Check your connection and try again."
        }
    }
}
