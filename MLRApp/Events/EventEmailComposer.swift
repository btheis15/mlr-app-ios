import SwiftUI
import Supabase

// MARK: - Email everyone about an event (migrations 0190–0193, 0197, 0204)
//
// ⚠️ NOTHING SENDS UNTIL IT'S BEEN REVIEWED. The entry point is "Preview the
// email →"; only the preview screen can send.
//
// ⚠️ The preview is NOT assembled client-side. `event_message_preview` is a dry
// run of the SAME SQL the real send uses — a house-scoped work item is
// RLS-invisible to a non-member, so building the body here would render a
// different email than the one that actually goes out.
//
// ⚠️ ONE SEND PER AUDIENCE, NOT ONE EMAIL. Recipients come back pre-sorted into
// buckets — one per house that has work items, plus a "general" one. A person
// lands in exactly one. The house copy SAYS it's the house copy; the general
// copy stays completely silent that a hidden list exists.

struct EventMessageWorkItem: Decodable, Identifiable {
    let title: String
    let notes: String?
    let urgency: String?
    let customLabel: String?
    let customColor: String?
    let peopleNeeded: Int?

    var id: String { title }
}

struct EventMessageHouseGroup: Decodable, Identifiable {
    let houseId: UUID
    let name: String
    let emoji: String?
    let items: [EventMessageWorkItem]?
    /// A COUNT, not addresses — the preview never returns email addresses.
    let recipients: Int

    var id: UUID { houseId }
}

struct EventMessagePreview: Decodable {
    let senderName: String?
    let senderEmail: String?
    let eventId: String
    let eventTitle: String?
    let eventWhen: String?
    let eventEmoji: String?
    let eventLocation: String?
    let eventDescription: String?
    let mlrItems: [EventMessageWorkItem]?
    let houseGroups: [EventMessageHouseGroup]?
    let generalRecipients: Int?

    enum CodingKeys: String, CodingKey {
        case senderName = "sender_name"
        case senderEmail = "sender_email"
        case eventId = "event_id"
        case eventTitle = "event_title"
        case eventWhen = "event_when"
        case eventEmoji = "event_emoji"
        case eventLocation = "event_location"
        case eventDescription = "event_description"
        case mlrItems = "mlr_items"
        case houseGroups = "house_groups"
        case generalRecipients = "general_recipients"
    }

    /// Everyone who'd receive something, across every bucket.
    var totalRecipients: Int {
        (generalRecipients ?? 0) + (houseGroups ?? []).reduce(0) { $0 + $1.recipients }
    }
}

@Observable
@MainActor
final class EventMessageService {

    func preview(eventId: String, title: String?, when: String?,
                 includeWorkItems: Bool, excludeNotAttending: Bool,
                 includeRoster: Bool) async throws -> EventMessagePreview? {
        struct P: Encodable {
            let p_event_id: String
            let p_event_title: String?
            let p_event_when: String?
            let p_include_work_items: Bool
            let p_exclude_not_attending: Bool
            let p_include_roster: Bool
        }
        let rows: [EventMessagePreview] = try await supabase
            .rpc("event_message_preview", params: P(
                p_event_id: eventId, p_event_title: title, p_event_when: when,
                p_include_work_items: includeWorkItems,
                p_exclude_not_attending: excludeNotAttending,
                p_include_roster: includeRoster
            )).execute().value
        return rows.first
    }

    /// Returns how many people were mailed, across every bucket.
    @discardableResult
    func send(eventId: String, title: String, when: String?,
              subject: String?, body: String?,
              includeWorkItems: Bool, excludeNotAttending: Bool,
              includeRoster: Bool) async throws -> Int {
        struct P: Encodable {
            let p_event_id: String
            let p_event_title: String
            let p_event_when: String?
            let p_subject: String?
            let p_body: String?
            let p_include_work_items: Bool
            let p_exclude_not_attending: Bool
            let p_include_roster: Bool
        }
        let count: Int = try await supabase
            .rpc("send_event_message", params: P(
                p_event_id: eventId, p_event_title: title, p_event_when: when,
                p_subject: subject, p_body: body,
                p_include_work_items: includeWorkItems,
                p_exclude_not_attending: excludeNotAttending,
                p_include_roster: includeRoster
            )).execute().value
        return count
    }

