import SwiftUI
import CoreLocation

// MARK: - AskForHelpSheet
// Compose an Ask-for-Help request: category, what (140 max), how many people,
// where (free text), optional scheduled time, "notify everyone willing"
// escape hatch. Submits via helpService.requestHelp (event targeting is
// resolved inside the service via helpTargeting()).

struct AskForHelpSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var category: HelpCategory = .hand
    @State private var what = ""
    @State private var neededCount = 1
    @State private var whereText = ""
    @State private var hasSchedule = false
    @State private var scheduledFor: Date = .now
    @State private var notifyAll = false
    // "When do you need help?" — right now, or an upcoming event the member
    // is going to (schedule-ahead targeting, event-gated so this can never
    // become a random off-resort ask).
    @State private var targetEvent: ResortEvent? = nil
    // One-tap GPS pin (optional) — a single on-device location read, not a
    // live tracker (see OneShotLocationFetcher).
    @State private var pinCoordinate: CLLocationCoordinate2D? = nil
    @State private var locationBusy = false
    @State private var locationError: String? = nil
    private let locationFetcher = OneShotLocationFetcher()
    @State private var bringItems: [String] = []
    @State private var newItem = ""
    @State private var linkedWorkItem: WorkItem?
    @State private var showTaskPicker = false

    @State private var isSubmitting = false
    @State private var submitError: String?

    private let maxWhat = 140

    private var canSubmit: Bool {
        !what.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSubmitting
    }

    /// Upcoming events (strictly after today) the member is RSVP'd going to —
    /// the pool a "schedule ahead" request can target. Mirrors web's
    /// `goingFuture` in HelpRequestsView.
    private var goingFutureEvents: [ResortEvent] {
        let today = Calendar.current.startOfDay(for: .now)
        return env.eventsService.events.filter { event in
            guard let start = event.startDateParsed, start > today else { return false }
            return env.eventsService.attendances[event.id]?.effectiveStatus() == .going
        }.sorted { ($0.startDateParsed ?? .distantFuture) < ($1.startDateParsed ?? .distantFuture) }
    }

    /// The target event's morning (9 AM local) — where `needed_at` lands for
    /// a scheduled-ahead request, matching web's activityReminderDefaults idiom.
    private func morningOf(_ event: ResortEvent) -> Date {
        guard let start = event.startDateParsed else { return .now }
        return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: start) ?? start
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    categorySection
                    workItemSection
                    whatSection
                    peopleSection
                    whereSection
                    locationSection
                    scheduleSection
                    itemsSection
                    if targetEvent == nil { notifyAllSection }

                    if let submitError {
                        Text(submitError)
                            .font(.mlrCaption)
                            .foregroundStyle(Color.mlrDanger)
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Ask for Help")
            .navigationBarTitleDisplayMode(.inline)
            .tint(Color.mlrFest)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Button("Send") { Task { await submit() } }
                            .fontWeight(.semibold)
                            .disabled(!canSubmit)
                    }
                }
            }
            .task {
                if env.workItemsService.items.isEmpty {
                    await env.workItemsService.fetchItems()
                }
            }
            .sheet(isPresented: $showTaskPicker) {
                WorkItemPickerSheet(items: env.workItemsService.openItems) { item in
                    linkedWorkItem = item
                    // Prefill the request text with the task title if the user
                    // hasn't typed anything yet.
                    if what.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        what = item.title
                    }
                }
            }
        }
    }

    // MARK: - Category

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "What kind of help?")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(HelpCategory.allCases, id: \.self) { cat in
                        Button {
                            Haptics.tap()
                            category = cat
                        } label: {
                            Text("\(cat.emoji) \(cat.label)")
                                .font(.mlrScaled(13, weight: .semibold))
                                .foregroundStyle(category == cat ? .white : Color.mlrText)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(category == cat
                                            ? (cat == .urgent ? Color.mlrDanger : Color.mlrFest)
                                            : Color.mlrCard)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
        }
    }

    // MARK: - What

    private var whatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "What do you need?")
                Spacer()
                Text("\(what.count)/\(maxWhat)")
                    .font(.mlrScaled(11))
                    .foregroundStyle(what.count > maxWhat ? Color.mlrDanger : Color.mlrTextSubtle)
            }
            TextEditor(text: $what)
                .frame(minHeight: 80)
                .padding(8)
                .background(Color.mlrSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.mlrBorder, lineWidth: 1))
                .onChange(of: what) { _, new in
                    if new.count > maxWhat { what = String(new.prefix(maxWhat)) }
                }
        }
    }

    // MARK: - People

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "How many people?")
            Stepper(value: $neededCount, in: 1...5) {
                Text("\(neededCount) \(neededCount == 1 ? "person" : "people")")
                    .foregroundStyle(Color.mlrText)
            }
            .padding(14)
            .background(Color.mlrCard)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Where

    private var whereSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Where? (optional)")
            TextField("e.g. Cabin 3, the dock, the pavilion", text: $whereText)
                .fieldStyle()
        }
    }

    // MARK: - When (right now, or an upcoming event you're going to)

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "When do you need help?")
            Button {
                withAnimation { targetEvent = nil }
            } label: {
                whenRow(title: "Right now", subtitle: nil, selected: targetEvent == nil)
            }
            .buttonStyle(.pressable)

            ForEach(goingFutureEvents) { event in
                Button {
                    withAnimation { targetEvent = event }
                } label: {
                    whenRow(title: event.title, subtitle: MLRFormat.shortDateISO(event.startDate),
                            selected: targetEvent?.id == event.id)
                }
                .buttonStyle(.pressable)
            }

            // A scheduled-ahead request is scoped to that event's crew and
            // anchored to the event date — no separate time picker needed.
            if targetEvent == nil {
                Toggle(isOn: $hasSchedule.animation()) {
                    Text("Schedule for a specific time")
                        .font(.mlrScaled(15))
                        .foregroundStyle(Color.mlrText)
                }
                .tint(Color.mlrFest)
                .padding(.top, 4)
                if hasSchedule {
                    DatePicker("When", selection: $scheduledFor, displayedComponents: [.date, .hourAndMinute])
                }
            }
        }
        .padding(14)
        .background(Color.mlrCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func whenRow(title: String, subtitle: String?, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.mlrFest : Color.mlrTextSubtle)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.mlrScaled(14, weight: .medium)).foregroundStyle(Color.mlrText)
                if let subtitle {
                    Text(subtitle).font(.mlrScaled(12)).foregroundStyle(Color.mlrTextMuted)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    // MARK: - Location pin

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let pinCoordinate {
                HStack(spacing: 10) {
                    Image(systemName: "mappin.circle.fill").foregroundStyle(Color.mlrFest)
                    Text("GPS pin added").font(.mlrScaled(14)).foregroundStyle(Color.mlrText)
                    Spacer()
                    Button("Remove") { self.pinCoordinate = nil }
                        .font(.mlrScaled(13, weight: .medium))
                        .foregroundStyle(Color.mlrTextSubtle)
                }
            } else {
                Button {
                    Task { await addGPSPin() }
                } label: {
                    HStack(spacing: 10) {
                        if locationBusy { ProgressView() } else { Image(systemName: "location.fill") }
                        Text("Add my GPS pin")
                            .font(.mlrScaled(14, weight: .medium))
                        Spacer()
                    }
                    .foregroundStyle(Color.mlrFest)
                }
                .buttonStyle(.pressable)
                .disabled(locationBusy)
            }
            if let locationError {
                Text(locationError).font(.mlrCaption).foregroundStyle(Color.mlrDanger)
            }
        }
        .padding(14)
        .background(Color.mlrCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func addGPSPin() async {
        locationBusy = true
        locationError = nil
        defer { locationBusy = false }
        do {
            pinCoordinate = try await locationFetcher.fetch()
        } catch {
            locationError = "Couldn't get your location. Check Settings → Privacy → Location Services."
        }
    }

    // MARK: - Link a Work Checklist task

    private var workItemSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Link a Work Checklist task (optional)")
            Button {
                showTaskPicker = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: linkedWorkItem == nil ? "checklist" : "checkmark.circle.fill")
                        .foregroundStyle(Color.mlrFest)
                    Text(linkedWorkItem?.title ?? "Choose a task…")
                        .font(.mlrScaled(15))
                        .foregroundStyle(linkedWorkItem == nil ? Color.mlrTextMuted : Color.mlrText)
                        .lineLimit(1)
                    Spacer()
                    if linkedWorkItem != nil {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.mlrTextSubtle)
                            .onTapGesture { linkedWorkItem = nil }
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.mlrScaled(13))
                            .foregroundStyle(Color.mlrTextSubtle)
                    }
                }
                .padding(14)
                .background(Color.mlrCard)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.pressable)
            if linkedWorkItem != nil {
                Text("Later today we'll ask if this got done — tapping “Yes” checks it off the list.")
                    .font(.mlrCaption)
                    .foregroundStyle(Color.mlrTextMuted)
            }
        }
    }

    /// When a task is linked, schedule the "did this get done?" nudge for 9 PM
    /// resort-local today — or 8 AM the next morning if it's already past 6 PM.
    private func followupTime() -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        let now = Date.now
        let hour = cal.component(.hour, from: now)
        if hour >= 18 {
            let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now
            return cal.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? now
        }
        return cal.date(bySettingHour: 21, minute: 0, second: 0, of: now) ?? now
    }

    // MARK: - What to bring

    private var itemsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "What to bring? (optional)")
            ForEach(Array(bringItems.enumerated()), id: \.offset) { index, item in
                HStack {
                    Text("• \(item)")
                        .font(.mlrScaled(14))
                        .foregroundStyle(Color.mlrText)
                    Spacer()
                    Button {
                        bringItems.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(Color.mlrDanger)
                    }
                    .buttonStyle(.pressable)
                }
            }
            HStack {
                TextField("Add an item (e.g. \"a folding table\")", text: $newItem)
                    .fieldStyle()
                Button("Add") { addItem() }
                    .font(.mlrScaled(14, weight: .semibold))
                    .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Helpers can check off the items they're bringing.")
                .font(.mlrCaption)
                .foregroundStyle(Color.mlrTextMuted)
        }
    }

    private func addItem() {
        let v = newItem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        bringItems.append(v)
        newItem = ""
    }

    // MARK: - Notify all

    private var notifyAllSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $notifyAll) {
                Text("Notify everyone willing")
                    .font(.mlrScaled(15))
                    .foregroundStyle(Color.mlrText)
            }
            .tint(Color.mlrFest)
            Text("Reaches all willing helpers, even those not currently at the resort. Use when you really need the extra hands.")
                .font(.mlrCaption)
                .foregroundStyle(Color.mlrTextMuted)
        }
        .padding(14)
        .background(Color.mlrCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Submit

    private func submit() async {
        guard env.isSignedIn else { env.authService.promptSignIn(); return }
        isSubmitting = true
        submitError = nil
        defer { isSubmitting = false }

        let trimmedWhere = whereText.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveScheduledFor: Date? = targetEvent.map(morningOf) ?? (hasSchedule ? scheduledFor : nil)
        do {
            try await env.helpService.requestHelp(
                category: category,
                what: what.trimmingCharacters(in: .whitespacesAndNewlines),
                neededCount: neededCount,
                whereDescription: trimmedWhere.isEmpty ? nil : trimmedWhere,
                latitude: pinCoordinate?.latitude,
                longitude: pinCoordinate?.longitude,
                scheduledFor: effectiveScheduledFor,
                notifyAll: targetEvent == nil && notifyAll,
                items: bringItems,
                workItemId: linkedWorkItem?.id,
                followupAt: linkedWorkItem != nil ? followupTime() : nil,
                targetEventId: targetEvent?.id
            )
            Haptics.success()
            dismiss()
        } catch {
            submitError = "Couldn't send your request. Check your connection and try again."
            print("[AskForHelp] submit error: \(error)")
        }
    }
}

// MARK: - Work Item Picker

/// Pick an open task from the Work Checklist to link to a help request.
private struct WorkItemPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let items: [WorkItem]
    let onPick: (WorkItem) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView(
                        "No open tasks",
                        systemImage: "checklist",
                        description: Text("There are no open Work Checklist tasks to link right now.")
                    )
                } else {
                    List(items) { item in
                        Button {
                            onPick(item)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "circle")
                                    .foregroundStyle(Color.mlrTextSubtle)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.mlrScaled(15, weight: .medium))
                                        .foregroundStyle(Color.mlrText)
                                    if let notes = item.notes, !notes.isEmpty {
                                        Text(notes)
                                            .font(.mlrCaption)
                                            .foregroundStyle(Color.mlrTextMuted)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Link a task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
