import AppIntents
import Foundation

// MARK: - Local place intents (Siri / Apple Intelligence)
//
// The nearby spots families use around the resort (dining, golf, marina, etc.).
// These live as in-code seed data (LocalPlace.all), so the entity query is
// synchronous. Powers "what restaurants are near the resort," "call Billy Bob's,"
// and "order from the Tilted Loon."

struct PlaceEntity: AppEntity {
    let id: String
    let name: String
    let category: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Local Place" }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(category)")
    }
    static var defaultQuery = PlaceEntityQuery()

    fileprivate static func from(_ p: LocalPlace) -> PlaceEntity {
        PlaceEntity(id: p.id, name: p.name, category: p.category.rawValue.capitalized)
    }
}

struct PlaceEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [PlaceEntity] {
        LocalPlace.all.filter { identifiers.contains($0.id) }.map(PlaceEntity.from)
    }
    func entities(matching string: String) async throws -> [PlaceEntity] {
        LocalPlace.all
            .filter { $0.name.localizedCaseInsensitiveContains(string) }
            .map(PlaceEntity.from)
    }
    func suggestedEntities() async throws -> [PlaceEntity] {
        LocalPlace.all.map(PlaceEntity.from)
    }
}

// MARK: - List places

struct LocalPlacesIntent: AppIntent {
    static var title: LocalizedStringResource = "Places Near the Resort"
    static var description = IntentDescription("Restaurants and spots near Muskellunge Lake Resort.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let dining = LocalPlace.all.filter { $0.category == .dining }
        let places = dining.isEmpty ? LocalPlace.all : dining
        guard !places.isEmpty else { return .result(dialog: "I don't have any local places listed.") }
        let names = places.prefix(6).map(\.name).joined(separator: ", ")
        return .result(dialog: IntentDialog(stringLiteral: "Near the resort: \(names)."))
    }
}

// MARK: - Call a place

struct CallLocalPlaceIntent: AppIntent {
    static var title: LocalizedStringResource = "Call a Local Place"
    static var description = IntentDescription("Call a nearby restaurant or spot.")

    @Parameter(title: "Place")
    var place: PlaceEntity

    static var parameterSummary: some ParameterSummary { Summary("Call \(\.$place)") }

    func perform() async throws -> some IntentResult & OpensIntent & ProvidesDialog {
        guard let match = LocalPlace.all.first(where: { $0.id == place.id }),
              let phone = match.phone?.filter({ $0.isNumber || $0 == "+" }),
              !phone.isEmpty,
              let url = URL(string: "tel:\(phone)") else {
            throw PlaceError.noPhone(place.name)
        }
        return .result(opensIntent: OpenURLIntent(url),
                       dialog: IntentDialog(stringLiteral: "Calling \(place.name)."))
    }
}

// MARK: - Order from a place

struct OrderFromLocalPlaceIntent: AppIntent {
    static var title: LocalizedStringResource = "Order From a Place"
    static var description = IntentDescription("Open online ordering (or the menu) for a nearby spot.")

    @Parameter(title: "Place")
    var place: PlaceEntity

    static var parameterSummary: some ParameterSummary { Summary("Order from \(\.$place)") }

    func perform() async throws -> some IntentResult & OpensIntent & ProvidesDialog {
        guard let match = LocalPlace.all.first(where: { $0.id == place.id }) else {
            throw PlaceError.noOrder(place.name)
        }
        let link = match.orderUrl ?? match.menuUrl
        guard let raw = link, let url = URL(string: raw) else {
            throw PlaceError.noOrder(place.name)
        }
        let verb = match.orderUrl != nil ? "Opening ordering for" : "Opening the menu for"
        return .result(opensIntent: OpenURLIntent(url),
                       dialog: IntentDialog(stringLiteral: "\(verb) \(place.name)."))
    }
}

enum PlaceError: Error, CustomLocalizedStringResourceConvertible {
    case noPhone(String)
    case noOrder(String)
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noPhone(let n): return "I don't have a phone number for \(n)."
        case .noOrder(let n): return "\(n) doesn't have online ordering or a menu link."
        }
    }
}
