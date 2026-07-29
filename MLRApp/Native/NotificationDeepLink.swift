import Foundation

// MARK: - Notification deep link
//
// Where a tapped notification should land. Built from the payload the Mac-mini
// sender puts on every APNs push (media-server/apns-sender.js `handleFeed` →
// `createApnsDelivery().sendToUser`):
//
//   • target_type — the notification row's `entity_type`: "post",
//     "committee_message", "house_message", "work_item", "help_request",
//     "cabin_booking", "private_activity", "schedule", "tournament", …
//   • target_id   — its `entity_id` (the post / message / work-item uuid).
//   • url         — the WEB deep link, prefixed with APP_URL, so it arrives as
//     `https://mlr-app-omega.vercel.app/posts?post=<uuid>`. It's the only field
//     carrying ids `target_id` doesn't: the Family Fest schedule item behind a
//     sign-up reminder (whose entity_id is the SIGN-UP row) or a tournament ping
//     (whose entity_id is the tournament).
//
// The in-app Activity list (NotificationsView) posts the same two `target_*`
// keys with no `url`, so both shapes have to resolve — and the `url` has to parse
// as a bare app-relative path as well as a full https URL, since only the push
// path prefixes it with the host.
//
// A committee/house chat message resolves its room from the message row rather
// than the url: the web trigger concatenates the raw area name into the query
// (`&area=Art & Decorating`, migration 0063), which isn't reliably parseable.

enum NotificationDeepLink: Equatable {
    /// A Main Feed post — new post, comment, reply, @mention, tag, or reaction.
    case post(id: UUID)
    /// The Feed tab itself (no specific post/message resolved).
    case feed
    /// A committee/role-channel chat message; the room comes from the message row.
    case committeeMessage(id: UUID)
    case committeeJoinRequest(requestId: UUID?, committeeId: UUID?)
    /// A house chat message; the house comes from the message row.
    case houseMessage(id: UUID)
    /// The House Hub (a new stay on the house calendar).
    case houseHub
    case workItem(id: UUID)
    case helpRequests
    /// The member's own cabin bookings (a request decision, edit, or guest note).
    case cabinStays
    case privateActivity(id: UUID)
    case festScheduleItem(id: UUID)
    case familyFest
    /// The Activity (notifications) tab.
    case notifications
    case home

    init(userInfo: [AnyHashable: Any]) {
        let link = WebLink(userInfo["url"] as? String)
        let targetId = (userInfo["target_id"] as? String).flatMap { UUID(uuidString: $0) }

        switch userInfo["target_type"] as? String {
        case "post":
            if let id = targetId ?? link.uuid("post") { self = .post(id: id) } else { self = .feed }
        case "committee_message":
            if let id = targetId ?? link.uuid("m") { self = .committeeMessage(id: id) } else { self = .feed }
        case "house_message":
            if let id = targetId ?? link.uuid("m") { self = .houseMessage(id: id) } else { self = .feed }
        case "house_stay":
            self = .houseHub
        case "work_item":
            if let id = targetId ?? link.uuid("work") { self = .workItem(id: id) } else { self = .home }
        case "committee_join_request":
            // entity_id is the REQUEST id; the sender forwards committee_id too so
            // the room can be opened without a second lookup (apns-sender.js).
            self = .committeeJoinRequest(
                requestId: targetId,
                committeeId: (userInfo["committee_id"] as? String).flatMap { UUID(uuidString: $0) })
        case "help_request":
            self = .helpRequests
        case "cabin_booking", "cabin":
            self = .cabinStays
        case "private_activity":
            if let id = targetId ?? link.uuid("activity") { self = .privateActivity(id: id) } else { self = .home }
        case "notification":
            self = .notifications
        default:
            // Unknown / absent target_type (a broadcast, a kind the web added
            // since) — fall back to whatever the url path says.
            self = Self(path: link)
        }
    }

    /// Route on the web deep link alone, so a notification kind iOS doesn't know
    /// about yet still lands on the right tab instead of dropping to Home.
    private init(path link: WebLink) {
        let path = link.path
        if path.hasPrefix("/family-fest/schedule"), let id = link.lastPathUUID {
            self = .festScheduleItem(id: id)
        } else if path.hasPrefix("/family-fest") {
            self = .familyFest
        } else if path.hasPrefix("/posts") {
            if let id = link.uuid("post") { self = .post(id: id) }
            else if let id = link.uuid("m") {
                self = link.query["house"] != nil ? .houseMessage(id: id) : .committeeMessage(id: id)
            } else { self = .feed }
        } else if path.hasPrefix("/notifications") {
            self = .notifications
        } else if path.hasPrefix("/help-requests") {
            self = .helpRequests
        } else if path.hasPrefix("/request-stay") || path.hasPrefix("/admin/cabins") {
            self = .cabinStays
        } else if path.hasPrefix("/house") {
            self = .houseHub
        } else if let id = link.uuid("activity") {
            self = .privateActivity(id: id)
        } else if let id = link.uuid("work") {
            self = .workItem(id: id)
        } else {
            self = .home
        }
    }
}

// MARK: - Web link
//
// The `url` the sender attaches, split into path + query. Parses a bare
// app-relative path (`/posts?post=…`) as well as the full `https://host/…` form,
// and tolerates the unescaped text SQL string-concatenation can leave in a query
// value by percent-encoding before a second attempt.

private struct WebLink {
    let path: String
    let query: [String: String]

    init(_ value: String?) {
        let raw = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty,
              let comps = URLComponents(string: raw)
                ?? URLComponents(string: raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw)
        else {
            path = ""
            query = [:]
            return
        }
        path = comps.path
        var items: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            if let value = item.value, !value.isEmpty { items[item.name] = value }
        }
        query = items
    }

    func uuid(_ name: String) -> UUID? {
        query[name].flatMap { UUID(uuidString: $0) }
    }

    /// The trailing path segment as a uuid — `/family-fest/schedule/<uuid>`.
    var lastPathUUID: UUID? {
        path.split(separator: "/").last.flatMap { UUID(uuidString: String($0)) }
    }
}
