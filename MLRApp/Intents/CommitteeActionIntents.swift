import AppIntents
import Foundation

// MARK: - Committee action intents (Siri / Apple Intelligence)
//
// Committee-aware actions driven off the roster (migration 0055): every person
// listed on a committee, with their roles and email. Powers:
//   • "Email the Family Fest committee" / "Email the Meals committee"
//   • "Email the people responsible for the games" (games → Entertainment & Games)
//   • "Who's responsible for the games for Family Fest?"
// The committee is resolved by fuzzy name via CommitteeEntityQuery (EntityStringQuery).

// MARK: - Email a whole committee

struct EmailCommitteeIntent: AppIntent {
    static var title: LocalizedStringResource = "Email a Committee"
    static var description = IntentDescription(
        "Start an email to everyone on a committee's roster."
    )

    @Parameter(title: "Committee")
    var committee: CommitteeEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Email the \(\.$committee) committee")
    }

    func perform() async throws -> some IntentResult & OpensIntent & ProvidesDialog {
        let roster = (try? await CommitteeService().fetchRoster(slug: committee.id)) ?? []
        let emails = roster
            .compactMap { $0.effectiveEmail?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let unique = Array(Set(emails)).sorted()

        guard !unique.isEmpty else {
            throw CommitteeActionError.noEmails(committee.name)
        }

        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = unique.joined(separator: ",")
        comps.queryItems = [URLQueryItem(name: "subject", value: "\(committee.name) — Muskellunge Lake Resort")]
        guard let url = comps.url else { throw CommitteeActionError.noEmails(committee.name) }

        return .result(
            opensIntent: OpenURLIntent(url),
            dialog: IntentDialog(stringLiteral: "Starting an email to the \(unique.count) people on the \(committee.name) committee.")
        )
    }
}

enum CommitteeActionError: Error, CustomLocalizedStringResourceConvertible {
    case noEmails(String)
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noEmails(let name): return "I couldn't find any email addresses on the \(name) committee roster."
        }
    }
}

// MARK: - Who's responsible for X

struct WhoIsResponsibleIntent: AppIntent {
    static var title: LocalizedStringResource = "Who's Responsible"
    static var description = IntentDescription(
        "See who's on a committee — who's responsible for something at the resort."
    )

    @Parameter(title: "Committee")
    var committee: CommitteeEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Who's responsible for \(\.$committee)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let roster = (try? await CommitteeService().fetchRoster(slug: committee.id)) ?? []
        let people = roster.filter { !$0.displayName.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !people.isEmpty else {
            return .result(dialog: "I don't see anyone listed on the \(committee.name) committee yet.")
        }
        // Leads first, then everyone else.
        let leads = people.filter(\.isLead).map(\.displayName)
        let others = people.filter { !$0.isLead }.map(\.displayName)
        let ordered = (leads + others)

        var sentence = "The \(committee.name) committee: \(ordered.prefix(8).joined(separator: ", "))"
        if ordered.count > 8 { sentence += ", and more" }
        sentence += "."
        if !leads.isEmpty {
            sentence += " Lead: \(leads.joined(separator: ", "))."
        }
        sentence += " You can open that committee's chat or say “email the \(committee.name) committee.”"
        return .result(dialog: IntentDialog(stringLiteral: sentence))
    }
}
