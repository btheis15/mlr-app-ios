import Foundation
import Supabase

// MARK: - Who will actually be AT a house, and when
//
// The union of two very different signals, in one place because several
// surfaces need the same answer:
//
//   1. `house_stays` (migration 0071) — somebody explicitly said "I'm going up
//      on these dates."
//   2. An RSVP to a resort event — someone attached to this house said they're
//      coming to something happening at the resort.
//
// ⚠️⚠️ THE RULE, AND ITS DIRECTION. If you're in the house and you're going to a
// resort event, you're going to be at the house — so you belong in "Who's
// staying", even if you're tenting. It does NOT run the other way: a house stay
// implies nothing about any event. Every derivation here is event → presence.
//
// Nothing here writes anything. An implied stay is DERIVED at read time and is
// never persisted — the moment someone adds a real stay or changes their RSVP,
// the derived row updates or disappears on its own.

struct HouseMemberRef: Identifiable, Equatable {
    let id: UUID
    let name: String
    let avatarUrl: String?
}

/// Somebody assigned to this house with NO app account yet (migration 0123).
///
/// ⚠️ First-class housemates, not a footnote. They can't RSVP themselves, but a
/// host can add them to an event (`event_attendance.roster_id`) — and when that
/// happens they are just as much "staying at the house" as anyone with a login.
/// Leaving them out is what made the house calendar undercount.
struct HouseRosterRef: Identifiable, Equatable {
    let id: UUID          // family_roster.id
    let name: String
}

/// A stay nobody typed: "<name> is going to <event>, so they'll be at the house."
///
/// Deliberately NOT a `HouseStay`. It has no row in `house_stays`, so it can't
/// be edited, deleted or opened like one — and giving it that type would invite
/// exactly those affordances.
struct ImpliedStay: Identifiable, Equatable {
    /// ⚠️ Keyed on the ATTENDANCE ROW's id, not the user id. A guest row has no
    /// user id, so two guests at one event would otherwise collide and render
    /// as one person.
    let id: String
    let userId: UUID?
    let name: String
    let avatarUrl: String?
    let startDate: String
    let endDate: String
    let eventId: String
    let eventTitle: String
    let via: Via
    /// For `.guest` — the housemate vouching for them.
    let sponsorName: String?

    /// Three genuinely different situations that all mean "they'll be here".
    /// Flattening them into one would make the list unreadable.
    enum Via: String {
        case member   // in the house, has an account, RSVP'd themselves
        case roster   // assigned to the house, no account yet
        case guest    // not family, but sponsored by someone in this house
    }
}

/// One person expected at the house on a given day.
struct DayOccupant: Identifiable {
    let id: String
    let name: String
    let avatarUrl: String?
    /// Nil for a real stay; set when the row came from an event RSVP.
    let eventTitle: String?
    let isImplied: Bool
    let via: ImpliedStay.Via?
    let sponsorName: String?
    /// Extra names riding on a real stay (`house_stays.guest_names`).
    let guestNames: [String]
}

// MARK: - The derivation

enum HousePresence {

    /// Do two inclusive ISO date ranges touch at all? (String compare is safe
    /// for `yyyy-MM-dd`.)
    static func overlaps(_ aStart: String, _ aEnd: String,
                         _ bStart: String, _ bEnd: String) -> Bool {
        aStart <= bEnd && aEnd >= bStart
    }

