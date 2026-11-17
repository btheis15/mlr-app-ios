import SwiftUI

// MARK: - EventComposer
// Admin create / edit form for resort events.
// Pass `existing` to edit; omit it to create a new event.

struct EventComposer: View {
    @Environment(AppEnvironment.self) private var env

    let existing: ResortEvent?

    struct Values: Equatable {
        var title = ""
        var description = ""
        var emoji: String?
        var kind: EventKind = .custom
        var startISO = ""            // yyyy-MM-dd
        var endISO: String?          // nil = single day
        var startTime: String?       // HH:mm (nil = no set time)
        var location = ""
        var dayRsvp = false
    }

    @State private var draft: EditorDraft<Values>

    // Work items that can be linked to this event (open items), + current selection.
    @State private var openWorkItems: [WorkItem] = []
    @State private var selectedItemIds: Set<UUID> = []
    @State private var originalItemIds: Set<UUID> = []

    init(existing: ResortEvent? = nil) {
        self.existing = existing
        var v = Values()
        v.startISO = existing?.startDate ?? FestDays.isoFmt.string(from: .now)
        if let existing {
            v.title = existing.title
            v.description = existing.description ?? ""
            v.emoji = existing.emoji
            v.kind = existing.kind
            v.location = existing.location ?? ""
            v.dayRsvp = existing.dayRsvp
            v.endISO = existing.endDate
            v.startTime = existing.startTime
        }
        _draft = State(initialValue: EditorDraft(v))
    }

    private var isEditing: Bool { existing != nil }

    /// The moment a reminder counts down to — the event's start date + start time
    /// (date-only when the event has no set time).
    private var reminderAnchor: ReminderAnchor? {
        guard let existing else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd"
        iso.timeZone = cal.timeZone
        guard let day = iso.date(from: existing.startDate) else { return nil }
        if let hhmm = existing.startTime {
            let parts = hhmm.split(separator: ":")
            let h = Int(parts.first ?? "0") ?? 0
            let m = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            let dt = cal.date(bySettingHour: h, minute: m, second: 0, of: day) ?? day
            return ReminderAnchor(date: dt, hasTime: true)
        }
        return ReminderAnchor(date: day, hasTime: false)
    }

    private var endBeforeStart: Bool {
        if let end = draft.value.endISO { return end < draft.value.startISO }
        return false
    }

    private var canSave: Bool {
        !draft.value.title.trimmingCharacters(in: .whitespaces).isEmpty && !endBeforeStart
    }

    var body: some View {
        EditorSheet(title: isEditing ? "Edit Event" : "New Event",
                    isDirty: draft.isDirty || selectedItemIds != originalItemIds,
                    canSave: canSave,
                    save: { try await save() }) {
            Section("Details") {
                EditorTextField("Event title", text: $draft.value.title, limit: 120, required: true)
                EditorEmojiField("Emoji", emoji: $draft.value.emoji)
                EditorLongText("Description", text: $draft.value.description, lines: 3...6)
                EditorTextField("Location", text: $draft.value.location, limit: 120)
            }

            Section("Kind") {
                Picker("Kind", selection: $draft.value.kind) {
                    Text("Work Weekend").tag(EventKind.workWeekend)
                    Text("Holiday").tag(EventKind.holiday)
                    Text("Other event").tag(EventKind.custom)
                }
                .pickerStyle(.segmented)
                if isEditing && existing?.isFamilyFest == true {
                    Text("Family Fest kind is fixed.")
                        .font(.caption)
                        .foregroundStyle(Color.mlrTextMuted)
                }
            }
            .disabled(existing?.isFamilyFest == true)

            Section("Dates") {
                EditorDateField("Starts", iso: $draft.value.startISO)
                EditorDateField("Ends (multi-day events)", iso: $draft.value.endISO,
                                isOptional: true, minISO: draft.value.startISO)
                if endBeforeStart {
                    Text("The end date can\u{2019}t be before the start date.")
                        .font(.caption).foregroundStyle(Color.mlrDanger)
                }
                EditorTimeField("Start time", time: $draft.value.startTime)
            }

            Section {
                EditorToggle("Per-day RSVP", isOn: $draft.value.dayRsvp,
                             caption: "Lets members pick which days they're coming (used for Family Fest).")
            }

            if !openWorkItems.isEmpty {
                Section {
                    ForEach(openWorkItems) { item in
                        Button {
                            if selectedItemIds.contains(item.id) {
                                selectedItemIds.remove(item.id)
                            } else {
                                selectedItemIds.insert(item.id)
                            }
                        } label: {
                            HStack {
                                Image(systemName: selectedItemIds.contains(item.id) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(selectedItemIds.contains(item.id) ? Color.mlrPrimary : Color.mlrTextSubtle)
                                Text(item.title)
                                    .foregroundStyle(Color.mlrText)
                                Spacer()
                            }
                        }
                    }
                } header: {
                    Text("Work items")
                } footer: {
                    Text("Check off tasks from the work checklist to plan them for this event.")
                }
            }

            // Reminders — only for a saved event (needs a real id to attach to).
            if let existing {
                Section {
                    ReminderScheduler(
                        sourceType: "event",
                        sourceId: existing.id,
                        sourceLabel: existing.title,
                        anchor: reminderAnchor,
                        eventId: existing.id
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
                }
            }
        }
        .tint(Color.mlrPineText)
        .task { await loadWorkItems() }
    }

    private func loadWorkItems() async {
        await env.workItemsService.fetchItems()
        openWorkItems = env.workItemsService.openItems
        if let existing {
            let linked = await env.workItemsService.fetchEventItems(eventId: existing.id)
            let ids = Set(linked.map(\.id))
            // Don't clobber ticks the user made while this was loading.
            if selectedItemIds == originalItemIds { selectedItemIds = ids }
            originalItemIds = ids
        }
    }

    private func save() async throws {
        let v = draft.value
        let trimmedDesc = v.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let descParam = trimmedDesc.isEmpty ? nil : trimmedDesc
        let trimmedLoc = v.location.trimmingCharacters(in: .whitespacesAndNewlines)
        let locParam = trimmedLoc.isEmpty ? nil : trimmedLoc
        let title = v.title.trimmingCharacters(in: .whitespaces)

        let eventId: String
        if let existing {
            try await env.eventsService.updateEvent(
                id: existing.id,
                title: title,
                description: descParam,
                kind: v.kind,
                startDate: v.startISO,
                endDate: v.endISO,
                location: locParam,
                dayRsvp: v.dayRsvp,
                emoji: v.emoji,
                startTime: v.startTime
            )
            eventId = existing.id
        } else {
            eventId = try await env.eventsService.createEvent(
                title: title,
                description: descParam,
                kind: v.kind,
                startDate: v.startISO,
                endDate: v.endISO,
                location: locParam,
                dayRsvp: v.dayRsvp,
                emoji: v.emoji,
                startTime: v.startTime
            )
        }
        // Replace the event's linked work items with the current selection.
        try await env.workItemsService.syncEventItems(eventId: eventId, itemIds: Array(selectedItemIds))
    }
}
