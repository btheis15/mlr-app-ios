import SwiftUI

// MARK: - FestScheduleEditSheet
// Lets a fest editor or the assigned lead update location, description, and
// lead assignment for a schedule item. Title and day stay planner-managed.
// Lead linking lets a named person get the inline "Edit event" button on their
// own device — they only need to be in the app as a member.

struct FestScheduleEditSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let item: ScheduleItem
    let onSaved: () async -> Void

    @State private var location: String = ""
    @State private var description: String = ""
    @State private var leadName: String = ""
    @State private var linkedUser: Profile? = nil
    @State private var links: [LinkDraft] = []
    @State private var showPicker = false
    @State private var isSaving = false
    @State private var saveError: String? = nil

    /// Editable link row (ScheduleLink is immutable; this backs the text fields).
    struct LinkDraft: Identifiable { let id = UUID(); var label: String; var href: String }

    private var canAssignLead: Bool { env.isAdmin || env.festContentService.userCanEditFest }

    var body: some View {
        Form {
            Section("Details") {
                LabeledContent("Location") {
                    TextField("Where?", text: $location)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                }
                TextField("Description (optional)", text: $description, axis: .vertical)
                    .lineLimit(3...5)
            }

            if canAssignLead {
                Section {
                    if let user = linkedUser {
                        HStack(spacing: 10) {
                            AvatarView(profile: user, size: .small)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.name).font(.mlrScaled(14, weight: .medium))
                                Text("Linked — they can edit from the Fest tab")
                                    .font(.caption).foregroundStyle(Color.mlrTextMuted)
                            }
                            Spacer()
                            Button {
                                linkedUser = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Color.mlrTextSubtle)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        LabeledContent("Name") {
                            TextField("Lead's name", text: $leadName)
                                .multilineTextAlignment(.trailing)
                        }
                        Button("Link to an app member…") { showPicker = true }
                            .font(.mlrScaled(13))
                            .foregroundStyle(Color.mlrPrimary)
                    }
                } header: {
                    Text("Lead")
                } footer: {
                    Text("Linking to a member lets them edit this event from the Fest tab without needing admin access.")
                        .font(.caption)
                }
            }

            // Link buttons (migration 0142) — e.g. a sign-up form + an info doc.
            Section {
                ForEach($links) { $link in
                    VStack(spacing: 4) {
                        TextField("Label (e.g. Sign-up form)", text: $link.label)
                        HStack {
                            TextField("https://…", text: $link.href)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                            Button { links.removeAll { $0.id == link.id } } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(Color.mlrDanger)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Button { links.append(LinkDraft(label: "", href: "")) } label: {
                    Label("Add a link", systemImage: "plus.circle")
                }
            } header: {
                Text("Links")
            } footer: {
                Text("Buttons shown on the event — a sign-up form, an info doc, etc.")
                    .font(.caption)
            }

            if let err = saveError {
                Section { Text(err).foregroundStyle(Color.mlrDanger).font(.mlrScaled(13)) }
            }
        }
        .navigationTitle("Edit event")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.mlrFestParchment, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if isSaving { ProgressView() }
                else { Button("Save") { Task { await save() } }.fontWeight(.semibold) }
            }
        }
        .sheet(isPresented: $showPicker) {
            InlineMemberPickerSheet { profile in
                linkedUser = profile
                leadName   = profile.name
            }
        }
        .onAppear { seed() }
    }

    private func seed() {
        location    = (item.location == "TBD" ? nil : item.location) ?? ""
        description = item.description ?? ""
        leadName    = item.leads.first ?? ""
        links       = item.links.map { LinkDraft(label: $0.label ?? "", href: $0.href) }
    }

    private func save() async {
        isSaving = true; saveError = nil; defer { isSaving = false }
        guard let uid = UUID(uuidString: item.id) else { saveError = "Invalid item ID."; return }
        let name = (linkedUser?.name ?? leadName).trimBlank
        let leadId = linkedUser?.id ?? item.leadUserId
        // Keep only links with a real URL; label falls back to the URL when blank.
        let cleanedLinks: [ScheduleLink] = links.compactMap { d in
            let href = d.href.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !href.isEmpty else { return nil }
            return ScheduleLink(href: href, label: d.label.trimBlank)
        }
        do {
            try await env.festContentService.updateScheduleItem(
                itemId:      uid,
                location:    location.trimBlank,
                description: description.trimBlank,
                leadName:    name,
                leadUserId:  leadId,
                leadPhone:   nil,
                links:       cleanedLinks
            )
            await onSaved()
            dismiss()
        } catch {
            saveError = "Save failed. Check your connection."
        }
    }
}

