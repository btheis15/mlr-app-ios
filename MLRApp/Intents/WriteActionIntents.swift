import AppIntents
import Foundation

// MARK: - Write-action intents (Siri / Apple Intelligence)
//
// Actions that change data — RSVP to an event, post to a committee chat. They run
// as the signed-in member (the RPCs gate on auth.uid()); signed-out throws a
// friendly nudge. Siri shows the parameter summary before running so the person
// confirms what they're doing.

enum RSVPResponse: String, AppEnum {
    case going, maybe, notGoing

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "RSVP" }
    static var caseDisplayRepresentations: [RSVPResponse: DisplayRepresentation] {
        [.going: "Going", .maybe: "Maybe", .notGoing: "Not going"]
    }

    var model: AttendanceStatus {
        switch self {
        case .going:    return .going
        case .maybe:    return .maybe
        case .notGoing: return .notGoing
        }
    }
    var spoken: String {
        switch self {
        case .going:    return "down for"
        case .maybe:    return "a maybe for"
        case .notGoing: return "not going to"
        }
    }
}

// MARK: - RSVP

struct RSVPIntent: AppIntent {
    static var title: LocalizedStringResource = "RSVP to an Event"
    static var description = IntentDescription("RSVP to a resort event.")

    @Parameter(title: "Event")
    var event: EventEntity

    @Parameter(title: "Response", default: .going)
    var response: RSVPResponse

    static var parameterSummary: some ParameterSummary {
        Summary("RSVP \(\.$response) to \(\.$event)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard (try? await supabase.auth.session) != nil else {
            throw ActionError.notSignedIn
        }
        try await EventsService().upsertAttendance(eventId: event.id, status: response.model)
        return .result(dialog: IntentDialog(stringLiteral: "Got it — you're \(response.spoken) \(event.title)."))
    }
}

// MARK: - Message a committee

struct SendCommitteeMessageIntent: AppIntent {
    static var title: LocalizedStringResource = "Message a Committee"
    static var description = IntentDescription("Post a message to a committee's chat.")

    @Parameter(title: "Committee")
    var committee: CommitteeEntity

    @Parameter(title: "Message", requestValueDialog: "What do you want to say?")
    var message: String

    static var parameterSummary: some ParameterSummary {
        Summary("Send “\(\.$message)” to the \(\.$committee) committee")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let uid = try? await supabase.auth.session.user.id else {
            throw ActionError.notSignedIn
        }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .result(dialog: "What would you like to say?") }

        // CommitteeEntity.id is the slug; the chat API needs the committee's UUID.
        struct IdRow: Decodable { let id: UUID }
        let rows: [IdRow] = (try? await supabase
            .from("committees")
            .select("id")
            .eq("slug", value: committee.id)
            .limit(1)
            .execute().value) ?? []
        guard let committeeId = rows.first?.id else {
            return .result(dialog: "I couldn't find the \(committee.name) committee.")
        }

        _ = try await CommitteeService().sendMessage(
            committeeId: committeeId,
            area: nil,               // General channel
            text: text,
            authorId: uid
        )
        return .result(dialog: IntentDialog(stringLiteral: "Sent to the \(committee.name) committee."))
    }
}

// MARK: - Errors

enum ActionError: Error, CustomLocalizedStringResourceConvertible {
    case notSignedIn
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSignedIn: return "Open MLR and sign in first, then try again."
        }
    }
}
