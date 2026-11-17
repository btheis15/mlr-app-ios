import SwiftUI
import Supabase

// MARK: - Status
// "Showing now / Scheduled / Ended / Off", derived from is_active + the date
// window (Chicago days, same clock Home filters with).

enum CalloutStatus: Equatable {
    case showingNow, scheduled(String), ended(String), off

    var label: String {
        switch self {
        case .showingNow: return "Showing now"
        case .scheduled(let d): return "Scheduled \u{00B7} starts \(CalloutDates.pretty(d))"
        case .ended(let d): return "Ended \(CalloutDates.pretty(d))"
        case .off: return "Off"
        }
    }
    var color: Color {
        switch self {
        case .showingNow: return .mlrSuccess
        case .scheduled: return .mlrWarning
        case .ended, .off: return .mlrTextSubtle
        }
    }
    var symbol: String {
        switch self {
        case .showingNow: return "dot.radiowaves.left.and.right"
        case .scheduled: return "clock"
        case .ended: return "checkmark.circle"
        case .off: return "eye.slash"
        }
    }
}

extension HomeCallout {
    func status(today: String) -> CalloutStatus {
        guard isActive else { return .off }
        if let s = startsOn, today < s { return .scheduled(s) }
        if let e = endsOn, today > e { return .ended(e) }
        return .showingNow
    }
}

enum CalloutDates {
    static let chicago = TimeZone(identifier: "America/Chicago") ?? .current
    static var today: String { FestDays.isoFmt.string(from: Date()) }

    static func pretty(_ iso: String) -> String {
        guard let d = FestDays.isoFmt.date(from: iso) else { return iso }
        return d.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: chicago))
    }

    /// ISO 8601 with or without fractional seconds (Postgres returns either).
    static func parseTimestamp(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}

// MARK: - AdminCalloutsView
// Manage Home callout cards (migration 0083 / 0093). Lists EVERY callout (active
// or not) in position order: drag to reorder (real positions), swipe to delete
// with confirm + undo, inline on/off switch, and a status line per row.

