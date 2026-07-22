import SwiftUI

// MARK: - NotifPrefsView
// Per-kind notification preference toggles. Saves to `profiles.notif_types`.

struct NotifPrefsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var enabledTypes: Set<NotifType> = []
    @State private var isSaving = false
    @State private var error: String? = nil
    @State private var saved = false

    private var profile: Profile? { env.currentProfile }

    // MARK: - Body

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("These control the in-app bell — the notifications list you see inside the app.")
                        .font(.subheadline)
                        .foregroundStyle(Color.mlrTextMuted)
                    Text("They're separate from Push notifications, which alert your phone even when the app is closed.")
                        .font(.caption)
                        .foregroundStyle(Color.mlrTextSubtle)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            // Your activity
            Section("Your Activity") {
                toggle(for: .postComment,  label: "Comments on your posts",   icon: "bubble.left.fill")
                toggle(for: .postReply,    label: "Replies to your comments", icon: "arrowshape.turn.up.left.fill")
                toggle(for: .postMention,  label: "Post @mentions",           icon: "at")
                toggle(for: .postTag,      label: "Tagged in a post",         icon: "tag.fill")
                toggle(for: .postReaction, label: "Reactions to your posts",  icon: "heart.fill")
            }

            // Social
            Section("Social") {
                toggle(for: .newPost,     label: "New posts in the feed", icon: "rectangle.stack.fill")
                toggle(for: .chatMention, label: "Chat @mentions",        icon: "bubble.left.and.bubble.right.fill")
            }

            // Committees
            Section("Committees") {
                toggle(for: .committeeJoin, label: "Joined a committee you lead", icon: "person.badge.plus")
                if env.isAdmin {
                    toggle(for: .committeeJoinRequest, label: "New committee join requests", icon: "person.badge.clock")
                        .foregroundStyle(Color.mlrText)
                }
            }

            // Cabin
            Section("Cabin Stays") {
                if env.isAdmin {
                    toggle(for: .cabinRequest, label: "New cabin booking requests", icon: "house.lodge.fill")
                }
                toggle(for: .cabinDecision, label: "Decisions on your cabin requests", icon: "house.lodge.fill")
            }

            // Events
            Section("Events") {
                toggle(for: .eventRsvp, label: "RSVPs to your events", icon: "calendar.badge.checkmark")
            }

            // Meetings
            Section("Meetings") {
                toggle(for: .meetingProposed,  label: "A meeting to vote on", icon: "calendar.badge.clock")
                toggle(for: .meetingScheduled, label: "A meeting was scheduled", icon: "calendar.badge.checkmark")
            }

            // House calendar
            Section("House calendar") {
                toggle(for: .houseStayCreated, label: "New stays at your house", icon: "house.fill")
            }

            // Work Checklist
            Section("Work Checklist") {
                toggle(for: .workItemCreated, label: "New work items",        icon: "wrench.and.screwdriver.fill")
                toggle(for: .workItemComment, label: "Comments on work items", icon: "bubble.left.fill")
                toggle(for: .workItemMention, label: "Work item @mentions",    icon: "at")
            }

            // Help Requests
            Section("Help Requests") {
                toggle(for: .helpRequest,  label: "Help requests near you", icon: "hand.raised.fill")
                toggle(for: .helpResponse, label: "Someone's on their way",  icon: "figure.walk")
                lockedRow(
                    label: "Urgent help (emergencies)",
                    desc: "When someone marks a request Urgent — goes to everyone. Always on; the only way to silence it is your phone's notification permission.",
                    icon: "exclamationmark.octagon.fill"
                )
            }
        }
        .navigationTitle("Activity Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isSaving {
                    ProgressView()
                } else if saved {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.mlrSuccess)
                }
            }
        }
        .onAppear { seedFromProfile() }
        .onChange(of: enabledTypes) { _, _ in
            Task { await savePrefs() }
        }
    }

    // MARK: - Toggle builder

    private func toggle(for type: NotifType, label: String, icon: String) -> some View {
        Toggle(isOn: Binding(
            get: { enabledTypes.contains(type) },
            set: { enabled in
                if enabled { enabledTypes.insert(type) }
                else { enabledTypes.remove(type) }
            }
        )) {
            Label {
                Text(label)
                    .font(.mlrScaled(15))
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(Color.mlrPrimary)
            }
        }
        .tint(Color.mlrPrimary)
    }

    // A non-toggle row for a notification type that's always on (server-enforced,
    // migration 0047). The only off-switch is the device's push permission.
    private func lockedRow(label: String, desc: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Label {
                    Text(label).font(.mlrScaled(15))
                } icon: {
                    Image(systemName: icon).foregroundStyle(Color.mlrPrimary)
                }
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(Color.mlrTextMuted)
            }
            Spacer(minLength: 8)
            Text("🔒 Always on")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.mlrPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.mlrPrimary.opacity(0.15))
                .clipShape(Capsule())
        }
    }

    // MARK: - Helpers

    private func seedFromProfile() {
        guard let p = profile else { return }
        enabledTypes = Set(p.notifTypes)
    }

    @MainActor
    private func savePrefs() async {
        guard let userId = profile?.id else { return }
        isSaving = true
        saved = false
        defer { isSaving = false }

        let types = enabledTypes.map(\.rawValue)
        do {
            try await supabase
                .from("profiles")
                .update(["notif_types": types])
                .eq("id", value: userId.uuidString)
                .execute()
            await env.loadProfile()
            saved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                saved = false
            }
        } catch {
            self.error = "Couldn't save preferences."
        }
    }
}

#Preview {
    NavigationStack {
        NotifPrefsView()
    }
    .environment(AppEnvironment())
}
