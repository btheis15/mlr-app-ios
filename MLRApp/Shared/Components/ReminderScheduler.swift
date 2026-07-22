import SwiftUI

// MARK: - ReminderScheduler
//
// "Remind people before this happens" — an add-on for an event or Home callout
// (migration 0101). Lists the pending reminders already queued for this item
// (scheduled_broadcasts tagged with sourceType/sourceId) and lets an admin add
// another: a relative offset ("1 day before") when the item has a real anchor
// time, or an exact date/time otherwise. Each reminder is a normal scheduled
// notification; cancel works here or from AdminScheduledBroadcasts. Mount only
// once the event/callout has a real id. Mirrors the web ReminderScheduler.

struct ReminderAnchor {
    let date: Date
    /// True when the anchor carries a time of day (events); false for date-only
    /// anchors (a callout deadline), which count offsets from 9am that day.
    let hasTime: Bool
}

struct ReminderScheduler: View {
    @Environment(AppEnvironment.self) private var env

    let sourceType: String          // "event" | "callout"
    let sourceId: String
    let sourceLabel: String
    let anchor: ReminderAnchor?
    var defaultTitle: String? = nil
    var defaultBody: String? = nil
    var eventId: String? = nil

    private struct Offset: Identifiable, Hashable { let label: String; let seconds: TimeInterval; var id: TimeInterval { seconds } }
    private static let hour: TimeInterval = 3600, day: TimeInterval = 86_400
    private var offsets: [Offset] {
        anchor?.hasTime == true
        ? [.init(label: "1 hour before", seconds: hour), .init(label: "2 hours before", seconds: 2*hour),
           .init(label: "1 day before", seconds: day), .init(label: "2 days before", seconds: 2*day),
           .init(label: "3 days before", seconds: 3*day), .init(label: "1 week before", seconds: 7*day)]
        : [.init(label: "1 day before (9am)", seconds: day), .init(label: "2 days before (9am)", seconds: 2*day),
           .init(label: "3 days before (9am)", seconds: 3*day), .init(label: "1 week before (9am)", seconds: 7*day)]
    }
    private var hour: TimeInterval { Self.hour }
    private var day: TimeInterval { Self.day }