    /// Derive "they'll be at the house" rows from event RSVPs.
    ///
    /// ⚠️ Four rules, each of which exists to stop a wrong or duplicate row:
    ///
    ///  1. **A real stay always wins.** If the member already has a `house_stays`
    ///     row overlapping the event, no implied row is produced — they've
    ///     stated their actual dates, which may be wider than the event.
    ///  2. **Per-day RSVPs are respected.** On a day-RSVP event, a member who
    ///     marked only Mon–Wed shows for Mon–Wed, not the whole week.
    ///  3. **Only "going" counts.** Somebody who might come is not somebody
    ///     who's staying.
    ///  4. **Finished events are skipped.** This answers "who's coming";
    ///     back-filling history would bury the real stays.
    static func impliedStays(
        events: [ResortEvent],
        attendance: [PresenceAttendanceRow],
        members: [HouseMemberRef],
        rosterMembers: [HouseRosterRef],
        stays: [HouseStay],
        today: String
    ) -> [ImpliedStay] {
        guard !today.isEmpty else { return [] }
        // A house with neither kind of member can't place anybody.
        guard !members.isEmpty || !rosterMembers.isEmpty else { return [] }

        let byId = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
        let byRosterId = Dictionary(uniqueKeysWithValues: rosterMembers.map { ($0.id, $0) })
        var out: [ImpliedStay] = []

        for event in events {
            // ⚠️ `endDate` is absent on a SINGLE-DAY event, so it can never be
            // compared raw — a bare `event.endDate < today` would treat every
            // one-day event as ongoing forever.
            let eventEnd = event.endDate ?? event.startDate
            if eventEnd < today { continue }               // Rule 4
            let days = eventDays(from: event.startDate, to: eventEnd)

            for row in attendance where row.eventId == event.id {
                // ── Which of the three kinds of person is this, and are they
                // OURS? This used to open with "no account ⇒ skip", which
                // silently dropped two whole categories of people who are just
                // as much at the house.
                var via: ImpliedStay.Via?
                var name = ""
                var avatarUrl: String?
                var sponsorName: String?

                if let uid = row.userId, let member = byId[uid] {
                    via = .member
                    name = member.name
                    avatarUrl = member.avatarUrl
                } else if let rid = row.rosterId, let entry = byRosterId[rid] {
                    via = .roster
                    name = entry.name
                } else if let guest = row.guestName?.trimmingCharacters(in: .whitespaces),
                          !guest.isEmpty,
                          let sponsorId = row.sponsorUserId,
                          let sponsor = byId[sponsorId] {
                    // A guest belongs to whoever vouched for them — the sponsor
                    // is required precisely so an outside guest is traceable. If
                    // that sponsor is in this house, so is the guest.
                    via = .guest
                    name = guest
                    sponsorName = sponsor.name
                }
                guard let via else { continue }   // nothing ties this row here

                if row.effectiveStatus != .going { continue }   // Rule 3

                // Rule 2 — narrow to the days they actually said yes to.
                let mine: [String]
                if let dayMap = row.days, !dayMap.isEmpty {
                    mine = days.filter { dayMap[$0] == .going }
                } else {
                    mine = days
                }
                guard let startDate = mine.first, let endDate = mine.last else { continue }

                // Rule 1 — they've already told us their real dates.
                //
                // ⚠️ Guarded on `userId`. `house_stays.created_by` is a uuid, so
                // no real stay can belong to a roster person or a guest —
                // matching a nil user id would suppress every one of them at
                // once.
                if let uid = row.userId,
                   stays.contains(where: { $0.createdBy == uid
                       && overlaps($0.startDate, $0.endDate, startDate, endDate) }) {
                    continue
                }

                out.append(ImpliedStay(
                    id: "event:\(event.id):\(row.id)",
                    userId: row.userId,
                    name: name,
                    avatarUrl: avatarUrl,
                    startDate: startDate,
                    endDate: endDate,
                    eventId: event.id,
                    eventTitle: event.title,
                    via: via,
                    sponsorName: sponsorName
                ))
            }
        }

        // Soonest first, then by name — the order the real-stay agenda uses.
        return out.sorted {
            $0.startDate == $1.startDate ? $0.name < $1.name : $0.startDate < $1.startDate
        }
    }

