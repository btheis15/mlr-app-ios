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
}

// MARK: - Dinner

struct FestDinner: Identifiable {
    let id: String
    let day: String
    let title: String
    let chef: String
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
    let orderUrl: String?
    let description: String?

    enum PlaceCategory: String {
        case dining, grocery, activity, marina, medical, golf
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
        LocalPlace(
            id: "inshalla",
            name: "Inshalla Country Club",
            category: .golf,
            phone: "+17154533130",
            address: "Tomahawk, WI",
            website: "https://inshallacc.com",
            menuUrl: nil,
            orderUrl: "https://stage.foreupsoftware.com/index.php/booking/19715/2251?booking_class_id=2431&schedule_id=2251#/teetimes",
            description: "Public 18-hole course with a pro shop, driving range, and bar & grill."
        ),
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
        FestDinner(
            id: "d-mon",
            day: "Monday",
            title: "Monday Dinner",
            chef: "Jessica Stewart",
            menu: "TBD",
            location: "TBD",
            time: "TBD",
            crew: []
        ),
        FestDinner(
            id: "d-tue",
            day: "Tuesday",
            title: "Tuesday Dinner",
            chef: "Natalie de Pareja & Karen",
            menu: "TBD",
            location: "TBD",
            time: "TBD",
            crew: []
        ),
        FestDinner(
            id: "d-wed",
            day: "Wednesday",
            title: "Wednesday Dinner",
            chef: "Lauren Zerfas",
            menu: "TBD",
            location: "TBD",
            time: "TBD",
            crew: []
        ),
        FestDinner(
            id: "d-thu",
            day: "Thursday",
            title: "Thursday Dinner",
            chef: "Rob & Joe",
            menu: "TBD",
            location: "TBD",
            time: "TBD",
            crew: []
        ),
        FestDinner(
            id: "d-fri",
            day: "Friday",
            title: "Friday Dinner",
            chef: "TBD",
            menu: "TBD",
            location: "TBD",
            time: "TBD",
            crew: []
        ),
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