    @State private var items: [ScheduledBroadcast] = []
    @State private var loading = true
    @State private var adding = false
    @State private var useCustom = false
    @State private var offsetSeconds: TimeInterval = Self.day
    @State private var customAt = Date.now.addingTimeInterval(86_400)
    @State private var title = ""
    @State private var body_ = ""
    @State private var excludeDone = true
    @State private var onlyUnconfirmed = false
    @State private var busyId: UUID?
    @State private var saving = false
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Reminders")
                Spacer()
                if !adding {
                    Button("+ Add a reminder") { startAdding() }
                        .font(.mlrScaled(12, weight: .semibold))
                        .foregroundStyle(Color.mlrPrimary)
                }
            }

            if loading {
                Text("Loading…").font(.caption).foregroundStyle(Color.mlrTextSubtle)
            } else if items.isEmpty && !adding {
                Text("No reminders scheduled yet.").font(.caption).foregroundStyle(Color.mlrTextSubtle)
            } else {
                ForEach(items) { it in reminderRow(it) }
            }

            if adding { addForm }
        }
        .padding(12)
        .background(Color.mlrSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.mlrBorder, lineWidth: 1))
        .task { await reload() }
    }

    private func reminderRow(_ it: ScheduledBroadcast) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(it.payload.title).font(.mlrScaled(12, weight: .medium)).lineLimit(1)
                Text(statusLine(it)).font(.mlrScaled(11)).foregroundStyle(Color.mlrTextSubtle)
            }
            Spacer(minLength: 6)
            if it.isPending {
                Button { Task { await cancel(it) } } label: {
                    Text(busyId == it.id ? "…" : "Cancel")
                        .font(.mlrScaled(11, weight: .semibold))
                        .foregroundStyle(Color.mlrAccent)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.mlrAccent.opacity(0.12)).clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(busyId == it.id)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.mlrCard).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var addForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            if anchor != nil {
                Picker("When", selection: $useCustom) {
                    Text("Before the \(sourceType)").tag(false)
                    Text("Custom time").tag(true)
                }
                .pickerStyle(.segmented)
            }

            if !useCustom, anchor != nil {
                Picker("Offset", selection: $offsetSeconds) {
                    ForEach(offsets) { Text($0.label).tag($0.seconds) }
                }
                .pickerStyle(.menu)
            } else {
                DatePicker("Send at", selection: $customAt,
                           in: Date.now.addingTimeInterval(120)...,
                           displayedComponents: [.date, .hourAndMinute])
            }

            TextField("Notification title", text: $title).fieldStyle()
            TextField("Details (optional)", text: $body_, axis: .vertical).lineLimit(1...3).fieldStyle()

            if sourceType == "callout" {
                Toggle("Skip anyone who already marked this done", isOn: $excludeDone)
                    .font(.mlrScaled(12)).tint(Color.mlrPrimary)
            }

            if eventId != nil {
                Toggle("Only remind people who haven't confirmed yet", isOn: $onlyUnconfirmed)
                    .font(.mlrScaled(12)).tint(Color.mlrPrimary)
            }

            if let when = computedAt {
                Text(inPast(when) ? "That time has already passed." : "Sends \(formatWhen(when))")
                    .font(.mlrScaled(11))
                    .foregroundStyle(inPast(when) ? Color.mlrDanger : Color.mlrTextSubtle)
            }
            if let status {
                Text(status).font(.mlrScaled(11, weight: .medium)).foregroundStyle(Color.mlrPrimary)
            }

            HStack(spacing: 12) {
                Button { Task { await add() } } label: {
                    Text(saving ? "Scheduling…" : "Add")
                        .font(.mlrScaled(13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(canAdd ? Color.mlrPrimary : Color.mlrTextSubtle)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain).disabled(!canAdd)
                Button("Cancel") { adding = false }
                    .font(.mlrScaled(12, weight: .medium)).foregroundStyle(Color.mlrTextMuted)
            }
        }
        .padding(10)
        .background(Color.mlrCard).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Logic

    private var computedAt: Date? {
        if useCustom || anchor == nil { return customAt }
        guard let anchor else { return nil }
        let base = anchor.hasTime ? anchor.date : nineAM(anchor.date)
        return base.addingTimeInterval(-offsetSeconds)
    }

    private func inPast(_ d: Date) -> Bool { d <= Date.now }

    private var canAdd: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
        && (computedAt.map { !inPast($0) } ?? false)
        && !saving
    }

    private func startAdding() {
        adding = true
        useCustom = anchor == nil
        offsetSeconds = offsets.first?.seconds ?? Self.day
        title = defaultTitle ?? "Reminder: \(sourceLabel)"
        body_ = defaultBody ?? ""
    }

    private func reload() async {
        items = await env.notificationsService.fetchScheduledBroadcastsBySource(
            sourceType: sourceType, sourceId: sourceId)
        loading = false
    }

    private func add() async {
        guard let when = computedAt else { return }
        saving = true; status = nil
        defer { saving = false }
        let payload = BroadcastPayload(
            title: title.trimmingCharacters(in: .whitespaces),
            body: body_.trimmingCharacters(in: .whitespaces).isEmpty ? nil : body_.trimmingCharacters(in: .whitespaces),
            audience: "everyone",
            eventId: eventId,
            excludeNotAttending: eventId != nil ? true : nil,
            onlyUnconfirmed: eventId != nil ? onlyUnconfirmed : nil,
            sourceType: sourceType,
            sourceId: sourceId,
            sourceLabel: sourceLabel,
            excludeCalloutDone: sourceType == "callout" ? excludeDone : nil
        )
        do {
            try await env.notificationsService.scheduleBroadcast(kind: .notification, payload: payload, scheduledAt: when)
            adding = false; body_ = ""
            status = "Reminder scheduled ✓"
            await reload()
        } catch {
            status = "Couldn't schedule the reminder."
        }
    }

    private func cancel(_ it: ScheduledBroadcast) async {
        busyId = it.id
        defer { busyId = nil }
        try? await env.notificationsService.cancelScheduledBroadcast(id: it.id)
        await reload()
    }

    // MARK: - Helpers

    private func nineAM(_ date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
    }

    private func statusLine(_ it: ScheduledBroadcast) -> String {
        if let sent = it.sentAt { return "Sent \(formatWhen(sent))" }
        if let err = it.error, !err.isEmpty { return "Failed: \(err)" }
        return "Sends \(formatWhen(it.scheduledAt))"
    }

    private func formatWhen(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"
        return f.string(from: d)
    }
}
