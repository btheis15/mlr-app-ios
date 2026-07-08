import AppIntents
import Foundation

// MARK: - Personalized intents (Siri / Apple Intelligence)
//
// Questions about the signed-in member's own world — turnout for an event they
// care about, what they've missed, their committees, and what they're signed up
// for. Everything reads as the current user (RLS-scoped); signed-out gets a
// friendly nudge.

// MARK: - Event turnout

struct EventTurnoutIntent: AppIntent {
    static var title: LocalizedStringResource = "Event Turnout"
    static var description = IntentDescription("How many people are coming to an event.")

    @Parameter(title: "Event")
    var event: EventEntity

    static var parameterSummary: some ParameterSummary {
        Summary("How many people are coming to \(\.$event)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let s = await EventsService().fetchSummary(eventId: event.id)
        guard s.total > 0 else {
            return .result(dialog: "No one has RSVP'd to \(event.title) yet.")
        }
        var parts = ["\(s.going) going"]
        if s.maybe > 0 { parts.append("\(s.maybe) maybe") }
        return .result(dialog: IntentDialog(stringLiteral: "\(event.title): \(parts.joined(separator: ", ")).")) 
    }
}

// MARK: - What did I miss

struct WhatDidIMissIntent: AppIntent {
    static var title: LocalizedStringResource = "What Did I Miss"
    static var description = IntentDescription("Catch up on your latest resort notifications.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let uid = try? await supabase.auth.session.user.id else {
            return .result(dialog: "Open MLR and sign in to see your activity.")
        }
        struct Row: Decodable { let title: String; let body: String? }
        let rows: [Row] = (try? await supabase
            .from("notifications")
            .select("title, body")
            .eq("recipient_id", value: uid.uuidString)
            .is("seen_at", value: nil)
            .order("created_at", ascending: false)
            .limit(10)
            .execute().value) ?? []
        guard !rows.isEmpty else {
            return .result(dialog: "You're all caught up up north. ✅")
        }
        let list = rows.prefix(5).map(\.title).joined(separator: "; ")
        return .result(dialog: IntentDialog(stringLiteral: "You have \(rows.count) new notification\(rows.count == 1 ? "" : "s"): \(list).")) 
    }
}

// MARK: - My committees

struct MyCommitteesIntent: AppIntent {
    static var title: LocalizedStringResource = "My Committees"
    static var description = IntentDescription("Which committees you're on.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let uid = try? await supabase.auth.session.user.id else {
            return .result(dialog: "Open MLR and sign in to see your committees.")
        }
        struct SRow: Decodable { let committeeSlug: String
            enum CodingKeys: String, CodingKey { case committeeSlug = "committee_slug" } }
        let rows: [SRow] = (try? await supabase
            .from("committee_roster")
            .select("committee_slug")
            .eq("linked_user_id", value: uid.uuidString)
            .execute().value) ?? []
        let slugs = Set(rows.map(\.committeeSlug))
        guard !slugs.isEmpty else {
            return .result(dialog: "You're not on any committees yet.")
        }
        let all = (try? await CommitteeEntityQuery.all()) ?? []
        let names = all.filter { slugs.contains($0.id) }.map(\.name)
        let display = names.isEmpty ? Array(slugs).sorted() : names
        return .result(dialog: IntentDialog(stringLiteral: "You're on \(display.count) committee\(display.count == 1 ? "" : "s"): \(display.joined(separator: ", ")).")) 
    }
}

// MARK: - What I'm signed up for (my RSVPs)

struct MyRSVPsIntent: AppIntent {
    static var title: LocalizedStringResource = "What I'm Signed Up For"
    static var description = IntentDescription("The events you've RSVP'd to.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let uid = try? await supabase.auth.session.user.id else {
            return .result(dialog: "Open MLR and sign in to see your RSVPs.")
        }
        struct Row: Decodable { let eventId: String
            enum CodingKeys: String, CodingKey { case eventId = "event_id" } }
        let rows: [Row] = (try? await supabase
            .from("event_attendance")
            .select("event_id")
            .eq("user_id", value: uid.uuidString)
            .in("status", values: ["going", "maybe"])
            .execute().value) ?? []
        let ids = Set(rows.map(\.eventId))
        guard !ids.isEmpty else {
            return .result(dialog: "You haven't RSVP'd to anything yet.")
        }
        let events = await EventEntityQuery.upcoming().filter { ids.contains($0.id) }
        guard !events.isEmpty else {
            return .result(dialog: "You're signed up for \(ids.count) event\(ids.count == 1 ? "" : "s") (all in the past).")
        }
        let names = events.prefix(6).map(\.title).joined(separator: ", ")
        return .result(dialog: IntentDialog(stringLiteral: "You're signed up for: \(names).")) 
    }
}
