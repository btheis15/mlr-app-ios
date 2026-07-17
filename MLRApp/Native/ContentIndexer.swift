import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

// MARK: - Content Indexer (Spotlight semantic index for Siri / Apple Intelligence)
//
// Pushes the resort's content into the on-device Spotlight semantic index so
// Apple Intelligence and Siri can find it "even when described vaguely," and so
// swipe-down Spotlight surfaces it. Every item carries the resort vernacular in
// its keywords ("Up North", "MLR", "the lake") plus type-specific terms (author
// names, committees, weekdays, birthdays), and a mlr:// deep link as its id.
//
// Everything runs as the signed-in user, so RLS scopes results to content that
// person is allowed to see — private chats never leak. Index is cleared on sign
// out. Each source is defensive: a failing query just contributes nothing.
//
// For content that has an App Entity (people, committees, events, work items,
// fest dinners/schedule) we keep the hand-built CSSearchableItem (its mlr:// id
// drives tap-routing + rich keywords) and additionally call `associateAppEntity`
// — per Apple's docs this gives the same Apple-Intelligence benefits as
// `indexAppEntities` WITHOUT creating duplicate index entries, and lets the
// `.system.open` intents open the entity from a Spotlight result on iOS 27.

enum ContentIndexer {
    private static let domain = "com.muskellungelakeresort.mlr"
    private static let baseKeywords = ["Up North", "MLR", "Muskellunge", "the resort", "the lake", "family", "cabin"]

    /// Re-index everything the current user can see. Safe to call on launch /
    /// sign-in; runs off the main actor where possible.
    private static let lastIndexedKey = "spotlight_last_indexed_at"

