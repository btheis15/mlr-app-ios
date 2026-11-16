import SwiftUI

// MARK: - NotificationsView
// The Activity tab. Shows a grouped, pull-to-refresh notification feed for
// the signed-in user. Non-members see a sign-in wall.

struct NotificationsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var isLoading = false
    @State private var error: String? = nil

    // Source of truth is the service, so app-wide realtime inserts appear here live.
    private var notifications: [AppNotification] { env.notificationsService.notifications }

    // MARK: - Grouping

    /// One section per calendar day, newest first ("Today", "Yesterday", then
    /// "Monday, Nov 9"). The list is `.plain`, so section headers pin (stick).
    private var grouped: [(label: String, items: [AppNotification])] {
        let cal = Calendar.current
        var order: [Date] = []
        var map: [Date: [AppNotification]] = [:]
        for n in notifications {
            let day = cal.startOfDay(for: n.createdAt)
            if map[day] == nil { order.append(day) }
            map[day, default: []].append(n)
        }
        return order.sorted(by: >).map { day in
            let label: String
            if cal.isDateInToday(day) { label = "Today" }
            else if cal.isDateInYesterday(day) { label = "Yesterday" }
            else { label = day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) }
            return (label, map[day] ?? [])
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if !env.isSignedIn {
                    signInWall
                } else if isLoading && notifications.isEmpty {
                    loadingState
                } else if !isLoading && notifications.isEmpty && error == nil {
                    emptyState
                } else {
                    feedList
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if env.isSignedIn && !notifications.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        markAllButton
                    }
                }
            }
        }
        .task {
            await loadAndMarkSeen()
        }
    }

    // MARK: - Feed list

    private var feedList: some View {
        ScrollViewReader { proxy in
        List {
            if let error {
                Section {
                    errorBanner(error)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }

            ForEach(grouped, id: \.label) { group in
                Section {
                    ForEach(group.items) { notif in
                        NotificationRow(notification: notif)
                            .contentShape(Rectangle())
                            .animation(MLRMotion.reduceMotion ? nil : MLRMotion.spring, value: notif.isUnread)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 0))
                            .listRowBackground(notif.isUnread
                                               ? Color.mlrPrimaryLight.opacity(0.35)
                                               : Color.mlrSurface)
                            .onTapGesture {
                                Task { await handleTap(notif) }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                if notif.isUnread {
                                    Button {
                                        Haptics.tap()
                                        Task { await markRead(notif) }
                                    } label: {
                                        Label("Mark read", systemImage: "envelope.open")
                                    }
                                    .tint(Color.mlrPrimary)
                                }
                            }
                    }
                } header: {
                    Text(group.label)
                        .font(.mlrScaled(12, weight: .semibold))
                        .foregroundStyle(Color.mlrTextMuted)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            await loadAndMarkSeen()
        }
        // Tapping the Activity tab again scrolls back to the newest row.
        .onReceive(NotificationCenter.default.publisher(for: .tabReselected)) { note in
            guard (note.object as? Tab) == .activity,
                  let first = grouped.first?.items.first else { return }
            withAnimation(MLRMotion.reduceMotion ? nil : MLRMotion.spring) {
                proxy.scrollTo(first.id, anchor: .top)
            }
        }
        }
    }

    // MARK: - Mark all button

    private var markAllButton: some View {
        Button {
            Task { await markAllRead() }
        } label: {
            Text("Mark all read")
                .font(.mlrScaled(14))
        }
        .foregroundStyle(Color.mlrPrimary)
        .disabled(!notifications.contains(where: \.isUnread))
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bell.slash")
                .font(.mlrScaled(44, weight: .light))
                .foregroundStyle(Color.mlrTextSubtle)
            Text("Nothing new yet")
                .font(.headline)
                .foregroundStyle(Color.mlrTextMuted)
            Text("Activity on your posts, mentions, events, and announcements will appear here.")
                .font(.subheadline)
                .foregroundStyle(Color.mlrTextSubtle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mlrSurface)
    }

    // MARK: - Loading state

    private var loadingState: some View {
        VStack(spacing: 20) {
            ForEach(0..<6, id: \.self) { _ in
                notifSkeleton
            }
            Spacer()
        }
        .padding(.top, 16)
        .padding(.horizontal, 16)
    }

    private var notifSkeleton: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Color.mlrCard)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.mlrCard)
                    .frame(height: 14)
                    .frame(maxWidth: .infinity)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.mlrCard)
                    .frame(height: 12)
                    .frame(maxWidth: 200)
            }
        }
        .shimmering()
    }

    // MARK: - Sign-in wall

    private var signInWall: some View {
        VStack(spacing: 24) {
            Image(systemName: "bell.badge.fill")
                .font(.mlrScaled(52, weight: .light))
                .foregroundStyle(Color.mlrPrimary.opacity(0.6))

            VStack(spacing: 8) {
                Text("Sign in to see your activity")
                    .font(.title3.bold())
                Text("Comments, mentions, RSVPs, and announcements will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(Color.mlrTextMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            NavigationLink {
                SignInView()
            } label: {
                Text("Sign In")
                    .primaryButton()
            }
            .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mlrSurface)
    }

    // MARK: - Error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.mlrWarning)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.mlrTextMuted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mlrWarning.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Actions

    @MainActor
    private func loadAndMarkSeen() async {
        guard env.isSignedIn, let userId = env.currentProfile?.id else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        // fetchNotifications is non-throwing; it sets .error and returns via .notifications
        await env.notificationsService.fetchNotifications(userId: userId)
        if env.notificationsService.error != nil {
            self.error = "Couldn't load notifications. Pull to retry."
            return
        }
        // Mark all as seen (clears badge) — non-throwing
        await env.notificationsService.markAllSeen(userId: userId)
        await env.notificationsService.fetchUnreadCount(userId: userId)
    }

    @MainActor
    private func markAllRead() async {
        guard let userId = env.currentProfile?.id else { return }
        do {
            // markAllRead stamps the service's rows optimistically.
            try await env.notificationsService.markAllRead(userId: userId)
            await env.notificationsService.fetchUnreadCount(userId: userId)
        } catch {
            self.error = "Couldn't mark notifications as read."
        }
    }

    @MainActor
    private func markRead(_ notification: AppNotification) async {
        // Own notifications only; nothing here writes as another member.
        await env.notificationsService.markRead(notificationId: notification.id)
        if let uid = env.currentProfile?.id {
            await env.notificationsService.fetchUnreadCount(userId: uid)
        }
    }

    @MainActor
    private func handleTap(_ notification: AppNotification) async {
        // Mark this individual notification as read via existing service method
        if notification.isUnread {
            // markRead stamps read_at on the service row — non-throwing
            await env.notificationsService.markRead(notificationId: notification.id)
            if let uid = env.currentProfile?.id {
                await env.notificationsService.fetchUnreadCount(userId: uid)
            }
        }

        // Navigate based on targetType
        guard let targetType = notification.targetType else { return }
        var userInfo: [String: Any] = [
            "target_type": targetType,
            "target_id": notification.targetId ?? ""
        ]
        // Carries anything targetType/targetId can't express alone — e.g. a
        // post_comment/reply/mention's `&comment=<id>` (migration 0164).
        if let url = notification.url { userInfo["url"] = url }
        NotificationCenter.default.post(name: .notificationTapped, object: nil, userInfo: userInfo)
    }
}