    /// Everyone expected at the house on ONE day — real stays and implied ones.
    ///
    /// ⚠️⚠️ THIS EXISTS BECAUSE THE DAY DETAIL AND THE LIST BELOW IT DISAGREED.
    /// The day popover counted only `house_stays`, so tapping a date said
    /// "Staying (0) · Nobody's marked a stay" while "Who's staying", three
    /// inches lower on the same screen, listed five people for those dates.
    /// Both read the same data; only one knew an RSVP counts as being there.
    ///
    /// Neither surface derives it any more — they both call this. If a third
    /// surface needs "who's here on day X", it calls this too rather than
    /// re-deriving and becoming the next one to disagree.
    static func occupants(on day: String,
                          stays: [HouseStay],
                          implied: [ImpliedStay]) -> [DayOccupant] {
        guard !day.isEmpty else { return [] }
        var out: [DayOccupant] = stays
            .filter { $0.covers(day) }
            .map { s in
                DayOccupant(id: "stay:\(s.id.uuidString)", name: s.authorName,
                            avatarUrl: s.authorAvatarUrl, eventTitle: nil,
                            isImplied: false, via: nil, sponsorName: nil,
                            guestNames: s.guestNames)
            }
        out += implied
            .filter { $0.startDate <= day && $0.endDate >= day }
            .map { i in
                DayOccupant(id: i.id, name: i.name, avatarUrl: i.avatarUrl,
                            eventTitle: i.eventTitle, isImplied: true,
                            via: i.via, sponsorName: i.sponsorName, guestNames: [])
            }
        return out.sorted { $0.name < $1.name }
    }

    /// How many PEOPLE are expected across everything upcoming — the number on
    /// the "Who's staying" heading.
    ///
    /// ⚠️ People, not rows. A real stay's `guest_names` are extra people
    /// sleeping there, so they count; and one person appearing in both a stay
    /// and an implied row is counted once. "Who's staying (5)" has to match what
    /// someone gets counting the names on screen.
    static func stayingCount(stays: [HouseStay], implied: [ImpliedStay]) -> Int {
        var names = Set<String>()
        for s in stays {
            names.insert("p:\(s.createdBy.uuidString)")
            for g in s.guestNames {
                let t = g.trimmingCharacters(in: .whitespaces).lowercased()
                if !t.isEmpty { names.insert("g:\(t)") }
            }
        }
        for i in implied {
            if let uid = i.userId {
                names.insert("p:\(uid.uuidString)")
            } else {
                names.insert("g:\(i.name.trimmingCharacters(in: .whitespaces).lowercased())")
            }
        }
        return names.count
    }

    /// Every inclusive ISO day between two dates. Capped so a bad range can't
    /// loop forever.
    static func eventDays(from start: String, to end: String) -> [String] {
        guard var d = HouseStay.iso.date(from: start),
              let last = HouseStay.iso.date(from: end) else { return [start] }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago")!
        var out: [String] = []
        var i = 0
        while d <= last && i < 366 {
            out.append(HouseStay.iso.string(from: d))
            guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
            i += 1
        }
        return out
    }
}

// MARK: - Wire type

/// An `event_attendance` row with the three columns presence needs, which the
/// app's shared `EventAttendance` model doesn't carry (it's built for "my own
/// RSVP", which is always a member).
struct PresenceAttendanceRow: Decodable, Identifiable {
    let id: String
    let eventId: String
    let userId: UUID?
    let rosterId: UUID?
    let guestName: String?
    let sponsorUserId: UUID?
    let status: AttendanceStatus
    let days: [String: AttendanceStatus]?

    var effectiveStatus: AttendanceStatus {
        guard let days, !days.isEmpty else { return status }
        if days.values.contains(.going) { return .going }
        if days.values.contains(.maybe) { return .maybe }
        return .notGoing
    }

