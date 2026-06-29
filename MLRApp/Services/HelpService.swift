import Foundation
import Supabase

// MARK: - HelpService
//
// "Ask for Help" (migrations 0037 + 0046). Mirrors web lib/helpRequests.ts:
// reads go through the members-read tables; writes go through SECURITY DEFINER
// RPCs (request/respond/withdraw/claim/status). Presence targeting (eligible /
// strict event ids + resort-local today) is computed client-side and handed to
// request_help so a client can never target arbitrary members.

@Observable
@MainActor
final class HelpService {
    var openRequests: [HelpRequest] = []
    var isLoading: Bool = false
    var error: String? = nil

    private var realtimeChannel: RealtimeChannelV2? = nil

    /// How many days ± an event window still count as "at the resort".
    private static let presenceGraceDays = 2

    /// The columns + joins for a help request, matching web lib/helpRequests.ts.
    private static let selectColumns = """
        id, user_id, description, category, where_text, lat, lng, needed_at,
        needed_count, status, fulfilled_at, notified_count, created_at, expires_at,
        profiles!user_id(display_name, avatar_url),
        help_responses(user_id, note, created_at, profiles!user_id(display_name, avatar_url)),
        help_request_items(id, label, position, claimed_by, claimed_at,
                           profiles!claimed_by(display_name))
        """

    // MARK: - Fetch

    func fetchOpenRequests() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let rows: [HelpRequestRow] = try await supabase
                .from("help_requests")
                .select(Self.selectColumns)
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
        notifyAll: Bool,
        items: [String] = []
    ) async throws {
        let targeting = helpTargeting()

        struct RequestParams: Encodable {
            let p_description: String
            let p_category: String
            let p_where_text: String?
            let p_lat: Double?
            let p_lng: Double?
            let p_needed_at: String?
            let p_needed_count: Int
            let p_audience: String
            let p_eligible: [String]
            let p_strict: [String]
            let p_today: String
            let p_items: [String]
        }

        let iso = ISO8601DateFormatter()
        let neededAtStr = scheduledFor.map { iso.string(from: $0) }

        try await supabase
            .rpc("request_help", params: RequestParams(
                p_description: what,
                p_category: category.rawValue,
                p_where_text: whereDescription,
                p_lat: latitude,
                p_lng: longitude,
                p_needed_at: neededAtStr,
                p_needed_count: neededCount,
                p_audience: notifyAll ? "all_willing" : "present",
                p_eligible: targeting.eligible,
                p_strict: targeting.strict,
                p_today: targeting.today,
                p_items: items
            ))
            .execute()

        await fetchOpenRequests()
    }

    // MARK: - Bring items ("what to bring", migration 0046)

    /// Claim or release a "what to bring" item. Claiming also marks you on the way.
    func claimHelpItem(itemId: UUID, claim: Bool) async throws {
        struct ClaimParams: Encodable {
            let p_item: String
            let p_claim: Bool
        }
        try await supabase
            .rpc("claim_help_item", params: ClaimParams(p_item: itemId.uuidString, p_claim: claim))
            .execute()
        await fetchOpenRequests()
    }

    // MARK: - Respond / withdraw

    func respondToHelp(requestId: UUID, note: String? = nil) async throws {
        struct RespondParams: Encodable {
            let p_request: String
            let p_note: String?
        }
        try await supabase
            .rpc("respond_to_help", params: RespondParams(p_request: requestId.uuidString, p_note: note))
            .execute()
        await fetchOpenRequests()
    }

    func withdrawHelp(requestId: UUID) async throws {
        struct WithdrawParams: Encodable { let p_request: String }
        try await supabase
            .rpc("withdraw_help", params: WithdrawParams(p_request: requestId.uuidString))
            .execute()
        await fetchOpenRequests()
    }

    // MARK: - Status (admin / requester)

    func setStatus(requestId: UUID, status: HelpRequestStatus) async throws {
        struct StatusParams: Encodable {
            let p_request: String
            let p_status: String
        }
        try await supabase
            .rpc("set_help_status", params: StatusParams(
                p_request: requestId.uuidString,
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

    // MARK: - helpTargeting()
    // Mirrors lib/helpRequests.ts helpTargeting(): eligible = live event ids whose
    // ±grace window includes today; strict = the day-RSVP subset that is actually
    // ongoing today (so a Mon–Wed attendee isn't pinged Thursday). `today` is the
    // resort-local ISO date. Seed events only (Family Fest dates live in code).

    func helpTargeting() -> (eligible: [String], strict: [String], today: String) {
        let isoFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone(identifier: "America/Chicago")
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }()
        let cal = Calendar.current
        let todayDate = cal.startOfDay(for: .now)
        let todayStr = isoFormatter.string(from: todayDate)
        let grace = Self.presenceGraceDays

        var eligible: [String] = []
        var strict: [String] = []

        for event in ResortEvent.seedEvents {
            guard let start = isoFormatter.date(from: event.startDate) else { continue }
            let end = event.endDate.flatMap { isoFormatter.date(from: $0) } ?? start
            let windowStart = cal.date(byAdding: .day, value: -grace, to: start) ?? start
            let windowEnd   = cal.date(byAdding: .day, value: grace, to: end) ?? end

            guard todayDate >= windowStart && todayDate <= windowEnd else { continue }
            eligible.append(event.id)
            // strict: a real event day (start…end) on a day-RSVP event.
            if event.dayRsvp && todayDate >= start && todayDate <= end {
                strict.append(event.id)
            }
        }

        return (eligible, strict, todayStr)
    }
}

// MARK: - Private row types
// help_requests / help_responses / help_request_items expose author info via the
// profiles join (no flat name columns).

private struct ProfileNameRow: Decodable {
    let displayName: String?
    let avatarUrl: String?
    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
    }
}

