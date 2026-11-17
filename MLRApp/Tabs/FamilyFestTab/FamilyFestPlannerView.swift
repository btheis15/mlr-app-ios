import SwiftUI

// MARK: - FamilyFestPlannerView
// In-app editor for Family Fest content (schedule, dinners, dues + payees).
// Writes to the shared DB (migration 0053) so web + iOS stay in sync. Visible to
// app admins and Family Fest committee members (RLS enforces it server-side too).

struct FamilyFestPlannerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openURL) private var openURL
    @State private var openingWeb = false

    private static let masterBase = "https://mlr-app-omega.vercel.app/family-fest/master"

    var body: some View {
        List {
            Section {
                NavigationLink { FestScheduleEditor() } label: {
                    Label("Schedule & events", systemImage: "calendar")
                }
                NavigationLink { FestDinnerEditor() } label: {
                    Label("Dinners", systemImage: "fork.knife")
                }
                NavigationLink { FestPayEditor() } label: {
                    Label("Dues & who to pay", systemImage: "dollarsign.circle")
                }
            } footer: {
                Text("Changes show up for everyone on both the app and the website.")
            }

            Section {
                NavigationLink { FestDetailsEditor() } label: {
                    Label("Fest details & dates", systemImage: "calendar.badge.clock")
                }
                NavigationLink { FestYearLookEditor() } label: {
                    Label("This year's theme & cover", systemImage: "paintpalette")
                }
                // Only once this fest is over: starting early invites dragging the
                // live year's dates forward instead (web gates the same way).
                if env.festContentService.config?.season.isConcluded == true {
                    NavigationLink { StartNextFestYearView() } label: {
                        Label("Start next year's fest", systemImage: "calendar.badge.plus")
                    }
                }
            } header: {
                Text("Family Fest \(String(env.festContentService.year))")
            } footer: {
                Text("Once this fest is over, you can start the next year here — it's added alongside this one, which stays exactly as it was in Past Years.")
            }

            // Bulk editing is easier on a big screen — hand off to the web master
            // editor, carrying your session so there's no second sign-in.
            Section {
                Button { Task { await openMasterEditor() } } label: {
                    HStack {
                        Label("Open the master editor on the web", systemImage: "macbook.and.iphone")
                        if openingWeb { Spacer(); ProgressView() }
                    }
                }
                .disabled(openingWeb)
            } footer: {
                Text("Editing a lot at once? The web master editor puts everything on one desktop-friendly page — it opens already signed in as you.")
            }
        }
        .navigationTitle("Family Fest Planner")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Open the web master editor, passing the current Supabase session in the URL
    /// fragment so the website signs in as the same person automatically (no
    /// re-sign-in). The fragment isn't sent to any server; the web strips it from
    /// history immediately after reading it.
    private func openMasterEditor() async {
        openingWeb = true
        defer { openingWeb = false }
        var urlString = Self.masterBase
        if let session = try? await supabase.auth.session {
            let allowed = CharacterSet(charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            let at = session.accessToken.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let rt = session.refreshToken.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            if !at.isEmpty, !rt.isEmpty {
                urlString += "#mlr_at=\(at)&mlr_rt=\(rt)"
            }
        }
        if let url = URL(string: urlString) {
            openURL(url)
        }
    }
}

// MARK: - Fest details (name, tagline, dates)
// Mirrors the config card in web's FestPlanner. Saves through `save_fest_config`
// so the planned week follows a moved start date. Still offered once the fest is
// over (web does the same, to correct the record), with a pointer to "Start next
// year's fest" for planning the next one.

private struct FestDetailsEditor: View {
    @Environment(AppEnvironment.self) private var env

    private struct Values: Equatable {
        var name = ""
        var tagline = ""
        var startISO = ""
        var endISO = ""
    }

    @State private var draft = EditorDraft(Values())
    @State private var loaded = false
    @State private var saving = false
    @State private var confirmMove = false
    @State private var message: String?
    @State private var error: String?

    private var service: FestContentService { env.festContentService }

    private var startChanged: Bool { draft.value.startISO != service.config?.startDate }
    private var validRange: Bool { draft.value.endISO >= draft.value.startISO }
    private var canSave: Bool {
        loaded && !saving && draft.isDirty && validRange
            && !draft.value.name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            if service.config?.season.isConcluded == true {
                Section {
                    Text("This fest is already over. Edit these only to correct the record. To plan the next one, use \u{201C}Start next year\u{2019}s fest\u{201D} on the planner page, which adds a new year and leaves this one intact in Past Years.")
                        .font(.mlrScaled(13))
                }
            }
            if let error { Section { EditorErrorBanner(message: error) { attemptSave() }.listRowInsets(EdgeInsets()) }.listRowBackground(Color.clear) }
            Section {
                EditorTextField("Fest name", text: $draft.value.name, limit: 80, required: true)
                EditorTextField("Tagline (optional)", text: $draft.value.tagline, limit: 120)
            }
            Section {
                EditorDateField("Start", iso: $draft.value.startISO)
                EditorDateField("End", iso: $draft.value.endISO, minISO: draft.value.startISO)
            } header: {
                Text("Dates")
            } footer: {
                if !validRange {
                    Text("End date must be on or after the start.").foregroundStyle(Color.mlrDanger)
                } else {
                    Text("Changing the start date moves the whole planned week with it: dinners, schedule, sign-ups and everyone\u{2019}s day RSVPs keep their weekday. Changing only the end date moves nothing.")
                }
            }
            if let message { Section { Text(message).foregroundStyle(Color.mlrPineText).font(.mlrScaled(13)) } }
        }
        .disabled(saving)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Fest details")
        .navigationBarTitleDisplayMode(.inline)
        .editorUnsavedGuard(isDirty: draft.isDirty && !saving)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() }
                else { Button("Save") { attemptSave() }.fontWeight(.semibold).disabled(!canSave) }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { EditorKeyboard.hide() }
            }
        }
        .task { populate() }
        .confirmationDialog("Move the whole week?", isPresented: $confirmMove, titleVisibility: .visible) {
            Button("Move the week and save") { Task { await save() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The start date is changing, so the whole planned week (dinners, schedule, sign-ups and day RSVPs) moves with it.")
        }
    }

    private func attemptSave() {
        guard canSave else { return }
        if startChanged { confirmMove = true } else { Task { await save() } }
    }

    private func populate() {
        guard !loaded, let c = service.config else { return }
        draft = EditorDraft(Values(name: c.name, tagline: c.tagline ?? "", startISO: c.startDate, endISO: c.endDate))
        loaded = true
    }

    private func save() async {
        guard !saving else { return }
        saving = true; error = nil; message = nil
        defer { saving = false }
        do {
            let v = draft.value
            let t = v.tagline.trimmingCharacters(in: .whitespaces)
            let r = try await service.saveConfig(
                name: v.name.trimmingCharacters(in: .whitespaces),
                tagline: t.isEmpty ? nil : t,
                startDate: v.startISO, endDate: v.endISO)
            message = r.message
            draft.markSaved()
            Haptics.success()
            await service.reload()
        } catch {
            self.error = EditorError.message(error)
            Haptics.error()
        }
    }
}