    enum CodingKeys: String, CodingKey {
        case id, status, days
        case eventId = "event_id"
        case userId = "user_id"
        case rosterId = "roster_id"
        case guestName = "guest_name"
        case sponsorUserId = "sponsor_user_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventId = try c.decode(String.self, forKey: .eventId)
        userId = try? c.decodeIfPresent(UUID.self, forKey: .userId)
        rosterId = try? c.decodeIfPresent(UUID.self, forKey: .rosterId)
        guestName = try? c.decodeIfPresent(String.self, forKey: .guestName)
        sponsorUserId = try? c.decodeIfPresent(UUID.self, forKey: .sponsorUserId)
        status = (try? c.decode(AttendanceStatus.self, forKey: .status)) ?? .notGoing
        days = try? c.decodeIfPresent([String: AttendanceStatus].self, forKey: .days)
        // `event_attendance` gained a real `id` in 0196 for exactly this reason
        // — before it, a guest row had no stable key. Fall back to a composite
        // so a pre-0196 database still renders rather than failing the decode.
        if let realId = try? c.decodeIfPresent(String.self, forKey: .id) {
            id = realId
        } else {
            id = "\(eventId)-\(userId?.uuidString ?? guestName ?? "?")"
        }
    }
}

// MARK: - Fetching

extension HousesService {

    /// Everyone whose profile says they're in this house.
    ///
    /// ⚠️ Compares `house_id` DIRECTLY rather than using `is_house_member()`,
    /// which grants app admins a blanket pass and would pull in outsiders.
    /// Empty on any failure: a presence list that can't resolve membership must
    /// show nothing rather than guess.
    func fetchHouseMemberRefs(houseId: UUID) async -> [HouseMemberRef] {
        struct Row: Decodable {
            let id: UUID; let displayName: String?; let avatarUrl: String?
            enum CodingKeys: String, CodingKey {
                case id
                case displayName = "display_name"
                case avatarUrl = "avatar_url"
            }
        }
        let rows: [Row] = (try? await supabase.from("profiles")
            .select("id, display_name, avatar_url")
            .eq("house_id", value: houseId.uuidString)
            .execute().value) ?? []
        return rows.map {
            HouseMemberRef(id: $0.id,
                           name: $0.displayName?.trimmingCharacters(in: .whitespaces).isEmpty == false
                               ? $0.displayName! : "Member",
                           avatarUrl: $0.avatarUrl)
        }
    }

    /// The house's account-less people (migration 0123).
    ///
    /// ⚠️ Only rows with nothing linked. Once a roster slot claims an account
    /// that person is covered by `profiles.house_id`, and returning them here
    /// too would list them twice.
    func fetchHouseRosterRefs(houseId: UUID) async -> [HouseRosterRef] {
        struct Row: Decodable {
            let id: UUID; let name: String?; let linkedUserId: UUID?
            enum CodingKeys: String, CodingKey {
                case id, name
                case linkedUserId = "linked_user_id"
            }
        }
        let rows: [Row] = (try? await supabase.from("family_roster")
            .select("id, name, linked_user_id")
            .eq("house_id", value: houseId.uuidString)
            .execute().value) ?? []
        return rows
            .filter { $0.linkedUserId == nil }
            .map { HouseRosterRef(id: $0.id,
                                  name: $0.name?.trimmingCharacters(in: .whitespaces).isEmpty == false
                                      ? $0.name! : "Family") }
    }

    /// Every attendance row the viewer can see, in the shape presence needs.
    ///
    /// ⚠️ Uses a column ladder: `roster_id` / `guest_name` / `sponsor_user_id`
    /// arrived in 0196, and an unknown column fails the WHOLE select with 42703
    /// — which would empty the calendar and read as "nobody's coming".
    func fetchPresenceAttendance() async -> [PresenceAttendanceRow] {
        let full = "id, event_id, user_id, roster_id, guest_name, sponsor_user_id, status, days"
        if let rows: [PresenceAttendanceRow] = try? await supabase
            .from("event_attendance").select(full).execute().value {
            return rows
        }
        let base = "event_id, user_id, status, days"
        return (try? await supabase
            .from("event_attendance").select(base).execute().value) ?? []
    }
}