    static func reindexAll(force: Bool = false) async {
        // Respect the user's opt-out (Profile → Features → Siri & Spotlight search).
        let enabled = (UserDefaults.standard.object(forKey: "spotlight_indexing_enabled") as? Bool) ?? true
        guard enabled else { clear(); return }
        // Only index while signed in — every query is RLS-scoped to the user.
        guard (try? await supabase.auth.session) != nil else { return }
        // Throttle: a full re-index is ~15 queries + up to ~1500 items, so skip it
        // if we indexed within the last 6 hours (unless forced).
        if !force {
            let last = UserDefaults.standard.double(forKey: lastIndexedKey)
            if last > 0, Date().timeIntervalSince1970 - last < 6 * 3600 { return }
        }

        var items: [CSSearchableItem] = []
        items += await memberItems()
        items += await committeeItems()
        items += await eventItems()
        items += await workItemItems()
        items += await festDinnerItems()
        items += await festScheduleItems()
        items += await postItems()
        items += await helpItems()
        items += await stayItems()
        items += await committeeMessageItems()
        items += await houseMessageItems()
        items += localPlaceItems()
        items += await announcementItems()

        // Stamp the run even if empty, so a genuinely-empty account doesn't re-query every launch.
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastIndexedKey)
        guard !items.isEmpty else { return }
        CSSearchableIndex.default().indexSearchableItems(items) { error in
            if let error { print("[ContentIndexer] index error: \(error)") }
            else { print("[ContentIndexer] indexed \(items.count) items") }
        }
    }

    /// Remove all indexed MLR content (call on sign-out).
    static func clear() {
        CSSearchableIndex.default().deleteAllSearchableItems { _ in }
        UserDefaults.standard.removeObject(forKey: lastIndexedKey)
        SharedStore.shared.nextVisit = nil
        SharedStore.shared.reloadWidgets()
    }

    /// Publish the App-Group widget snapshots (currently the next house-calendar
    /// visit for the "Next Visit Up North" widget). NOT gated by the Spotlight
    /// opt-out — widgets are a separate surface.
    static func publishWidgetSnapshots() async {
        // Cache the member's first name for personalized Siri responses.
        if let uid = try? await supabase.auth.session.user.id {
            struct P: Decodable { let displayName: String?
                enum CodingKeys: String, CodingKey { case displayName = "display_name" } }
            let rows: [P] = (try? await supabase
                .from("profiles").select("display_name").eq("id", value: uid.uuidString).limit(1)
                .execute().value) ?? []
            if let name = rows.first?.displayName, !name.isEmpty {
                SharedStore.shared.memberFirstName = name.split(separator: " ").first.map(String.init)
            }
        }

        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd"
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.timeZone = TimeZone(identifier: "America/Chicago")
        let today = iso.string(from: Date())

        struct Row: Decodable {
            let startDate: String
            let endDate: String
            let title: String?
            let profiles: A?
            let houses: H?
            struct A: Decodable { let displayName: String?
                enum CodingKeys: String, CodingKey { case displayName = "display_name" } }
            struct H: Decodable { let name: String? }
            enum CodingKeys: String, CodingKey {
                case startDate = "start_date"
                case endDate = "end_date"
                case title, profiles, houses
            }
        }
        let rows: [Row] = (try? await supabase
            .from("house_stays")
            .select("start_date, end_date, title, profiles!created_by(display_name), houses(name)")
            .gte("end_date", value: today)
            .order("start_date", ascending: true)
            .limit(1)
            .execute().value) ?? []

        guard let n = rows.first else {
            SharedStore.shared.nextVisit = nil
            SharedStore.shared.reloadWidgets()
            return
        }
        let out = DateFormatter()
        out.dateFormat = "MMM d"
        out.locale = Locale(identifier: "en_US_POSIX")
        out.timeZone = TimeZone(identifier: "America/Chicago")
        let label: String = {
            guard let s = iso.date(from: n.startDate) else { return n.startDate }
            let a = out.string(from: s)
            if n.endDate == n.startDate { return a }
            if let e = iso.date(from: n.endDate) { return "\(a) – \(out.string(from: e))" }
            return a
        }()
        let who = n.profiles?.displayName
            ?? n.title?.trimmingCharacters(in: .whitespaces)
            ?? "Someone"
        SharedStore.shared.nextVisit = VisitSnapshot(who: who, dateLabel: label, house: n.houses?.name)
        SharedStore.shared.reloadWidgets()
    }

    // MARK: - Item builder

    private static func item(
        id: String,
        title: String,
        description: String?,
        keywords: [String],
        contentType: UTType = .text
    ) -> CSSearchableItem {
        let a = CSSearchableItemAttributeSet(contentType: contentType)
        a.title = title
        a.contentDescription = description
        a.keywords = baseKeywords + keywords.filter { !$0.isEmpty }
        return CSSearchableItem(uniqueIdentifier: id, domainIdentifier: domain, attributeSet: a)
    }

    private static func nameTokens(_ full: String) -> [String] {
        [full] + full.split(separator: " ").map(String.init)
    }

    // MARK: - Sources (reuse the App Entity queries where they exist)

    private static func memberItems() async -> [CSSearchableItem] {
        let members = (try? await MemberEntityQuery.all()) ?? []
        return members.map { m in
            var keywords = nameTokens(m.name) + ["member", "people", "directory", "family member"]
            var desc = "MLR family member"
            if let raw = m.birthday, !raw.isEmpty {
                let pretty = BirthdayIntent.friendly(raw) ?? raw
                keywords += ["birthday", "born", pretty]
                desc = "Birthday: \(pretty)"
            }
            let it = item(id: "mlr://people?id=\(m.id.uuidString)", title: m.name,
                          description: desc, keywords: keywords, contentType: .contact)
            return it
        }
    }

    private static func committeeItems() async -> [CSSearchableItem] {
        let committees = (try? await CommitteeEntityQuery.all()) ?? []
        return committees.map { c in
            let it = item(id: "mlr://committees?slug=\(c.id)", title: "\(c.emoji) \(c.name)",
                          description: "Committee", keywords: [c.name, "committee", "volunteer", "group"])
            return it
        }
    }

    private static func eventItems() async -> [CSSearchableItem] {
        let events = await EventEntityQuery.upcoming()
        return events.map { e in
            let it = item(id: "mlr://events?id=\(e.id)", title: e.title,
                          description: e.subtitle, keywords: [e.title, "event", "calendar", "gathering", e.subtitle])
            return it
        }
    }

    private static func workItemItems() async -> [CSSearchableItem] {
        let items0 = (try? await WorkItemEntityQuery.open()) ?? []
        return items0.map { w in
            let it = item(id: "mlr://work?id=\(w.id.uuidString)", title: w.title,
                          description: "Work checklist · \(w.subtitle)",
                          keywords: [w.title, "work", "task", "to do", "checklist", "project", "fix"])
            return it
        }
    }

    private static func festDinnerItems() async -> [CSSearchableItem] {
        let dinners = await FestDinnerEntityQuery.all()
        return dinners.map { d in
            let it = item(id: "mlr://family-fest?dinner=\(d.id)", title: d.title,
                          description: d.subtitle,
                          keywords: [d.title, "dinner", "meal", "chef", "cooking", "food", "family fest"])
            return it
        }
    }

    private static func festScheduleItems() async -> [CSSearchableItem] {
        let sched = await FestScheduleEntityQuery.all()
        return sched.map { s in
            let it = item(id: "mlr://family-fest?item=\(s.id)", title: s.title,
                          description: s.subtitle,
                          keywords: [s.title, "schedule", "plan", "activity", "family fest", "event"])
            return it
        }
    }

    // MARK: - Direct-query sources

    private static func postItems() async -> [CSSearchableItem] {
        struct Row: Decodable {
            let id: UUID
            let text: String?
            let profiles: A?
            struct A: Decodable { let displayName: String?
                enum CodingKeys: String, CodingKey { case displayName = "display_name" } }
        }
        let rows: [Row] = (try? await supabase
            .from("posts")
            .select("id, text, profiles!author_id(display_name)")
            .eq("status", value: "visible")
            .order("created_at", ascending: false)
            .limit(200)
            .execute().value) ?? []
        return rows.compactMap { r in
            let author = r.profiles?.displayName ?? "Someone"
            let text = (r.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = text.isEmpty ? "\(author)'s post" : "\(author): \(text.prefix(60))"
            return item(id: "mlr://posts?id=\(r.id.uuidString)", title: String(title),
                        description: text.isEmpty ? "Feed post" : text,
                        keywords: nameTokens(author) + ["post", "feed", "update"])
        }
    }

    private static func helpItems() async -> [CSSearchableItem] {
        struct Row: Decodable {
            let id: UUID
            let description: String?
            let category: String?
            let profiles: A?
            struct A: Decodable { let displayName: String?
                enum CodingKeys: String, CodingKey { case displayName = "display_name" } }
        }
        let rows: [Row] = (try? await supabase
            .from("help_requests")
            .select("id, description, category, profiles!user_id(display_name)")
            .eq("status", value: "open")
            .order("created_at", ascending: false)
            .limit(50)
            .execute().value) ?? []
        return rows.compactMap { r in
            let what = (r.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !what.isEmpty else { return nil }
            let who = r.profiles?.displayName ?? "Someone"
            return item(id: "mlr://help?id=\(r.id.uuidString)", title: "Help needed: \(what.prefix(50))",
                        description: "\(who) needs a hand: \(what)",
                        keywords: [r.category ?? "", "help", "lend a hand", "volunteer"] + nameTokens(who))
        }
    }

    private static func stayItems() async -> [CSSearchableItem] {
        struct Row: Decodable {
            let id: UUID
            let startDate: String
            let endDate: String
            let title: String?
            let profiles: A?
            let houses: H?
            struct A: Decodable { let displayName: String?
                enum CodingKeys: String, CodingKey { case displayName = "display_name" } }
            struct H: Decodable { let name: String? }
            enum CodingKeys: String, CodingKey {
                case id, title, profiles, houses
                case startDate = "start_date"
                case endDate = "end_date"
            }
        }
        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd"
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.timeZone = TimeZone(identifier: "America/Chicago")
        let today = iso.string(from: Date())
        let rows: [Row] = (try? await supabase
            .from("house_stays")
            .select("id, start_date, end_date, title, profiles!created_by(display_name), houses(name)")
            .gte("end_date", value: today)
            .order("start_date", ascending: true)
            .limit(100)
            .execute().value) ?? []
        return rows.map { r in
            let who = r.profiles?.displayName ?? "Someone"
            let house = r.houses?.name ?? "a house"
            return item(id: "mlr://houses?stay=\(r.id.uuidString)",
                        title: "\(who) up north · \(r.startDate)",
                        description: "\(who) at \(house): \(r.startDate) to \(r.endDate)",
                        keywords: nameTokens(who) + [house, "visit", "stay", "house calendar", "going up", "up north"])
        }
    }

    private static func committeeMessageItems() async -> [CSSearchableItem] {
        struct Row: Decodable {
            let id: UUID
            let text: String?
            let profiles: A?
            let committees: C?
            struct A: Decodable { let displayName: String?
                enum CodingKeys: String, CodingKey { case displayName = "display_name" } }
            struct C: Decodable { let name: String? }
        }
        let rows: [Row] = (try? await supabase
            .from("committee_messages")
            .select("id, text, profiles!author_id(display_name), committees(name)")
            .is("deleted_at", value: nil)
            .order("created_at", ascending: false)
            .limit(500)
            .execute().value) ?? []
        return rows.compactMap { r in
            let text = (r.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let who = r.profiles?.displayName ?? "Someone"
            let committee = r.committees?.name ?? "a committee"
            return item(id: "mlr://committees?message=\(r.id.uuidString)",
                        title: "\(who) in \(committee)",
                        description: text,
                        keywords: nameTokens(who) + [committee, "committee", "chat", "message", "said"])
        }
    }

    private static func houseMessageItems() async -> [CSSearchableItem] {
        struct Row: Decodable {
            let id: UUID
            let text: String?
            let profiles: A?
            let houses: H?
            struct A: Decodable { let displayName: String?
                enum CodingKeys: String, CodingKey { case displayName = "display_name" } }
            struct H: Decodable { let name: String? }
        }
        let rows: [Row] = (try? await supabase
            .from("house_messages")
            .select("id, text, profiles!author_id(display_name), houses(name)")
            .is("deleted_at", value: nil)
            .order("created_at", ascending: false)
            .limit(500)
            .execute().value) ?? []
        return rows.compactMap { r in
            let text = (r.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let who = r.profiles?.displayName ?? "Someone"
            let house = r.houses?.name ?? "a house"
            return item(id: "mlr://houses?message=\(r.id.uuidString)",
                        title: "\(who) in \(house) chat",
                        description: text,
                        keywords: nameTokens(who) + [house, "house", "chat", "message", "said"])
        }
    }

    private static func localPlaceItems() -> [CSSearchableItem] {
        LocalPlace.all.map { p in
            var keywords = [p.name, p.category.rawValue, "restaurant", "dining", "nearby", "local"]
            if p.orderUrl != nil { keywords.append("order") }
            if p.menuUrl != nil { keywords.append("menu") }
            let desc = [p.description, p.phone].compactMap { $0 }.joined(separator: " · ")
            return item(id: "mlr://places?id=\(p.id)", title: p.name,
                        description: desc.isEmpty ? p.category.rawValue.capitalized : desc,
                        keywords: keywords)
        }
    }

    private static func announcementItems() async -> [CSSearchableItem] {
        struct Row: Decodable { let id: String; let title: String; let body: String? }
        let nowISO = ISO8601DateFormatter().string(from: Date())
        let rows: [Row] = (try? await supabase
            .from("announcements")
            .select("id, title, body")
            .or("expires_at.is.null,expires_at.gte.\(nowISO)")
            .order("created_at", ascending: false)
            .limit(30)
            .execute().value) ?? []
        return rows.map { r in
            item(id: "mlr://home?announcement=\(r.id)", title: r.title,
                 description: r.body ?? "Announcement",
                 keywords: [r.title, "announcement", "notice", "news"])
        }
    }
}
