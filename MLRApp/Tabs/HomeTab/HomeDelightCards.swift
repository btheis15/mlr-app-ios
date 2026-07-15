import SwiftUI

// MARK: - UpcomingBirthdaysCard
// Members with birthdays in the next 14 days. Signed-in only, self-hidden.
// Fetches all profiles with a birthday and filters year-agnostically in Swift
// (Chicago timezone) so we never need year-sensitive SQL date math.

struct UpcomingBirthdaysCard: View {
    @Environment(AppEnvironment.self) private var env

    struct BirthdayPerson: Identifiable {
        let id: UUID
        let name: String
        let avatarUrl: String?
        let daysUntil: Int
        let dateLabel: String
    }

    @State private var upcoming: [BirthdayPerson] = []

    var body: some View {
        if env.isSignedIn, !upcoming.isEmpty {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("🎂").font(.mlrScaled(18))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Upcoming Birthdays")
                        .font(.mlrScaled(14, weight: .semibold))
                        .foregroundStyle(Color.mlrText)
                    Text("Next 14 days")
                        .font(.caption2)
                        .foregroundStyle(Color.mlrTextSubtle)
                }
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(upcoming) { person in
                        VStack(spacing: 5) {
                            AvatarView(url: person.avatarUrl, size: .medium)
                            Text(firstName(person.name))
                                .font(.mlrScaled(11, weight: .medium))
                                .foregroundStyle(Color.mlrText)
                                .lineLimit(1)
                            Text(person.daysUntil == 0 ? "Today 🎉" : person.dateLabel)
                                .font(.mlrScaled(10))
                                .foregroundStyle(
                                    person.daysUntil == 0 ? Color.mlrPrimary : Color.mlrTextMuted
                                )
                        }
                        .frame(width: 58)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(14)
        .cardStyle()
        .task { await load() }
    }

    private func load() async {
        guard let myId = env.currentProfile?.id else { return }

        do {
            let rows: [BirthdayFetchRow] = try await supabase
                .from("profiles")
                .select("id, display_name, avatar_url, birthday")
                .execute()
                .value

            var cal = Calendar.current
            cal.timeZone = TimeZone(identifier: "America/Chicago")!
            let today = cal.startOfDay(for: Date())

            let fmt = DateFormatter()
            fmt.dateFormat = "MMM d"

            upcoming = rows.compactMap { row -> BirthdayPerson? in
                guard row.id != myId,
                      let bday = row.birthday,
                      let next = nextOccurrence(of: bday, from: today, calendar: cal),
                      let days = cal.dateComponents([.day], from: today, to: next).day,
                      days >= 0, days < 14
                else { return nil }

                return BirthdayPerson(
                    id: row.id,
                    name: row.displayName ?? "Member",
                    avatarUrl: row.avatarUrl,
                    daysUntil: days,
                    dateLabel: fmt.string(from: next)
                )
            }
            .sorted { $0.daysUntil < $1.daysUntil }
        } catch {
            print("[UpcomingBirthdaysCard] \(error)")
        }
    }

    /// Next occurrence of the birthday's MM-DD on or after `from` date.
    private func nextOccurrence(of iso: String, from: Date, calendar: Calendar) -> Date? {
        let parts = iso.split(separator: "-")
        guard parts.count >= 3,
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else { return nil }
        let year = calendar.component(.year, from: from)
        var comps = DateComponents()
        comps.month = month; comps.day = day; comps.year = year
        if let d = calendar.date(from: comps), d >= from { return d }
        comps.year = year + 1
        return calendar.date(from: comps)
    }

    private func firstName(_ name: String) -> String {
        String(name.split(separator: " ").first ?? Substring(name))
    }
}

// MARK: - WhosUpNorthCard
// Members currently at the resort — RSVPed to a multi-day event covering today
// or holding an approved cabin booking that spans today. Signed-in only, self-hidden.
// Event IDs are fetched fresh from the DB (no dependency on EventsService load order).
// Cabin bookings silently fall back to empty if RLS blocks them for non-admins.

struct WhosUpNorthCard: View {
    @Environment(AppEnvironment.self) private var env

    struct UpNorthPerson: Identifiable {
        let id: UUID
        let name: String
        let avatarUrl: String?
    }

    @State private var people: [UpNorthPerson] = []