// MARK: - Shimmer modifier
// Simple shimmer animation for skeleton placeholders.

private extension View {
    func shimmering() -> some View {
        self.modifier(ShimmerModifier())
    }
}

private struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.white.opacity(0),
                        Color.white.opacity(0.5),
                        Color.white.opacity(0)
                    ]),
                    startPoint: .init(x: phase - 0.3, y: 0),
                    endPoint: .init(x: phase + 0.3, y: 0)
                )
                .blendMode(BlendMode.screen)
            )
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1.3
                }
            }
    }
}

// MARK: - NotificationsService additions
// Extends the existing service with the mark-all-read and mark-single-read
// capabilities needed by this view. The existing service already has
// fetchNotifications(userId:), markAllSeen(userId:), and markRead(notificationId:).

extension NotificationsService {
    /// Stamp `read_at` on all unread rows for `userId`. The notifications table
    /// keys the recipient as `recipient_id` (there is no `user_id` column).
    func markAllRead(userId: UUID) async throws {
        // Web parity: mark_all_notifications_read() takes no args; it resolves the
        // caller via auth.uid() (migration 0030).
        try await supabase.rpc("mark_all_notifications_read").execute()

        // Optimistically stamp the in-memory rows so the list updates immediately.
        let now = Date.now
        notifications = notifications.map { n in
            var updated = n
            if updated.readAt == nil { updated.readAt = now }
            if updated.seenAt == nil { updated.seenAt = now }
            return updated
        }
    }
}

#Preview {
    NotificationsView()
        .environment(AppEnvironment())
}
