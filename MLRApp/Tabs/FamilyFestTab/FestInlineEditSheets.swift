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
    @State private var bring: String = ""
    @State private var leadName: String = ""
    @State private var linkedUser: Profile? = nil
    @State private var links: [LinkDraft] = []
    @State private var showPicker = false
    @State private var isSaving = false
    @State private var saveError: String? = nil

    // Sign-up config (admin / fest-editor only).
    @State private var signupEnabled = false
    @State private var signupMode = "interval"       // interval | slots | headcount
    @State private var signupCapacity = ""
    @State private var signupTeamSize = 1
    @State private var signupInstructions = ""
    @State private var signupStart = FestScheduleEditSheet.defaultTime(18, 0)
    @State private var signupEnd = FestScheduleEditSheet.defaultTime(20, 0)
    @State private var signupSlotMinutes = 15

    // Edit-and-notify (#393) — admin-only, default OFF; sends on save when on.
    @State private var notifyOnSave = false
    @State private var notifyMessage = ""
    @State private var notifyBanner = true
    @State private var notifyActivity = true
    @State private var notifyEmail = false

    static func defaultTime(_ h: Int, _ m: Int) -> Date {
        Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
    }

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
                TextField("What to bring (optional)", text: $bring, axis: .vertical)
                    .lineLimit(1...4)
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

            // Sign-ups (migrations 0135/0143) — authoring is admin / fest-editor only.
            if canAssignLead {
                Section {
                    Toggle("Take sign-ups", isOn: $signupEnabled)
                    if signupEnabled {
                        Picker("Type", selection: $signupMode) {
                            Text("Head count").tag("headcount")
                            Text("Time slots").tag("interval")
                            Text("Named slots").tag("slots")
                        }
                        LabeledContent("Capacity") {
                            TextField("No limit", text: $signupCapacity)
                                .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        }
                        Stepper("Team size: \(signupTeamSize)", value: $signupTeamSize, in: 1...8)
                        TextField("Instructions (optional)", text: $signupInstructions, axis: .vertical).lineLimit(1...3)
                        if signupMode == "interval" {
                            DatePicker("First slot", selection: $signupStart, displayedComponents: .hourAndMinute)
                            DatePicker("Ends by", selection: $signupEnd, displayedComponents: .hourAndMinute)
                            Picker("Slot length", selection: $signupSlotMinutes) {
                                ForEach([10, 15, 20, 30, 45, 60], id: \.self) { Text("\($0) min").tag($0) }
                            }
                        }
                    }
                } header: {
                    Text("Sign-ups")
                } footer: {
                    Text(signupMode == "slots"
                         ? "Named-slot lists are edited on the web for now."
                         : "Members can sign up right on the event.")
                        .font(.caption)
                }
            }

            // Edit-and-notify (#393) — admin-only. Off by default; when on, a send
            // fires on Save to everyone at Family Fest except those who RSVP'd "not
            // coming" (people who haven't RSVP'd still get it).
            if canAssignLead {
                Section {
                    Toggle("📣 Notify about this change", isOn: $notifyOnSave)
                    if notifyOnSave {
                        TextField("Message", text: $notifyMessage, axis: .vertical).lineLimit(1...3)
                        Toggle("Banner + push", isOn: $notifyBanner)
                        Toggle("Activity tab", isOn: $notifyActivity)
                        Toggle("Email", isOn: $notifyEmail)
                    }
                } header: {
                    Text("Tell everyone")
                } footer: {
                    if notifyOnSave {
                        Text("Sends on Save to everyone at Family Fest except those who said they're not coming.")
                            .font(.caption)
                    }
                }
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
        bring       = item.bring ?? ""
        leadName    = item.leads.first ?? ""
        links       = item.links.map { LinkDraft(label: $0.label ?? "", href: $0.href) }
        signupEnabled      = item.signupEnabled
        signupMode         = item.signupMode ?? "interval"
        signupCapacity     = item.signupCapacity.map(String.init) ?? ""
        signupTeamSize     = item.signupTeamSize ?? 1
        signupInstructions = item.signupInstructions ?? ""
        signupSlotMinutes  = item.signupSlotMinutes ?? 15
        if let s = Self.timeFromHHMM(item.signupStartTime) { signupStart = s }
        if let e = Self.timeFromHHMM(item.signupEndTime) { signupEnd = e }
        notifyMessage = "Update: \(item.title)"
    }

    private static func timeFromHHMM(_ s: String?) -> Date? {
        guard let parts = s?.split(separator: ":"), parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return defaultTime(h, m)
    }
    private static func hhmm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
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
        // Only admins/fest editors author sign-up config; leads leave it untouched.
        let signupConfig: FestContentService.SignupConfig? = canAssignLead
            ? .init(
                enabled: signupEnabled,
                mode: signupMode,
                capacity: Int(signupCapacity.trimmingCharacters(in: .whitespaces)),
                slotMinutes: signupMode == "interval" ? signupSlotMinutes : nil,
                startTime: signupMode == "interval" ? Self.hhmm(signupStart) : nil,
                endTime: signupMode == "interval" ? Self.hhmm(signupEnd) : nil,
                instructions: signupInstructions.trimBlank,
                teamSize: signupTeamSize > 1 ? signupTeamSize : nil)
            : nil
        do {
            try await env.festContentService.updateScheduleItem(
                itemId:      uid,
                location:    location.trimBlank,
                description: description.trimBlank,
                leadName:    name,
                leadUserId:  leadId,
                leadPhone:   nil,
                bring:       bring.trimBlank,
                links:       cleanedLinks,
                signup:      signupConfig
            )
            // Optional: tell everyone about the change (#393). Admin-only, opt-in.
            if canAssignLead, notifyOnSave {
                let msg = notifyMessage.trimBlank
                if let msg, (notifyBanner || notifyActivity || notifyEmail) {
                    do {
                        try await env.notificationsService.sendActivityNotify(
                            title: msg, body: nil,
                            banner: notifyBanner, activity: notifyActivity, email: notifyEmail,
                            scheduleItemId: item.id)
                    } catch {
                        // The edit saved; only the notification failed — surface it,
                        // don't dismiss, so they can retry the send.
                        saveError = "Saved, but the notification didn't send. Try again."
                        return
                    }
                }
            }
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
