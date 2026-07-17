import AppIntents
import Foundation

// MARK: - Fest + Member App Entities (Siri / Apple Intelligence / Spotlight)
//
// Entity mirrors for Family Fest dinners + schedule and for family members, so
// Apple Intelligence can resolve references like "the Monday dinner" or a person
// by name ("Jessica") and intents can answer questions about them.
// (IndexedEntity was dropped — its default witnesses require iOS 26.)

// MARK: Family Fest dinner

struct FestDinnerEntity: AppEntity {
    let id: String
    let title: String
    let subtitle: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Family Fest Dinner" }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }
    static var defaultQuery = FestDinnerEntityQuery()
}

struct FestDinnerEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [FestDinnerEntity] {
        await Self.all().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [FestDinnerEntity] { await Self.all() }

    @MainActor
    static func all() async -> [FestDinnerEntity] {
        let svc = FestContentService()
        await svc.load()
        return svc.dinners.map {
            FestDinnerEntity(
                id: $0.id,
                title: "\($0.day): \($0.title)",
                subtitle: $0.chef == "TBD" ? "Chef TBD" : "Chef: \($0.chef)"
            )
        }
    }
}

// MARK: Family Fest schedule item

struct FestScheduleEntity: AppEntity {
    let id: String
    let title: String
    let subtitle: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Family Fest Schedule Item" }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }
    static var defaultQuery = FestScheduleEntityQuery()
}

struct FestScheduleEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [FestScheduleEntity] {
        await Self.all().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [FestScheduleEntity] { await Self.all() }

    @MainActor
    static func all() async -> [FestScheduleEntity] {
        let svc = FestContentService()
        await svc.load()
        return svc.schedule.filter { !$0.isPrivate }.map {
            FestScheduleEntity(
                id: $0.id,
                title: "\($0.day): \($0.title)",
                subtitle: [$0.time, $0.location].compactMap { $0 }.joined(separator: " · ")
            )
        }
    }
}

// MARK: Member (resolvable by name for "when is Jessica's birthday")

struct MemberEntity: AppEntity {
    let id: UUID
    let name: String
    let birthday: String?

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Family Member" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static var defaultQuery = MemberEntityQuery()
}

/// EntityStringQuery lets Siri / Apple Intelligence resolve a member by spoken
/// name ("Jessica") — not just by identifier.
struct MemberEntityQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [MemberEntity] {
        try await Self.all().filter { identifiers.contains($0.id) }
    }
    func entities(matching string: String) async throws -> [MemberEntity] {
        try await Self.all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
    func suggestedEntities() async throws -> [MemberEntity] { try await Self.all() }

    static func all() async throws -> [MemberEntity] {
        let rows: [Profile] = try await supabase
            .from("profiles")
            .select("*")
            .order("display_name", ascending: true)
            .execute()
            .value
        // Never surface the hidden App Review account.
        return rows
            .filter { !ReviewAccess.isReviewEmail($0.email) }
            .map { MemberEntity(id: $0.id, name: $0.name, birthday: $0.birthday) }
    }
}
