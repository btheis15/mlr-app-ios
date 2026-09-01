import SwiftUI
import Supabase

// MARK: - Adding someone to an event by hand (migration 0196)
//
// ⚠️ TWO PATHS, DELIBERATELY SEPARATE — they are not the same act:
//
//   • FAMILY — someone on the app, or on the family roster but not on the app
//     yet. Nobody sponsors them; they're already family.
//   • GUEST  — not family. A SPONSOR IS REQUIRED and picked from a dropdown,
//     never typed, so an outside guest is always traceable to a member.
//
// Collapsing these into one "type a name" box is exactly the confusion they
// exist to fix.

struct AddEventAttendeeSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let event: ResortEvent
    let onAdded: () -> Void

    private enum Mode: String, CaseIterable { case family, guest
        var label: String { self == .family ? "Family" : "Guest" }
    }

    @State private var mode: Mode = .family
    @State private var members: [Profile] = []
    @State private var roster: [FamilyRosterEntry] = []
    @State private var pickedMemberId: UUID?
    @State private var pickedRosterId: UUID?
    @State private var guestName = ""
    @State private var guestEmail = ""
    @State private var sponsorId: UUID?
    @State private var status = "going"
    @State private var saving = false
    @State private var error: String?

    private var canSave: Bool {
        switch mode {
        case .family: return pickedMemberId != nil || pickedRosterId != nil
        case .guest:
            // The sponsor is as required as the name.
            return !guestName.trimmingCharacters(in: .whitespaces).isEmpty && sponsorId != nil
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Who", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                switch mode {
                case .family: familySection
                case .guest:  guestSection
                }

                Section("Mark them as") {
                    Picker("Status", selection: $status) {
                        Text("Going").tag("going")
                        Text("Maybe").tag("maybe")
                        Text("Can't make it").tag("not_going")
                    }
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.mlrScaled(13)).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add someone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving { ProgressView() } else { Text("Add").fontWeight(.semibold) }
                    }
                    .disabled(!canSave || saving)
                }
            }
            .task { await load() }
        }
    }

    @ViewBuilder
    private var familySection: some View {
        Section("On the app") {
            Picker("Member", selection: $pickedMemberId) {
                Text("Nobody").tag(UUID?.none)
                ForEach(members) { m in Text(m.name).tag(UUID?.some(m.id)) }
            }
            .onChange(of: pickedMemberId) { _, new in if new != nil { pickedRosterId = nil } }
        }
        Section {
            Picker("Family roster", selection: $pickedRosterId) {
                Text("Nobody").tag(UUID?.none)
                ForEach(roster) { r in Text(r.name).tag(UUID?.some(r.id)) }
            }
            .onChange(of: pickedRosterId) { _, new in if new != nil { pickedMemberId = nil } }
        } header: {
            Text("Not on the app yet")
        } footer: {
            Text("Family who don't have an account. They can't RSVP themselves, so this is the only way they show up.")
        }
    }

    @ViewBuilder
    private var guestSection: some View {
        Section {
            TextField("Their name", text: $guestName)
            TextField("Email (optional)", text: $guestEmail)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
        } header: {
            Text("The guest")
        }
        Section {
            Picker("Sponsor", selection: $sponsorId) {
                Text("Pick someone").tag(UUID?.none)
                ForEach(members) { m in Text(m.name).tag(UUID?.some(m.id)) }
            }
        } header: {
            Text("Whose guest are they?")
        } footer: {
            Text("Required, and picked from the list rather than typed — so every guest at the resort traces back to a family member.")
        }
    }

    private func load() async {
        members = (try? await supabase.from("profiles")
            .select("*").order("display_name", ascending: true)
            .execute().value) ?? []
        // ⚠️ Only UNLINKED roster slots. A claimed one already has a profile and
        // would list the same person twice.
        roster = await env.familyRosterService.fetchRoster().filter { !$0.isLinked }
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            switch mode {
            case .family:
                try await env.eventMessageService.addFamilyMember(
                    eventId: event.id, userId: pickedMemberId,
                    rosterId: pickedRosterId, status: status)
            case .guest:
                guard let sponsorId else { return }
                try await env.eventMessageService.addGuest(
                    eventId: event.id,
                    name: guestName.trimmingCharacters(in: .whitespaces),
                    sponsorUserId: sponsorId, status: status,
                    email: guestEmail.trimmingCharacters(in: .whitespaces).isEmpty
                        ? nil : guestEmail.trimmingCharacters(in: .whitespaces))
            }
            Haptics.success()
            onAdded()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
