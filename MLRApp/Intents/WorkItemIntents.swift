import AppIntents

// MARK: - Work item App Intents (Siri / Shortcuts / Spotlight)
//
// AddWorkItemIntent posts a resort (MLR) work item headlessly — Siri/Shortcuts
// prompt for the fields natively, then it submits via create_work_item using the
// app's persisted Supabase session (the intent runs in the app's process). When
// signed out it raises a friendly error pointing at the app. OpenAddWorkItemIntent
// opens the app to the pre-filled composer (used by the "form" shortcut and the
// Home widget); the Control Center control uses its own opener in the widget target.

// MARK: - Urgency enum (Shortcuts picker)

enum WorkUrgencyAppEnum: String, AppEnum {
    case asap
    case thisYear
    case niceToHave

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Urgency" }
    static var caseDisplayRepresentations: [WorkUrgencyAppEnum: DisplayRepresentation] {
        [
            .asap:       "ASAP",
            .thisYear:   "This year",
            .niceToHave: "Nice to have",
        ]
    }

    var model: WorkUrgency {
        switch self {
        case .asap:       return .asap
        case .thisYear:   return .thisYear
        case .niceToHave: return .niceToHave
        }
    }
}

// MARK: - Add (headless)

struct AddWorkItemIntent: AppIntent {
    static var title: LocalizedStringResource = "Add a Work Item"
    static var description = IntentDescription("Add a task to the resort work checklist.")

    @Parameter(title: "Task", requestValueDialog: "What's the task?")
    var taskTitle: String

    @Parameter(title: "Details")
    var notes: String?

    @Parameter(title: "Urgency", default: .thisYear)
    var urgency: WorkUrgencyAppEnum?

    @Parameter(title: "People needed")
    var peopleNeeded: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$taskTitle) to the work checklist") {
            \.$urgency
            \.$peopleNeeded
            \.$notes
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Requires a signed-in session (the RPC gates on auth.uid()).
        guard (try? await supabase.auth.session) != nil else {
            throw AddWorkItemError.notSignedIn
        }
        let trimmed = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AddWorkItemError.emptyTitle }

        let people = (peopleNeeded ?? 0) > 0 ? peopleNeeded : nil
        let service = WorkItemsService()
        _ = try await service.createItem(
            title: trimmed,
            notes: notes?.trimmingCharacters(in: .whitespacesAndNewlines),
            category: nil,
            peopleNeeded: people,
            houseId: nil,             // MLR / resort-wide from Siri
            urgency: urgency?.model
        )
        return .result(dialog: "Added “\(trimmed)” to the work checklist.")
    }
}

enum AddWorkItemError: Error, CustomLocalizedStringResourceConvertible {
    case notSignedIn
    case emptyTitle

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSignedIn: return "Open MLR and sign in first, then try again."
        case .emptyTitle:  return "Please provide a task."
        }
    }
}

// MARK: - Open the composer (form fallback / widget)

struct OpenAddWorkItemIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Work Item (Form)"
    static var description = IntentDescription("Opens MLR to the add-work-item form.")
    static var openAppWhenRun = true

    @Dependency private var router: IntentRouter

    @MainActor
    func perform() async throws -> some IntentResult {
        router.requestRoute(.addWorkItem)
        return .result()
    }
}