// MARK: - Fest day helpers

enum FestDays {
    static let weekdayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d"; f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/Chicago"); return f
    }()
    static let isoFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/Chicago"); return f
    }()

    /// Fest day ISO strings derived from config (fallback to FamilyFestConfig).
    static func options(_ config: FestConfig?) -> [String] {
        let startStr = config?.startDate ?? FamilyFestConfig.startDate
        let endStr = config?.endDate ?? FamilyFestConfig.endDate
        guard let start = isoFmt.date(from: startStr), let end = isoFmt.date(from: endStr) else { return [] }
        var out: [String] = []
        var d = start
        while d <= end {
            out.append(isoFmt.string(from: d))
            d = Calendar.current.date(byAdding: .day, value: 1, to: d) ?? end.addingTimeInterval(86400)
        }
        return out
    }

    static func label(_ iso: String) -> String {
        guard let d = isoFmt.date(from: iso) else { return iso }
        return weekdayFmt.string(from: d)
    }
}

// MARK: - Schedule editor

private struct FestScheduleEditor: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = EditorListModel<FestScheduleDraft>()
    @State private var loading = true
    @State private var editing: FestScheduleDraft?

    private var service: FestContentService { env.festContentService }

    /// Days in list order (the service returns rows sorted by day, then position).
    private var days: [String] {
        var seen = Set<String>(); return model.items.map(\.day).filter { seen.insert($0).inserted }
    }

    var body: some View {
        List {
            if loading {
                ProgressView()
            } else if model.items.isEmpty {
                Text("No events yet. Tap + to add one.").foregroundStyle(Color.mlrTextMuted)
            } else {
                ForEach(days, id: \.self) { day in
                    EditorListSection(model, header: FestDays.label(day), group: { $0.day == day }) { item in
                        Button { editing = item } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(item.emoji ?? "") \(item.title)").foregroundStyle(Color.mlrText)
                                Text(subtitle(item)).font(.caption).foregroundStyle(Color.mlrTextMuted)
                            }
                        }
                    }
                }
            }
        }
        .editorListChrome(model)
        .navigationTitle("Schedule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = newDraft() } label: { Image(systemName: "plus") }
            }
        }
        .task {
            model.title = { $0.title }
            model.persistOrder = { ids in
                try await service.saveOrder(.schedule, ids: ids.compactMap { $0 })
                await reloadAfterWrite()
            }
            model.commitDelete = { item in
                if let id = item.id { try await service.deleteSchedule(id: id) }
                await service.reload()
            }
            await load()
        }
        .sheet(item: $editing, onDismiss: { Task { await load() } }) { d in
            ScheduleEditSheet(draft: d)
        }
    }

    private func subtitle(_ item: FestScheduleDraft) -> String {
        if item.anytime { return "Anytime" }
        guard let t = item.startTime?.nilIfBlank else { return FestDays.label(item.day) }
        return "\(FestDays.label(item.day)) · \(MLRFormat.time(t))"
    }

    /// New rows go at the end (max position + 1), not position 0.
    private func newDraft() -> FestScheduleDraft {
        let day = FestDays.options(service.config).first ?? FamilyFestConfig.startDate
        let next = (model.items.map(\.position).max() ?? -1) + 1
        return FestScheduleDraft(id: nil, day: day, anytime: false, startTime: nil, endTime: nil, title: "", emoji: nil,
                                 location: nil, description: nil, bring: nil, isPrivate: false,
                                 leadUserId: nil, leadName: nil, leadPhone: nil, position: next,
                                 tournamentEnabled: false)
    }
    private func load() async {
        model.replace(await service.editableSchedule()); loading = false
    }
    /// Refresh drafts so their `position` values match the server after a reorder.
    private func reloadAfterWrite() async {
        await service.reload()
        model.replace(await service.editableSchedule())
    }
}

