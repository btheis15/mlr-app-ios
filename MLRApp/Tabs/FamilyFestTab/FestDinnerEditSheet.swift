import SwiftUI

// MARK: - FestDinnerEditSheet (entry point from a dinner's own screen)
//
// Mirrors web's two dinner editors (migration 0099):
//   • full editors (admin / can_edit_fest) get everything in one sheet: day,
//     emoji, title, chef, crew members, houses, served + prep, menu;
//   • the dinner's head chef or a crew member gets only the operational details:
//     menu, served time/location, prep time/location (`updateDinnerDetails`).
// The row is fetched first so the narrow editor starts from the real prep
// time/location (the display model does not carry them) instead of blanking them.

struct FestDinnerEditSheet: View {
    @Environment(AppEnvironment.self) private var env

    let dinner: FestDinner
    /// Called after a successful save so the caller can refresh content.
    let onSaved: () async -> Void

    var body: some View {
        FestDraftLoader(title: "Edit dinner", load: {
            guard let uid = UUID(uuidString: dinner.id) else { throw FestEditError.badId }
            return try await env.festContentService.dinnerDraft(id: uid)
        }) { d in
            if env.isFullFestEditor {
                FestDinnerFullEditor(draft: d, onSaved: onSaved)
            } else {
                FestDinnerDetailsEditor(draft: d, onSaved: onSaved)
            }
        }
    }
}

// MARK: - Narrow editor (chef / crew)

struct FestDinnerDetailsEditor: View {
    @Environment(AppEnvironment.self) private var env

    let onSaved: () async -> Void
    @State private var draft: EditorDraft<FestDinnerDraft>

    init(draft: FestDinnerDraft, onSaved: @escaping () async -> Void) {
        _draft = State(initialValue: EditorDraft(draft)); self.onSaved = onSaved
    }

    var body: some View {
        EditorSheet(
            title: "Edit \(draft.original.title)",
            isDirty: draft.isDirty,
            canSave: true,
            save: {
                guard let id = draft.value.id else { throw FestEditError.badId }
                let v = draft.value
                try await env.festContentService.updateDinnerDetails(
                    dinnerId: id.uuidString, menu: v.menu?.trimBlank,
                    servedTime: v.servedTime, servedLocation: v.servedLocation?.trimBlank,
                    prepTime: v.prepTime, prepLocation: v.prepLocation?.trimBlank)
                await env.festContentService.reload()
                await onSaved()
            }
        ) {
            Section("Menu") {
                EditorLongText("What\u{2019}s cooking (blank = TBD)", text: $draft.value.menu, lines: 3...6)
            }
            Section("Served") {
                EditorTimeField("Time", time: $draft.value.servedTime)
                FestLegacyTimeNote(value: draft.value.servedTime)
                EditorTextField("Location", text: $draft.value.servedLocation, placeholder: "e.g. Pavilion", limit: 120)
            }
            Section {
                EditorTimeField("Prep time", time: $draft.value.prepTime)
                FestLegacyTimeNote(value: draft.value.prepTime)
                EditorTextField("Prep location", text: $draft.value.prepLocation,
                                placeholder: "Same as served if blank", limit: 120)
            } header: {
                Text("Crew prep")
            } footer: {
                Text("Leave Prep Location blank if the crew meets at the same spot as dinner.")
            }
        }
    }
}

// MARK: - Full editor (fest editors) — used in place AND by the Planner

struct FestDinnerFullEditor: View {
    @Environment(AppEnvironment.self) private var env

    var onSaved: (() async -> Void)?
    @State private var draft: EditorDraft<FestDinnerDraft>
    @State private var houses: EditorDraft<String>
    @State private var showChefPicker = false

    init(draft: FestDinnerDraft, onSaved: (() async -> Void)? = nil) {
        _draft = State(initialValue: EditorDraft(draft))
        _houses = State(initialValue: EditorDraft(draft.houses.joined(separator: ", ")))
        self.onSaved = onSaved
    }

    private var dayOptions: [String] {
        var days = FestDays.options(env.festContentService.config)
        if !days.contains(draft.value.day) { days.insert(draft.value.day, at: 0) }
        return days
    }

    var body: some View {
        EditorSheet(
            title: draft.value.id == nil ? "Add dinner" : "Edit dinner",
            isDirty: draft.isDirty || houses.isDirty,
            canSave: !draft.value.title.trimmingCharacters(in: .whitespaces).isEmpty,
            save: {
                var d = draft.value
                d.title = d.title.trimmingCharacters(in: .whitespaces)
                d.houses = houses.value.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                try await env.festContentService.saveDinner(d)
                await env.festContentService.reload()
                await onSaved?()
            }
        ) {
            Section("Dinner") {
                Picker("Day", selection: $draft.value.day) {
                    ForEach(dayOptions, id: \.self) { Text(FestDays.label($0)).tag($0) }
                }
                EditorEmojiField("Emoji (optional)", emoji: $draft.value.emoji)
                EditorTextField("Title", text: $draft.value.title, placeholder: "e.g. Monday Dinner", limit: 80, required: true)
            }
            Section("Chef") {
                EditorTextField("Chef name(s)", text: $draft.value.chefName, limit: 120)
                if draft.value.chefUserId != nil {
                    HStack {
                        Label("Linked to an app member", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.mlrSuccess)
                        Spacer()
                        Button("Unlink", role: .destructive) { draft.value.chefUserId = nil }
                            .buttonStyle(.borderless)
                    }
                    .font(.mlrScaled(13))
                } else {
                    Button { showChefPicker = true } label: {
                        Label("Link a member", systemImage: "person.crop.circle.badge.plus")
                    }
                    .buttonStyle(.borderless)
                }
                EditorTextField("Phone (optional)", text: $draft.value.chefPhone, keyboard: .phonePad)
            }
            FestCrewField(ids: $draft.value.crewUserIds,
                          footer: "Crew members can update the menu, serving time, and location from the Fest tab.")
            Section {
                EditorTextField("Houses on crew", text: $houses.value, placeholder: "Comma-separated")
            } footer: {
                Text("House names say which families are teaming up. Crew members above are who get editing rights.")
            }
            Section("Served") {
                EditorTimeField("Time", time: $draft.value.servedTime)
                FestLegacyTimeNote(value: draft.value.servedTime)
                EditorTextField("Location", text: $draft.value.servedLocation, limit: 120)
            }
            Section("Prep") {
                EditorTimeField("Prep time", time: $draft.value.prepTime)
                FestLegacyTimeNote(value: draft.value.prepTime)
                EditorTextField("Prep location", text: $draft.value.prepLocation, limit: 120)
            }
            Section("Menu") { EditorLongText("Menu", text: $draft.value.menu, lines: 2...6) }
        }
        .sheet(isPresented: $showChefPicker) {
            InlineMemberPickerSheet { p in draft.value.chefUserId = p.id; draft.value.chefName = p.name }
        }
    }
}
