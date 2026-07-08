import AppIntents
import Foundation

// MARK: - Cabin entity + request intent (Siri / Apple Intelligence)
//
// Resolve a cabin by name and request a stay by voice. The request goes through
// request_cabin_stay (RLS-gated to signed-in members) and lands as a pending
// booking for an admin to approve — same as the in-app flow.

struct CabinEntity: AppEntity {
    let id: UUID
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Cabin" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static var defaultQuery = CabinEntityQuery()
}

struct CabinEntityQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [CabinEntity] {
        try await Self.all().filter { identifiers.contains($0.id) }
    }
    func entities(matching string: String) async throws -> [CabinEntity] {
        try await Self.all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
    func suggestedEntities() async throws -> [CabinEntity] { try await Self.all() }

    static func all() async throws -> [CabinEntity] {
        struct Row: Decodable { let id: UUID; let name: String }
        let rows: [Row] = try await supabase
            .from("cabins")
            .select("id, name")
            .eq("active", value: true)
            .order("sort_order", ascending: true)
            .execute().value
        return rows.map { CabinEntity(id: $0.id, name: $0.name) }
    }
}

// MARK: - Request a cabin stay

struct RequestCabinIntent: AppIntent {
    static var title: LocalizedStringResource = "Request a Cabin"
    static var description = IntentDescription("Request a stay in a resort cabin.")

    @Parameter(title: "Cabin")
    var cabin: CabinEntity

    @Parameter(title: "Check-in")
    var checkIn: Date

    @Parameter(title: "Check-out")
    var checkOut: Date

    @Parameter(title: "Guests", default: 1)
    var guests: Int

    @Parameter(title: "Note")
    var note: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Request \(\.$cabin) from \(\.$checkIn) to \(\.$checkOut)") {
            \.$guests
            \.$note
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard (try? await supabase.auth.session) != nil else {
            throw CabinIntentError.notSignedIn
        }
        let inISO = Self.iso(checkIn)
        let outISO = Self.iso(checkOut)
        try await CabinService().requestStay(
            cabinId: cabin.id,
            checkIn: inISO,
            checkOut: outISO,
            guests: max(1, guests),
            note: note?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let human = DateFormatter()
        human.dateFormat = "MMM d"
        human.timeZone = TimeZone(identifier: "America/Chicago")
        return .result(dialog: IntentDialog(stringLiteral:
            "Requested \(cabin.name) from \(human.string(from: checkIn)) to \(human.string(from: checkOut)). You'll hear back once it's approved."))
    }

    private static func iso(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/Chicago")
        return f.string(from: date)
    }
}

enum CabinIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notSignedIn
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSignedIn: return "Open MLR and sign in first, then request a cabin."
        }
    }
}