private struct HelpResponseRow: Decodable {
    let userId: UUID
    let note: String?
    let createdAt: Date
    let profiles: ProfileNameRow?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case note
        case createdAt = "created_at"
        case profiles
    }

    func toResponse(requestId: UUID) -> HelpResponse {
        HelpResponse(
            requestId: requestId,
            responderId: userId,
            responderName: profiles?.displayName?.trimmedNonEmpty ?? "Member",
            responderAvatarUrl: profiles?.avatarUrl,
            note: note,
            createdAt: createdAt
        )
    }
}

private struct HelpItemRow: Decodable {
    let id: UUID
    let label: String
    let position: Int
    let claimedBy: UUID?
    let claimedAt: Date?
    let profiles: ProfileNameRow?

    enum CodingKeys: String, CodingKey {
        case id, label, position
        case claimedBy = "claimed_by"
        case claimedAt = "claimed_at"
        case profiles
    }

    var toBringItem: BringItem {
        BringItem(
            id: id,
            label: label,
            claimedBy: claimedBy,
            claimedByName: profiles?.displayName?.trimmedNonEmpty,
            claimedAt: claimedAt
        )
    }
}

private struct HelpRequestRow: Decodable {
    let id: UUID
    let userId: UUID
    let description: String
    let category: String?
    let whereText: String?
    let lat: Double?
    let lng: Double?
    let neededAt: Date?
    let neededCount: Int
    let status: HelpRequestStatus
    let fulfilledAt: Date?
    let notifiedCount: Int
    let createdAt: Date
    let expiresAt: Date?
    let profiles: ProfileNameRow?
    let helpResponses: [HelpResponseRow]?
    let helpRequestItems: [HelpItemRow]?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case description, category
        case whereText = "where_text"
        case lat, lng
        case neededAt = "needed_at"
        case neededCount = "needed_count"
        case status
        case fulfilledAt = "fulfilled_at"
        case notifiedCount = "notified_count"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case profiles
        case helpResponses = "help_responses"
        case helpRequestItems = "help_request_items"
    }

    var toHelpRequest: HelpRequest {
        HelpRequest(
            id: id,
            requesterId: userId,
            requesterName: profiles?.displayName?.trimmedNonEmpty ?? "Member",
            requesterAvatarUrl: profiles?.avatarUrl,
            category: HelpCategory(key: category),
            what: description,
            neededCount: neededCount,
            whereDescription: whereText,
            latitude: lat,
            longitude: lng,
            scheduledFor: neededAt,
            status: status,
            fulfilledAt: fulfilledAt,
            notifiedCount: notifiedCount,
            createdAt: createdAt,
            expiresAt: expiresAt,
            responses: (helpResponses ?? [])
                .map { $0.toResponse(requestId: id) }
                .sorted { $0.createdAt < $1.createdAt },
            items: (helpRequestItems ?? [])
                .sorted { $0.position < $1.position }
                .map(\.toBringItem)
        )
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
