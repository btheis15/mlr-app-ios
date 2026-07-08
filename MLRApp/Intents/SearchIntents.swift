import AppIntents
import Foundation

// MARK: - Global "Search Up North" intent (Siri / Apple Intelligence)
//
// One catch-all search across the resort's content — people, committees, events,
// work items, and chats — that speaks a summary of what it found. Complements the
// Spotlight semantic index (ContentIndexer): the index surfaces content in system
// search, this intent answers "search Up North for X" out loud. All reads are
// RLS-scoped to the signed-in user.

struct SearchUpNorthIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Up North"
    static var description = IntentDescription(
        "Search across the resort — people, committees, events, work items, and chats."
    )

    @Parameter(title: "Search", requestValueDialog: "What are you looking for?")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search Up North for \(\.$query)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            return .result(dialog: "What should I search for up north?")
        }

        var found: [String] = []

        if let members = try? await MemberEntityQuery().entities(matching: q), !members.isEmpty {
            found.append(summary(members.map(\.name), one: "person", many: "people"))
        }
        if let committees = try? await CommitteeEntityQuery().entities(matching: q), !committees.isEmpty {
            found.append(summary(committees.map(\.name), one: "committee", many: "committees"))
        }
        let events = await EventEntityQuery.upcoming().filter { $0.title.localizedCaseInsensitiveContains(q) }
        if !events.isEmpty {
            found.append(summary(events.map(\.title), one: "event", many: "events"))
        }
        if let work = try? await WorkItemEntityQuery.open() {
            let hits = work.filter { $0.title.localizedCaseInsensitiveContains(q) }
            if !hits.isEmpty { found.append(summary(hits.map(\.title), one: "work item", many: "work items")) }
        }
        let chat = await ChatSearch.run(topic: q, authorId: nil)
        if let top = chat.first {
            let extra = chat.count > 1 ? " and \(chat.count - 1) more" : ""
            found.append("a chat message from \(top.author)\(extra)")
        }

        guard !found.isEmpty else {
            return .result(dialog: IntentDialog(stringLiteral: "I couldn't find anything up north for “\(q).”"))
        }
        let sentence = "For “\(q)” up north I found: " + found.joined(separator: "; ") + "."
        return .result(dialog: IntentDialog(stringLiteral: sentence))
    }

    private func summary(_ names: [String], one: String, many: String) -> String {
        let noun = names.count == 1 ? one : many
        let sample = names.prefix(3).joined(separator: ", ")
        return "\(names.count) \(noun) (\(sample))"
    }
}
