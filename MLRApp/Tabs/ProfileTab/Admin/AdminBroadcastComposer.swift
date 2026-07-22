import SwiftUI
import Supabase

// MARK: - AdminBroadcastComposer (migration 0126)
//
// One admin form that replaces the separate "Post an alert" + "Send a
// notification" composers. Three INDEPENDENT channels — 📣 Banner, 🔔 Activity
// tab, ✉️ Email — at least one required. A send can now email opted-in members
// WITHOUT painting a banner (announcements.show_banner=false). Mirrors the web
// AdminBroadcastComposer.

struct AdminBroadcastComposer: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    enum Audience: String, CaseIterable, Identifiable {
        case everyone, admins
        var id: String { rawValue }
        var label: String { self == .everyone ? "Everyone" : "Admins only" }
        var broadcast: BroadcastAudience { self == .everyone ? .everyone : .admins }
        var emailAudience: String { self == .everyone ? "all" : "admins" }
    }

    @State private var title = ""
    @State private var messageBody = ""
    @State private var kind: AnnouncementKind = .info
    @State private var expiry: ExpiryWindow = .sixHours
    @State private var audience: Audience = .everyone

    // Channels (≥1 required).
    @State private var toBanner = true
    @State private var toActivity = false
    @State private var toEmail = false

    @State private var selectedEventId: String? = nil
    @State private var excludeNotAttending = true
    @State private var scheduleAt: Date? = nil
    @State private var isPosting = false
    @State private var error: String? = nil
    @State private var posted = false

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespaces) }
    private var hasChannel: Bool { toBanner || toActivity || toEmail }
    private var canPost: Bool { !trimmedTitle.isEmpty && hasChannel && !isPosting }
    private var upcomingEvents: [ResortEvent] { env.eventsService.upcomingEvents }

    var body: some View {
        NavigationStack {
            Form {
                Section("Message") {
                    TextField("Title (required)", text: $title).font(.mlrScaled(16, weight: .medium))
                    ZStack(alignment: .topLeading) {
                        if messageBody.isEmpty {
                            Text("Body (optional)").foregroundStyle(Color.mlrTextSubtle)
                                .padding(.top, 8).padding(.leading, 4)
                        }
                        TextEditor(text: $messageBody).frame(minHeight: 80)
                    }
                }

                Section {
                    channelToggle($toBanner, "📣 Banner", "Top-of-app banner everyone sees")
                    channelToggle($toActivity, "🔔 Activity tab", "A notification in every member's Activity feed")
                    channelToggle($toEmail, "✉️ Email", "Emails members who have email alerts on")
                } header: {
                    Text("Send via")
                } footer: {
                    if !hasChannel { Text("Pick at least one channel.").foregroundStyle(Color.mlrDanger) }
                }

                Section("Who") {
                    Picker("Audience", selection: $audience) {
                        ForEach(Audience.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                if toBanner {
                    Section("Banner style") {
                        Picker("Kind", selection: $kind) {
                            Label("Info", systemImage: "info.circle.fill").tag(AnnouncementKind.info)
                            Label("Warning", systemImage: "exclamationmark.triangle.fill").tag(AnnouncementKind.warning)
                            Label("Urgent", systemImage: "exclamationmark.octagon.fill").tag(AnnouncementKind.urgent)
                            Label("Fest", systemImage: "star.fill").tag(AnnouncementKind.fest)
                        }
                        .pickerStyle(.menu)
                    }
                }

                if toBanner || toEmail {
                    Section("Auto-hide banner after") {
                        Picker("Expiry", selection: $expiry) {
                            ForEach(ExpiryWindow.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                }

                EventTargetPicker(events: upcomingEvents,
                                  selectedEventId: $selectedEventId,
                                  excludeNotAttending: $excludeNotAttending)

                Section("When") {
                    ScheduleSendPicker(selection: $scheduleAt)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                if let error {
                    Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(Color.mlrDanger).font(.subheadline) }
                }

                Section {
                    Button { Task { await send() } } label: {
                        HStack { Spacer()
                            if isPosting { ProgressView().tint(.white) }
                            else {
                                Label(scheduleAt == nil ? "Send" : "Schedule",
                                      systemImage: scheduleAt == nil ? "paperplane.fill" : "clock.badge.checkmark")
                                    .fontWeight(.semibold).foregroundStyle(.white)
                            }
                            Spacer() }
                    }
                    .frame(height: 48)
                    .background(canPost ? Color.mlrPrimary : Color.mlrCard)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .disabled(!canPost)
                }
                .listRowBackground(Color.clear)
            }
            .navigationTitle("Broadcast")
            .navigationBarTitleDisplayMode(.inline)
            .task { if env.eventsService.events.isEmpty { await env.eventsService.fetchEvents() } }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.foregroundStyle(Color.mlrPrimary) }
            }
            .alert("Sent!", isPresented: $posted) {
                Button("Done") { dismiss() }
            } message: {
                Text(scheduleAt == nil ? "Your broadcast is on its way." : "Your broadcast is scheduled.")
            }
        }
    }

    private func channelToggle(_ binding: Binding<Bool>, _ title: String, _ subtitle: String) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.mlrScaled(15, weight: .medium))
                Text(subtitle).font(.caption).foregroundStyle(Color.mlrTextMuted)
            }
        }
        .tint(Color.mlrPrimary)
    }

    // MARK: - Send

    private func send() async {
        guard canPost else { return }
        isPosting = true; error = nil
        defer { isPosting = false }
        let body = messageBody.trimmingCharacters(in: .whitespaces)
        let bodyOrNil = body.isEmpty ? nil : body
        let eventId = selectedEventId
        let exclude = eventId != nil ? excludeNotAttending : true

        do {
            if let scheduleAt {
                // Queue one row per channel-group at the same send time.
                if toBanner || toEmail {
                    let payload = BroadcastPayload(
                        title: trimmedTitle, body: bodyOrNil,
                        expiryHours: expiry.hours, notifyEmail: toEmail,
                        emailAudience: audience.emailAudience, alsoBanner: toBanner,
                        eventId: eventId, excludeNotAttending: eventId != nil ? exclude : nil)
                    try await env.notificationsService.scheduleBroadcast(kind: .announcement, payload: payload, scheduledAt: scheduleAt)
                }
                if toActivity {
                    let payload = BroadcastPayload(
                        title: trimmedTitle, body: bodyOrNil, audience: audience.rawValue,
                        eventId: eventId, excludeNotAttending: eventId != nil ? exclude : nil)
                    try await env.notificationsService.scheduleBroadcast(kind: .notification, payload: payload, scheduledAt: scheduleAt)
                }
                posted = true
                return
            }

            if toBanner || toEmail {
                try await env.notificationsService.postAnnouncement(
                    title: trimmedTitle, body: bodyOrNil, severity: kind.severity,
                    showBanner: toBanner, notifyEmail: toEmail, emailAudience: audience.emailAudience,
                    expiresAt: expiry.expiresAt, eventId: eventId, excludeNotAttending: exclude)
            }
            if toActivity {
                try await env.notificationsService.sendBroadcast(
                    title: trimmedTitle, body: bodyOrNil, audience: audience.broadcast,
                    mirrorBanner: false, expiresAt: expiry.expiresAt,
                    eventId: eventId, excludeNotAttending: exclude)
            }
            posted = true
        } catch {
            self.error = "Couldn't send. Please try again."
            print("[AdminBroadcastComposer] send error: \(error)")
        }
    }
}