    // MARK: - Manual attendee add (migration 0196)
    //
    // ⚠️ TWO RPCs, DELIBERATELY SEPARATE. Collapsing them into one "type a name"
    // box is exactly the confusion they exist to fix.

    @discardableResult
    func addFamilyMember(eventId: String, userId: UUID? = nil,
                         rosterId: UUID? = nil, status: String = "going") async throws -> UUID {
        struct P: Encodable {
            let p_event_id: String; let p_user_id: String?
            let p_roster_id: String?; let p_status: String
        }
        return try await supabase.rpc("add_event_family_member", params: P(
            p_event_id: eventId, p_user_id: userId?.uuidString,
            p_roster_id: rosterId?.uuidString, p_status: status
        )).execute().value
    }

    /// ⚠️ A guest's SPONSOR IS REQUIRED and picked from a dropdown, never typed,
    /// so an outside guest is always traceable to a family member.
    @discardableResult
    func addGuest(eventId: String, name: String, sponsorUserId: UUID,
                  status: String = "going", email: String? = nil) async throws -> UUID {
        struct P: Encodable {
            let p_event_id: String; let p_name: String; let p_sponsor_user_id: String
            let p_status: String; let p_email: String?
        }
        return try await supabase.rpc("add_event_guest", params: P(
            p_event_id: eventId, p_name: name,
            p_sponsor_user_id: sponsorUserId.uuidString,
            p_status: status, p_email: email
        )).execute().value
    }
}

// MARK: - The composer

