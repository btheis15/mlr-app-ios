import AppIntents
import Foundation

// MARK: - Global search — `.system.searchInApp` assistant schema (Siri / Apple Intelligence)
//
// Conforms to Apple's system in-app-search schema so free-form Siri / Apple
// Intelligence queries route here WITHOUT a shortcut ("search MLR for the dock",
// and vaguer phrasings on iOS 27's AI Siri). The schema *navigates to search
// results*, so this opens the app to `GlobalSearchView` (via `IntentRouter`)
// rather than speaking a summary. The aggregate query itself lives in
// `ResortSearch`, shared with that screen. All reads are RLS-scoped to the
// signed-in user.

// `.system.searchInApp` is iOS 27+. The deployment target stays at iOS 26 so the
// family's 26 devices don't crash — iOS 26 users still get the manual Home search
// screen + Spotlight; only this schema-Siri entry is gated to 27.
@available(iOS 27.0, *)
@AppIntent(schema: .system.searchInApp)
struct SearchUpNorthIntent: ShowInAppSearchResultsIntent {
    static var title: LocalizedStringResource = "Search Up North"
    static var searchScopes: [StringSearchScope] = [.general]

    @Dependency private var router: IntentRouter

    var criteria: StringSearchCriteria

    func perform() async throws -> some IntentResult {
        let term = criteria.term.trimmingCharacters(in: .whitespacesAndNewlines)
        await router.requestRoute(.search(term: term))
        return .result()
    }
}

// MARK: - Aggregate resort search (shared by GlobalSearchView)
//
// One catch-all pass across the resort's content — people, committees, events,
// the work list, Family Fest, and chats — returning grouped, tappable hits. Each
// hit carries an `mlr://` URL the app already knows how to route (see
// `IntentRouter.Route(url:)`). Reused by both the `.system.search` destination
// screen and the manual Home search entry.

struct ResortSearchHit: Identifiable, Hashable {
    let id: String
    let symbol: String
    let title: String
    let subtitle: String
    let url: URL
}

struct ResortSearchGroup: Identifiable {
    var id: String { title }
    let title: String
    let hits: [ResortSearchHit]
}

enum ResortSearch {
    /// Search everything the signed-in user can see; empty query → no groups.
    /// Never throws — a failing source just contributes nothing.
    static func run(term: String) async -> [ResortSearchGroup] {
        let q = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        var groups: [ResortSearchGroup] = []

        // People
        if let members = try? await MemberEntityQuery().entities(matching: q), !members.isEmpty {
            let hits = members.prefix(12).map { m in
                ResortSearchHit(
                    id: "person-\(m.id.uuidString)",
                    symbol: "person.crop.circle",
                    title: m.name,
                    subtitle: "Person",
                    url: URL(string: "mlr://people?id=\(m.id.uuidString)")!
                )
            }
            groups.append(ResortSearchGroup(title: "People", hits: Array(hits)))
        }

        // Committees
        if let committees = try? await CommitteeEntityQuery().entities(matching: q), !committees.isEmpty {
            let hits = committees.prefix(12).compactMap { c -> ResortSearchHit? in
                guard let url = URL(string: "mlr://committees?slug=\(c.id)") else { return nil }
                return ResortSearchHit(
                    id: "committee-\(c.id)",
                    symbol: "person.3",
                    title: "\(c.emoji) \(c.name)",
                    subtitle: "Committee",
                    url: url
                )
            }
            groups.append(ResortSearchGroup(title: "Committees", hits: hits))
        }

        // Events
        let events = await EventEntityQuery.upcoming()
            .filter { $0.title.localizedCaseInsensitiveContains(q) }
        if !events.isEmpty {
            let hits = events.prefix(12).map { e in
                ResortSearchHit(
                    id: "event-\(e.id)",
                    symbol: "calendar",
                    title: e.title,
                    subtitle: e.subtitle.isEmpty ? "Event" : e.subtitle,
                    url: URL(string: "mlr://events")!
                )
            }
            groups.append(ResortSearchGroup(title: "Events", hits: Array(hits)))
        }

        // Work list
        if let work = try? await WorkItemEntityQuery.open() {
            let hits = work.filter { $0.title.localizedCaseInsensitiveContains(q) }
                .prefix(12)
                .map { w in
                    ResortSearchHit(
                        id: "work-\(w.id.uuidString)",
                        symbol: "checklist",
                        title: w.title,
                        subtitle: w.subtitle,
                        url: URL(string: "mlr://work?id=\(w.id.uuidString)")!
                    )
                }
            if !hits.isEmpty { groups.append(ResortSearchGroup(title: "Work List", hits: Array(hits))) }
        }

        // Family Fest — dinners + schedule
        let festURL = URL(string: "mlr://family-fest")!
        var festHits: [ResortSearchHit] = []
        let dinners = await FestDinnerEntityQuery.all().filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.subtitle.localizedCaseInsensitiveContains(q)
        }
        festHits += dinners.prefix(8).map { d in
            ResortSearchHit(id: "dinner-\(d.id)", symbol: "fork.knife", title: d.title, subtitle: d.subtitle, url: festURL)
        }
        let schedule = await FestScheduleEntityQuery.all().filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.subtitle.localizedCaseInsensitiveContains(q)
        }
        festHits += schedule.prefix(8).map { s in
            ResortSearchHit(id: "schedule-\(s.id)", symbol: "calendar.day.timeline.left", title: s.title, subtitle: s.subtitle, url: festURL)
        }
        if !festHits.isEmpty {
            groups.append(ResortSearchGroup(title: "Family Fest", hits: festHits))
        }

        // Chats
        let chat = await ChatSearch.run(topic: q, authorId: nil)
        if !chat.isEmpty {
            let hits = chat.prefix(12).enumerated().map { i, m in
                ResortSearchHit(
                    id: "chat-\(i)",
                    symbol: "text.bubble",
                    title: "\(m.author): \(m.text)",
                    subtitle: m.context,
                    url: URL(string: "mlr://posts")!
                )
            }
            groups.append(ResortSearchGroup(title: "Chats", hits: Array(hits)))
        }

        return groups
    }
}
