import SwiftUI
import Supabase

// MARK: - Fest in-place editors (schedule events, dinner crew)
//
// Everything here runs on the EditorKit (real server errors, unsaved guard, no
// double submit) and mirrors web's rules for who may edit what:
//   • full editors (admin / can_edit_fest) get the whole event editor, the same
//     fields as the Planner (`FestScheduleFullEditor`);
//   • an event's lead or crew member (not a full editor) gets only web's narrower
//     `updateScheduleDetails` set: location, description, what to bring, links.
// The pencil is shown to exactly those people, never while an admin previews as
// another member, and never on the read-only Past Years page (that page uses its
// own read-only rows).

// MARK: - Who may edit

extension AppEnvironment {
    /// Admin or fest-committee editor (server-authoritative flag cached by
    /// `FestContentService.canEditFest()`), hidden while previewing as someone else.
    var isFullFestEditor: Bool {
        isSignedIn && !isPreviewing && (isAdmin || festContentService.userCanEditFest)
    }

    /// Web's rule for the Edit button on an event: full editor, or that event's lead/crew.
    func canEditFestEvent(_ item: ScheduleItem) -> Bool {
        guard isSignedIn, !isPreviewing else { return false }
        if isFullFestEditor { return true }
        guard let me = currentProfile?.id else { return false }
        return item.leadUserId == me || item.crewUserIds.contains(me)
    }

    /// Web's rule for a dinner: full editor, or that dinner's chef/crew.
    func canEditFestDinner(chefUserId: UUID?, crewUserIds: [UUID]) -> Bool {
        guard isSignedIn, !isPreviewing else { return false }
        if isFullFestEditor { return true }
        guard let me = currentProfile?.id else { return false }
        return chefUserId == me || crewUserIds.contains(me)
    }
}

// MARK: - Edit pencil (one look everywhere in Fest)
// EditorKit has no `EditPencil` yet; unify with it at integration.

struct FestEditPencil: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: "pencil.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(Color.mlrFest)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("Edit \(label)")
    }
}

// MARK: - Member directory (throws, so callers can show an error + retry)

enum FestMemberDirectory {
    static func all() async throws -> [Profile] {
        try await supabase.from("profiles").select("*")
            .order("display_name", ascending: true).execute().value
    }
    static func profiles(ids: [UUID]) async throws -> [Profile] {
        guard !ids.isEmpty else { return [] }
        return try await supabase.from("profiles").select("*")
            .in("id", values: ids.map(\.uuidString)).execute().value
    }
}

// MARK: - Draft loader
// Fetches one row, then hands it to the editor. Failure shows the real error with Retry.

struct FestDraftLoader<Draft, Content: View>: View {
    let title: String
    let load: () async throws -> Draft?
    @ViewBuilder let content: (Draft) -> Content

    @Environment(\.dismiss) private var dismiss
    @State private var draft: Draft?
    @State private var error: String?
    @State private var gone = false

    init(title: String, load: @escaping () async throws -> Draft?,
         @ViewBuilder content: @escaping (Draft) -> Content) {
        self.title = title; self.load = load; self.content = content
    }

