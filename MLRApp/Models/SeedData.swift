import Foundation

// FamilyFestConfig moved to Shared/Utilities/FestSeason.swift (shared with the
// widget target without pulling in the model layer).

// MARK: - Schedule Item

struct ScheduleItem: Identifiable {
    let id: String
    let day: String            // weekday name ("Monday"…) or "Anytime"
    let isoDate: String?       // yyyy-MM-dd for real ordering + weather; nil for Anytime/seed
    let time: String
    let title: String
    let location: String?
    let description: String?
    let isPrivate: Bool
    let leads: [String]
    var leadUserId: UUID? = nil
    var crewUserIds: [UUID] = []   // migration 0110 — event/activity crew self-edit
    var links: [ScheduleLink] = [] // migration 0142 — ordered link buttons (e.g. sign-up + info)

    // Sign-ups (migrations 0135/0136/0143). When enabled, members can sign up —
    // by time slot ("interval"/"slots") or a plain running count ("headcount").
    var signupEnabled: Bool = false
    var signupMode: String? = nil          // interval | slots | headcount
    var signupCapacity: Int? = nil         // per-slot (interval/slots) or total (headcount); nil = uncapped
    var signupSlotMinutes: Int? = nil      // interval mode: minutes per generated slot
    var signupStartTime: String? = nil     // interval mode: first slot "HH:MM"
    var signupEndTime: String? = nil       // interval mode: boundary the last slot ends by
    var signupInstructions: String? = nil
    var signupTeamSize: Int? = nil         // nil/1 = individual; >1 = sign up in fixed teams
    var signupFields: [SignupField] = []   // admin-defined custom columns
}

/// One labeled link button on a schedule event (migration 0142 `links` jsonb —
/// replaced the old single link_url/link_label pair).
struct ScheduleLink: Identifiable, Hashable, Decodable {
    let href: String
    let label: String?
    var id: String { href }
    /// Button text — the label if set, else the raw URL.
    var display: String {
        let l = label?.trimmingCharacters(in: .whitespaces) ?? ""
        return l.isEmpty ? href : l
    }
}

// MARK: - Dinner

struct FestDinner: Identifiable {
    let id: String
    let day: String
    let title: String
    let chef: String
    /// UUID of the chef's profile, if they're a real app member (migration 0053).
    let chefUserId: UUID?
    /// Members explicitly assigned to help with this dinner (migration 0099) —
    /// distinct from `crew` (house names). These users can self-edit the dinner.
    let crewUserIds: [UUID]
    let menu: String
    let location: String?
    let time: String
    let crew: [String]

