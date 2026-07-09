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
    @State private var items: [FestScheduleDraft] = []
    @State private var loading = true
    @State private var editing: FestScheduleDraft?

    var body: some View {
        List {
            if loading {
                ProgressView()
            } else {
                ForEach(items) { item in
                    Button { editing = item } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(item.emoji ?? "") \(item.title)").foregroundStyle(Color.mlrText)
                            Text("\(FestDays.label(item.day))\(item.startTime?.nilIfBlank.map { " · \($0)" } ?? "")")
                                .font(.caption).foregroundStyle(Color.mlrTextMuted)
                        }
                    }
                }
                .onDelete { idx in Task { await deleteRows(idx) } }
            }
        }
        .navigationTitle("Schedule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = newDraft() } label: { Image(systemName: "plus") }
            }
        }
        .task { await load() }
        .sheet(item: $editing, onDismiss: { Task { await load() } }) { d in
            ScheduleEditSheet(draft: d)
        }
    }

    private func newDraft() -> FestScheduleDraft {
        let day = FestDays.options(env.festContentService.config).first ?? FamilyFestConfig.startDate
        return FestScheduleDraft(id: nil, day: day, startTime: nil, endTime: nil, title: "", emoji: nil,
                                 location: nil, description: nil, bring: nil, isPrivate: false,
                                 leadUserId: nil, leadName: nil, leadPhone: nil, position: items.count)
    }
    private func load() async { loading = true; items = await env.festContentService.editableSchedule(); loading = false }
    private func deleteRows(_ idx: IndexSet) async {
        for i in idx { if let id = items[i].id { try? await env.festContentService.deleteSchedule(id: id) } }
        await env.festContentService.reload(); await load()
    }
}

private struct ScheduleEditSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State var draft: FestScheduleDraft
    @State private var hasTime = false
    @State private var saving = false
    @State private var showMemberPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Event") {
                    Picker("Day", selection: $draft.day) {
                        ForEach(FestDays.options(env.festContentService.config), id: \.self) { Text(FestDays.label($0)).tag($0) }
                    }
                    TextField("Title (e.g. Lake Day)", text: $draft.title)
                    TextField("Emoji (optional)", text: optional($draft.emoji))
                    Toggle("Set a time", isOn: $hasTime)
                    if hasTime {
                        TextField("Time (e.g. 2:00 PM)", text: optional($draft.startTime))
                    }
                    TextField("Location (blank = TBD)", text: optional($draft.location))
                }
                Section("Who's in charge") {
                    TextField("Name", text: optional($draft.leadName))
                    Button {
                        showMemberPicker = true
                    } label: {
                        Label(draft.leadUserId == nil ? "Link a member" : "Linked ✓", systemImage: "person.crop.circle.badge.plus")
                    }
                    TextField("Phone (optional)", text: optional($draft.leadPhone))
                        .keyboardType(.phonePad)
                }
                Section("Details") {
                    TextField("Description", text: optional($draft.description), axis: .vertical).lineLimit(2...5)
                    TextField("What to bring (optional)", text: optional($draft.bring), axis: .vertical).lineLimit(1...3)
                    Toggle("Private (members only)", isOn: $draft.isPrivate)
                }
            }
            .navigationTitle(draft.id == nil ? "Add event" : "Edit event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() }
                    else { Button("Save") { Task { await save() } }.disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty) }
                }
            }
            .sheet(isPresented: $showMemberPicker) {
                FestMemberPicker { profile in
                    draft.leadUserId = profile.id
                    draft.leadName = profile.name
                }
            }
            .onAppear { hasTime = draft.startTime?.nilIfBlank != nil }
        }
    }

    private func save() async {
        saving = true; defer { saving = false }
        if !hasTime { draft.startTime = nil }
        do { try await env.festContentService.saveSchedule(draft); await env.festContentService.reload(); dismiss() }
        catch { print("[Planner] saveSchedule error: \(error)") }
    }
}

// MARK: - Dinner editor

private struct FestDinnerEditor: View {
    @Environment(AppEnvironment.self) private var env
    @State private var items: [FestDinnerDraft] = []
    @State private var loading = true
    @State private var editing: FestDinnerDraft?