// MARK: - FestCrewAssignSheet
// Admin, canEditFest users, and the chef can assign members to a dinner's crew.
// Assigned crew members see "Edit menu & details" on that dinner from the Fest tab.

struct FestCrewAssignSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let dinner: FestDinner
    let onSaved: () async -> Void

    @State private var crewIds: [UUID] = []
    @State private var crewProfiles: [Profile] = []
    @State private var showPicker = false
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var saveError: String? = nil

    var body: some View {
        Form {
            Section {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if crewProfiles.isEmpty {
                    Text("No crew assigned yet")
                        .foregroundStyle(Color.mlrTextMuted)
                        .font(.mlrScaled(14))
                } else {
                    ForEach(crewProfiles) { member in
                        HStack(spacing: 12) {
                            AvatarView(profile: member, size: .small)
                            Text(member.name).font(.mlrScaled(14))
                            Spacer()
                            Button {
                                crewIds.removeAll { $0 == member.id }
                                crewProfiles.removeAll { $0.id == member.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(Color.mlrDanger)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Button { showPicker = true } label: {
                    Label("Add crew member", systemImage: "person.badge.plus")
                        .font(.mlrScaled(14))
                        .foregroundStyle(Color.mlrPrimary)
                }
            } header: {
                Text("Crew")
            } footer: {
                Text("Crew members can update the menu, serving time, and location from the Fest tab.")
                    .font(.caption)
            }

            if let err = saveError {
                Section { Text(err).foregroundStyle(Color.mlrDanger).font(.mlrScaled(13)) }
            }
        }
        .navigationTitle("Manage crew")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.mlrFestParchment, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if isSaving { ProgressView() }
                else { Button("Save") { Task { await save() } }.fontWeight(.semibold) }
            }
        }
        .sheet(isPresented: $showPicker) {
            InlineMemberPickerSheet(excludeIds: crewIds) { profile in
                guard !crewIds.contains(profile.id) else { return }
                crewIds.append(profile.id)
                crewProfiles.append(profile)
            }
        }
        .task { await loadCrew() }
    }

    private func loadCrew() async {
        isLoading = true; defer { isLoading = false }
        crewIds = dinner.crewUserIds
        guard !crewIds.isEmpty else { return }
        let rows: [Profile] = (try? await supabase
            .from("profiles").select("*")
            .in("id", values: crewIds.map(\.uuidString))
            .execute().value) ?? []
        crewProfiles = crewIds.compactMap { id in rows.first { $0.id == id } }
    }

    private func save() async {
        isSaving = true; saveError = nil; defer { isSaving = false }
        guard let uid = UUID(uuidString: dinner.id) else { saveError = "Invalid dinner ID."; return }
        do {
            try await env.festContentService.updateDinnerCrew(dinnerId: uid, crewUserIds: crewIds)
            await onSaved()
            dismiss()
        } catch {
            saveError = "Save failed. Check your connection."
        }
    }
}

// MARK: - InlineMemberPickerSheet
// Searchable profile list used by both edit sheets. Tapping a row calls `onPick`
// and dismisses — caller handles single vs. multi-select semantics.

struct InlineMemberPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    var excludeIds: [UUID] = []
    let onPick: (Profile) -> Void

    @State private var profiles: [Profile] = []
    @State private var search: String = ""
    @State private var isLoading = false

    private var filtered: [Profile] {
        let excluded = Set(excludeIds)
        let pool = profiles.filter { !excluded.contains($0.id) }
        guard !search.isEmpty else { return pool }
        let q = search.lowercased()
        return pool.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { profile in
                Button {
                    onPick(profile)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(profile: profile, size: .small)
                        Text(profile.name)
                            .font(.mlrScaled(14, weight: .medium))
                            .foregroundStyle(Color.mlrText)
                    }
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $search, prompt: "Search members")
            .overlay {
                if isLoading { ProgressView() }
                else if !search.isEmpty && filtered.isEmpty {
                    ContentUnavailableView("No results for \"\(search)\"", systemImage: "person.slash")
                }
            }
            .navigationTitle("Pick a member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { await load() }
        }
    }

    private func load() async {
        isLoading = true; defer { isLoading = false }
        profiles = (try? await supabase
            .from("profiles").select("*")
            .order("display_name", ascending: true)
            .execute().value) ?? []
    }
}

private extension String {
    var trimBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
