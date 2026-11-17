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
    /// The Activity tab entry's own expiry — separate from the banner's,
    /// since past it the item just stops counting toward the bell badge
    /// rather than disappearing. `nil` = doesn't expire (the default).
    @State private var feedExpiry: ExpiryWindow? = nil
    @State private var audience: Audience = .everyone

    // Channels (≥1 required).
    @State private var toBanner = true
    @State private var toActivity = false
    @State private var toEmail = false

    @State private var selectedEventId: String? = nil
    @State private var excludeNotAttending = true
    // "Remind about an activity" autofill (#393) — sets the tap-through link.
    @State private var linkUrl: String? = nil
    @State private var scheduleAt: Date? = nil
    @State private var isPosting = false
    @State private var error: String? = nil
    @State private var posted = false
    @State private var showDiscard = false
    @State private var confirmSend = false
    /// Parts that already went out in this session ("banner/email", "activity"),
    /// so a retry after a partial failure cannot double-send them.
    @State private var completed: Set<String> = []

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespaces) }
    private var hasChannel: Bool { toBanner || toActivity || toEmail }
    private var canPost: Bool { !trimmedTitle.isEmpty && hasChannel && !isPosting && !posted }
    /// Unsaved-work guard: anything typed or chosen that hasn't been sent.
    private var isDirty: Bool { hasContent && !posted }
    private var audienceWord: String { audience == .everyone ? "everyone" : "admins only" }
    private var channelList: String {
        [toBanner ? "banner" : nil, toActivity ? "Activity tab" : nil, toEmail ? "email" : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }
    private var upcomingEvents: [ResortEvent] { env.eventsService.upcomingEvents }

    var body: some View {
        NavigationStack {
            Form {
                // Remind about a Family Fest activity — autofills the message +
                // targets Fest attendees (#393).
                if !festActivities.isEmpty {
                    Section {
                        Menu {
                            ForEach(festActivities) { item in
                                Button(item.title) { Haptics.tap(); autofill(from: item) }
                            }
                            Divider()
                            Button(role: .destructive) { Haptics.tap(); requestReset() } label: {
                                Label("Start fresh (clear all)", systemImage: "arrow.counterclockwise")
                            }
                        } label: {
                            Label("Attach an activity / start fresh", systemImage: "sparkles")
                                .font(.mlrScaled(14, weight: .medium))
                        }
                    }
                }

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

                if toActivity {
                    Section {
                        Picker("Expiry", selection: $feedExpiry) {
                            Text("Doesn't expire").tag(ExpiryWindow?.none)
                            ForEach(ExpiryWindow.allCases) { Text($0.label).tag(ExpiryWindow?.some($0)) }
                        }
                        .pickerStyle(.menu)
                    } header: {
                        Text("Activity tab expiry")
                    } footer: {
                        Text("Past this, the item stays in the list but stops counting toward the bell badge.")
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
                    Button { Haptics.tap(); confirmSend = true } label: {
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
            .disabled(isPosting)
            .interactiveDismissDisabled(isDirty || isPosting)
            .confirmationDialog(scheduleAt == nil ? "Send this now?" : "Schedule this send?",
                                isPresented: $confirmSend, titleVisibility: .visible) {
                Button(scheduleAt == nil ? "Send to \(audienceWord)" : "Schedule for \(audienceWord)") {
                    Task { await send() }
                }
                Button("Review again", role: .cancel) {}
            } message: {
                // The existing RPCs return no recipient count, so say who, not how many.
                Text("\u{201C}\(trimmedTitle)\u{201D} goes to \(audienceWord) via \(channelList).")
            }
            .confirmationDialog("Discard this broadcast?", isPresented: $showDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            } message: { Text("Your unsent message will be lost.") }
            .confirmationDialog("Clear this notification?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Start fresh", role: .destructive) { resetToBlank() }
                Button("Cancel", role: .cancel) {}
            }
            .navigationTitle("Broadcast")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if env.eventsService.events.isEmpty { await env.eventsService.fetchEvents() }
                if env.festContentService.schedule.isEmpty { await env.festContentService.reload() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { if isDirty { showDiscard = true } else { dismiss() } }
                        .foregroundStyle(Color.mlrPineText)
                        .disabled(isPosting)
                }
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
        .tint(Color.mlrPineText)
    }

    // MARK: - Activity autofill (#393)

    @State private var confirmReset = false

    /// Anything worth protecting from an accidental wipe?
    private var hasContent: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            || !messageBody.trimmingCharacters(in: .whitespaces).isEmpty
            || selectedEventId != nil || linkUrl != nil || scheduleAt != nil
    }

    /// Route through a confirmation only when there IS content (Phase 8).
    private func requestReset() {
        if hasContent { confirmReset = true } else { resetToBlank() }
    }

    /// Return ALL composer state to its initial defaults (leaves isPosting/posted).
    private func resetToBlank() {
        title = ""; messageBody = ""
        kind = .info; expiry = .sixHours; feedExpiry = nil; audience = .everyone
        toBanner = true; toActivity = false; toEmail = false
        selectedEventId = nil; excludeNotAttending = true
        linkUrl = nil; scheduleAt = nil; error = nil; completed = []
    }

    private var festActivities: [ScheduleItem] {
        env.festContentService.schedule.filter { !$0.isPrivate }
    }

    /// Pull title + when/where from a Fest activity, link the notification to it,
    /// and target Family Fest attendees — mirrors activityReminderDefaults.
    private func autofill(from item: ScheduleItem) {
        title = item.title
        let when = item.day == "Anytime" ? "Anytime all week" : "\(item.day) · \(MLRFormat.time(item.time))"
        var parts = [when]
        if let loc = item.location, loc != "TBD" { parts.append("📍 \(loc)") }
        messageBody = parts.joined(separator: "  ·  ")
        selectedEventId = NotificationsService.familyFestEventId
        excludeNotAttending = true
        linkUrl = "/family-fest/schedule/\(item.id)"
        if !hasChannel { toActivity = true }
    }

    // MARK: - Send

    private func send() async {
        guard canPost else { return }       // also the in-flight lock (isPosting)
        isPosting = true; error = nil
        defer { isPosting = false }
        let body = messageBody.trimmingCharacters(in: .whitespaces)
        let bodyOrNil = body.isEmpty ? nil : body
        let eventId = selectedEventId
        let exclude = eventId != nil ? excludeNotAttending : true
        let isScheduled = scheduleAt != nil

        // One group at a time, remembering what went out, so a failure in the
        // second group never re-sends the first on retry.
        func run(_ group: String, _ label: String, _ work: () async throws -> Void) async -> String? {
            guard !completed.contains(group) else { return nil }
            do { try await work(); completed.insert(group); return nil }
            catch {
                print("[AdminBroadcastComposer] \(group) error: \(error)")
                return "\(label): \(EditorError.message(error))"
            }
        }

        var failures: [String] = []
        if let scheduleAt {
            // Queue one row per channel-group at the same send time.
            if toBanner || toEmail {
                let payload = BroadcastPayload(
                    title: trimmedTitle, body: bodyOrNil,
                    expiryHours: expiry.hours, notifyEmail: toEmail,
                    emailAudience: audience.emailAudience, alsoBanner: toBanner,
                    eventId: eventId, excludeNotAttending: eventId != nil ? exclude : nil)
                if let f = await run("announcement", "Banner/email", {
                    try await env.notificationsService.scheduleBroadcast(kind: .announcement, payload: payload, scheduledAt: scheduleAt)
                }) { failures.append(f) }
            }
            if toActivity {
                let payload = BroadcastPayload(
                    title: trimmedTitle, body: bodyOrNil, audience: audience.rawValue,
                    expiryHours: feedExpiry?.hours,
                    eventId: eventId, excludeNotAttending: eventId != nil ? exclude : nil)
                if let f = await run("activity", "Activity tab", {
                    try await env.notificationsService.scheduleBroadcast(kind: .notification, payload: payload, scheduledAt: scheduleAt)
                }) { failures.append(f) }
            }
        } else {
            if toBanner || toEmail {
                if let f = await run("announcement", "Banner/email", {
                    try await env.notificationsService.postAnnouncement(
                        title: trimmedTitle, body: bodyOrNil, severity: kind.severity,
                        showBanner: toBanner, notifyEmail: toEmail, emailAudience: audience.emailAudience,
                        expiresAt: expiry.expiresAt, eventId: eventId, excludeNotAttending: exclude)
                }) { failures.append(f) }
            }
            if toActivity {
                if let f = await run("activity", "Activity tab", {
                    try await env.notificationsService.sendBroadcast(
                        title: trimmedTitle, body: bodyOrNil, audience: audience.broadcast,
                        mirrorBanner: false, url: linkUrl, expiresAt: feedExpiry?.expiresAt,
                        eventId: eventId, excludeNotAttending: exclude)
                }) { failures.append(f) }
            }
        }

        if failures.isEmpty {
            Haptics.success()
            posted = true
        } else {
            let verb = isScheduled ? "scheduled" : "sent"
            let went = completed.isEmpty ? "" : " The rest was already \(verb); sending again only retries what failed."
            error = "Didn\u{2019}t finish. " + failures.joined(separator: " ") + went
            Haptics.error()
        }
    }
}
