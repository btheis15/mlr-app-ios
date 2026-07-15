import Foundation
import Supabase
import UserNotifications

// MARK: - NotificationsService

@Observable
@MainActor
final class NotificationsService {
    var notifications: [AppNotification] = []
    var unreadCount: Int = 0
    var isLoading: Bool = false
    var error: String? = nil

    private var realtimeChannel: RealtimeChannelV2? = nil

    // MARK: - Fetch

    func fetchNotifications(userId: UUID) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let rows: [NotifRow] = try await supabase
                .from("notifications")
                .select("""
                    id, recipient_id, type, title, body, entity_type, entity_id,
                    seen_at, read_at, expires_at, created_at,
                    profiles!actor_id(display_name, avatar_url)
                """)
                .eq("recipient_id", value: userId.uuidString)
                .order("created_at", ascending: false)
                .limit(100)
                .execute()
                .value
            notifications = rows.map(\.toNotification)
            updateUnreadCount()
        } catch {
            self.error = "Couldn't load notifications."
            print("[NotificationsService] fetchNotifications error: \(error)")
        }
    }

    func fetchUnreadCount(userId: UUID) async {
        do {
            // Use the PostgREST exact-count header (not the disabled `.count()`
            // aggregate) — a HEAD request that returns the row count only.
            let response = try await supabase
                .from("notifications")
                .select("id", head: true, count: .exact)
                .eq("recipient_id", value: userId.uuidString)
                .is("seen_at", value: nil as Bool?)
                .or("expires_at.is.null,expires_at.gt.\(iso8601Now())")
                .execute()
            unreadCount = response.count ?? 0
            syncAppIconBadge()
        } catch {
            print("[NotificationsService] fetchUnreadCount error: \(error)")
        }
    }

    // MARK: - Mark seen / read

    /// Mark all unseen notifications seen — clears the badge.
    func markAllSeen(userId: UUID) async {
        do {
            // mark_notifications_seen() takes no args — it resolves the caller via auth.uid().
            try await supabase
                .rpc("mark_notifications_seen")
                .execute()

            // Optimistic update
            let now = Date.now
            notifications = notifications.map { n in
                var updated = n
                if updated.seenAt == nil { updated.seenAt = now }
                return updated
            }
            unreadCount = 0
            syncAppIconBadge()
        } catch {
            print("[NotificationsService] markAllSeen error: \(error)")
        }
    }

    /// Mark an individual notification read — removes bold styling.
    func markRead(notificationId: UUID) async {
        do {
            struct MarkReadParams: Encodable { let p_id: String }
            try await supabase
                .rpc("mark_notification_read", params: MarkReadParams(p_id: notificationId.uuidString))
                .execute()

            // Optimistic update
            let now = Date.now
            if let idx = notifications.firstIndex(where: { $0.id == notificationId }) {
                notifications[idx].readAt = now
            }
        } catch {
            print("[NotificationsService] markRead error: \(error)")
        }
    }

    // MARK: - Admin broadcast

    /// Send a broadcast notification to the chosen audience.
    /// - Parameters:
    ///   - eventId: Optional event ID; when set with `excludeNotAttending`, members who
    ///     RSVP'd "Can't make it" to that event are skipped (migration 0096).
    ///   - excludeNotAttending: Only has effect when `eventId` is non-nil.
    func sendBroadcast(
        title: String,
        body: String?,
        audience: BroadcastAudience,
        mirrorBanner: Bool,
        url: String? = nil,
        expiresAt: Date? = nil,
        eventId: String? = nil,
        excludeNotAttending: Bool = false
    ) async throws {
        struct BroadcastParams: Encodable {
            let p_title: String
            let p_body: String?
            let p_url: String?
            let p_audience: String
            let p_expires_at: String?
            let p_event_id: String?
            let p_exclude_not_attending: Bool
        }
        let iso = ISO8601DateFormatter()
        let expiresStr = expiresAt.map { iso.string(from: $0) }
        try await supabase
            .rpc("send_broadcast_notification", params: BroadcastParams(
                p_title: title,
                p_body: body,
                p_url: url,
                p_audience: audience.rawValue,
                p_expires_at: expiresStr,
                p_event_id: eventId,
                p_exclude_not_attending: excludeNotAttending
            ))
            .execute()

        // Banner mirror is a separate announcements insert (banner is everyone-only),
        // matching the web AdminNotificationComposer.
        if mirrorBanner && audience == .everyone {
            let uid = try? await supabase.auth.session.user.id
            // Default the banner to a 6-hour life if no explicit expiry was set.
            let bannerExpiry = expiresAt ?? Date.now.addingTimeInterval(6 * 3600)
            var params: [String: AnyJSON] = [
                "title": .string(title),
                "body": body.map(AnyJSON.string) ?? .null,
                "severity": .string("alert"),
                "notify_email": .bool(false),
                "expires_at": .string(iso.string(from: bannerExpiry))
            ]
            if let uid { params["author_id"] = .string(uid.uuidString) }
            if let eventId {
                params["event_id"] = .string(eventId)
                params["exclude_not_attending"] = .bool(excludeNotAttending)
            }
            try await supabase
                .from("announcements")
                .insert(params)
                .execute()
        }
    }

    // MARK: - Realtime

    func subscribeToRealtime(userId: UUID) {
        guard realtimeChannel == nil else { return }
        let channel = supabase.channel("notifications-\(userId.uuidString)")
        realtimeChannel = channel

        Task {
            channel.onPostgresChange(
                InsertAction.self,
                schema: "public",
                table: "notifications",
                filter: "recipient_id=eq.\(userId.uuidString)"
            ) { [weak self] action in
                guard let self else { return }
                Task { @MainActor in
                    guard let idStr = action.record["id"]?.stringValue,
                          let id = UUID(uuidString: idStr)
                    else { return }
                    // Re-fetch to get the profiles join for actor name/avatar
                    if let row: NotifRow = try? await supabase
                        .from("notifications")
                        .select("""
                            id, recipient_id, type, title, body, entity_type, entity_id,
                            seen_at, read_at, expires_at, created_at,
                            profiles!actor_id(display_name, avatar_url)
                        """)
                        .eq("id", value: id.uuidString)
                        .single()
                        .execute()
                        .value
                    {
                        let notif = row.toNotification
                        if !self.notifications.contains(where: { $0.id == notif.id }) {
                            self.notifications.insert(notif, at: 0)
                            if notif.countsForBadge {
                                self.unreadCount += 1
                                self.syncAppIconBadge()
                            }
                        }
                    }
                }
            }
            await channel.subscribe()
        }
    }

    func unsubscribeFromRealtime() {
        Task {
            if let channel = realtimeChannel {
                await supabase.removeChannel(channel)
                realtimeChannel = nil
            }
        }
    }

    // MARK: - Private helpers

    private func updateUnreadCount() {
        unreadCount = notifications.filter(\.countsForBadge).count
        syncAppIconBadge()
    }

    /// Keep the Home Screen app-icon badge in lockstep with the in-app unread
    /// count. Without this, a badge delivered by a push payload lingers on the
    /// icon even after the notifications are read in-app.
    func syncAppIconBadge() {
        let count = unreadCount
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(count) }
    }

    private func iso8601Now() -> String {
        ISO8601DateFormatter().string(from: .now)
    }
}