struct EventEmailComposer: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let event: ResortEvent

    @State private var includeWorkItems = true
    @State private var excludeNotAttending = true
    @State private var includeRoster = true
    @State private var subject = ""
    @State private var note = ""
    @State private var preview: EventMessagePreview?
    @State private var loading = false
    @State private var showingPreview = false
    @State private var error: String?

    private var service: EventMessageService { env.eventMessageService }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Subject (optional)", text: $subject)
                    TextField("A note to go at the top (optional)", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                } footer: {
                    Text("Leave both empty and the email uses the event's own details.")
                }

                Section("Who gets it") {
                    Toggle("Skip people who said they're not coming", isOn: $excludeNotAttending)
                    Toggle("Include family not on the app", isOn: $includeRoster)
                }

                Section {
                    Toggle("Include the work-item plan", isOn: $includeWorkItems)
                } footer: {
                    Text("Each house only ever sees its own items — the general copy doesn't mention them at all.")
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.mlrScaled(13)).foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await loadPreview() }
                    } label: {
                        HStack {
                            Text("Preview the email →").fontWeight(.semibold)
                            if loading { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(loading)
                } footer: {
                    Text("Nothing sends from here. You'll see the real email, and who it goes to, before anything leaves.")
                }
            }
            .navigationTitle("Email everyone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .navigationDestination(isPresented: $showingPreview) {
                if let preview {
                    EventEmailPreviewView(
                        event: event, preview: preview,
                        subject: subject.isEmpty ? nil : subject,
                        note: note.isEmpty ? nil : note,
                        includeWorkItems: includeWorkItems,
                        excludeNotAttending: excludeNotAttending,
                        includeRoster: includeRoster,
                        onSent: { dismiss() }
                    )
                }
            }
        }
    }

    private func loadPreview() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            preview = try await service.preview(
                // ⚠️ `p_event_when` is a display string that goes straight into
                // the email body, not a date the server parses. Passing the raw
                // ISO would mail the family "2026-09-06".
                eventId: event.id, title: event.title,
                when: MLRFormat.dateRange(start: event.startDate, end: event.endDate),
                includeWorkItems: includeWorkItems,
                excludeNotAttending: excludeNotAttending,
                includeRoster: includeRoster
            )
            if preview == nil {
                error = "Couldn't build a preview for this event."
            } else {
                showingPreview = true
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - The preview — the only screen that can send

private struct EventEmailPreviewView: View {
    @Environment(AppEnvironment.self) private var env
    let event: ResortEvent
    let preview: EventMessagePreview
    let subject: String?
    let note: String?
    let includeWorkItems: Bool
    let excludeNotAttending: Bool
    let includeRoster: Bool
    let onSent: () -> Void

    @State private var sending = false
    @State private var sentCount: Int?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                if preview.totalRecipients == 0 {
                    Label("Nobody would receive this — there's no one to send it to.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.mlrScaled(13)).foregroundStyle(.orange)
                } else {
                    // One line per bucket, because that's literally one send
                    // each. A person lands in exactly one.
                    if let general = preview.generalRecipients, general > 0 {
                        LabeledContent("Everyone else") { Text("\(general)") }
                    }
                    ForEach(preview.houseGroups ?? []) { group in
                        LabeledContent("\(group.emoji ?? "🏠") \(group.name)") {
                            Text("\(group.recipients)")
                        }
                    }
                }
            } header: {
                Text("Who gets it — \(preview.totalRecipients) in total")
            } footer: {
                Text("Each house gets its own copy naming its work items. The general copy doesn't mention that the house lists exist.")
            }

            Section("The email") {
                if let from = preview.senderName {
                    LabeledContent("From") { Text(from) }
                }
                LabeledContent("Subject") {
                    Text(subject ?? "\(preview.eventEmoji ?? "📅") \(preview.eventTitle ?? event.title)")
                        .multilineTextAlignment(.trailing)
                }
                if let note {
                    Text(note).font(.mlrScaled(13))
                }
                if let when = preview.eventWhen { LabeledContent("When") { Text(when) } }
                if let place = preview.eventLocation { LabeledContent("Where") { Text(place) } }
                if let desc = preview.eventDescription, !desc.isEmpty {
                    Text(desc).font(.mlrScaled(13)).foregroundStyle(Color.mlrTextMuted)
                }
            }

            if includeWorkItems, let items = preview.mlrItems, !items.isEmpty {
                Section("🌲 Around the Resort") {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.mlrScaled(14, weight: .medium))
                            if let n = item.notes, !n.isEmpty {
                                Text(n).font(.mlrScaled(12)).foregroundStyle(Color.mlrTextMuted)
                            }
                        }
                    }
                }
            }

            if includeWorkItems {
                ForEach(preview.houseGroups ?? []) { group in
                    if let items = group.items, !items.isEmpty {
                        Section("\(group.emoji ?? "🏠") \(group.name) — their copy only") {
                            ForEach(items) { item in
                                Text(item.title).font(.mlrScaled(14))
                            }
                        }
                    }
                }
            }

            if let sentCount {
                Section {
                    Label("Sent to \(sentCount) \(sentCount == 1 ? "person" : "people").",
                          systemImage: "checkmark.circle.fill")
                        .font(.mlrScaled(13)).foregroundStyle(Color.mlrSuccess)
                }
            } else {
                Section {
                    Button {
                        Task { await send() }
                    } label: {
                        HStack {
                            Text("Send it").fontWeight(.semibold)
                            if sending { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(sending || preview.totalRecipients == 0)
                }
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.mlrScaled(13)).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Preview")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func send() async {
        sending = true
        error = nil
        defer { sending = false }
        do {
            let count = try await env.eventMessageService.send(
                eventId: event.id, title: preview.eventTitle ?? event.title,
                when: preview.eventWhen, subject: subject, body: note,
                includeWorkItems: includeWorkItems,
                excludeNotAttending: excludeNotAttending,
                includeRoster: includeRoster
            )
            sentCount = count
            Haptics.success()
            try? await Task.sleep(for: .seconds(1.2))
            onSent()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
