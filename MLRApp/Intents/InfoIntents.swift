import AppIntents
import Foundation

// MARK: - Info intents (Siri / Apple Intelligence)
//
// House rules, announcements, and directions to the resort.

// MARK: - House rules

struct HouseRulesIntent: AppIntent {
    static var title: LocalizedStringResource = "House Rules"
    static var description = IntentDescription("Read your house's rules.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let uid = try? await supabase.auth.session.user.id else {
            return .result(dialog: "Open MLR and sign in to see your house rules.")
        }
        struct ProfileRow: Decodable { let houseId: UUID?
            enum CodingKeys: String, CodingKey { case houseId = "house_id" } }
        let profs: [ProfileRow] = (try? await supabase
            .from("profiles").select("house_id").eq("id", value: uid.uuidString).limit(1)
            .execute().value) ?? []
        guard let hid = profs.first?.houseId else {
            return .result(dialog: "You're not assigned to a house yet.")
        }
        struct HouseRow: Decodable { let rules: String? }
        let houses: [HouseRow] = (try? await supabase
            .from("houses").select("rules").eq("id", value: hid.uuidString).limit(1)
            .execute().value) ?? []
        let rules = (houses.first?.rules ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rules.isEmpty else {
            return .result(dialog: "No house rules have been posted yet.")
        }
        let spoken = rules.count > 320 ? String(rules.prefix(320)) + "… Open the app for the rest." : rules
        return .result(dialog: IntentDialog(stringLiteral: spoken))
    }
}

// MARK: - Announcements

struct AnnouncementsIntent: AppIntent {
    static var title: LocalizedStringResource = "Resort Announcements"
    static var description = IntentDescription("The latest announcements up north.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        struct Row: Decodable { let title: String; let body: String? }
        let nowISO = ISO8601DateFormatter().string(from: Date())
        let rows: [Row] = (try? await supabase
            .from("announcements")
            .select("title, body")
            .or("expires_at.is.null,expires_at.gte.\(nowISO)")
            .order("created_at", ascending: false)
            .limit(5)
            .execute().value) ?? []
        guard !rows.isEmpty else {
            return .result(dialog: "No announcements up north right now.")
        }
        if rows.count == 1, let body = rows[0].body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            return .result(dialog: IntentDialog(stringLiteral: "\(rows[0].title): \(body)"))
        }
        let titles = rows.prefix(5).map(\.title).joined(separator: "; ")
        return .result(dialog: IntentDialog(stringLiteral: "\(rows.count) announcement\(rows.count == 1 ? "" : "s"): \(titles)."))
    }
}

// MARK: - Directions to the resort

struct DirectionsToResortIntent: AppIntent {
    static var title: LocalizedStringResource = "Directions to the Resort"
    static var description = IntentDescription("Get driving directions up north.")

    func perform() async throws -> some IntentResult & OpensIntent & ProvidesDialog {
        let r = MapsHelper.resort
        // Deterministic, always-valid Apple Maps URL (numeric coords) — force-unwrap
        // keeps a single return type for the opaque `OpensIntent` result.
        let url = URL(string: "http://maps.apple.com/?daddr=\(r.latitude),\(r.longitude)")!
        return .result(opensIntent: OpenURLIntent(url),
                       dialog: "Getting directions up north.")
    }
}