// MARK: - Private row type for notifications
// DB columns: id, recipient_id, type, actor_id, title, body, url,
//             entity_type, entity_id, created_at, seen_at, read_at, expires_at
// (no flat actor_name / actor_avatar_url — actor info comes from profiles!actor_id join)

private struct NotifRow: Decodable {
    let id: UUID
    let recipientId: UUID
    let type: String
    let title: String
    let body: String?
    let entityType: String?
    let entityId: String?
    let seenAt: Date?
    let readAt: Date?
    let expiresAt: Date?
    let createdAt: Date
    let profiles: ActorInfo?

    enum CodingKeys: String, CodingKey {
        case id
        case recipientId = "recipient_id"
        case type
        case title, body
        case entityType = "entity_type"
        case entityId = "entity_id"
        case seenAt = "seen_at"
        case readAt = "read_at"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
        case profiles
    }

    struct ActorInfo: Decodable {
        let name: String?
        let avatarUrl: String?
        enum CodingKeys: String, CodingKey {
            case name = "display_name"
            case avatarUrl = "avatar_url"
        }
    }

    var toNotification: AppNotification {
        AppNotification(
            id: id,
            userId: recipientId,
            kind: NotifType(rawValue: type) ?? .broadcast,
            title: title,
            body: body,
            targetType: entityType,
            targetId: entityId,
            actorName: profiles?.name,
            actorAvatarUrl: profiles?.avatarUrl,
            seenAt: seenAt,
            readAt: readAt,
            expiresAt: expiresAt,
            createdAt: createdAt
        )
    }
}

// MARK: - Broadcast audience

enum BroadcastAudience: String {
    case everyone = "everyone"
    case admins
}
