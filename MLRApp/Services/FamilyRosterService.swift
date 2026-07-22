import Foundation
import Supabase

// MARK: - FamilyRosterService (migrations 0123–0125)
//
// CRUD for the family roster (people not on the app yet) + the gated recipient
// pools that back the widened People email composer. Mirrors lib/familyRoster.ts
// + lib/emailBlast.ts. Reads are signed-in members (they carry PII); writes are
// admins only (RLS-enforced).

@Observable
@MainActor
final class FamilyRosterService {

    // MARK: - Roster

    func fetchRoster() async -> [FamilyRosterEntry] {
        do {
            let rows: [RosterRow] = try await supabase
                .from("family_roster")
                .select("id, name, email, phone, house_id, position, linked_user_id, profiles:linked_user_id(display_name, avatar_url)")
                .order("name", ascending: true)
                .execute()
                .value
            return rows.map(\.toEntry)
        } catch {
            print("[FamilyRosterService] fetchRoster error: \(error)")
            return []
        }
    }

    /// Create or update a roster person (admin-gated). The link trigger stamps
    /// linked_user_id from the email, so we never set it directly.
    func saveEntry(id: UUID?, name: String, email: String?, phone: String?, houseId: UUID?) async throws {
        let uid = try? await supabase.auth.session.user.id
        var row: [String: AnyJSON] = [
            "name": .string(name.trimmingCharacters(in: .whitespaces)),
            "email": email?.trimmingCharacters(in: .whitespaces).nilIfEmpty.map { AnyJSON.string($0) } ?? .null,
            "phone": phone?.trimmingCharacters(in: .whitespaces).nilIfEmpty.map { AnyJSON.string($0) } ?? .null,
            "house_id": houseId.map { AnyJSON.string($0.uuidString) } ?? .null,
            "updated_at": .string(ISO8601DateFormatter().string(from: Date())),
        ]
        row["updated_by"] = uid.map { AnyJSON.string($0.uuidString) } ?? .null
        if let id {
            try await supabase.from("family_roster").update(row).eq("id", value: id.uuidString).execute()
        } else {
            try await supabase.from("family_roster").insert(row).execute()
        }
    }

    func deleteEntry(id: UUID) async throws {
        try await supabase.from("family_roster").delete().eq("id", value: id.uuidString).execute()
    }

    // MARK: - Email recipient pools

    private func recipients(rpc: String, params: (some Encodable)? = Optional<String>.none) async -> [EmailRecipient] {
        do {
            let rows: [RecipientRow]
            if let params {
                rows = try await supabase.rpc(rpc, params: params).execute().value
            } else {
                rows = try await supabase.rpc(rpc).execute().value
            }
            return rows.compactMap(\.toRecipient)
        } catch {
            print("[FamilyRosterService] \(rpc) error: \(error)")
            return []
        }
    }

    func allMemberRecipients() async -> [EmailRecipient] { await recipients(rpc: "all_member_recipients") }
    func directoryRecipients() async -> [EmailRecipient] { await recipients(rpc: "directory_recipients") }
    func adminRecipients() async -> [EmailRecipient] { await recipients(rpc: "admin_recipients") }

    func houseRecipients(houseId: UUID) async -> [EmailRecipient] {
        struct P: Encodable { let hid: String }
        return await recipients(rpc: "house_member_recipients", params: P(hid: houseId.uuidString))
    }

    /// Committee pool — carries `roles` so the By-Role filter works.
    func committeeRecipients(committeeId: UUID) async -> [EmailRecipient] {
        struct P: Encodable { let cid: String }
        return await recipients(rpc: "committee_member_recipients", params: P(cid: committeeId.uuidString))
    }
}

// MARK: - Row decoding

private struct RosterRow: Decodable {
    let id: UUID
    let name: String
    let email: String?
    let phone: String?
    let houseId: UUID?
    let position: Int
    let linkedUserId: UUID?
    let profiles: LinkedProfile?

    struct LinkedProfile: Decodable {
        let displayName: String?
        let avatarUrl: String?
        enum CodingKeys: String, CodingKey { case displayName = "display_name"; case avatarUrl = "avatar_url" }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, email, phone, position, profiles
        case houseId = "house_id"
        case linkedUserId = "linked_user_id"
    }

    var toEntry: FamilyRosterEntry {
        FamilyRosterEntry(
            id: id, name: name, email: email, phone: phone, houseId: houseId,
            position: position, linkedUserId: linkedUserId,
            linkedName: profiles?.displayName, linkedAvatarUrl: profiles?.avatarUrl)
    }
}

private struct RecipientRow: Decodable {
    let id: UUID
    let name: String?
    let email: String?
    let roles: [String]?

    var toRecipient: EmailRecipient? {
        guard let email, !email.isEmpty else { return nil }
        return EmailRecipient(id: id, name: name ?? "Member", email: email, areas: roles ?? [])
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