/// The Planner's event editor is the same full editor used in place on the
/// event's own screen (FestInlineEditSheets.swift), so both always have every field.
private struct ScheduleEditSheet: View {
    let draft: FestScheduleDraft
    var body: some View { FestScheduleFullEditor(draft: draft) }
}

// MARK: - Dinner editor

private struct FestDinnerEditor: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = EditorListModel<FestDinnerDraft>()
    @State private var loading = true
    @State private var editing: FestDinnerDraft?

    private var service: FestContentService { env.festContentService }

    private var days: [String] {
        var seen = Set<String>(); return model.items.map(\.day).filter { seen.insert($0).inserted }
    }

    var body: some View {
        List {
            if loading { ProgressView() }
            else if model.items.isEmpty {
                Text("No dinners yet. Tap + to add one.").foregroundStyle(Color.mlrTextMuted)
            } else {
                ForEach(days, id: \.self) { day in
                    EditorListSection(model, header: FestDays.label(day), group: { $0.day == day }) { item in
                        Button { editing = item } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).foregroundStyle(Color.mlrText)
                                Text("\(FestDays.label(item.day)) · \(item.chefName?.nilIfBlank ?? "Chef TBD")")
                                    .font(.caption).foregroundStyle(Color.mlrTextMuted)
                            }
                        }
                    }
                }
            }
        }
        .editorListChrome(model)
        .navigationTitle("Dinners")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button { editing = newDraft() } label: { Image(systemName: "plus") } }
        }
        .task {
            model.title = { $0.title }
            model.persistOrder = { ids in
                try await service.saveOrder(.dinners, ids: ids.compactMap { $0 })
                await service.reload()
                model.replace(await service.editableDinners())
            }
            model.commitDelete = { item in
                if let id = item.id { try await service.deleteDinner(id: id) }
                await service.reload()
            }
            await load()
        }
        .sheet(item: $editing, onDismiss: { Task { await load() } }) { d in DinnerEditSheet(draft: d) }
    }

    private func newDraft() -> FestDinnerDraft {
        let day = FestDays.options(service.config).first ?? FamilyFestConfig.startDate
        let next = (model.items.map(\.position).max() ?? -1) + 1
        return FestDinnerDraft(id: nil, day: day, title: "Dinner", emoji: "🍽️", chefUserId: nil, chefName: nil,
                               chefPhone: nil, crewUserIds: [], houses: [], menu: nil, servedTime: nil, servedLocation: nil,
                               prepTime: nil, prepLocation: nil, position: next)
    }
    private func load() async { model.replace(await service.editableDinners()); loading = false }
}