    var body: some View {
        if let draft {
            content(draft)
        } else {
            NavigationStack {
                Group {
                    if let error {
                        ContentUnavailableView {
                            Label("Couldn't load", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Retry") { Task { await run() } }
                        }
                    } else if gone {
                        ContentUnavailableView("No longer exists", systemImage: "trash",
                                               description: Text("This was deleted by someone else."))
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            }
            .task { await run() }
        }
    }

    private func run() async {
        error = nil
        do {
            if let d = try await load() { draft = d } else { gone = true }
        } catch {
            self.error = EditorError.message(error)
        }
    }
}

// MARK: - Legacy time note
// Older rows hold free text ("after lunch"). The kit shows them untouched; the
// picker can't display them, so say what is stored until the editor changes it.

struct FestLegacyTimeNote: View {
    let value: String?
    var body: some View {
        if let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty, EditorTimeField.parts(v) == nil {
            Text("Currently saved as \u{201C}\(v)\u{201D}. Picking a time replaces it.")
                .font(.mlrCaption).foregroundStyle(Color.mlrTextMuted)
        }
    }
}

// MARK: - Crew picker field (a Form Section)

struct FestCrewField: View {
    @Binding var ids: [UUID]
    var footer = "Crew members also get editing rights for this one."

    @State private var people: [UUID: Profile] = [:]
    @State private var loadError: String?
    @State private var showPicker = false

    var body: some View {
        Section {
            ForEach(ids, id: \.self) { id in
                HStack(spacing: 12) {
                    if let p = people[id] {
                        AvatarView(profile: p, size: .small)
                        Text(p.name).font(.mlrScaled(14))
                    } else {
                        Image(systemName: "person.circle").foregroundStyle(Color.mlrTextSubtle)
                        Text("Member").font(.mlrScaled(14)).foregroundStyle(Color.mlrTextMuted)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        withAnimation(MLRMotion.reduceMotion ? nil : MLRMotion.spring) { ids.removeAll { $0 == id } }
                        Haptics.tap()
                    } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(people[id]?.name ?? "member") from crew")
                }
            }
            if let loadError {
                HStack(alignment: .top) {
                    Text("Couldn't load names: \(loadError)").font(.mlrCaption).foregroundStyle(Color.mlrDanger)
                    Spacer()
                    Button("Retry") { Task { await loadNames() } }.buttonStyle(.borderless)
                }
            }
            Button { showPicker = true } label: { Label("Add crew member", systemImage: "person.badge.plus") }
                .buttonStyle(.borderless)
                .task(id: ids) { await loadNames() }
                .sheet(isPresented: $showPicker) {
                    InlineMemberPickerSheet(excludeIds: ids) { p in
                        guard !ids.contains(p.id) else { return }
                        people[p.id] = p
                        ids.append(p.id)
                    }
                }
        } header: {
            Text("Crew")
        } footer: {
            Text(footer)
        }
    }

    private func loadNames() async {
        let missing = ids.filter { people[$0] == nil }
        guard !missing.isEmpty else { loadError = nil; return }
        do {
            for p in try await FestMemberDirectory.profiles(ids: missing) { people[p.id] = p }
            loadError = nil
        } catch {
            loadError = EditorError.message(error)
        }
    }
}

// MARK: - FestScheduleEditSheet (entry point used from the event's own screen)
//
// Full editors get the whole event editor; a lead/crew member gets web's narrower
// details editor. `onSaved` runs after the write so the screen underneath refreshes.

struct FestScheduleEditSheet: View {
    @Environment(AppEnvironment.self) private var env

    let item: ScheduleItem
    let onSaved: () async -> Void

    var body: some View {
        if env.isFullFestEditor {
            FestDraftLoader(title: "Edit event", load: {
                guard let uid = UUID(uuidString: item.id) else { throw FestEditError.badId }
                return try await env.festContentService.scheduleDraft(id: uid)
            }) { d in
                FestScheduleFullEditor(draft: d, onSaved: onSaved)
            }
        } else {
            FestScheduleDetailsEditor(item: item, onSaved: onSaved)
        }
    }
}

enum FestEditError: LocalizedError {
    case badId, notificationFailed(String)
    var errorDescription: String? {
        switch self {
        case .badId: return "This item has an invalid id."
        case .notificationFailed(let m): return "Saved, but the notification didn't send: \(m) Tap Retry to send it."
        }
    }
}

// MARK: - Narrow editor (event lead / crew): location, description, bring, links

struct FestScheduleDetailsEditor: View {
    @Environment(AppEnvironment.self) private var env

    struct Values: Equatable {
        var location: String?
        var description: String?
        var bring: String?
        var links: [EditorLink]
    }

    let item: ScheduleItem
    let onSaved: () async -> Void
    @State private var draft: EditorDraft<Values>

    init(item: ScheduleItem, onSaved: @escaping () async -> Void) {
        self.item = item; self.onSaved = onSaved
        _draft = State(initialValue: EditorDraft(Values(
            location: item.location == "TBD" ? nil : item.location,
            description: item.description,
            bring: item.bring,
            links: item.links.map { EditorLink(label: $0.label ?? "", url: $0.href) })))
    }

    var body: some View {
        EditorSheet(
            title: "Edit event",
            isDirty: draft.isDirty,
            canSave: linksOK(draft.value.links),
            save: {
                guard let uid = UUID(uuidString: item.id) else { throw FestEditError.badId }
                let v = draft.value
                try await env.festContentService.updateScheduleDetails(
                    itemId: uid, location: v.location?.trimBlank, description: v.description?.trimBlank,
                    bring: v.bring?.trimBlank, links: v.links)
                await env.festContentService.reload()
                await onSaved()
            }
        ) {
            Section {
                EditorTextField("Location", text: $draft.value.location, placeholder: "Where (blank = TBD)", limit: 120)
                EditorLongText("Details", text: $draft.value.description, placeholder: "What it is, when to arrive\u{2026}", lines: 2...5)
                EditorLongText("What to bring (optional)", text: $draft.value.bring, lines: 1...3)
            } header: {
                Text("Details")
            } footer: {
                Text("Location, details, and what to bring \u{2014} since you\u{2019}re running this one.")
            }
            Section("Links") {
                EditorLinksField("Links (optional)", links: $draft.value.links)
            }
        }
    }
}

/// Blank rows are dropped on save; any row with text must be a valid web address.
private func linksOK(_ links: [EditorLink]) -> Bool {
    links.allSatisfy { $0.url.trimmingCharacters(in: .whitespaces).isEmpty || EditorLink.isValidURL($0.url) }
}

// MARK: - Full event editor (fest editors) — used in place AND by the Planner

struct FestScheduleFullEditor: View {
    @Environment(AppEnvironment.self) private var env

    var onSaved: (() async -> Void)?
    @State private var draft: EditorDraft<FestScheduleDraft>
    @State private var imageKey = UUID().uuidString
    @State private var showLeadPicker = false

    // Per-slot capacity editing (named-slot mode, existing events only).
    @State private var slotList: [ScheduleSlot] = []
    @State private var slotCapacities: [UUID: String] = [:]

    // Edit-and-notify (#393): opt-in, sent after a successful save.
    @State private var notifyOn = false
    @State private var notifyMessage = ""
    @State private var notifyBanner = true
    @State private var notifyActivity = true
    @State private var notifyEmail = false

    init(draft: FestScheduleDraft, onSaved: (() async -> Void)? = nil) {
        _draft = State(initialValue: EditorDraft(draft))
        _notifyMessage = State(initialValue: "Update: \(draft.title)")
        self.onSaved = onSaved
    }

    private var isNew: Bool { draft.value.id == nil }
    private var service: FestContentService { env.festContentService }

    private var dayOptions: [String] {
        var days = FestDays.options(service.config)
        if !days.contains(draft.value.day) { days.insert(draft.value.day, at: 0) }
        return days
    }

    private var slotsDirty: Bool {
        slotList.contains { slot in
            guard let raw = slotCapacities[slot.id] else { return false }
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t.isEmpty ? nil : Int(t)) != slot.capacity
        }
    }

    private var canSave: Bool {
        let d = draft.value
        return !d.title.trimmingCharacters(in: .whitespaces).isEmpty
            && (d.anytime || !d.day.isEmpty)
            && d.signup.isValid
            && linksOK(d.links)
    }

    private var showsSlots: Bool {
        !isNew && draft.value.signup.enabled && draft.value.signup.mode == "slots"
    }

    var body: some View {
        EditorSheet(
            title: isNew ? "Add event" : "Edit event",
            isDirty: draft.isDirty || slotsDirty || notifyOn,
            canSave: canSave,
            save: save
        ) {
            Section("What & when") {
                EditorEmojiField("Emoji (optional)", emoji: $draft.value.emoji)
                EditorTextField("Title", text: $draft.value.title, placeholder: "e.g. Lake Day", limit: 80, required: true)
                EditorToggle("Anytime (no set day)", isOn: $draft.value.anytime.animation(),
                             caption: "Shows in \u{201C}Anytime all week\u{201D} instead of on a day.")
                if !draft.value.anytime {
                    Picker("Day", selection: $draft.value.day) {
                        ForEach(dayOptions, id: \.self) { Text(FestDays.label($0)).tag($0) }
                    }
                }
                EditorTimeField("Starts", time: $draft.value.startTime)
                FestLegacyTimeNote(value: draft.value.startTime)
                if draft.value.startTime != nil {
                    EditorTimeField("Ends (optional)", time: $draft.value.endTime)
                    FestLegacyTimeNote(value: draft.value.endTime)
                }
                EditorTextField("Location", text: $draft.value.location, placeholder: "Blank = TBD", limit: 120)
            }

            Section {
                EditorTextField("Name", text: $draft.value.leadName, limit: 80)
                if draft.value.leadUserId != nil {
                    HStack {
                        Label("Linked to an app member", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.mlrSuccess)
                        Spacer()
                        Button("Unlink", role: .destructive) { draft.value.leadUserId = nil }
                            .buttonStyle(.borderless)
                    }
                    .font(.mlrScaled(13))
                } else {
                    Button { showLeadPicker = true } label: {
                        Label("Link a member", systemImage: "person.crop.circle.badge.plus")
                    }
                    .buttonStyle(.borderless)
                }
                EditorTextField("Phone (optional)", text: $draft.value.leadPhone, keyboard: .phonePad)
            } header: {
                Text("Who\u{2019}s in charge")
            } footer: {
                Text("A linked lead can edit this event\u{2019}s location and details from the Fest tab.")
            }

            FestCrewField(ids: $draft.value.crewUserIds)

            Section("More details") {
                EditorLongText("Details", text: $draft.value.description, placeholder: "What it is, when to arrive\u{2026}", lines: 2...5)
                EditorTextField("What to bring (optional)", text: $draft.value.bring, limit: 160)
                EditorImageField("Photo (optional)", url: $draft.value.imageUrl) { img in
                    try await env.mediaService.uploadSiteImage(
                        image: img, key: "schedule/\(draft.value.id?.uuidString ?? imageKey)")
                }
                EditorLinksField("Links (optional)", links: $draft.value.links)
            }

            signupSection

            if showsSlots && !slotList.isEmpty { slotCapacitySection }

            Section("Advanced") {
                EditorToggle("Private (members only)", isOn: $draft.value.isPrivate,
                             caption: "Hide location and details from signed-out guests.")
            }

            if !isNew && (env.isAdmin || service.userCanEditFest) { notifySection }
        }
        .sheet(isPresented: $showLeadPicker) {
            InlineMemberPickerSheet { p in
                draft.value.leadUserId = p.id
                draft.value.leadName = p.name
            }
        }
        .task(id: "\(draft.value.signup.enabled)-\(draft.value.signup.mode)") { await loadSlots() }
    }

    // MARK: Sections

    @ViewBuilder private var signupSection: some View {
        Section {
            EditorToggle("Take sign-ups", isOn: $draft.value.signup.enabled.animation())
            if draft.value.signup.enabled {
                Picker("Type", selection: $draft.value.signup.mode) {
                    Text("Head count").tag("headcount")
                    Text("Time slots").tag("interval")
                    Text("Named slots").tag("slots")
                }
                EditorIntField("Capacity", value: $draft.value.signup.capacity,
                               placeholder: draft.value.signup.mode == "headcount" ? "No limit" : "Per slot")
                Stepper("Team size: \(draft.value.signup.teamSize)", value: $draft.value.signup.teamSize,
                        in: 1...max(8, draft.value.signup.teamSize))
                EditorToggle("Hide who\u{2019}s signed up", isOn: $draft.value.signup.hideNames)
                EditorLongText("Instructions (optional)", text: $draft.value.signup.instructions, lines: 1...3)
                if draft.value.signup.mode == "interval" {
                    EditorTimeField("First slot", time: $draft.value.signup.startTime, isOptional: false)
                    EditorTimeField("Ends by", time: $draft.value.signup.endTime, isOptional: false)
                    Picker("Slot length", selection: $draft.value.signup.slotMinutes) {
                        ForEach(slotLengths, id: \.self) { Text("\($0) min").tag($0) }
                    }
                }
            }
            EditorToggle("\u{1F3C6} Tournament", isOn: $draft.value.tournamentEnabled)
        } header: {
            Text("Sign-ups")
        } footer: {
            if !draft.value.signup.isValid {
                Text(draft.value.signup.mode == "interval"
                     ? "Time slots need a capacity, a slot length, and a start before the end."
                     : "Check the sign-up settings.")
                    .foregroundStyle(Color.mlrDanger)
            } else if draft.value.signup.mode == "slots" && draft.value.signup.enabled {
                Text("Named-slot lists are managed on the web. You can edit each slot\u{2019}s capacity below.")
            } else {
                Text("Members can sign up right on the event.")
            }
        }
    }

    private var slotLengths: [Int] {
        var l = [10, 15, 20, 30, 45, 60, 90, 120]
        if !l.contains(draft.value.signup.slotMinutes) { l.append(draft.value.signup.slotMinutes); l.sort() }
        return l
    }

    @ViewBuilder private var slotCapacitySection: some View {
        Section {
            ForEach(slotList) { slot in
                HStack {
                    Text(slotLabel(slot)).font(.mlrScaled(14))
                    Spacer()
                    TextField("No limit", text: Binding(
                        get: { slotCapacities[slot.id] ?? (slot.capacity.map(String.init) ?? "") },
                        set: { slotCapacities[slot.id] = $0 }))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
            }
        } header: {
            Text("Slot capacities")
        } footer: {
            Text("Override the default capacity for individual slots. Leave blank to use the default above.")
        }
    }

    @ViewBuilder private var notifySection: some View {
        Section {
            EditorToggle("\u{1F4E3} Notify about this change", isOn: $notifyOn.animation())
            if notifyOn {
                EditorTextField("Message", text: $notifyMessage, limit: 140)
                EditorToggle("Banner + push", isOn: $notifyBanner)
                EditorToggle("Activity tab", isOn: $notifyActivity)
                EditorToggle("Email", isOn: $notifyEmail)
            }
        } header: {
            Text("Tell everyone")
        } footer: {
            if notifyOn {
                Text("Sends on Save to everyone at Family Fest except those who said they\u{2019}re not coming.")
            }
        }
    }

    // MARK: Actions

    private func slotLabel(_ slot: ScheduleSlot) -> String {
        if let label = slot.label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return label }
        let start = MLRFormat.time(slot.startTime)
        if let end = slot.endTime, !end.isEmpty { return "\(start)\u{2013}\(MLRFormat.time(end))" }
        return start
    }

    private func loadSlots() async {
        guard showsSlots, let id = draft.value.id else { return }
        slotList = await env.signupsService.fetchSlots(itemId: id)
    }

    private func save() async throws {
        var d = draft.value
        d.title = d.title.trimmingCharacters(in: .whitespaces)
        // Web writes an end time only alongside a start time.
        if d.startTime == nil { d.endTime = nil }
        try await service.saveSchedule(d)

        if d.signup.enabled && d.signup.mode == "slots" {
            for slot in slotList {
                guard let raw = slotCapacities[slot.id] else { continue }
                let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let newCap = t.isEmpty ? nil : Int(t)
                if newCap != slot.capacity {
                    try await env.signupsService.updateSlotCapacity(slotId: slot.id, capacity: newCap)
                }
            }
        }

        if notifyOn, !isNew, let id = d.id,
           let msg = notifyMessage.trimBlank, notifyBanner || notifyActivity || notifyEmail {
            do {
                try await env.notificationsService.sendActivityNotify(
                    title: msg, body: nil, banner: notifyBanner, activity: notifyActivity,
                    email: notifyEmail, scheduleItemId: id.uuidString)
            } catch {
                // The edit itself saved; keep the sheet open so the send can be retried.
                await service.reload()
                throw FestEditError.notificationFailed(EditorError.message(error))
            }
        }
        await service.reload()
        await onSaved?()
    }
}

// MARK: - FestCrewAssignSheet
// A dinner's head chef (who is not a full editor) assigns crew here; full editors
// do it inside the full dinner editor. Crew members then see Edit on that dinner.

struct FestCrewAssignSheet: View {
    @Environment(AppEnvironment.self) private var env

    let dinner: FestDinner
    let onSaved: () async -> Void
    @State private var crew: EditorDraft<[UUID]>

    init(dinner: FestDinner, onSaved: @escaping () async -> Void) {
        self.dinner = dinner; self.onSaved = onSaved
        _crew = State(initialValue: EditorDraft(dinner.crewUserIds))
    }

    var body: some View {
        EditorSheet(
            title: "Manage crew",
            isDirty: crew.isDirty,
            canSave: true,
            save: {
                guard let uid = UUID(uuidString: dinner.id) else { throw FestEditError.badId }
                try await env.festContentService.updateDinnerCrew(dinnerId: uid, crewUserIds: crew.value)
                await onSaved()
            }
        ) {
            FestCrewField(ids: $crew.value,
                          footer: "Crew members can update the menu, serving time, and location from the Fest tab.")
        }
    }
}

// MARK: - InlineMemberPickerSheet
// Searchable profile list. Tapping a row calls `onPick` and dismisses. A failed
// load shows the real error with Retry (never a silent empty list).

struct InlineMemberPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    var excludeIds: [UUID] = []
    let onPick: (Profile) -> Void

    @State private var profiles: [Profile] = []
    @State private var search: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

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
                .buttonStyle(.pressable)
            }
            .searchable(text: $search, prompt: "Search members")
            .safeAreaInset(edge: .top, spacing: 0) {
                if let errorMessage {
                    EditorErrorBanner(message: "Couldn't load members. \(errorMessage)") { Task { await load() } }
                }
            }
            .overlay {
                if isLoading && profiles.isEmpty { ProgressView() }
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
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do { profiles = try await FestMemberDirectory.all() }
        catch { errorMessage = EditorError.message(error) }
    }
}

extension String {
    /// Trimmed text, or nil when blank.
    var trimBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