struct AdminCalloutsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = EditorListModel<HomeCallout>()
    @State private var composing = false
    @State private var editing: HomeCallout? = nil
    @State private var loaded = false
    @State private var loadError: String?
    @State private var toggleError: String?

    var body: some View {
        List {
            if let loadError {
                Section {
                    EditorErrorBanner(message: loadError) { Task { await load() } }
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
            }
            if !loaded && loadError == nil {
                Section { HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear) }
            } else if model.items.isEmpty && loadError == nil {
                Text("No callout cards yet. Tap + to create one.")
                    .font(.mlrScaled(14))
                    .foregroundStyle(Color.mlrTextMuted)
                    .listRowBackground(Color.clear)
            } else {
                EditorListSection(model) { callout in calloutRow(callout) }
            }
        }
        .editorListChrome(model, editButton: !model.items.isEmpty)
        .navigationTitle("Home Callouts")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { composing = true } label: { Image(systemName: "plus") }
                    .tint(Color.mlrPineText)
                    .accessibilityLabel("New callout")
            }
        }
        .alert("Couldn\u{2019}t update", isPresented: Binding(get: { toggleError != nil },
                                                             set: { if !$0 { toggleError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(toggleError ?? "") }
        .sheet(isPresented: $composing, onDismiss: { Task { await load() } }) {
            CalloutComposerView(existing: nil)
        }
        .sheet(item: $editing, onDismiss: { Task { await load() } }) { callout in
            CalloutComposerView(existing: callout)
        }
        .task {
            model.title = { $0.title?.isEmpty == false ? ($0.title ?? "") : "call-out" }
            model.persistOrder = { ids in try await persistOrder(ids) }
            model.commitDelete = { callout in
                try await supabase.from("home_callouts").delete().eq("id", value: callout.id).execute()
                await env.festContentService.reload()
            }
            await env.festContentService.load()
            await load()
        }
    }

    // MARK: Data

    private func load() async {
        do {
            model.replace(try await env.festContentService.allCallouts())
            loadError = nil
        } catch {
            loadError = EditorError.message(error)
        }
        loaded = true
    }

    /// Writes a real `position` for every row whose slot changed. If a write
    /// fails part-way, the rows already written are put back before throwing.
    private func persistOrder(_ ids: [String]) async throws {
        let old = Dictionary(uniqueKeysWithValues: model.items.map { ($0.id, $0.position) })
        var written: [(String, Int)] = []
        do {
            for (index, id) in ids.enumerated() where old[id] != index {
                try await supabase.from("home_callouts").update(["position": index]).eq("id", value: id).execute()
                written.append((id, old[id] ?? 0))
            }
        } catch {
            for (id, pos) in written {
                _ = try? await supabase.from("home_callouts").update(["position": pos]).eq("id", value: id).execute()
            }
            throw error
        }
        for (index, id) in ids.enumerated() {
            if let i = model.items.firstIndex(where: { $0.id == id }) { model.items[i].position = index }
        }
        await env.festContentService.reload()
    }

    private func setActive(_ callout: HomeCallout, _ on: Bool) {
        guard let i = model.items.firstIndex(where: { $0.id == callout.id }) else { return }
        model.items[i].isActive = on
        Haptics.select()
        Task {
            do {
                try await supabase.from("home_callouts").update(["is_active": on]).eq("id", value: callout.id).execute()
                await env.festContentService.reload()
            } catch {
                if let j = model.items.firstIndex(where: { $0.id == callout.id }) { model.items[j].isActive = !on }
                toggleError = EditorError.message(error)
                Haptics.error()
            }
        }
    }

    // MARK: Row

    private func calloutRow(_ callout: HomeCallout) -> some View {
        let status = callout.status(today: CalloutDates.today)
        return HStack(spacing: 12) {
            Button { editing = callout } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(callout.title?.isEmpty == false ? (callout.title ?? "") : "(no title)")
                        .font(.mlrScaled(15, weight: .semibold))
                        .foregroundStyle(callout.isActive ? Color.mlrText : Color.mlrTextMuted)
                    if let body = callout.body, !body.isEmpty {
                        Text(body)
                            .font(.mlrScaled(12))
                            .foregroundStyle(Color.mlrTextMuted)
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        Label(status.label, systemImage: status.symbol)
                            .font(.mlrScaled(11, weight: .semibold))
                            .foregroundStyle(status.color)
                        if !callout.links.isEmpty {
                            Text("\(callout.links.count) link\(callout.links.count == 1 ? "" : "s")")
                                .font(.mlrScaled(11))
                                .foregroundStyle(Color.mlrPineText)
                        }
                    }
                    if status == .showingNow, let e = callout.endsOn {
                        Text("Through \(CalloutDates.pretty(e))")
                            .font(.mlrScaled(11)).foregroundStyle(Color.mlrTextSubtle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)

            Toggle("Active", isOn: Binding(get: { callout.isActive }, set: { setActive(callout, $0) }))
                .labelsHidden()
                .tint(Color.mlrPineText)
                .accessibilityLabel("\(callout.title ?? "Call-out") active")
        }
        .padding(.vertical, 4)
    }
}

// MARK: - CalloutComposerView
// Create or edit a Home callout card on the shared editor kit: dirty tracking,
// unsaved-changes guard, real errors, native date pickers, photo upload, a live
// preview of the real Home card. Presents itself as a sheet (EditorSheet owns
// the NavigationStack), so callers present it directly.

struct CalloutDraft: Equatable {
    var title = ""
    var body = ""
    var imageUrl: String?
    var links: [EditorLink] = []
    var startsOn: String?
    var endsOn: String?
    var hasDeadline = false
    var deadline = Date()
    var isActive = true
    /// Linked Fest activity (migration 0137).
    var signupItemId: String?
    /// Event targeting (migration 0096).
    var eventId: String?
    var excludeNotAttending = true
    /// Linked Drop Box folder (migration 0172).
    var dropBoxId: String?

    init() {}
    init(_ c: HomeCallout) {
        title = c.title ?? ""
        body = c.body ?? ""
        imageUrl = c.imageUrl?.trimmingCharacters(in: .whitespaces).isEmpty == false ? c.imageUrl : nil
        links = c.links.map { EditorLink(label: $0.label ?? "", url: $0.href) }
        startsOn = c.startsOn
        endsOn = c.endsOn
        isActive = c.isActive
        signupItemId = c.signupItemId
        eventId = c.eventId
        excludeNotAttending = c.excludeNotAttending
        dropBoxId = c.dropBoxId
        if let dl = c.deadlineAt, let date = CalloutDates.parseTimestamp(dl) {
            hasDeadline = true
            deadline = date
        }
    }

    /// Non-blank link rows as the card/DB shape.
    var cleanLinks: [CalloutLink] {
        links.compactMap { l in
            let href = l.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !href.isEmpty else { return nil }
            let label = l.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return CalloutLink(href: href, label: label.isEmpty ? nil : label)
        }
    }

    static func linkIsValid(_ href: String) -> Bool {
        let t = href.trimmingCharacters(in: .whitespaces).lowercased()
        return EditorLink.isValidURL(href) || (t.hasPrefix("tel:") && t.count > 4) || (t.hasPrefix("mailto:") && t.count > 7)
    }
}

/// Shown when the callout saved but a one-time notify/email step did not.
private struct CalloutSideActionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct CalloutComposerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let existing: HomeCallout?

    @State private var draft: EditorDraft<CalloutDraft>
    /// Set after a first successful insert so a Retry updates instead of duplicating.
    @State private var savedId: String?
    // One-time side actions (default OFF each open, not saved on the callout).
    @State private var alsoNotify = false
    @State private var alsoEmail = false
    @State private var confirmReset = false
    @State private var showDeleteAlert = false
    @State private var deleting = false
    @State private var deleteError: String?

    init(existing: HomeCallout?) {
        self.existing = existing
        _draft = State(initialValue: EditorDraft(existing.map(CalloutDraft.init) ?? CalloutDraft()))
    }

    private var currentId: String? { existing?.id ?? savedId }
    private var d: CalloutDraft { draft.value }
    private var hasTitle: Bool { !d.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var hasContent: Bool {
        hasTitle || !d.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || d.imageUrl != nil || !d.cleanLinks.isEmpty || d.signupItemId != nil || d.dropBoxId != nil
    }
    private var validRange: Bool {
        guard let s = d.startsOn, let e = d.endsOn else { return true }
        return e >= s
    }
    private var linksValid: Bool { d.cleanLinks.allSatisfy { CalloutDraft.linkIsValid($0.href) } }
    private var canSave: Bool {
        hasContent && validRange && linksValid && ((!alsoNotify && !alsoEmail) || hasTitle)
    }

    /// The real Home card for what's typed right now.
    private var previewCallout: HomeCallout {
        HomeCallout(
            id: currentId ?? "preview",
            title: d.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : d.title,
            body: d.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : d.body,
            imageUrl: d.imageUrl,
            links: d.cleanLinks,
            startsOn: d.startsOn,
            endsOn: d.endsOn,
            deadlineAt: d.hasDeadline ? ISO8601DateFormatter().string(from: d.deadline) : nil,
            dismissId: existing?.dismissId ?? "preview",
            position: existing?.position ?? 0,
            isActive: d.isActive,
            signupItemId: d.signupItemId,
            eventId: d.eventId,
            excludeNotAttending: d.eventId != nil && d.excludeNotAttending,
            dropBoxId: d.dropBoxId
        )
    }

    var body: some View {
        EditorSheet(
            title: existing == nil && savedId == nil ? "New Callout" : "Edit Callout",
            isDirty: draft.isDirty || alsoNotify || alsoEmail,
            canSave: canSave,
            save: { try await save() }
        ) {
            Section {
                HomeCalloutCard(callout: previewCallout)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .combine)
                    .padding(.vertical, 6)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    .listRowBackground(Color.clear)
                if d.hasDeadline {
                    Label("Reminders count down to \(d.deadline.formatted(date: .abbreviated, time: .shortened))",
                          systemImage: "alarm")
                        .font(.mlrCaption).foregroundStyle(Color.mlrTextMuted)
                }
                if !d.isActive {
                    Label("Off: members won\u{2019}t see this card until you turn it on.", systemImage: "eye.slash")
                        .font(.mlrCaption).foregroundStyle(Color.mlrTextMuted)
                }
            } header: { Text("Live preview") }

            Section("Card Content") {
                EditorTextField("Title", text: $draft.value.title, placeholder: "T-shirts on sale \u{00B7} Work weekend", limit: 120)
                EditorLongText("Body", text: $draft.value.body, placeholder: "Short description\u{2026}", lines: 2...5)
            }

            Section {
                Picker("Link a Fest activity", selection: $draft.value.signupItemId) {
                    Text("None").tag(String?.none)
                    ForEach(env.festContentService.schedule) { item in
                        Text(item.title).tag(String?.some(item.id))
                    }
                }
            } footer: {
                Text("The card links to that activity. If it's taking sign-ups, a \"\u{1F4DD} Sign up\" button is added too.")
            }

            EventTargetPicker(events: env.eventsService.upcomingEvents,
                              selectedEventId: $draft.value.eventId,
                              excludeNotAttending: $draft.value.excludeNotAttending)

            Section {
                Picker("Link a Drop Box folder", selection: $draft.value.dropBoxId) {
                    Text("None").tag(String?.none)
                    ForEach(env.dropBoxesService.boxes.filter { !$0.isArchived }) { box in
                        Text("\(box.emoji ?? "\u{1F4F8}") \(box.title)").tag(String?.some(box.id.uuidString))
                    }
                }
            } footer: {
                Text("Adds a \"\u{1F4F8} Add & see photos\" button that deep-links straight into that shared album.")
            }

            Section("Image") {
                EditorImageField("Photo or flyer", url: $draft.value.imageUrl) { img in
                    try await env.mediaService.uploadSiteImage(image: img, key: "callout")
                }
            }

            Section {
                EditorLinksField("Action links", links: $draft.value.links)
            } footer: {
                Text("Web addresses, or tel: / mailto: links.")
            }

            Section {
                EditorDateField("Starts on", iso: $draft.value.startsOn, isOptional: true)
                EditorDateField("Ends on", iso: $draft.value.endsOn, isOptional: true, minISO: d.startsOn)
                if !validRange {
                    Text("The end date is before the start date.")
                        .font(.mlrCaption).foregroundStyle(Color.mlrDanger)
                }
                EditorToggle("Active", isOn: $draft.value.isActive)
            } header: { Text("Visibility") }

            Section {
                Toggle("Has deadline", isOn: $draft.value.hasDeadline.animation()).tint(Color.mlrPineText)
                if d.hasDeadline {
                    DatePicker("Deadline", selection: $draft.value.deadline,
                               displayedComponents: [.date, .hourAndMinute])
                }
            } header: {
                Text("Deadline")
            } footer: {
                Text("The actual due-by moment (separate from the show window above). Used by scheduled reminders.")
            }

            // Reminders only for a saved callout (needs a real id to attach to).
            if let id = currentId {
                Section {
                    ReminderScheduler(
                        sourceType: "callout",
                        sourceId: id,
                        sourceLabel: hasTitle ? d.title : "callout",
                        anchor: d.hasDeadline ? ReminderAnchor(date: d.deadline, hasTime: true) : nil
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
                }
            }

            Section {
                Toggle("Also send a notification", isOn: $alsoNotify).tint(Color.mlrPineText)
                Toggle("Also email everyone", isOn: $alsoEmail).tint(Color.mlrPineText)
            } header: {
                Text("On save")
            } footer: {
                Text("One-time \u{2014} sends this callout's title & body to everyone's Activity feed / inbox when you save. Resets each time you open this. If a send fails you'll see why, and the callout itself stays saved.")
            }

            Section {
                Button(role: .destructive) { confirmReset = true } label: {
                    Label("Clear all fields", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .disabled(!hasContent && !d.hasDeadline)
                .confirmationDialog("Clear this callout?", isPresented: $confirmReset, titleVisibility: .visible) {
                    Button("Clear all fields", role: .destructive) { resetToBlank() }
                    Button("Cancel", role: .cancel) {}
                }
            }

            if let id = currentId {
                Section {
                    if let deleteError {
                        Text(deleteError).font(.mlrScaled(13)).foregroundStyle(Color.mlrDanger)
                    }
                    Button(role: .destructive) { showDeleteAlert = true } label: {
                        if deleting { ProgressView().frame(maxWidth: .infinity) }
                        else { Text("Delete Callout").frame(maxWidth: .infinity, alignment: .center) }
                    }
                    .disabled(deleting)
                    .alert("Delete this callout?", isPresented: $showDeleteAlert) {
                        Button("Delete", role: .destructive) { Task { await delete(id) } }
                        Button("Cancel", role: .cancel) {}
                    } message: { Text("This removes it from Home for everyone.") }
                }
            }
        }
        .task {
            if env.eventsService.events.isEmpty { await env.eventsService.fetchEvents() }
            if env.dropBoxesService.boxes.isEmpty { await env.dropBoxesService.fetchBoxes() }
        }
    }

    /// Clears EVERYTHING including the linked activity; the picker's "None"
    /// stays available for unlinking just the activity.
    private func resetToBlank() {
        draft.value = CalloutDraft()
        alsoNotify = false; alsoEmail = false
    }

    // MARK: Save

    private struct IdRow: Decodable { let id: UUID }

    /// Only the columns this form owns. Explicit nulls so a cleared field really
    /// clears. `position` / `dismiss_id` are NOT here for an edit (reordering
    /// owns position); a new row gets them in `save()`.
    private func fields(_ c: CalloutDraft) -> [String: AnyJSON] {
        func s(_ v: String) -> AnyJSON {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? .null : .string(t)
        }
        func o(_ v: String?) -> AnyJSON { v.map(AnyJSON.string) ?? .null }
        return [
            "title": s(c.title),
            "body": s(c.body),
            "image_url": o(c.imageUrl),
            "links": .array(c.cleanLinks.map { .object(["href": .string($0.href), "label": o($0.label)]) }),
            "starts_on": o(c.startsOn),
            "ends_on": o(c.endsOn),
            "deadline_at": c.hasDeadline ? .string(ISO8601DateFormatter().string(from: c.deadline)) : .null,
            "is_active": .bool(c.isActive),
            "signup_item_id": o(c.signupItemId),
            "event_id": o(c.eventId),
            "exclude_not_attending": .bool(c.eventId != nil && c.excludeNotAttending),
            "drop_box_id": o(c.dropBoxId),
        ]
    }

    private func write(_ f: [String: AnyJSON], id: String?) async throws -> String {
        if let id {
            try await supabase.from("home_callouts").update(f).eq("id", value: id).execute()
            return id
        }
        let row: IdRow = try await supabase.from("home_callouts").insert(f).select("id").single().execute().value
        return row.id.uuidString
    }

    private func save() async throws {
        let snapshot = draft.value
        let needsWrite = draft.isDirty || currentId == nil
        if needsWrite {
            var f = fields(snapshot)
            var row = f
            if currentId == nil {
                // New card: appended at the end; dismiss_id is NOT NULL in the table.
                let all = (try? await env.festContentService.allCallouts()) ?? env.festContentService.callouts
                f["position"] = .integer((all.map(\.position).max() ?? -1) + 1)
                f["dismiss_id"] = .string("callout-" + UUID().uuidString.lowercased())
                if let uid = try? await supabase.auth.session.user.id { f["created_by"] = .string(uid.uuidString) }
                row = f
            }
            let id: String
            do {
                id = try await write(row, id: currentId)
            } catch where EditorError.message(error).contains("drop_box_id") {
                // Pre-migration 0172: retry without the column (same as the web).
                row.removeValue(forKey: "drop_box_id")
                id = try await write(row, id: currentId)
            }
            savedId = id
            draft.markSaved()
            await env.festContentService.reload()
        }

        // One-time side actions: reported separately from the (already safe) save.
        guard (alsoNotify || alsoEmail), hasTitle else { return }
        let title = snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyText = snapshot.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyOrNil = bodyText.isEmpty ? nil : bodyText
        var failures: [String] = []
        if alsoNotify {
            do {
                try await env.notificationsService.sendBroadcast(
                    title: title, body: bodyOrNil, audience: .everyone, mirrorBanner: false)
                alsoNotify = false
            } catch { failures.append("The notification didn\u{2019}t send: \(EditorError.message(error))") }
        }
        if alsoEmail {
            do {
                try await env.notificationsService.postAnnouncement(
                    title: title, body: bodyOrNil, severity: "alert",
                    showBanner: false, notifyEmail: true, emailAudience: "all",
                    expiresAt: Date.now.addingTimeInterval(6 * 3600))
                alsoEmail = false
            } catch { failures.append("The email didn\u{2019}t send: \(EditorError.message(error))") }
        }
        if !failures.isEmpty {
            throw CalloutSideActionError(message: "Saved. " + failures.joined(separator: " "))
        }
    }

    private func delete(_ id: String) async {
        deleting = true; deleteError = nil
        defer { deleting = false }
        do {
            try await supabase.from("home_callouts").delete().eq("id", value: id).execute()
            await env.festContentService.reload()
            Haptics.warning()
            dismiss()
        } catch {
            deleteError = "Couldn\u{2019}t delete. \(EditorError.message(error))"
            Haptics.error()
        }
    }
}
