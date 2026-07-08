import AppIntents
import Foundation

// MARK: - Chat search intent (Siri / Apple Intelligence)
//
// "What did Rick say about meals?" — full-text searches committee + house chat
// for messages matching a topic, optionally filtered to one person, and speaks
// back the most recent match. RLS scopes results to chats the signed-in user is
// a member of, so nothing private leaks. Soft-deleted messages are excluded.

struct SearchChatIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Chats"
    static var description = IntentDescription(
        "Search what people have said in committee and house chats about a topic."
    )

    @Parameter(title: "Topic", requestValueDialog: "What topic should I look for?")
    var topic: String

    @Parameter(title: "Person")
    var member: MemberEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Search chats for \(\.$topic)") {
            \.$member
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let q = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            return .result(dialog: "What topic should I search the chats for?")
        }
        let matches = await ChatSearch.run(topic: q, authorId: member?.id)
        guard let top = matches.first else {
            let who = member.map { " from \($0.name)" } ?? ""
            return .result(dialog: IntentDialog(stringLiteral: "I couldn't find any messages about \(q)\(who)."))
        }
        return .result(dialog: IntentDialog(stringLiteral: top.spoken))
    }
}

// MARK: - Search implementation

struct ChatMatch {
    let author: String
    let context: String   // e.g. "the Meals committee chat"
    let text: String
    let date: Date

    var spoken: String {
        let d = date.formatted(.dateTime.month(.abbreviated).day())
        return "In \(context) on \(d), \(author) said: \"\(text)\""
    }
}

enum ChatSearch {
    /// Search committee + house chats; newest match first. Never throws — a failing
    /// source just contributes nothing.
    static func run(topic: String, authorId: UUID?) async -> [ChatMatch] {
        async let committee = committeeMatches(topic: topic, authorId: authorId)
        async let house = houseMatches(topic: topic, authorId: authorId)
        let all = (await committee) + (await house)
        return all.sorted { $0.date > $1.date }
    }

    // MARK: Committee chat

    private struct CommitteeRow: Decodable {
        let text: String?
        let createdAt: Date
        let profiles: Author?
        let committees: Committee?
        struct Author: Decodable { let displayName: String?
            enum CodingKeys: String, CodingKey { case displayName = "display_name" } }
        struct Committee: Decodable { let name: String? }
        enum CodingKeys: String, CodingKey {
            case text
            case createdAt = "created_at"
            case profiles
            case committees
        }
    }

    private static func committeeMatches(topic: String, authorId: UUID?) async -> [ChatMatch] {
        var query = supabase
            .from("committee_messages")
            .select("text, created_at, profiles!author_id(display_name), committees(name)")
            .is("deleted_at", value: nil)
            .ilike("text", pattern: "%\(topic)%")
        if let authorId { query = query.eq("author_id", value: authorId.uuidString) }
        let rows: [CommitteeRow] = (try? await query
            .order("created_at", ascending: false)
            .limit(12)
            .execute()
            .value) ?? []
        return rows.compactMap { r in
            guard let text = r.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let committee = r.committees?.name ?? "a committee"
            return ChatMatch(
                author: r.profiles?.displayName ?? "Someone",
                context: "the \(committee) committee chat",
                text: text,
                date: r.createdAt
            )
        }
    }

    // MARK: House chat

    private struct HouseRow: Decodable {
        let text: String?
        let createdAt: Date
        let profiles: Author?
        let houses: House?
        struct Author: Decodable { let displayName: String?
            enum CodingKeys: String, CodingKey { case displayName = "display_name" } }
        struct House: Decodable { let name: String? }
        enum CodingKeys: String, CodingKey {
            case text
            case createdAt = "created_at"
            case profiles
            case houses
        }
    }

    private static func houseMatches(topic: String, authorId: UUID?) async -> [ChatMatch] {
        var query = supabase
            .from("house_messages")
            .select("text, created_at, profiles!author_id(display_name), houses(name)")
            .is("deleted_at", value: nil)
            .ilike("text", pattern: "%\(topic)%")
        if let authorId { query = query.eq("author_id", value: authorId.uuidString) }
        let rows: [HouseRow] = (try? await query
            .order("created_at", ascending: false)
            .limit(12)
            .execute()
            .value) ?? []
        return rows.compactMap { r in
            guard let text = r.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let house = r.houses?.name ?? "a house"
            return ChatMatch(
                author: r.profiles?.displayName ?? "Someone",
                context: "the \(house) house chat",
                text: text,
                date: r.createdAt
            )
        }
    }
}