/// Not `private` — the full dinner editor (FestDinnerEditSheet.swift) for
/// `can_edit_fest()` viewers; the Planner and the Dinners screens share it.
struct DinnerEditSheet: View {
    let draft: FestDinnerDraft
    var body: some View { FestDinnerFullEditor(draft: draft) }
}

// MARK: - Pay editor (dues tiers + payees)

private struct FestPayEditor: View {
    @Environment(AppEnvironment.self) private var env
    @State private var duesModel = EditorListModel<FestDuesTier>()
    @State private var payeeModel = EditorListModel<Payee>()
    @State private var editingDues: FestDuesTier?
    @State private var editingPayee: Payee?

    private var service: FestContentService { env.festContentService }

    var body: some View {
        List {
            EditorListSection(duesModel, header: "Dues amounts") { tier in
                Button { editingDues = tier } label: {
                    HStack {
                        Text(tier.label).foregroundStyle(Color.mlrText)
                        Spacer()
                        Text(tier.amount.map { "$\($0)" } ?? "TBD").foregroundStyle(Color.mlrTextMuted)
                    }
                }
            }
            Section {
                Button { editingDues = FestDuesTier(id: UUID(), label: "", amount: nil, note: nil) } label: {
                    Label("Add a dues amount", systemImage: "plus")
                }
            }
            EditorListSection(payeeModel, header: "Who to pay") { p in
                Button { editingPayee = p } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).foregroundStyle(Color.mlrText)
                        if let role = p.role, !role.isEmpty { Text(role).font(.caption).foregroundStyle(Color.mlrTextMuted) }
                    }
                }
            }
            Section {
                Button { editingPayee = Payee(id: UUID(), name: "", role: nil, venmo: nil, zelle: nil, appleCash: nil, paypal: nil, amount: nil, note: nil) } label: {
                    Label("Add a payee", systemImage: "plus")
                }
            }
        }
        .editorListChrome(duesModel)
        .editorListChrome(payeeModel, editButton: false)
        .navigationTitle("Dues & Pay")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            duesModel.title = { $0.label }
            duesModel.persistOrder = { ids in
                try await service.saveOrder(.dues, ids: ids)
                await service.reload()
                duesModel.replace(service.dues)
            }
            duesModel.commitDelete = { t in try await service.deleteDues(id: t.id); await service.reload() }
            payeeModel.title = { $0.name }
            payeeModel.persistOrder = { ids in
                try await service.saveOrder(.payees, ids: ids)
                await service.reload()
                payeeModel.replace(service.payees)
            }
            payeeModel.commitDelete = { p in try await service.deletePayee(id: p.id); await service.reload() }
            await service.load()
            syncModels()
        }
        .onChange(of: service.dues) { _, _ in duesModel.replace(service.dues) }
        .onChange(of: service.payees) { _, _ in payeeModel.replace(service.payees) }
        .sheet(item: $editingDues, onDismiss: { Task { await service.reload(); syncModels() } }) { t in
            DuesEditSheet(tier: t, isNew: !duesModel.items.contains { $0.id == t.id })
        }
        .sheet(item: $editingPayee, onDismiss: { Task { await service.reload(); syncModels() } }) { p in
            PayeeEditSheet(payee: p, isNew: !payeeModel.items.contains { $0.id == p.id })
        }
    }

    private func syncModels() { duesModel.replace(service.dues); payeeModel.replace(service.payees) }
}

