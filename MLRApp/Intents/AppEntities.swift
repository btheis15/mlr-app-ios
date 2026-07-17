import AppIntents

// MARK: - App Entities (Siri / Shortcuts / Spotlight)
//
// Lightweight entity mirrors of the app's core content so Siri, the Shortcuts
// app, and intent parameters can refer to real work items, events, committees,
// and houses. Queries read via the app's Supabase session (intents run in the
// app's process). Spotlight discoverability comes from the hand-built
// CSSearchableItems in ContentIndexer (IndexedEntity/associateAppEntity was
// dropped — its default witnesses require iOS 26 and crashed on older OSes).

// MARK: Work item

struct WorkItemEntity: AppEntity {
    let id: UUID
    let title: String
    let subtitle: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Work Item" }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }
    static var defaultQuery = WorkItemEntityQuery()
}

struct WorkItemEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [WorkItemEntity] {
        try await Self.open().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [WorkItemEntity] {
        try await Self.open()
    }
    static func open() async throws -> [WorkItemEntity] {
        let rows: [WorkItem] = try await supabase
            .from("work_items")
            .select("*")
            .eq("status", value: "open")
            .order("created_at", ascending: false)
            .execute()
            .value
        return rows.map {
            WorkItemEntity(id: $0.id, title: $0.title, subtitle: $0.urgency?.label ?? "Open")
        }
    }
}

// MARK: Event

struct EventEntity: AppEntity {
    let id: String
    let title: String
    let subtitle: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Event" }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }
    static var defaultQuery = EventEntityQuery()
}

struct EventEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [EventEntity] {
        await Self.upcoming().filter { identifiers.contains($0.id) }
    }
    // Resolve an event by spoken name — "the 4th of July", "Family Fest".
    func entities(matching string: String) async throws -> [EventEntity] {
        await Self.upcoming().filter { $0.title.localizedCaseInsensitiveContains(string) }
    }
    func suggestedEntities() async throws -> [EventEntity] {
        await Self.upcoming()
    }
    @MainActor
    static func upcoming() async -> [EventEntity] {
        let svc = EventsService()
        await svc.fetchEvents()
        return svc.upcomingEvents.map { ev in
            let when = ev.startDateParsed.map { $0.formatted(.dateTime.month(.abbreviated).day()) } ?? ""
            return EventEntity(id: ev.id, title: ev.title, subtitle: when)
        }
    }
}

// MARK: Committee

struct CommitteeEntity: AppEntity {
    let id: String       // committee slug
    let name: String
    let emoji: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Committee" }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(emoji) \(name)")
    }
    static var defaultQuery = CommitteeEntityQuery()
}

struct CommitteeEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [CommitteeEntity] {
        try await Self.all().filter { identifiers.contains($0.id) }
    }
    // Resolve a committee by spoken name — "games" → "Entertainment & Games",
    // "meals" → "Meals", "family fest" → the Family Fest committee.
    func entities(matching string: String) async throws -> [CommitteeEntity] {
        let q = string.trimmingCharacters(in: .whitespaces)
        return try await Self.all().filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.id.localizedCaseInsensitiveContains(q)
        }
    }
    func suggestedEntities() async throws -> [CommitteeEntity] {
        try await Self.all()
    }
    static func all() async throws -> [CommitteeEntity] {
        let rows: [Committee] = try await supabase
            .from("committees")
            .select("*")
            .order("name", ascending: true)
            .execute()
            .value
        return rows.map { CommitteeEntity(id: $0.slug, name: $0.name, emoji: $0.emoji ?? "💬") }
    }
}

// MARK: House

struct HouseEntity: AppEntity {
    let id: String       // house slug
    let name: String
    let emoji: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "House" }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(emoji) \(name)")
    }
    static var defaultQuery = HouseEntityQuery()
}

struct HouseEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [HouseEntity] {
        try await Self.all().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [HouseEntity] {
        try await Self.all()
    }
    static func all() async throws -> [HouseEntity] {
        let rows: [House] = try await supabase
            .from("houses")
            .select("*")
            .order("position", ascending: true)
            .execute()
            .value
        return rows.map { HouseEntity(id: $0.slug, name: $0.name, emoji: $0.emoji) }
    }
}
