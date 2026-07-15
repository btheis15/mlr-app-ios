import Foundation
import Supabase

// MARK: - WorkItemsService
//
// Work checklist (migrations 0048–0050). Mirrors web lib/workItems.ts: reads are
// public; writes go through SECURITY DEFINER RPCs (create/markDone any member;
// update/delete/sync admin-only). event_work_items.event_id is TEXT — the stable
// ResortEvent string id (seed events included).

@Observable
@MainActor
final class WorkItemsService {
    var items: [WorkItem] = []
    var isLoading: Bool = false
    var error: String? = nil

    var openItems: [WorkItem] { items.filter { $0.status == .open } }
    var doneItems: [WorkItem] { items.filter { $0.status == .done } }

    private var realtimeChannel: RealtimeChannelV2? = nil

    // MARK: - Fetch

    /// All work items, open first then done (newest-first within each group).
    func fetchItems() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let rows: [WorkItem] = try await supabase
                .from("work_items")
                .select("*, work_item_media(*), work_item_comments(id), completed_by_profile:profiles!completed_by(display_name)")
                .order("status", ascending: true)        // 'done' sorts after 'open'
                .order("created_at", ascending: false)
                .execute()
                .value
            items = rows
            writeTodoSnapshot()
        } catch {
            self.error = "Couldn't load the work checklist."
            print("[WorkItemsService] fetchItems error: \(error)")
        }
    }

    /// Publish the open MLR (resort-wide) work items to the App Group so the
    /// "Things to do" widget can show them without a network call. House-scoped
    /// items stay out of the shared/widget surface — it's public-safe.
    private func writeTodoSnapshot() {
        let open = openItems.filter { $0.houseId == nil }
        SharedStore.shared.todo = TodoSnapshot(
            openCount: open.count,
            titles: Array(open.prefix(3).map(\.title))
        )
        SharedStore.shared.reloadWidgets()
    }

    /// Work items linked to a specific event.
    func fetchEventItems(eventId: String) async -> [WorkItem] {
        do {
            let rows: [EventWorkItemRow] = try await supabase
                .from("event_work_items")
                .select("work_item_id, work_items(*)")
                .eq("event_id", value: eventId)
                .execute()
                .value
            return rows.compactMap(\.workItem)
        } catch {
            print("[WorkItemsService] fetchEventItems error: \(error)")
            return []
        }
    }

    // MARK: - Mutations

    /// Create a new item (any signed-in member). `houseId` nil = an MLR /
    /// resort-wide item; non-nil = a house-only item (requires membership,
    /// enforced server-side). Returns the new item id. (migrations 0066/0069)
    @discardableResult
    func createItem(
        title: String, notes: String?, category: String?, peopleNeeded: Int?,
        houseId: UUID? = nil, urgency: WorkUrgency? = nil
    ) async throws -> UUID {
        struct CreateParams: Encodable {
            let p_title: String
            let p_notes: String?
            let p_category: String?
            let p_people_needed: Int?
            let p_house_id: String?
            let p_urgency: String?
        }
        let id: UUID = try await supabase
            .rpc("create_work_item", params: CreateParams(
                p_title: title, p_notes: notes, p_category: category, p_people_needed: peopleNeeded,
                p_house_id: houseId?.uuidString, p_urgency: urgency?.rawValue
            ))
            .execute()
            .value
        await fetchItems()
        return id
    }

    /// Mark an item done (any signed-in member).
    func markDone(id: UUID) async throws {
        struct DoneParams: Encodable { let p_id: String }
        try await supabase
            .rpc("mark_work_item_done", params: DoneParams(p_id: id.uuidString))
            .execute()
    }

    /// Edit an item's fields + status (admin only). Admins can re-scope an item
    /// between MLR and a house, and set/clear urgency. (migrations 0066/0069)
    func updateItem(
        id: UUID, title: String, notes: String?, category: String?, status: WorkItemStatus,
        peopleNeeded: Int?, houseId: UUID? = nil, urgency: WorkUrgency? = nil
    ) async throws {
        struct UpdateParams: Encodable {
            let p_id: String
            let p_title: String
            let p_notes: String?
            let p_category: String?
            let p_status: String
            let p_people_needed: Int?
            let p_house_id: String?
            let p_urgency: String?
        }
        try await supabase
            .rpc("update_work_item", params: UpdateParams(
                p_id: id.uuidString, p_title: title, p_notes: notes,
                p_category: category, p_status: status.rawValue, p_people_needed: peopleNeeded,
                p_house_id: houseId?.uuidString, p_urgency: urgency?.rawValue
            ))
            .execute()
        await fetchItems()
    }

    /// Delete an item (admin only).
    func deleteItem(id: UUID) async throws {
        struct DeleteParams: Encodable { let p_id: String }
        try await supabase
            .rpc("delete_work_item", params: DeleteParams(p_id: id.uuidString))
            .execute()
        items.removeAll { $0.id == id }
    }

    // MARK: - Media (migration 0067)

    /// Attach an already-uploaded media URL to an item (item creator or admin).
    @discardableResult
    func addMedia(workItemId: UUID, url: String, mediaType: String, position: Int) async throws -> UUID {
        struct Params: Encodable {
            let p_work_item_id: String
            let p_url: String
            let p_media_type: String
            let p_position: Int
        }
        return try await supabase
            .rpc("add_work_item_media", params: Params(
                p_work_item_id: workItemId.uuidString, p_url: url,
                p_media_type: mediaType, p_position: position
            ))
            .execute()
            .value
    }

    /// Remove a media attachment (item creator or admin).
    func removeMedia(id: UUID) async throws {
        struct Params: Encodable { let p_id: String }
        try await supabase
            .rpc("remove_work_item_media", params: Params(p_id: id.uuidString))
            .execute()
    }

    // MARK: - Comments (migration 0068)

    /// Comment thread for an item, oldest-first, with @mentions stitched in.
    func fetchComments(workItemId: UUID) async throws -> [WorkItemComment] {
        let rows: [WorkItemCommentRow] = try await supabase
            .from("work_item_comments")
            .select("id, work_item_id, author_id, text, created_at, profiles!author_id(display_name, avatar_url)")
            .eq("work_item_id", value: workItemId.uuidString)
            .order("created_at", ascending: true)
            .execute()
            .value

        // Stitch mentioned user ids in from the join table (one extra query).
        var mentionsByComment: [UUID: [UUID]] = [:]
        let ids = rows.map(\.id.uuidString)
        if !ids.isEmpty {
            struct MentionRow: Decodable {
                let commentId: UUID
                let mentionedUserId: UUID
                enum CodingKeys: String, CodingKey {
                    case commentId = "comment_id"
                    case mentionedUserId = "mentioned_user_id"
                }
            }
            let mrows: [MentionRow] = (try? await supabase
                .from("work_item_comment_mentions")
                .select("comment_id, mentioned_user_id")
                .in("comment_id", values: ids)
                .execute()
                .value) ?? []
            for m in mrows { mentionsByComment[m.commentId, default: []].append(m.mentionedUserId) }
        }
        return rows.map { $0.toComment(mentions: mentionsByComment[$0.id] ?? []) }
    }

    /// Post a comment (anyone who can see the item). Records @mentions so the
    /// server fires notifications. Returns the created comment.
    @discardableResult
    func addComment(workItemId: UUID, text: String, authorId: UUID, mentionedIds: [UUID] = []) async throws -> WorkItemComment {
        let insert: [String: AnyJSON] = [
            "work_item_id": .string(workItemId.uuidString),
            "author_id":    .string(authorId.uuidString),
            "text":         .string(text),
        ]
        let row: WorkItemCommentRow = try await supabase
            .from("work_item_comments")
            .insert(insert)
            .select("id, work_item_id, author_id, text, created_at, profiles!author_id(display_name, avatar_url)")
            .single()
            .execute()
            .value
        if !mentionedIds.isEmpty {
            let rows: [[String: AnyJSON]] = mentionedIds.map {
                ["comment_id": .string(row.id.uuidString), "mentioned_user_id": .string($0.uuidString)]
            }
            try? await supabase.from("work_item_comment_mentions").insert(rows).execute()
        }
        return row.toComment(mentions: mentionedIds)
    }

    /// Delete a comment (author or admin).
    func removeComment(id: UUID) async throws {
        try await supabase
            .from("work_item_comments")
            .delete()
            .eq("id", value: id.uuidString)
            .execute()
    }

    /// Link a single item to an event (any signed-in member; additive).
    func addToEvent(eventId: String, itemId: UUID) async throws {
        struct LinkParams: Encodable {
            let p_event_id: String
            let p_work_item_id: String
        }
        try await supabase
            .rpc("add_work_item_to_event", params: LinkParams(
                p_event_id: eventId, p_work_item_id: itemId.uuidString
            ))
            .execute()
    }

    /// Replace the full set of items linked to an event (admin only; empty clears all).
    func syncEventItems(eventId: String, itemIds: [UUID]) async throws {
        struct SyncParams: Encodable {
            let p_event_id: String
            let p_item_ids: [String]
        }
        try await supabase
            .rpc("sync_event_work_items", params: SyncParams(
                p_event_id: eventId, p_item_ids: itemIds.map(\.uuidString)
            ))
            .execute()
    }

    // MARK: - Realtime

    /// Live-update the checklist when items are created, completed, or edited
    /// anywhere — matching the web app.
    func subscribeToRealtime() {
        guard realtimeChannel == nil else { return }
        let channel = supabase.channel("work-items-live")
        realtimeChannel = channel

        Task {
            channel.onPostgresChange(AnyAction.self, schema: "public", table: "work_items") { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in await self.fetchItems() }
            }
            await channel.subscribe()
        }
    }

    func unsubscribeFromRealtime() {
        Task {
            if let channel = realtimeChannel {
                await supabase.removeChannel(channel)
                realtimeChannel = nil
            }
        }
    }
}

