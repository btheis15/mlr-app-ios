import Foundation
import Supabase

// MARK: - PrivateActivitiesService (migration 0150)
//
// Member-made, invite-only activities in the Events tab. Reads via the client
// (RLS scopes rows to the viewer's own activities); writes via SECURITY DEFINER
// RPCs. Degrades to empty / thrown errors surfaced by callers. Mirrors
// lib/privateActivities.ts.

@Observable
@MainActor
final class PrivateActivitiesService {

    /// Every private activity the viewer can see (RLS = creator + invited +
    /// admin), newest first. Empty on any failure / pre-migration.
    func fetchActivities() async -> [PrivateActivity] {
        do {
            return try await supabase
                .from("private_activities")
                .select("*, private_activity_members(*)")
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            return []
        }
    }

    @discardableResult
    func create(
        title: String,
        emoji: String?,
        description: String?,
        location: String?,
        startsAt: Date?,
        tournamentEnabled: Bool,
        members: [MemberInput],
        notify: Bool
    ) async throws -> UUID {
        let params: [String: AnyJSON] = [
            "p_title":       .string(title),
            "p_emoji":       emoji.map { AnyJSON.string($0) } ?? .null,
            "p_description": description.map { AnyJSON.string($0) } ?? .null,
            "p_location":    location.map { AnyJSON.string($0) } ?? .null,
            "p_starts_at":   startsAt.map { AnyJSON.string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
            "p_ends_at":     .null,
            "p_tournament_enabled": .bool(tournamentEnabled),
            "p_members":     .array(members.map { $0.json }),
            "p_notify":      .bool(notify),
        ]
        return try await supabase.rpc("create_private_activity", params: params).execute().value
    }

    func update(id: UUID, title: String, emoji: String?, description: String?,
                location: String?, startsAt: Date?, clearStart: Bool, tournamentEnabled: Bool?) async throws {
        let params: [String: AnyJSON] = [
            "p_activity":    .string(id.uuidString),
            "p_title":       .string(title),
            "p_emoji":       emoji.map { AnyJSON.string($0) } ?? .null,
            "p_description": description.map { AnyJSON.string($0) } ?? .null,
            "p_location":    location.map { AnyJSON.string($0) } ?? .null,
            "p_starts_at":   startsAt.map { AnyJSON.string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
            "p_ends_at":     .null,
            "p_tournament_enabled": tournamentEnabled.map { AnyJSON.bool($0) } ?? .null,
            "p_clear_start": .bool(clearStart),
        ]
        try await supabase.rpc("update_private_activity", params: params).execute()
    }

    func delete(id: UUID) async throws {
        struct P: Encodable { let p_activity: String }
        try await supabase.rpc("delete_private_activity", params: P(p_activity: id.uuidString)).execute()
    }

    func setArchived(id: UUID, archived: Bool) async throws {
        struct P: Encodable { let p_activity: String; let p_archived: Bool }
        try await supabase.rpc("set_private_activity_archived", params: P(p_activity: id.uuidString, p_archived: archived)).execute()
    }

    @discardableResult
    func addMember(activityId: UUID, member: MemberInput, role: ActivityRole = .player, notify: Bool = false) async throws -> UUID {
        let params: [String: AnyJSON] = [
            "p_activity": .string(activityId.uuidString),
            "p_user_id":  member.userId.map { AnyJSON.string($0.uuidString) } ?? .null,
            "p_name":     member.name.map { AnyJSON.string($0) } ?? .null,
            "p_role":     .string(role.rawValue),
            "p_notify":   .bool(notify),
        ]
        return try await supabase.rpc("add_private_activity_member", params: params).execute().value
    }

    func removeMember(memberId: UUID) async throws {
        struct P: Encodable { let p_member: String }
        try await supabase.rpc("remove_private_activity_member", params: P(p_member: memberId.uuidString)).execute()
    }

    func setMemberRole(memberId: UUID, role: ActivityRole) async throws {
        struct P: Encodable { let p_member: String; let p_role: String }
        try await supabase.rpc("set_private_activity_member_role", params: P(p_member: memberId.uuidString, p_role: role.rawValue)).execute()
    }

    func setRsvp(activityId: UUID, rsvp: ActivityRsvp?) async throws {
        let params: [String: AnyJSON] = [
            "p_activity": .string(activityId.uuidString),
            "p_rsvp":     rsvp.map { AnyJSON.string($0.rawValue) } ?? .null,
        ]
        try await supabase.rpc("set_private_activity_rsvp", params: params).execute()
    }

    // MARK: - Member input

    struct MemberInput {
        var userId: UUID?
        var name: String?
        var json: AnyJSON {
            .object([
                "user_id": userId.map { AnyJSON.string($0.uuidString) } ?? .null,
                "name":    name.map { AnyJSON.string($0) } ?? .null,
            ])
        }
    }
}
