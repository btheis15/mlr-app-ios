import SwiftUI
import UserNotifications

// MARK: - PushToggleView
// Push notification settings. Master toggle + per-type granular control.
// When enabling: requests permission then shows granular toggles.
// When disabling: removes APNs token from Supabase.

struct PushToggleView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var permissionStatus: UNAuthorizationStatus = .notDetermined
    @State private var masterEnabled: Bool = false
    @State private var enabledTypes: Set<PushType> = []
    @State private var notifyNewMembers: Bool = true
    @State private var isRequesting = false
    @State private var isSaving = false
    @State private var saved = false
    @State private var showSettingsAlert = false

    private var profile: Profile? { env.currentProfile }

    // MARK: - Body

    var body: some View {
        Form {
            // Explanation
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Push notifications alert this device even when the app is closed.")
                        .font(.subheadline)
                        .foregroundStyle(Color.mlrTextMuted)
                    Text("Pick exactly what buzzes your phone below. The in-app bell — the notifications list you see inside the app — is set separately under “Activity notifications.”")
                        .font(.caption)
                        .foregroundStyle(Color.mlrTextSubtle)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            // Master toggle
            Section {
                Toggle(isOn: Binding(
                    get: { masterEnabled },
                    set: { enabled in Task { await setMaster(enabled: enabled) } }
                )) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Push Notifications")
                                .font(.mlrScaled(15, weight: .medium))
                            if masterEnabled {
                                Text("Notifications are sent to this device")
                                    .font(.caption)
                                    .foregroundStyle(Color.mlrSuccess)
                            } else {
                                Text("Tap to enable on this device")
                                    .font(.caption)
                                    .foregroundStyle(Color.mlrTextMuted)
                            }
                        }
                    } icon: {
                        Image(systemName: masterEnabled ? "bell.badge.fill" : "bell.slash.fill")
                            .foregroundStyle(masterEnabled ? Color.mlrPrimary : Color.mlrTextSubtle)
                    }
                }
                .tint(Color.mlrPrimary)
                .disabled(isRequesting || isSaving)

                // Permission denied banner
                if permissionStatus == .denied {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.mlrWarning)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Notifications are blocked")
                                .font(.subheadline.bold())
                            Text("Allow in iOS Settings to enable push.")
                                .font(.caption)
                                .foregroundStyle(Color.mlrTextMuted)
                        }
                        Spacer()
                        Button("Settings") {
                            openSettings()
                        }
                        .font(.caption.bold())
                        .foregroundStyle(Color.mlrPrimary)
                    }
                    .padding(.vertical, 4)
                }
            }

            // Granular toggles (only when master is on)
            if masterEnabled && permissionStatus == .authorized {
                Section {
                    pushToggle(for: .alerts,    label: "Announcements & alerts",  desc: "Resort-wide announcements from admins", icon: "megaphone.fill")
                    pushToggle(for: .birthdays, label: "Birthdays",                desc: "A heads-up on members' birthdays", icon: "birthday.cake.fill")
                    pushToggle(for: .chat,      label: "Chat messages",            desc: "New messages in your committee and house chats", icon: "bubble.left.fill")
                    pushToggle(for: .postTag,   label: "Tagged in a post",         desc: "When someone tags you in a feed post", icon: "tag.fill")
                    pushToggle(for: .postMention, label: "Post @mentions",         desc: "When someone @mentions you in a comment", icon: "at")
                    pushToggle(for: .postReply, label: "Replies on posts",         desc: "Replies to your posts and comments", icon: "arrowshape.turn.up.left.fill")
                    pushToggle(for: .eventRsvp, label: "Event RSVPs",              desc: "When someone RSVPs to an event you created", icon: "calendar.badge.checkmark")
                    pushToggle(for: .meetingProposed,  label: "Meetings to vote on",   desc: "When a meeting poll opens in your committee or house", icon: "calendar.badge.clock")
                    pushToggle(for: .meetingScheduled, label: "Meetings scheduled",     desc: "When a meeting time is locked in", icon: "calendar.badge.checkmark")
                    pushToggle(for: .cabinDecision, label: "Cabin stay decisions", desc: "When your cabin request is approved or declined", icon: "house.lodge.fill")
                    pushToggle(for: .cabinMessage, label: "Messages from your host", desc: "When the host of a place you're staying messages guests", icon: "envelope.fill")
                    pushToggle(for: .committeeJoin, label: "Committee joins",      desc: "When someone joins a committee you lead", icon: "person.badge.plus")
                    pushToggle(for: .helpRequest,  label: "Help requests",         desc: "Nearby “Ask for Help” requests", icon: "hand.raised.fill")
                    pushToggle(for: .helpResponse, label: "Help responses",        desc: "When someone's on their way to help you", icon: "figure.walk")
                    pushToggle(for: .workItemCreated, label: "New work items",     desc: "When a new work item is added", icon: "wrench.and.screwdriver.fill")
                    pushToggle(for: .houseStayCreated, label: "New house stays",    desc: "New stays added to your house calendar", icon: "house.fill")

                    if env.isAdmin {
                        pushToggle(for: .committeeJoinRequest, label: "Committee join requests", desc: "Admins only: when a member asks to join a committee", icon: "person.badge.clock")
                        newMemberToggle
                    }
                } header: {
                    Text("Notify me about…")
                } footer: {
                    Text("These apply only while Push Notifications is on. Urgent “Ask for Help” emergencies always come through as long as push is on.")
                }
            }
        }
        .navigationTitle("Push Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isRequesting || isSaving {
                    ProgressView()
                } else if saved {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.mlrSuccess)
                }
            }
        }
        .alert("Open iOS Settings", isPresented: $showSettingsAlert) {
            Button("Open Settings") { openSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Go to Settings → Notifications → MLR and allow notifications.")
        }
        .task {
            await refreshPermissionStatus()
            seedFromProfile()
        }
    }

    // MARK: - Push type toggle

    private func pushToggle(for type: PushType, label: String, desc: String, icon: String) -> some View {
        Toggle(isOn: Binding(
            get: { enabledTypes.contains(type) },
            set: { enabled in
                if enabled { enabledTypes.insert(type) }
                else { enabledTypes.remove(type) }
                Task { await saveTypes() }
            }
        )) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.mlrScaled(15))
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(Color.mlrTextMuted)
                }
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(Color.mlrPrimary)
            }
        }
        .tint(Color.mlrPrimary)
        .disabled(isSaving)
    }

    // Admin-only, independent of push_types (mirrors PushToggle.tsx's "🆕 New
    // member joins" checkbox) — bound directly to profiles.notify_new_members.
    private var newMemberToggle: some View {
        Toggle(isOn: Binding(
            get: { notifyNewMembers },
            set: { enabled in
                notifyNewMembers = enabled
                Task { await saveNotifyNewMembers() }
            }
        )) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New member joins")
                        .font(.mlrScaled(15))
                    Text("Admins only: get a push when someone new joins")
                        .font(.caption)
                        .foregroundStyle(Color.mlrTextMuted)
                }
            } icon: {
                Image(systemName: "person.badge.plus.fill")
                    .foregroundStyle(Color.mlrPrimary)
            }
        }
        .tint(Color.mlrPrimary)
        .disabled(isSaving)
    }

    // MARK: - Actions

    @MainActor
    private func setMaster(enabled: Bool) async {
        if enabled {
            await requestPermission()
        } else {
            await disablePush()
        }
    }

    @MainActor
    private func requestPermission() async {
        isRequesting = true
        defer { isRequesting = false }

        let center = UNUserNotificationCenter.current()
        let current = await center.notificationSettings()

        switch current.authorizationStatus {
        case .denied:
            permissionStatus = .denied
            return

        case .authorized, .provisional, .ephemeral:
            permissionStatus = .authorized
            masterEnabled = true
            await env.pushService.requestPermission()
            await saveLevel(level: "all")
            await saveDefaultTypes()

        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                if granted {
                    permissionStatus = .authorized
                    masterEnabled = true
                    UIApplication.shared.registerForRemoteNotifications()
                    await env.pushService.requestPermission()
                    await saveLevel(level: "all")
                    await saveDefaultTypes()
                } else {
                    permissionStatus = .denied
                    masterEnabled = false
                }
            } catch {
                masterEnabled = false
            }

        @unknown default:
            masterEnabled = false
        }
    }

    @MainActor
    private func disablePush() async {
        isSaving = true
        defer { isSaving = false }
        guard let userId = profile?.id else { return }
        masterEnabled = false
        try? await env.pushService.removeToken(userId: userId)
        await saveLevel(level: "off")
        // Mirrors the web app (PushToggle.tsx): turning push off clears push_types
        // too, so re-enabling later (here or on web) starts from a clean slate
        // instead of silently keeping stale category picks.
        enabledTypes = []
        await saveTypes()
    }

    // Mirrors the web app's DEFAULT_PUSH_TYPES (lib/types.ts) — turning push ON
    // opts into this set unconditionally (same as web's master toggle), so a
    // member who enables push for the first time on iOS doesn't end up with
    // every category silently off until they visit each row individually.
    private static let defaultPushTypes: Set<PushType> = [
        .alerts, .birthdays, .committeeJoin, .cabinDecision, .cabinMessage,
        .postTag, .postMention, .postReply, .chat, .helpRequest, .helpResponse,
    ]

    @MainActor
    private func saveDefaultTypes() async {
        enabledTypes = Self.defaultPushTypes
        await saveTypes()
    }

    @MainActor
    private func saveLevel(level: String) async {
        guard let userId = profile?.id else { return }
        try? await supabase
            .from("profiles")
            .update(["push_level": level])
            .eq("id", value: userId.uuidString)
            .execute()
        await env.loadProfile()
    }

    @MainActor
    private func saveTypes() async {
        guard let userId = profile?.id else { return }
        isSaving = true
        saved = false
        defer { isSaving = false }

        let types = enabledTypes.map(\.rawValue)
        do {
            try await supabase
                .from("profiles")
                .update(["push_types": types])
                .eq("id", value: userId.uuidString)
                .execute()
            await env.loadProfile()
            saved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saved = false }
        } catch {
            // Non-fatal
        }
    }

    private func seedFromProfile() {
        guard let p = profile else { return }
        masterEnabled = (p.pushLevel != nil && p.pushLevel != "off")
        enabledTypes = Set(p.pushTypes)
        notifyNewMembers = p.notifyNewMembers
    }

    @MainActor
    private func saveNotifyNewMembers() async {
        guard let userId = profile?.id else { return }
        isSaving = true
        defer { isSaving = false }
        try? await supabase
            .from("profiles")
            .update(["notify_new_members": notifyNewMembers])
            .eq("id", value: userId.uuidString)
            .execute()
        await env.loadProfile()
    }

    private func refreshPermissionStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run { permissionStatus = settings.authorizationStatus }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

#Preview {
    NavigationStack {
        PushToggleView()
    }
    .environment(AppEnvironment())
}
