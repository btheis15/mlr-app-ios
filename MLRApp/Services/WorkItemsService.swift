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

    // MARK: - Fetch

    /// All work items, open first then done (newest-first within each group).
    func fetchItems() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let rows: [WorkItem] = try await supabase
                .from("work_items")
                .select("*")
                .order("status", ascending: true)        // 'done' sorts after 'open'
                .order("created_at", ascending: false)
                .execute()
                .value
            items = rows
        } catch {
            self.error = "Couldn't load the work checklist."
            print("[WorkItemsService] fetchItems error: \(error)")
        }
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

    /// Create a new item (any signed-in member). Returns the new item id.
    @discardableResult
    func createItem(title: String, notes: String?, category: String?, peopleNeeded: Int?) async throws -> UUID {
        struct CreateParams: Encodable {
            let p_title: String
            let p_notes: String?
            let p_category: String?
            let p_people_needed: Int?
        }
        let id: UUID = try await supabase
            .rpc("create_work_item", params: CreateParams(
                p_title: title, p_notes: notes, p_category: category, p_people_needed: peopleNeeded
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

    /// Edit an item's fields + status (admin only).
    func updateItem(id: UUID, title: String, notes: String?, category: String?, status: WorkItemStatus, peopleNeeded: Int?) async throws {
        struct UpdateParams: Encodable {
            let p_id: String
            let p_title: String
            let p_notes: String?
            let p_category: String?
            let p_status: String
            let p_people_needed: Int?
        }
        try await supabase
            .rpc("update_work_item", params: UpdateParams(
                p_id: id.uuidString, p_title: title, p_notes: notes,
                p_category: category, p_status: status.rawValue, p_people_needed: peopleNeeded
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
}

// MARK: - Private row type for event_work_items join

private struct EventWorkItemRow: Decodable {
    let workItem: WorkItem?
    enum CodingKeys: String, CodingKey {
        case workItem = "work_items"
    }
}
