import Foundation
import Supabase

// MARK: - House Lists (migration 0169)
//
// Shared lists for a house, mirroring lib/houseLists.ts: ANY member can create a
// list and add/check/edit/delete ANY item on it — a shared scratchpad, not a
// per-person to-do (house work items, 0066, remain that surface). No
// notifications by design; kept live by Realtime while a screen is open.

extension HousesService {

    /// Every list on a house, items included — one round-trip via the nested
    /// embed. Newest lists first (create_house_list assigns min(position) - 1).
    func fetchLists(houseId: UUID) async -> [HouseList] {
        do {
            let rows: [HouseListRow] = try await supabase
                .from("house_lists")
                .select("""
                    id, house_id, title, emoji, note, position, created_by, created_at, updated_at,
                    author:created_by(display_name),
                    house_list_items(id, list_id, text, checked_at, checked_by, created_by, created_at,
                                      checker:checked_by(display_name))
                """)
                .eq("house_id", value: houseId.uuidString)
                .order("position", ascending: true)
                .order("created_at", ascending: false)
                .execute()
                .value
            return rows.map(\.toList)
        } catch {
            print("[HousesService] fetchLists error: \(error)")
            return []
        }
    }

    /// Start a new list. Any member of the house. Returns the new list's id.
    @discardableResult
    func createList(houseId: UUID, title: String, emoji: String = "📝", note: String? = nil) async throws -> UUID {
        struct P: Encodable { let p_house: String; let p_title: String; let p_emoji: String; let p_note: String? }
        let id: UUID = try await supabase
            .rpc("create_house_list", params: P(p_house: houseId.uuidString, p_title: title, p_emoji: emoji, p_note: note))
            .execute().value
        return id
    }

    /// Rename / re-emoji a list. Any member of its house.
    func updateList(id: UUID, title: String, emoji: String? = nil, note: String? = nil) async throws {
        struct P: Encodable { let p_id: String; let p_title: String; let p_emoji: String?; let p_note: String? }
        try await supabase
            .rpc("update_house_list", params: P(p_id: id.uuidString, p_title: title, p_emoji: emoji, p_note: note))
            .execute()
    }

    /// Delete a list and its items. Any member of its house.
    func deleteList(id: UUID) async throws {
        struct P: Encodable { let p_id: String }
        try await supabase.rpc("delete_house_list", params: P(p_id: id.uuidString)).execute()
    }

    /// Add an item to the end of a list. Any member of its house.
    @discardableResult
    func addListItem(listId: UUID, text: String) async throws -> UUID {
        struct P: Encodable { let p_list: String; let p_text: String }
        let id: UUID = try await supabase
            .rpc("add_house_list_item", params: P(p_list: listId.uuidString, p_text: text))
            .execute().value
        return id
    }

    /// Edit an item's text. Any member of its house.
    func updateListItem(id: UUID, text: String) async throws {
        struct P: Encodable { let p_id: String; let p_text: String }
        try await supabase.rpc("update_house_list_item", params: P(p_id: id.uuidString, p_text: text)).execute()
    }

    /// Check / uncheck an item (stamps who + when). Any member of its house.
    func setListItemChecked(id: UUID, checked: Bool) async throws {
        struct P: Encodable { let p_id: String; let p_checked: Bool }
        try await supabase.rpc("set_house_list_item_checked", params: P(p_id: id.uuidString, p_checked: checked)).execute()
    }

    /// Delete one item. Any member of its house.
    func deleteListItem(id: UUID) async throws {
        struct P: Encodable { let p_id: String }
        try await supabase.rpc("delete_house_list_item", params: P(p_id: id.uuidString)).execute()
    }

    /// Sweep every checked item off a list ("we're home from the store").
    /// Returns how many were cleared. Any member of its house.
    @discardableResult
    func clearCheckedListItems(listId: UUID) async throws -> Int {
        struct P: Encodable { let p_list: String }
        let n: Int = try await supabase
            .rpc("clear_checked_house_list_items", params: P(p_list: listId.uuidString))
            .execute().value
        return n
    }

    /// Uncheck everything, to reuse a recurring checklist next trip.
    @discardableResult
    func uncheckListItems(listId: UUID) async throws -> Int {
        struct P: Encodable { let p_list: String }
        let n: Int = try await supabase
            .rpc("uncheck_house_list_items", params: P(p_list: listId.uuidString))
            .execute().value
        return n
    }

    /// Live-update a house's lists — two people at the store both see items
    /// check off. Fires on any change to either table for this house.
    func subscribeToLists(houseId: UUID, onChange: @escaping () -> Void) {
        guard listChannels[houseId] == nil else { return }
        let channel = supabase.channel("house-lists-\(houseId.uuidString)")
        listChannels[houseId] = channel
        Task {
            channel.onPostgresChange(
                AnyAction.self, schema: "public", table: "house_lists",
                filter: "house_id=eq.\(houseId.uuidString)"
            ) { _ in Task { @MainActor in onChange() } }
            channel.onPostgresChange(
                AnyAction.self, schema: "public", table: "house_list_items",
                filter: "house_id=eq.\(houseId.uuidString)"
            ) { _ in Task { @MainActor in onChange() } }
            await channel.subscribe()
        }
    }

    func unsubscribeFromLists(houseId: UUID) {
        guard let channel = listChannels[houseId] else { return }
        Task {
            await supabase.removeChannel(channel)
            listChannels.removeValue(forKey: houseId)
        }
    }
}

// MARK: - Decode rows

private struct HouseListRow: Decodable {
    let id: UUID
    let houseId: UUID
    let title: String
    let emoji: String?
    let note: String?
    let position: Int
    let createdBy: UUID
    let createdAt: Date
    let updatedAt: Date
    let author: Author?
    let houseListItems: [HouseListItemRow]?

    enum CodingKeys: String, CodingKey {
        case id, title, emoji, note, position, author
        case houseId = "house_id"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case houseListItems = "house_list_items"
    }

    struct Author: Decodable { let displayName: String?
        enum CodingKeys: String, CodingKey { case displayName = "display_name" } }

    var toList: HouseList {
        HouseList(
            id: id, houseId: houseId, title: title,
            emoji: (emoji?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? "📝",
            note: note, position: position, createdBy: createdBy,
            authorName: author?.displayName ?? "Member",
            createdAt: createdAt, updatedAt: updatedAt,
            items: (houseListItems ?? []).map(\.toItem)
        )
    }
}

private struct HouseListItemRow: Decodable {
    let id: UUID
    let listId: UUID
    let text: String
    let checkedAt: Date?
    let checkedBy: UUID?
    let createdBy: UUID
    let createdAt: Date
    let checker: Checker?

    enum CodingKeys: String, CodingKey {
        case id, text, checker
        case listId = "list_id"
        case checkedAt = "checked_at"
        case checkedBy = "checked_by"
        case createdBy = "created_by"
        case createdAt = "created_at"
    }

    struct Checker: Decodable { let displayName: String?
        enum CodingKeys: String, CodingKey { case displayName = "display_name" } }

    var toItem: HouseListItem {
        HouseListItem(
            id: id, listId: listId, text: text, checkedAt: checkedAt, checkedBy: checkedBy,
            checkedByName: checker?.displayName, createdBy: createdBy, createdAt: createdAt
        )
    }
}
