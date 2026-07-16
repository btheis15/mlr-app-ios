import Foundation

// MARK: - Scheduled Broadcast (migration 0097)
//
// Queue row for a banner announcement / broadcast notification scheduled to
// fire at a future time. The actual send happens server-side via pg_cron
// (run_scheduled_broadcasts) — the app only does queue CRUD. `payload` mirrors
// what the two admin composers collect, so scheduling reuses the same shape.

enum BroadcastKind: String, Codable {
    case announcement
    case notification
}

/// Everything either composer might stash in `payload`. Each kind uses a subset
/// (see run_scheduled_broadcasts' per-kind branch). All-optional so it decodes
/// whatever the server stored.
struct BroadcastPayload: Codable, Equatable {
    var title: String
    var body: String?
    var url: String?
    var audience: String?            // "everyone" | "admins"
    var expiryHours: Int?
    var notifyEmail: Bool?
    var emailAudience: String?       // "all" | "admins"
    var alsoBanner: Bool?
    var eventId: String?
    var excludeNotAttending: Bool?
    // Reminder provenance (ReminderScheduler) — mostly a client label, except
    // excludeCalloutDone which the cron reads directly.
    var sourceType: String?          // "event" | "callout"
    var sourceId: String?
    var sourceLabel: String?
    var excludeCalloutDone: Bool?

    init(title: String, body: String? = nil, url: String? = nil,
         audience: String? = nil, expiryHours: Int? = nil, notifyEmail: Bool? = nil,
         emailAudience: String? = nil, alsoBanner: Bool? = nil, eventId: String? = nil,
         excludeNotAttending: Bool? = nil, sourceType: String? = nil, sourceId: String? = nil,
         sourceLabel: String? = nil, excludeCalloutDone: Bool? = nil) {
        self.title = title; self.body = body; self.url = url; self.audience = audience
        self.expiryHours = expiryHours; self.notifyEmail = notifyEmail
        self.emailAudience = emailAudience; self.alsoBanner = alsoBanner; self.eventId = eventId
        self.excludeNotAttending = excludeNotAttending; self.sourceType = sourceType
        self.sourceId = sourceId; self.sourceLabel = sourceLabel; self.excludeCalloutDone = excludeCalloutDone
    }
}

struct ScheduledBroadcast: Codable, Identifiable, Equatable {
    let id: UUID
    let kind: BroadcastKind
    let payload: BroadcastPayload
    let scheduledAt: Date
    let sentAt: Date?
    let cancelledAt: Date?
    let error: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, kind, payload, error
        case scheduledAt = "scheduled_at"
        case sentAt = "sent_at"
        case cancelledAt = "cancelled_at"
        case createdAt = "created_at"
    }

    /// Display status for the admin queue.
    var statusLabel: String {
        if let error, !error.isEmpty { return "Failed" }
        if sentAt != nil { return "Sent" }
        if cancelledAt != nil { return "Cancelled" }
        return "Pending"
    }

    var isPending: Bool { sentAt == nil && cancelledAt == nil && (error?.isEmpty ?? true) }
}
