import SwiftUI

// MARK: - EventComposer
// Admin create / edit form for resort events.
// Pass `existing` to edit; omit it to create a new event.

struct EventComposer: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let existing: ResortEvent?

    @State private var title: String
    @State private var description: String
    @State private var kind: EventKind
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var hasEndDate: Bool
    @State private var location: String
    @State private var dayRsvp: Bool

    @State private var hasStartTime: Bool
    @State private var startTimeDate: Date

    @State private var isSaving = false
    @State private var saveError: String?

    // Work items that can be linked to this event (open items), + current selection.
    @State private var openWorkItems: [WorkItem] = []
    @State private var selectedItemIds: Set<UUID> = []

    init(existing: ResortEvent? = nil) {
        self.existing = existing
        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd"
        iso.timeZone = TimeZone(identifier: "America/Chicago")

        _title       = State(initialValue: existing?.title ?? "")
        _description = State(initialValue: existing?.description ?? "")
        _kind        = State(initialValue: existing?.kind ?? .custom)
        _location    = State(initialValue: existing?.location ?? "")
        _dayRsvp     = State(initialValue: existing?.dayRsvp ?? false)

        let start = existing.flatMap { iso.date(from: $0.startDate) } ?? .now
        _startDate = State(initialValue: start)

        if let endStr = existing?.endDate, let end = iso.date(from: endStr) {
            _endDate = State(initialValue: end)
            _hasEndDate = State(initialValue: true)
        } else {
            _endDate = State(initialValue: start)
            _hasEndDate = State(initialValue: false)
        }

        if let hhmm = existing?.startTime {
            _hasStartTime = State(initialValue: true)
            _startTimeDate = State(initialValue: Self.parseTime(hhmm))
        } else {
            _hasStartTime = State(initialValue: false)
            _startTimeDate = State(initialValue: Self.defaultTime())
        }
    }

    private static func parseTime(_ hhmm: String) -> Date {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return defaultTime() }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago")!
        var comps = cal.dateComponents([.year, .month, .day], from: .now)
        comps.hour = parts[0]; comps.minute = parts[1]
        return cal.date(from: comps) ?? defaultTime()
    }

    private static func defaultTime() -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago")!
        var comps = cal.dateComponents([.year, .month, .day], from: .now)
        comps.hour = 9; comps.minute = 0
        return cal.date(from: comps) ?? .now
    }

    private var startTimeString: String? {
        guard hasStartTime else { return nil }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone(identifier: "America/Chicago")!
        return f.string(from: startTimeDate)
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

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Event title", text: $title)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                    TextField("Location", text: $location)
                }

                Section("Kind") {
                    Picker("Kind", selection: $kind) {
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
                    DatePicker("Starts", selection: $startDate, displayedComponents: .date)
                    Toggle("Multi-day event", isOn: $hasEndDate.animation())
                    if hasEndDate {
                        DatePicker("Ends", selection: $endDate,
                                   in: startDate..., displayedComponents: .date)
                    }
                    Toggle("Set start time", isOn: $hasStartTime.animation())
                    if hasStartTime {
                        DatePicker("Time", selection: $startTimeDate,
                                   displayedComponents: .hourAndMinute)
                    }
                }

                Section {
                    Toggle("Per-day RSVP", isOn: $dayRsvp)
                } footer: {
                    Text("Lets members pick which days they're coming (used for Family Fest).")
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

                if let saveError {
                    Section {
                        Text(saveError)
                            .font(.mlrCaption)
                            .foregroundStyle(Color.mlrDanger)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Event" : "New Event")
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
                            .disabled(!canSave)
                    }
                }
            }
            .task { await loadWorkItems() }
        }
    }

    private func loadWorkItems() async {
        await env.workItemsService.fetchItems()
        openWorkItems = env.workItemsService.openItems
        if let existing {
            let linked = await env.workItemsService.fetchEventItems(eventId: existing.id)
            selectedItemIds = Set(linked.map(\.id))
        }
    }

    private func save() async {
        isSaving = true
        saveError = nil
        defer { isSaving = false }

        let startISO = startDate.isoDateString
        let endISO: String? = hasEndDate ? endDate.isoDateString : nil
        let trimmedDesc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let descParam = trimmedDesc.isEmpty ? nil : trimmedDesc
        let trimmedLoc = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let locParam = trimmedLoc.isEmpty ? nil : trimmedLoc

        do {
            let eventId: String
            if let existing {
                try await env.eventsService.updateEvent(
                    id: existing.id,
                    title: title,
                    description: descParam,
                    kind: kind,
                    startDate: startISO,
                    endDate: endISO,
                    location: locParam,
                    dayRsvp: dayRsvp,
                    startTime: startTimeString
                )
                eventId = existing.id
            } else {
                eventId = try await env.eventsService.createEvent(
                    title: title,
                    description: descParam,
                    kind: kind,
                    startDate: startISO,
                    endDate: endISO,
                    location: locParam,
                    dayRsvp: dayRsvp,
                    startTime: startTimeString
                )
            }
            // Replace the event's linked work items with the current selection.
            try await env.workItemsService.syncEventItems(eventId: eventId, itemIds: Array(selectedItemIds))
            dismiss()
        } catch {
            saveError = "Couldn't save the event. Check your connection and try again."
            print("[EventComposer] save error: \(error)")
        }
    }
}
