import Foundation

// MARK: - House List (migration 0169)
//
// A shared, flexible list for a house — a grocery run, a cabin close-up
// checklist, a packing list. ONE shape deliberately: a title + checkable
// items, so a shopping list and a checklist are the same thing. ANY member of
// the house can create a list and add/check/edit/delete ANY item on it (a
// shared scratchpad, not a per-person to-do — that's work items, 0066).
//
// Built in HouseListsService from a row + the profiles join (author/checker
// name), mirroring HouseStay — not decoded directly.

struct HouseList: Identifiable, Equatable {
    let id: UUID
    let houseId: UUID
    var title: String
    var emoji: String
    var note: String?
    var position: Int
    let createdBy: UUID
    var authorName: String
    let createdAt: Date
    var updatedAt: Date
    var items: [HouseListItem]

    /// "3 of 8" progress.
    var progress: (done: Int, total: Int) {
        (items.filter { $0.checkedAt != nil }.count, items.count)
    }

    /// The one-line summary shown collapsed / on the Hub tile.
    var summary: String {
        let (done, total) = progress
        if total == 0 { return "Empty — add the first item" }
        if done == total { return "All \(total) done" }
        return "\(done) of \(total) done"
    }

    /// Items ordered the way the list reads: open first (in add order), checked
    /// ones settle to the bottom — so an optimistic check re-sorts in place.
    var sortedItems: [HouseListItem] {
        items.sorted { a, b in
            let ac = a.checkedAt != nil, bc = b.checkedAt != nil
            if ac != bc { return !ac }
            return a.createdAt < b.createdAt
        }
    }
}

struct HouseListItem: Identifiable, Equatable {
    let id: UUID
    let listId: UUID
    var text: String
    var checkedAt: Date?
    var checkedBy: UUID?
    var checkedByName: String?
    let createdBy: UUID
    let createdAt: Date

    var isChecked: Bool { checkedAt != nil }
}