    var body: some View {
        if env.isSignedIn, !people.isEmpty {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("🌲").font(.mlrScaled(18))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Who's Up North")
                        .font(.mlrScaled(14, weight: .semibold))
                        .foregroundStyle(Color.mlrText)
                    let noun = people.count == 1 ? "person" : "people"
                    Text("\(people.count) \(noun) at the resort today")
                        .font(.caption2)
                        .foregroundStyle(Color.mlrTextSubtle)
                }
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(people) { person in
                        VStack(spacing: 5) {
                            AvatarView(url: person.avatarUrl, size: .medium)
                            Text(firstName(person.name))
                                .font(.mlrScaled(11, weight: .medium))
                                .foregroundStyle(Color.mlrText)
                                .lineLimit(1)
                        }
                        .frame(width: 58)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(14)
        .cardStyle()
        .task { await load() }
    }

    private func load() async {
        guard let myId = env.currentProfile?.id else { return }
        let today = isoToday()
        var byId: [UUID: UpNorthPerson] = [:]

        // 1. Events covering today — fetch IDs fresh so we don't depend on
        //    EventsService having loaded before this card's task fires.
        do {
            let eventRows: [EventIdFetchRow] = try await supabase
                .from("events")
                .select("id, start_date, end_date")
                .lte("start_date", value: today)
                .execute()
                .value

            // Filter client-side: event must end on or after today.
            // Events without end_date are single-day; include when start = today.
            let todayIds = eventRows.filter { row in
                let end = row.endDate ?? row.startDate
                return end >= today
            }.map(\.id)

            if !todayIds.isEmpty {
                let attRows: [AttendanceFetchRow] = try await supabase
                    .from("event_attendance")
                    .select("user_id, status, profiles!user_id(id, display_name, avatar_url)")
                    .in("event_id", values: todayIds)
                    .in("status", values: ["going", "maybe"])
                    .execute()
                    .value

                for row in attRows {
                    guard row.userId != myId, let p = row.profiles else { continue }
                    byId[row.userId] = UpNorthPerson(
                        id: row.userId,
                        name: p.displayName ?? "Member",
                        avatarUrl: p.avatarUrl
                    )
                }
            }
        } catch {
            print("[WhosUpNorthCard] events/attendance: \(error)")
        }

        // 2. Approved cabin bookings covering today (check_in <= today < check_out).
        //    Silently skipped if RLS denies non-admin access — cabin people show for admins.
        do {
            let bookingRows: [BookingFetchRow] = try await supabase
                .from("cabin_bookings")
                .select("user_id, profiles!user_id(id, display_name, avatar_url)")
                .eq("status", value: "approved")
                .lte("check_in", value: today)
                .gt("check_out", value: today)
                .execute()
                .value

            for row in bookingRows {
                guard row.userId != myId, let p = row.profiles else { continue }
                byId[row.userId] = UpNorthPerson(
                    id: row.userId,
                    name: p.displayName ?? "Member",
                    avatarUrl: p.avatarUrl
                )
            }
        } catch {
            // Not fatal — admins see cabin guests; non-admins see event attendees only.
        }

        people = Array(byId.values).sorted { $0.name < $1.name }
    }

    private func isoToday() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "America/Chicago")!
        return f.string(from: Date())
    }

    private func firstName(_ name: String) -> String {
        String(name.split(separator: " ").first ?? Substring(name))
    }
}

// MARK: - Private fetch row types

private struct BirthdayFetchRow: Decodable {
    let id: UUID
    let displayName: String?
    let avatarUrl: String?
    let birthday: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case avatarUrl   = "avatar_url"
        case birthday
    }
}

private struct ProfileSnippet: Decodable {
    let id: UUID
    let displayName: String?
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case avatarUrl   = "avatar_url"
    }
}

private struct AttendanceFetchRow: Decodable {
    let userId: UUID
    let status: String
    let profiles: ProfileSnippet?

    enum CodingKeys: String, CodingKey {
        case userId  = "user_id"
        case status
        case profiles
    }
}

private struct BookingFetchRow: Decodable {
    let userId: UUID
    let profiles: ProfileSnippet?

    enum CodingKeys: String, CodingKey {
        case userId  = "user_id"
        case profiles
    }
}

private struct EventIdFetchRow: Decodable {
    let id: String
    let startDate: String
    let endDate: String?

    enum CodingKeys: String, CodingKey {
        case id
        case startDate = "start_date"
        case endDate   = "end_date"
    }
}
