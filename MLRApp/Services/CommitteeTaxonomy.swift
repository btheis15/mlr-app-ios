import Foundation

// MARK: - Admin committee taxonomy (migration 0112)
//
// Admins can create/rename/archive committees and their roles ("areas" = chat
// channels). "Delete" = archive (restorable), never destroy. Backend is live +
// shared with the web app; iOS just calls the same RPCs. See
// docs/ios-committee-taxonomy-parity.md in the web repo.

extension CommitteeService {

    /// Committees visible in the live app (archived ones drop out).
    var liveCommittees: [Committee] { committees.filter { !$0.isArchived } }

    /// Committees that have been archived (admin "Archived" section + restore).
    var archivedCommittees: [Committee] { committees.filter { $0.isArchived } }

    // MARK: Areas (the role/channel allow-list — source of truth)

    /// A committee's roles/areas. `includeArchived: false` returns only the live
    /// set (drives the roster group-by, join picker, and role checkboxes).
    func fetchCommitteeAreas(slug: String, includeArchived: Bool = false) async -> [CommitteeArea] {
        let base = supabase
            .from("committee_areas")
            .select("committee_slug, area, archived_at")
            .eq("committee_slug", value: slug)
        do {
            if includeArchived {
                return try await base.order("area", ascending: true).execute().value
            }
            return try await base
                .filter("archived_at", operator: "is", value: "null")
                .order("area", ascending: true)
                .execute().value
        } catch {
            print("[CommitteeService] fetchCommitteeAreas error: \(error)")
            return []
        }
    }

    // MARK: Committee RPCs (admin-only; RLS enforces is_admin)

    @discardableResult
    func createCommittee(name: String, emoji: String, description: String) async throws -> Committee {
        struct P: Encodable { let p_name: String; let p_emoji: String; let p_description: String }
        return try await supabase
            .rpc("create_committee", params: P(p_name: name, p_emoji: emoji, p_description: description))
            .execute().value
    }

    func updateCommittee(id: UUID, name: String, emoji: String, description: String, position: Int? = nil) async throws {
        struct P: Encodable { let cid: String; let p_name: String; let p_emoji: String; let p_description: String; let p_position: Int? }
        try await supabase
            .rpc("update_committee", params: P(cid: id.uuidString, p_name: name, p_emoji: emoji, p_description: description, p_position: position))
            .execute()
    }

    func archiveCommittee(id: UUID) async throws {
        struct P: Encodable { let cid: String }
        try await supabase.rpc("archive_committee", params: P(cid: id.uuidString)).execute()
    }

    func restoreCommittee(id: UUID) async throws {
        struct P: Encodable { let cid: String }
        try await supabase.rpc("restore_committee", params: P(cid: id.uuidString)).execute()
    }

    // MARK: Area / role RPCs

    func addCommitteeArea(committeeId: UUID, area: String) async throws {
        struct P: Encodable { let cid: String; let p_area: String }
        try await supabase.rpc("add_committee_area", params: P(cid: committeeId.uuidString, p_area: area)).execute()
    }

    /// Renames a role AND cascades the name through its whole chat history +
    /// roster/member/read/join rows server-side. Never rename by table write.
    func renameCommitteeArea(committeeId: UUID, old: String, new: String) async throws {
        struct P: Encodable { let cid: String; let p_old: String; let p_new: String }
        try await supabase.rpc("rename_committee_area", params: P(cid: committeeId.uuidString, p_old: old, p_new: new)).execute()
    }

    func archiveCommitteeArea(committeeId: UUID, area: String) async throws {
        struct P: Encodable { let cid: String; let p_area: String }
        try await supabase.rpc("archive_committee_area", params: P(cid: committeeId.uuidString, p_area: area)).execute()
    }

    func restoreCommitteeArea(committeeId: UUID, area: String) async throws {
        struct P: Encodable { let cid: String; let p_area: String }
        try await supabase.rpc("restore_committee_area", params: P(cid: committeeId.uuidString, p_area: area)).execute()
    }
}