    var body: some View {
        List {
            if loading { ProgressView() }
            else {
                ForEach(items) { item in
                    Button { editing = item } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).foregroundStyle(Color.mlrText)
                            Text("\(FestDays.label(item.day)) · \(item.chefName?.nilIfBlank ?? "Chef TBD")")
                                .font(.caption).foregroundStyle(Color.mlrTextMuted)
                        }
                    }
                }
                .onDelete { idx in Task { await deleteRows(idx) } }
            }
        }
        .navigationTitle("Dinners")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button { editing = newDraft() } label: { Image(systemName: "plus") } }
        }
        .task { await load() }
        .sheet(item: $editing, onDismiss: { Task { await load() } }) { d in DinnerEditSheet(draft: d) }
    }

    private func newDraft() -> FestDinnerDraft {
        let day = FestDays.options(env.festContentService.config).first ?? FamilyFestConfig.startDate
        return FestDinnerDraft(id: nil, day: day, title: "Dinner", emoji: "🍽️", chefUserId: nil, chefName: nil,
                               chefPhone: nil, houses: [], menu: nil, servedTime: nil, servedLocation: nil,
                               prepTime: nil, prepLocation: nil, position: items.count)
    }
    private func load() async { loading = true; items = await env.festContentService.editableDinners(); loading = false }
    private func deleteRows(_ idx: IndexSet) async {
        for i in idx { if let id = items[i].id { try? await env.festContentService.deleteDinner(id: id) } }
        await env.festContentService.reload(); await load()
    }
}

private struct DinnerEditSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State var draft: FestDinnerDraft
    @State private var housesText = ""
    @State private var saving = false
    @State private var showMemberPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Dinner") {
                    Picker("Day", selection: $draft.day) {
                        ForEach(FestDays.options(env.festContentService.config), id: \.self) { Text(FestDays.label($0)).tag($0) }
                    }
                    TextField("Title (e.g. Monday Dinner)", text: $draft.title)
                }
                Section("Chef") {
                    TextField("Chef name(s)", text: optional($draft.chefName))
                    Button { showMemberPicker = true } label: {
                        Label(draft.chefUserId == nil ? "Link a member" : "Linked ✓", systemImage: "person.crop.circle.badge.plus")
                    }
                    TextField("Phone (optional)", text: optional($draft.chefPhone)).keyboardType(.phonePad)
                    TextField("Houses / crew (comma-separated)", text: $housesText)
                }
                Section("Served") {
                    TextField("Time (e.g. 6:00 PM)", text: optional($draft.servedTime))
                    TextField("Location", text: optional($draft.servedLocation))
                }
                Section("Prep") {
                    TextField("Prep time", text: optional($draft.prepTime))
                    TextField("Prep location", text: optional($draft.prepLocation))
                }
                Section { TextField("Menu", text: optional($draft.menu), axis: .vertical).lineLimit(2...5) }
            }
            .navigationTitle(draft.id == nil ? "Add dinner" : "Edit dinner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button("Save") { Task { await save() } } }
                }
            }
            .sheet(isPresented: $showMemberPicker) {
                FestMemberPicker { p in draft.chefUserId = p.id; draft.chefName = p.name }
            }
            .onAppear { housesText = draft.houses.joined(separator: ", ") }
        }
    }

    private func save() async {
        saving = true; defer { saving = false }
        draft.houses = housesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        do { try await env.festContentService.saveDinner(draft); await env.festContentService.reload(); dismiss() }
        catch { print("[Planner] saveDinner error: \(error)") }
    }
}

// MARK: - Pay editor (dues tiers + payees)

private struct FestPayEditor: View {
    @Environment(AppEnvironment.self) private var env
    @State private var editingDues: FestDuesTier?
    @State private var editingPayee: Payee?

    private var dues: [FestDuesTier] { env.festContentService.dues }
    private var payees: [Payee] { env.festContentService.payees }

