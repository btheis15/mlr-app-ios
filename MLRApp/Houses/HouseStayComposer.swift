import SwiftUI

// MARK: - HouseStayComposer
// Add or edit a stay on the house calendar. The signed-in member is always the
// one staying; they add anyone else coming along as free names (spouse, kids,
// the dog, a friend) — no account needed. Title + note are optional.
// Pass `existing` to edit; omit it to add a new stay.

struct HouseStayComposer: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let houseId: UUID
    let houseName: String
    let existing: HouseStay?
    let onSaved: () -> Void

    @State private var title: String
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var note: String
    @State private var guests: [String]
    @State private var guestDraft: String = ""

    @State private var isSaving = false
    @State private var saveError: String?

    init(houseId: UUID, houseName: String, existing: HouseStay? = nil, onSaved: @escaping () -> Void) {
        self.houseId = houseId
        self.houseName = houseName
        self.existing = existing
        self.onSaved = onSaved

        _title = State(initialValue: existing?.title ?? "")
        _note = State(initialValue: existing?.note ?? "")
        _guests = State(initialValue: existing?.guestNames ?? [])

        let start = existing?.startDateParsed ?? .now
        _startDate = State(initialValue: start)
        _endDate = State(initialValue: existing?.endDateParsed ?? start)
    }

    private var isEditing: Bool { existing != nil }
    private var memberFirstName: String {
        let name = env.currentProfile?.name ?? "You"
        return name.split(separator: " ").first.map(String.init) ?? name
    }
    private var headCount: Int { 1 + guests.count + (guestDraft.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : 1) }

    var body: some View {
        NavigationStack {
            Form {
                Section("What's the occasion? (optional)") {
                    TextField("Fishing weekend, opening up the cabin…", text: $title)
                }

                Section("When") {
                    DatePicker("Arriving", selection: $startDate, displayedComponents: .date)
                    DatePicker("Leaving", selection: $endDate, in: startDate..., displayedComponents: .date)
                }

                Section {
                    // The member is always coming (fixed).
                    HStack {
                        Image(systemName: "person.fill").foregroundStyle(Color.mlrPrimary)
                        Text("\(memberFirstName) (you)").foregroundStyle(Color.mlrText)
                        Spacer()
                    }
                    ForEach(Array(guests.enumerated()), id: \.offset) { idx, g in
                        HStack {
                            Image(systemName: "person").foregroundStyle(Color.mlrTextSubtle)
                            Text(g).foregroundStyle(Color.mlrText)
                        }
                    }
                    .onDelete { guests.remove(atOffsets: $0) }

                    HStack {
                        TextField("Add someone — wife, kids, the dog…", text: $guestDraft)
                            .onSubmit(addGuest)
                        Button(action: addGuest) {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(guestDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Who's coming (\(headCount))")
                } footer: {
                    Text("They don't need an account — just type their name.")
                }

                Section("Anything else? (optional)") {
                    TextField("Bringing the boat, arriving late Friday…", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                }

                if let saveError {
                    Section {
                        Text(saveError).font(.mlrCaption).foregroundStyle(Color.mlrDanger)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit stay" : "Add your stay")
            .navigationBarTitleDisplayMode(.inline)
            .tint(Color.mlrPrimary)
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
        }
    }

    private func addGuest() {
        let name = guestDraft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if !guests.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            guests.append(name)
        }
        guestDraft = ""
    }

    private func save() async {
        isSaving = true
        saveError = nil
        defer { isSaving = false }

        // Fold a half-typed guest name in so it isn't silently lost.
        addGuest()

        let startISO = HouseStay.iso.string(from: startDate)
        let endISO = HouseStay.iso.string(from: max(endDate, startDate))
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            if let existing {
                try await env.housesService.updateStay(
                    id: existing.id, startDate: startISO, endDate: endISO,
                    title: t.isEmpty ? nil : t, guestNames: guests, note: n.isEmpty ? nil : n)
            } else {
                try await env.housesService.createStay(
                    houseId: houseId, startDate: startISO, endDate: endISO,
                    title: t.isEmpty ? nil : t, guestNames: guests, note: n.isEmpty ? nil : n)
            }
            onSaved()
            dismiss()
        } catch {
            saveError = "Couldn't save your stay. Check your connection and try again."
            print("[HouseStayComposer] save error: \(error)")
        }
    }
}