private struct DuesEditSheet: View {
    @Environment(AppEnvironment.self) private var env
    @State private var draft: EditorDraft<FestDuesTier>
    let isNew: Bool

    init(tier: FestDuesTier, isNew: Bool) {
        _draft = State(initialValue: EditorDraft(tier)); self.isNew = isNew
    }

    var body: some View {
        EditorSheet(
            title: isNew ? "Add dues amount" : "Edit dues amount",
            isDirty: draft.isDirty,
            canSave: !draft.value.label.trimmingCharacters(in: .whitespaces).isEmpty,
            save: {
                var t = draft.value
                t.label = t.label.trimmingCharacters(in: .whitespaces)
                // position nil: new rows are appended at the end; edits keep their place.
                try await env.festContentService.saveDues(t, isNew: isNew)
                await env.festContentService.reload()
            }
        ) {
            Section {
                EditorTextField("Label", text: $draft.value.label, placeholder: "e.g. Adult, Kid, Per day", limit: 60, required: true)
                EditorIntField("Amount", value: $draft.value.amount, placeholder: "Leave blank for TBD")
                EditorTextField("Note (optional)", text: $draft.value.note, limit: 120)
                EditorToggle("Billed per day", isOn: $draft.value.perDay,
                             caption: draft.value.perDay
                                ? "The Pay calculator multiplies this amount by a shared \u{201C}number of days\u{201D} count." : nil)
            }
        }
    }
}

private struct PayeeEditSheet: View {
    @Environment(AppEnvironment.self) private var env
    @State private var draft: EditorDraft<Payee>
    let isNew: Bool

    init(payee: Payee, isNew: Bool) {
        _draft = State(initialValue: EditorDraft(payee)); self.isNew = isNew
    }

    var body: some View {
        EditorSheet(
            title: isNew ? "Add payee" : "Edit payee",
            isDirty: draft.isDirty,
            canSave: !draft.value.name.trimmingCharacters(in: .whitespaces).isEmpty,
            save: {
                var p = draft.value
                p.name = p.name.trimmingCharacters(in: .whitespaces)
                try await env.festContentService.savePayee(p, isNew: isNew)
                await env.festContentService.reload()
            }
        ) {
            Section("Person") {
                EditorTextField("Name", text: $draft.value.name, limit: 80, required: true)
                EditorTextField("Role / what it's for", text: $draft.value.role, limit: 120)
                EditorIntField("Amount (optional)", value: $draft.value.amount)
            }
            Section("Handles") {
                EditorTextField("Venmo", text: $draft.value.venmo, autocapitalize: false)
                EditorTextField("Zelle", text: $draft.value.zelle, autocapitalize: false)
                EditorTextField("Apple Cash", text: $draft.value.appleCash, autocapitalize: false)
                EditorTextField("PayPal", text: $draft.value.paypal, autocapitalize: false)
            }
            Section { EditorTextField("Note (optional)", text: $draft.value.note, limit: 200) }
        }
    }
}

// MARK: - Member picker (link a real account for who's-in-charge / chef)

struct FestMemberPicker: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (Profile) -> Void

    @State private var members: [Profile] = []
    @State private var query = ""
    @State private var errorMessage: String?
    @State private var loading = false

    private var shown: [Profile] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return members }
        return members.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List(shown) { m in
                Button { onPick(m); dismiss() } label: {
                    HStack { AvatarView(profile: m, size: .small); Text(m.name).foregroundStyle(Color.mlrText) }
                }
            }
            .searchable(text: $query)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let errorMessage {
                    EditorErrorBanner(message: "Couldn\u{2019}t load members. \(errorMessage)") { Task { await load() } }
                }
            }
            .overlay { if loading && members.isEmpty { ProgressView() } }
            .navigationTitle("Link a member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true; errorMessage = nil
        defer { loading = false }
        do { members = try await FestMemberDirectory.all() }
        catch { errorMessage = EditorError.message(error) }
    }
}

private extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