    /// The menu split into individual lines (blank lines dropped) — shared by the
    /// dinner detail view and the inline expandable dinner row.
    var menuLines: [String] {
        menu.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Local Place

struct LocalPlace: Identifiable {
    let id: String
    let name: String
    let category: PlaceCategory
    let phone: String?
    let address: String?
    let website: String?
    let menuUrl: String?
    let orderUrl: String?          // online ordering, or a golf tee-time booking link
    var ratesUrl: String? = nil    // rates-only golf course ("See Rates" pill)
    let description: String?

    enum PlaceCategory: String {
        case dining, grocery, activity, marina, medical, golf, coffee
    }
}

// MARK: - Activity

struct ResortActivity: Identifiable {
    let id: String
    let category: String
    let title: String
    let description: String
    let icon: String
}

// MARK: - Local Places Seed Data

extension LocalPlace {
    static let all: [LocalPlace] = [
        // ── Golf ──
        LocalPlace(
            id: "inshalla",
            name: "Inshalla Country Club",
            category: .golf,
            phone: "+17154533130",
            address: "Tomahawk, WI",
            website: "https://inshallacc.com",
            menuUrl: nil,
            orderUrl: "https://stage.foreupsoftware.com/index.php/booking/19715/2251?booking_class_id=2431&schedule_id=2251#/teetimes",
            description: "Public 18-hole course with a pro shop, driving range, and bar & grill. Book your tee time online."
        ),
        LocalPlace(
            id: "edgewater",
            name: "Edgewater Country Club",
            category: .golf,
            phone: "+17154533320",
            address: "Tomahawk, WI",
            website: "https://edgewaterccgolf.com",
            menuUrl: nil,
            orderUrl: nil,
            ratesUrl: "https://edgewaterccgolf.com/rates",
            description: "Family-friendly public 9-hole course tucked along the shores of Lake Alice, just outside town."
        ),
        LocalPlace(
            id: "pinewood",
            name: "Pinewood Country Club",
            category: .golf,
            phone: "+17152825500",
            address: "Harshaw, WI",
            website: nil,
            menuUrl: nil,
            orderUrl: nil,
            ratesUrl: "https://www.pinewoodcc.com",
            description: "Public 18-hole course open April through October, with a pro shop and online tee-time booking."
        ),
        LocalPlace(
            id: "merrill-golf",
            name: "Merrill Golf Club",
            category: .golf,
            phone: "+17155362529",
            address: "Merrill, WI",
            website: "https://www.merrillgolfclub.com",
            menuUrl: nil,
            orderUrl: "https://merrill-golf-club.book.teeitup.com/?course=17053",
            description: "18-hole championship public course with a pro shop, lessons, and a bar & grill."
        ),
        LocalPlace(
            id: "timber-ridge",
            name: "Timber Ridge Golf Club",
            category: .golf,
            phone: "+17153569502",
            address: "Minocqua, WI",
            website: "https://timberridgegolfclub.com",
            menuUrl: nil,
            orderUrl: "https://www.chronogolf.com/club/19672/widget?medium=widget&source=club",
            description: "Scenic 18-hole, par-72 Northwoods course with rolling elevation changes, a short drive south of Minocqua."
        ),
        LocalPlace(
            id: "northwood-golf",
            name: "Northwood Golf Club",
            category: .golf,
            phone: "+17152826565",
            address: "Rhinelander, WI",
            website: "https://northwoodgolfclub.com",
            menuUrl: nil,
            orderUrl: "https://foreupsoftware.com/index.php/booking/22872/12171#/teetimes",
            description: "18-hole public course carved out of ancient rock and timber, with a full clubhouse, restaurant, and bar."
        ),
        LocalPlace(
            id: "trout-lake",
            name: "Trout Lake Golf Club",
            category: .golf,
            phone: "+17153852189",
            address: "Arbor Vitae, WI",
            website: "https://troutlakegolf.com",
            menuUrl: nil,
            orderUrl: "https://foreupsoftware.com/index.php/booking/19524/1784#/teetimes",
            description: "The Northwoods' oldest 18-hole course (est. 1924), freshly renovated, with a driving range and a historic clubhouse."
        ),
        // ── Food & Drink ──
        LocalPlace(
            id: "billy-bobs",
            name: "Billy Bob's Sports Bar & Grill",
            category: .dining,
            phone: "+17154534984",
            address: "Tomahawk, WI",
            website: "https://billybobssportsbarandgrill.com",
            menuUrl: "https://billybobssportsbarandgrill.com/menu/",
            orderUrl: nil,
            description: "Our usual pizza order — plus burgers, baskets, and the big game on."
        ),
        LocalPlace(
            id: "tilted-loon",
            name: "Tilted Loon",
            category: .dining,
            phone: "+17154532768",
            address: "Lake Nokomis · Tomahawk, WI",
            website: "https://www.tiltedloon.com",
            menuUrl: "https://www.tiltedloon.com/menus-1",
            orderUrl: "https://order.toasttab.com/online/tilted_loon",
            description: "Lakeside saloon known for pizza, burgers, and the Friday fish fry — takes online orders."
        ),
        LocalPlace(
            id: "outboards",
            name: "Outboards Bar & Grill",
            category: .dining,
            phone: "+17152243594",
            address: "Downtown Tomahawk, WI",
            website: "https://outboardsbarandgrill.com",
            menuUrl: "https://outboardsbarandgrill.com/menu/",
            orderUrl: nil,
            description: "Downtown bar & grill — fish fry, happy hour, and a full grill menu."
        ),
        LocalPlace(
            id: "sideways",
            name: "Sideways Wine & Craft Beer",
            category: .dining,
            phone: "+17154930826",
            address: "Downtown Tomahawk, WI",
            website: "https://www.sidewayswineandcraftbeer.com",
            menuUrl: "https://www.sidewayswineandcraftbeer.com/menu",
            orderUrl: nil,
            description: "Wine, Wisconsin craft beer, flatbreads, and charcuterie — a relaxed night out."
        ),
        // ── Coffee ──
        LocalPlace(
            id: "northwoods-cafe",
            name: "Northwoods Cafe & Coffeehouse",
            category: .coffee,
            phone: "+17154536280",
            address: "Tomahawk, WI",
            website: "https://northwoods-cafe.square.site",
            menuUrl: nil,
            orderUrl: nil,
            description: "A cozy, family-run downtown cafe serving breakfast, lunch, and specialty coffee drinks."
        ),
        LocalPlace(
            id: "whats-brewin",
            name: "What's Brewin' Coffee Shop",
            category: .coffee,
            phone: "+17154533555",
            address: "Downtown Tomahawk, WI",
            website: "https://www.facebook.com/whatsbrewintomahawk/",
            menuUrl: nil,
            orderUrl: nil,
            description: "Downtown coffee shop pairing gourmet coffee and cold brew with homemade soups, sandwiches, baked goods, and fudge."
        ),
        LocalPlace(
            id: "rise-coffee",
            name: "Rise Coffee Co.",
            category: .coffee,
            phone: "+17159661311",
            address: "Tomahawk, WI",
            website: "https://risecoffeetomahawk.com",
            menuUrl: nil,
            orderUrl: nil,
            description: "A friendly mother-daughter drive-thru serving fresh espresso and coffee on the go."
        ),
    ]
}

// MARK: - Schedule Item Seed Data
// Jul 27 = Monday · Jul 28 = Tuesday · Jul 29 = Wednesday · Jul 30 = Thursday · Jul 31 = Friday

extension ScheduleItem {
    // One headline activity per day so far. Titles are real; times, locations,
    // and details are still being set, so they read "TBD" (no placeholders).
    // Emoji is prepended to the title (ScheduleItem has no emoji field).
    static let seed: [ScheduleItem] = [
        ScheduleItem(
            id: "games-up-top",
            day: "Monday",
            isoDate: "2026-07-27",
            time: "TBD",
            title: "🏅 Games Up Top",
            location: "TBD",
            description: "Details TBD.",
            isPrivate: false,
            leads: []
        ),
        ScheduleItem(
            id: "lake-day",
            day: "Tuesday",
            isoDate: "2026-07-28",
            time: "TBD",
            title: "🏖️ Lake Day",
            location: "TBD",
            description: "Details TBD.",
            isPrivate: false,
            leads: []
        ),
        ScheduleItem(
            id: "golf-outing",
            day: "Wednesday",
            isoDate: "2026-07-29",
            time: "TBD",
            title: "⛳ Golf Outing",
            location: "TBD",
            description: "Details TBD.",
            isPrivate: false,
            leads: []
        ),
        ScheduleItem(
            id: "variety-show",
            day: "Thursday",
            isoDate: "2026-07-30",
            time: "TBD",
            title: "🎭 Variety Show",
            location: "TBD",
            description: "Hosted by Michelle Birkholz. Details TBD.",
            isPrivate: false,
            leads: ["Michelle Birkholz"]
        ),
        ScheduleItem(
            id: "friday-tbd",
            day: "Friday",
            isoDate: "2026-07-31",
            time: "TBD",
            title: "🗓️ TBD",
            location: "TBD",
            description: "Details TBD.",
            isPrivate: false,
            leads: []
        ),
        // Anytime — runs all week with no set time.
        ScheduleItem(
            id: "scavenger-hunt",
            day: "Anytime",
            isoDate: nil,
            time: "Any time",
            title: "🗺️ Family Fest scavenger hunt",
            location: "Pick up your card at the Main Lodge",
            description: "Track down hidden landmarks & oddities around the lake — any time, all week. Pick up a hunt card at the lodge, then find each spot around Muskellunge Lake at your own pace — solo, as a family, or as a house. Finish the list any day and turn it in at the lodge for a prize at the farewell BBQ.",
            isPrivate: false,
            leads: []
        ),
    ]
}

// MARK: - Fest Dinner Seed Data
// Jul 27 = Monday · Jul 28 = Tuesday · Jul 29 = Wednesday · Jul 30 = Thursday · Jul 31 = Friday

extension FestDinner {
    // Head chefs are real; menus, crew, times, and locations are still being set
    // (they read "TBD" — no placeholders).
    static let seed: [FestDinner] = [
        FestDinner(id: "d-mon", day: "Monday", title: "Monday Dinner",
                   chef: "Jessica Stewart", chefUserId: nil, crewUserIds: [],
                   menu: "TBD", location: "TBD", time: "TBD", crew: []),
        FestDinner(id: "d-tue", day: "Tuesday", title: "Tuesday Dinner",
                   chef: "Natalie de Pareja & Karen", chefUserId: nil, crewUserIds: [],
                   menu: "TBD", location: "TBD", time: "TBD", crew: []),
        FestDinner(id: "d-wed", day: "Wednesday", title: "Wednesday Dinner",
                   chef: "Lauren Zerfas", chefUserId: nil, crewUserIds: [],
                   menu: "TBD", location: "TBD", time: "TBD", crew: []),
        FestDinner(id: "d-thu", day: "Thursday", title: "Thursday Dinner",
                   chef: "Rob & Joe", chefUserId: nil, crewUserIds: [],
                   menu: "TBD", location: "TBD", time: "TBD", crew: []),
        FestDinner(id: "d-fri", day: "Friday", title: "Friday Dinner",
                   chef: "TBD", chefUserId: nil, crewUserIds: [],
                   menu: "TBD", location: "TBD", time: "TBD", crew: []),
    ]
}

// MARK: - Seed Events

extension ResortEvent {
    static let seedEvents: [ResortEvent] = [
        ResortEvent(
            id: "family-fest-2026",
            title: "Family Fest 2026",
            description: "The annual Theis Family gathering at Muskellunge Lake Resort.",
            kind: .familyFest,
            startDate: FamilyFestConfig.startDate,
            endDate: FamilyFestConfig.endDate,
            location: "Muskellunge Lake Resort",
            dayRsvp: true,
            source: .seed
        ),
        ResortEvent(
            id: "up-north-4th-2026",
            title: "Up North for the 4th",
            description: "The 4th of July weekend Up North — fireworks, cookouts, and time on the water. Let everyone know if you're heading up.",
            kind: .holiday,
            startDate: "2026-07-03",
            endDate: "2026-07-05",
            location: "Muskellunge Lake Resort",
            dayRsvp: false,
            source: .seed
        ),
    ]
}

// MARK: - Seed Activities

extension ResortActivity {
    static let all: [ResortActivity] = [
        ResortActivity(id: "fishing", category: "Water", title: "Fishing", description: "World-class muskie fishing on Muskellunge Lake. Boats and gear available.", icon: "🎣"),
        ResortActivity(id: "boating", category: "Water", title: "Boating", description: "Explore the lake by pontoon, canoe, or kayak.", icon: "⛵"),
        ResortActivity(id: "swimming", category: "Water", title: "Swimming", description: "Sandy beach and swimming area on the lake.", icon: "🏊"),
        ResortActivity(id: "hunting", category: "Land", title: "Hunting", description: "Deer and turkey hunting on resort grounds. Licenses required.", icon: "🦌"),
        ResortActivity(id: "hiking", category: "Land", title: "Hiking", description: "Trails through the northern Wisconsin woods.", icon: "🥾"),
        ResortActivity(id: "bonfires", category: "Evening", title: "Bonfires", description: "Gather around the fire pit for evening stories and s'mores.", icon: "🔥"),
        ResortActivity(id: "golf", category: "Land", title: "Golf", description: "Several golf courses within 20 minutes of the resort.", icon: "⛳")
    ]
}

// MARK: - Seed Announcements

extension Announcement {
    static let seed: [Announcement] = [
        Announcement(
            id: "welcome-2026",
            title: "Welcome to MLR",
            body: "Est. 1987 · Leo & Dorothy Theis · Tomahawk, WI",
            kind: .info,
            expiresAt: nil,
            createdAt: nil
        )
    ]
}