    var body: some View {
        List {
            Section("Dues amounts") {
                ForEach(dues) { tier in
                    Button { editingDues = tier } label: {
                        HStack {
                            Text(tier.label).foregroundStyle(Color.mlrText)
                            Spacer()
                            Text(tier.amount.map { "$\($0)" } ?? "TBD").foregroundStyle(Color.mlrTextMuted)
                        }
                    }
                }
                .onDelete { idx in Task { await deleteDues(idx) } }
                Button { editingDues = FestDuesTier(id: UUID(), label: "", amount: nil, note: nil) } label: {
                    Label("Add a dues amount", systemImage: "plus")
                }
            }
            Section("Who to pay") {
                ForEach(payees) { p in
                    Button { editingPayee = p } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).foregroundStyle(Color.mlrText)
                            if let role = p.role, !role.isEmpty { Text(role).font(.caption).foregroundStyle(Color.mlrTextMuted) }
                        }
                    }
                }
                .onDelete { idx in Task { await deletePayee(idx) } }
                Button { editingPayee = Payee(id: UUID(), name: "", role: nil, venmo: nil, zelle: nil, appleCash: nil, paypal: nil, amount: nil, note: nil) } label: {
                    Label("Add a payee", systemImage: "plus")
                }
            }
        }
        .navigationTitle("Dues & Pay")
        .navigationBarTitleDisplayMode(.inline)
        .task { await env.festContentService.load() }
        .sheet(item: $editingDues, onDismiss: { Task { await env.festContentService.reload() } }) { t in
            DuesEditSheet(tier: t, isNew: !dues.contains { $0.id == t.id })
        }
        .sheet(item: $editingPayee, onDismiss: { Task { await env.festContentService.reload() } }) { p in
            PayeeEditSheet(payee: p, isNew: !payees.contains { $0.id == p.id })
        }
    }

    private func deleteDues(_ idx: IndexSet) async {
        for i in idx { try? await env.festContentService.deleteDues(id: dues[i].id) }
        await env.festContentService.reload()
    }
    private func deletePayee(_ idx: IndexSet) async {
        for i in idx { try? await env.festContentService.deletePayee(id: payees[i].id) }
        await env.festContentService.reload()
    }
}

private struct DuesEditSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State var tier: FestDuesTier
    let isNew: Bool
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Label (e.g. Adult, Kid, Per day)", text: $tier.label)
                TextField("Amount (leave blank for TBD)", value: $tier.amount, format: .number).keyboardType(.numberPad)
                TextField("Note (optional)", text: optional($tier.note))
                Toggle("Billed per day", isOn: $tier.perDay)
                if tier.perDay {
                    Text("The Pay calculator multiplies this amount by a shared \u{201C}number of days\u{201D} count.")
                        .font(.mlrCaption).foregroundStyle(Color.mlrTextMuted)
                }
            }
            .navigationTitle(isNew ? "Add dues amount" : "Edit dues amount")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() }
                    else { Button("Save") { Task { await save() } }.disabled(tier.label.trimmingCharacters(in: .whitespaces).isEmpty) }
                }
            }
        }
    }
    private func save() async {
        saving = true; defer { saving = false }
        do { try await env.festContentService.saveDues(tier, position: 0, isNew: isNew); await env.festContentService.reload(); dismiss() }
        catch { print("[Planner] saveDues error: \(error)") }
    }
}

private struct PayeeEditSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State var payee: Payee
    let isNew: Bool
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Person") {
                    TextField("Name", text: $payee.name)
                    TextField("Role / what it's for", text: optional($payee.role))
                    TextField("Amount (optional)", value: $payee.amount, format: .number).keyboardType(.numberPad)
                }
                Section("Handles") {
                    TextField("Venmo", text: optional($payee.venmo)).textInputAutocapitalization(.never)
                    TextField("Zelle", text: optional($payee.zelle)).textInputAutocapitalization(.never)
                    TextField("Apple Cash", text: optional($payee.appleCash)).textInputAutocapitalization(.never)
                    TextField("PayPal", text: optional($payee.paypal)).textInputAutocapitalization(.never)
                }
                Section { TextField("Note (optional)", text: optional($payee.note)) }
            }
            .navigationTitle(isNew ? "Add payee" : "Edit payee")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() }
                    else { Button("Save") { Task { await save() } }.disabled(payee.name.trimmingCharacters(in: .whitespaces).isEmpty) }
                }
            }
        }
    }
    private func save() async {
        saving = true; defer { saving = false }
        do { try await env.festContentService.savePayee(payee, position: 0, isNew: isNew); await env.festContentService.reload(); dismiss() }
        catch { print("[Planner] savePayee error: \(error)") }
    }
}

// MARK: - Member picker (link a real account for who's-in-charge / chef)

struct FestMemberPicker: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (Profile) -> Void

    @State private var members: [Profile] = []
    @State private var query = ""

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
            .navigationTitle("Link a member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                members = (try? await supabase.from("profiles")
                    .select("id, display_name, avatar_url, is_admin, beta_tester, willing_to_help, intro_seen, email_alerts, push_level, push_types, notif_types, push_prompted, contact_email, created_at")
                    .order("display_name", ascending: true).execute().value) ?? []
            }
        }
    }
}

// MARK: - Optional-string binding helper

private func optional(_ source: Binding<String?>) -> Binding<String> {
    Binding(get: { source.wrappedValue ?? "" }, set: { source.wrappedValue = $0.isEmpty ? nil : $0 })
}

private extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
