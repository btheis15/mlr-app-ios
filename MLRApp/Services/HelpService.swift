import Foundation
import Supabase

// MARK: - HelpService

@Observable
@MainActor
final class HelpService {
    var openRequests: [HelpRequest] = []
    var isLoading: Bool = false
    var error: String? = nil

    private var realtimeChannel: RealtimeChannelV2? = nil

    /// How many days ± an event window for presence detection (mirrors EVENT_PRESENCE_GRACE_DAYS).
    private static let presenceGraceDays = 2

    // MARK: - Fetch

    func fetchOpenRequests() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let rows: [HelpRequestRow] = try await supabase
                .from("help_requests")
                .select("""
                    *,
                    help_responses(request_id, user_id, note, created_at,
                                   profiles!user_id(display_name))
                """)
                .eq("status", value: "open")
                .order("created_at", ascending: false)
                .execute()
                .value
            openRequests = rows.map(\.toHelpRequest)
        } catch {
            self.error = "Couldn't load help requests."
            print("[HelpService] fetchOpenRequests error: \(error)")
        }
    }

    // MARK: - Request help

    func requestHelp(
        category: HelpCategory,
        what: String,
        neededCount: Int,
        whereDescription: String?,
        latitude: Double?,
        longitude: Double?,
        scheduledFor: Date?,
        notifyAll: Bool
    ) async throws {
        let eventIds = helpTargeting()

        struct RequestParams: Encodable {
            let p_category: String
            let p_what: String
            let p_needed_count: Int
            let p_where_description: String?
            let p_latitude: Double?
            let p_longitude: Double?
            let p_scheduled_for: String?
            let p_notify_all: Bool
            let p_event_ids: [String]
        }

        let iso = ISO8601DateFormatter()
        let scheduledStr = scheduledFor.map { iso.string(from: $0) }

        try await supabase
            .rpc("request_help", params: RequestParams(
                p_category: category.rawValue,
                p_what: what,
                p_needed_count: neededCount,
                p_where_description: whereDescription,
                p_latitude: latitude,
                p_longitude: longitude,
                p_scheduled_for: scheduledStr,
                p_notify_all: notifyAll,
                p_event_ids: eventIds
            ))
            .execute()

        // Refresh after posting
        await fetchOpenRequests()
    }

    // MARK: - Respond / withdraw

    func respondToHelp(requestId: UUID) async throws {
        struct RespondParams: Encodable { let p_request_id: String }
        try await supabase
            .rpc("respond_to_help", params: RespondParams(p_request_id: requestId.uuidString))
            .execute()
        await fetchOpenRequests()
    }

    func withdrawHelp(requestId: UUID) async throws {
        struct WithdrawParams: Encodable { let p_request_id: String }
        try await supabase
            .rpc("withdraw_help", params: WithdrawParams(p_request_id: requestId.uuidString))
            .execute()
        await fetchOpenRequests()
    }

    // MARK: - Status (admin / requester)

    func setStatus(requestId: UUID, status: HelpRequestStatus) async throws {
        struct StatusParams: Encodable {
            let p_request_id: String
            let p_status: String
        }
        try await supabase
            .rpc("set_help_status", params: StatusParams(
                p_request_id: requestId.uuidString,
                p_status: status.rawValue
            ))
            .execute()

        if status != .open {
            openRequests.removeAll { $0.id == requestId }
        }
    }

    // MARK: - Realtime

    func subscribeToRealtime() {
        guard realtimeChannel == nil else { return }
        let channel = supabase.channel("help-requests")
        realtimeChannel = channel

        Task {
            channel.onPostgresChange(AnyAction.self, schema: "public", table: "help_requests") { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    await self.fetchOpenRequests()
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

    // MARK: - Private row types
    // help_responses has composite PK (request_id, user_id) — no id, responder_id, responder_name.
    // Responder name comes from profiles!user_id join.

    // MARK: - helpTargeting()
    // Mirrors lib/helpRequests.ts helpTargeting().
    // Returns event IDs whose ±grace-day window includes today.
    // Seed events only — Family Fest uses its configured dates.

    func helpTargeting() -> [String] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let grace = Self.presenceGraceDays

        let isoFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone(identifier: "America/Chicago")
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }()

        func dayOffset(_ date: Date, by days: Int) -> Date {
            cal.date(byAdding: .day, value: days, to: date) ?? date
        }

        var matchingIds: [String] = []

        for event in ResortEvent.seedEvents {
            guard let start = isoFormatter.date(from: event.startDate) else { continue }
            let end = event.endDate.flatMap { isoFormatter.date(from: $0) } ?? start

            let windowStart = dayOffset(start, by: -grace)
            let windowEnd   = dayOffset(end,   by: +grace)

            if today >= windowStart && today <= windowEnd {
                matchingIds.append(event.id)
            }
        }

        return matchingIds
    }
}

// MARK: - Private row types for help_requests + help_responses

private struct HelpResponseRow: Decodable {
    let requestId: UUID
    let userId: UUID
    let note: String?
    let createdAt: Date
    let profiles: ResponderInfo?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case userId = "user_id"
        case note
        case createdAt = "created_at"
        case profiles
    }

    struct ResponderInfo: Decodable {
        let name: String?
        enum CodingKeys: String, CodingKey { case name = "display_name" }
    }

    var toResponse: HelpResponse {
        HelpResponse(
            requestId: requestId,
            responderId: userId,
            responderName: profiles?.name ?? "Member",
            note: note,
            createdAt: createdAt
        )
    }
}

private struct HelpRequestRow: Decodable {
    let id: UUID
    let requesterId: UUID
    let requesterName: String
    let category: HelpCategory
    let what: String
    let neededCount: Int
    let whereDescription: String?
    let latitude: Double?
    let longitude: Double?
    let scheduledFor: Date?
    let notifyAll: Bool
    let status: HelpRequestStatus
    let fulfilledAt: Date?
    let createdAt: Date
    let helpResponses: [HelpResponseRow]

    enum CodingKeys: String, CodingKey {
        case id
        case requesterId = "requester_id"
        case requesterName = "requester_name"
        case category, what
        case neededCount = "needed_count"
        case whereDescription = "where_description"
        case latitude, longitude
        case scheduledFor = "scheduled_for"
        case notifyAll = "notify_all"
        case status
        case fulfilledAt = "fulfilled_at"
        case createdAt = "created_at"
        case helpResponses = "help_responses"
    }

    var toHelpRequest: HelpRequest {
        HelpRequest(
            id: id,
            requesterId: requesterId,
            requesterName: requesterName,
            category: category,
            what: what,
            neededCount: neededCount,
            whereDescription: whereDescription,
            latitude: latitude,
            longitude: longitude,
            scheduledFor: scheduledFor,
            notifyAll: notifyAll,
            status: status,
            fulfilledAt: fulfilledAt,
            createdAt: createdAt,
            responses: helpResponses.map(\.toResponse)
        )
    }
}
