import AppIntents

// MARK: - Browse / action App Intents (Siri / Shortcuts)
//
// Read + navigation intents that open MLR's content to Siri, Spotlight, and the
// Shortcuts app. Read intents run headlessly and return entities + a spoken
// summary; "open" intents bring the app to the right screen via IntentRouter.

// MARK: Show work items

struct ShowWorkItemsIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Work Items"
    static var description = IntentDescription("See the open items on the resort work checklist.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[WorkItemEntity]> & ProvidesDialog {
        let items = try await WorkItemEntityQuery.open()
        let dialog: IntentDialog = items.isEmpty
            ? "The work checklist is all caught up. ✅"
            : "There \(items.count == 1 ? "is" : "are") \(items.count) open work item\(items.count == 1 ? "" : "s")."
        return .result(value: items, dialog: dialog)
    }
}

// MARK: Show upcoming events

struct ShowUpcomingEventsIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Upcoming Events"
    static var description = IntentDescription("See what's coming up at the resort.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[EventEntity]> & ProvidesDialog {
        let events = await EventEntityQuery.upcoming()
        let dialog: IntentDialog = {
            guard let next = events.first else { return "Nothing on the calendar right now." }
            return "Next up: \(next.title) on \(next.subtitle)."
        }()
        return .result(value: events, dialog: dialog)
    }
}

// MARK: Who's going

struct WhosGoingIntent: AppIntent {
    static var title: LocalizedStringResource = "Who's Going"
    static var description = IntentDescription("See who's going to an event.")

    @Parameter(title: "Event")
    var event: EventEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Who's going to \(\.$event)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let people = (try? await EventsService().fetchWhoIsGoing(eventId: event.id)) ?? []
        let names = people.map(\.name).filter { !$0.isEmpty }
        let dialog: IntentDialog
        if names.isEmpty {
            dialog = "No one has RSVP'd to \(event.title) yet."
        } else if names.count <= 6 {
            dialog = "Going to \(event.title): \(names.joined(separator: ", "))."
        } else {
            dialog = "\(names.count) people are going to \(event.title), including \(names.prefix(5).joined(separator: ", "))."
        }
        return .result(dialog: dialog)
    }
}

// MARK: Open a committee chat

struct OpenCommitteeChatIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Committee Chat"
    static var description = IntentDescription("Open a committee's chat in MLR.")
    static var openAppWhenRun = true

    @Parameter(title: "Committee")
    var committee: CommitteeEntity

    @Dependency private var router: IntentRouter

    static var parameterSummary: some ParameterSummary {
        Summary("Open the \(\.$committee) chat")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        router.requestRoute(.committeeChat(slug: committee.id))
        return .result()
    }
}

// MARK: Open the house chat

struct OpenHouseChatIntent: AppIntent {
    static var title: LocalizedStringResource = "Open House Chat"
    static var description = IntentDescription("Open your house's chat in MLR.")
    static var openAppWhenRun = true

    @Dependency private var router: IntentRouter

    @MainActor
    func perform() async throws -> some IntentResult {
        router.requestRoute(.houseChat)
        return .result()
    }
}