// MARK: - Private row type for event_work_items join

private struct EventWorkItemRow: Decodable {
    let workItem: WorkItem?
    enum CodingKeys: String, CodingKey {
        case workItem = "work_items"
    }
}

// MARK: - Private row type for work_item_comments
// Author name/avatar come from the profiles!author_id join, not flat columns.

private struct WorkItemCommentRow: Decodable {
    let id: UUID
    let workItemId: UUID
    let authorId: UUID
    let text: String
    let createdAt: Date
    let profiles: AuthorInfo?

    enum CodingKeys: String, CodingKey {
        case id
        case workItemId = "work_item_id"
        case authorId = "author_id"
        case text
        case createdAt = "created_at"
        case profiles
    }

    struct AuthorInfo: Decodable {
        let name: String?
        let avatarUrl: String?
        enum CodingKeys: String, CodingKey {
            case name = "display_name"
            case avatarUrl = "avatar_url"
        }
    }

    func toComment(mentions: [UUID]) -> WorkItemComment {
        WorkItemComment(
            id: id,
            workItemId: workItemId,
            authorId: authorId,
            authorName: profiles?.name ?? "Member",
            authorAvatarUrl: profiles?.avatarUrl,
            text: text,
            mentions: mentions,
            createdAt: createdAt
        )
    }
}
