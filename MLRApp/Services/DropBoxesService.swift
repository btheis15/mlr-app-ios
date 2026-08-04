import Foundation
import Supabase

// MARK: - DropBoxesService (migration 0171)
//
// Shared photo/video folders — mirrors lib/dropBoxes.ts. Members-only reads
// (RLS on drop_boxes/drop_box_media); every write goes through a SECURITY
// DEFINER RPC. A flagged upload (the mini's Tier-2 moderation) is held —
// visible only to its uploader + admins — until an admin approves it.

@Observable
@MainActor
final class DropBoxesService {
    var boxes: [DropBox] = []
    var isLoading = false

    private var channel: RealtimeChannelV2?

    /// Every drop box the viewer can see, newest first, each with its items
    /// (RLS already hid anyone else's held media). Empty with no backend or
    /// pre-migration (42P01) — never throws.
    func fetchBoxes() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let rows: [DropBoxRow] = try await supabase
                .from("drop_boxes")
                .select("id, title, emoji, created_by, archived_at, created_at, author:created_by(display_name), drop_box_media(id, box_id, storage_path, thumbnail_url, media_type, status, uploaded_by, created_at, captured_at, uploader:uploaded_by(display_name))")
                .order("created_at", ascending: false)
                .execute()
                .value
            boxes = rows.map(\.toBox)
        } catch {
            print("[DropBoxesService] fetchBoxes error:", error)
        }
    }

    // MARK: Box CRUD

    @discardableResult
    func createBox(title: String, emoji: String? = nil) async throws -> UUID {
        struct P: Encodable { let p_title: String; let p_emoji: String? }
        let id: UUID = try await supabase
            .rpc("create_drop_box", params: P(p_title: title, p_emoji: emoji))
            .execute().value
        return id
    }

    func updateBox(id: UUID, title: String?, emoji: String?) async throws {
        struct P: Encodable { let p_box: String; let p_title: String?; let p_emoji: String? }
        try await supabase
            .rpc("update_drop_box", params: P(p_box: id.uuidString, p_title: title, p_emoji: emoji))
            .execute()
    }

    func setArchived(id: UUID, archived: Bool) async throws {
        struct P: Encodable { let p_box: String; let p_archived: Bool }
        try await supabase
            .rpc("set_drop_box_archived", params: P(p_box: id.uuidString, p_archived: archived))
            .execute()
    }

    func deleteBox(id: UUID) async throws {
        struct P: Encodable { let p_box: String }
        try await supabase.rpc("delete_drop_box", params: P(p_box: id.uuidString)).execute()
    }

    // MARK: Media

    /// Attach an already-uploaded file (mini url) to a box. The DB's
    /// BEFORE INSERT trigger holds it automatically if the mini flagged it.
    @discardableResult
    func addMedia(boxId: UUID, url: String, thumbnailUrl: String?, type: String,
                  capturedAt: Date? = nil, creditUserId: UUID? = nil) async throws -> UUID {
        struct P: Encodable {
            let p_box: String; let p_url: String; let p_type: String; let p_thumbnail_url: String?
            let p_captured_at: String?; let p_credit_user_id: String?
        }
        let iso = capturedAt.map { ISO8601DateFormatter().string(from: $0) }
        let id: UUID = try await supabase
            .rpc("add_drop_box_media", params: P(p_box: boxId.uuidString, p_url: url, p_type: type,
                                                  p_thumbnail_url: thumbnailUrl,
                                                  p_captured_at: iso,
                                                  p_credit_user_id: creditUserId?.uuidString))
            .execute().value
        return id
    }

    func removeMedia(id: UUID) async throws {
        struct P: Encodable { let p_media: String }
        try await supabase.rpc("remove_drop_box_media", params: P(p_media: id.uuidString)).execute()
    }

    /// Bulk-remove multiple media items (used by selection-mode delete).
    func removeMediaBatch(ids: [UUID]) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { try await self.removeMedia(id: id) } }
            try await group.waitForAll()
        }
    }

    /// Admin-only: release a false-positive hold, or hide an item.
    func setMediaStatus(id: UUID, status: DropBoxMediaStatus) async throws {
        struct P: Encodable { let p_media: String; let p_status: String }
        try await supabase
            .rpc("set_drop_box_media_status", params: P(p_media: id.uuidString, p_status: status.rawValue))
            .execute()
    }

    // MARK: Realtime — a photo someone else drops appears live in an open box.

    func subscribe(onChange: @escaping () -> Void) {
        guard channel == nil else { return }
        let ch = supabase.channel("drop-boxes")
        channel = ch
        Task {
            ch.onPostgresChange(AnyAction.self, schema: "public", table: "drop_boxes") { _ in
                Task { @MainActor in onChange() }
            }
            ch.onPostgresChange(AnyAction.self, schema: "public", table: "drop_box_media") { _ in
                Task { @MainActor in onChange() }
            }
            await ch.subscribe()
        }
    }

    func unsubscribe() {
        guard let ch = channel else { return }
        Task { await supabase.removeChannel(ch) }
        channel = nil
    }
}

// MARK: - Decode rows

private struct DropBoxRow: Decodable {
    let id: UUID
    let title: String
    let emoji: String?
    let createdBy: UUID
    let archivedAt: Date?
    let createdAt: Date
    let author: NameEmbed?
    let dropBoxMedia: [DropBoxMediaRow]?

    enum CodingKeys: String, CodingKey {
        case id, title, emoji, author
        case createdBy = "created_by"
        case archivedAt = "archived_at"
        case createdAt = "created_at"
        case dropBoxMedia = "drop_box_media"
    }

    var toBox: DropBox {
        DropBox(
            id: id, title: title, emoji: emoji, createdBy: createdBy,
            createdByName: author?.displayName ?? "Member",
            archivedAt: archivedAt, createdAt: createdAt,
            items: (dropBoxMedia ?? []).map(\.toMedia)
        )
    }
}

private struct DropBoxMediaRow: Decodable {
    let id: UUID
    let boxId: UUID
    let storagePath: String
    let thumbnailUrl: String?
    let mediaType: String
    let status: DropBoxMediaStatus
    let uploadedBy: UUID
    let createdAt: Date
    let capturedAt: Date?
    let uploader: NameEmbed?

    enum CodingKeys: String, CodingKey {
        case id, status, uploader
        case boxId = "box_id"
        case storagePath = "storage_path"
        case thumbnailUrl = "thumbnail_url"
        case mediaType = "media_type"
        case uploadedBy = "uploaded_by"
        case createdAt = "created_at"
        case capturedAt = "captured_at"
    }

    var toMedia: DropBoxMedia {
        DropBoxMedia(
            id: id, boxId: boxId, url: storagePath, thumbnailUrl: thumbnailUrl,
            mediaType: mediaType, status: status, uploadedBy: uploadedBy,
            uploadedByName: uploader?.displayName ?? "Member",
            capturedAt: capturedAt, creditUserId: nil,
            creditUserName: nil, createdAt: createdAt
        )
    }
}

private struct NameEmbed: Decodable {
    let displayName: String?
    enum CodingKeys: String, CodingKey { case displayName = "display_name" }
}
