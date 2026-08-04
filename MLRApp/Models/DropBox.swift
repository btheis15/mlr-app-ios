import Foundation

// MARK: - Drop Box (migration 0171)
//
// A shared "just dump the photos/videos here and everyone sees them" folder —
// the app's account-free alternative to a Google Drive shared folder. Any
// signed-in member can open a box, add as many photos/videos as they want, and
// browse everything anyone else dropped in. The bytes live on the Mac-mini
// media server; these rows are just the folder + an ordered list of what's in
// it. Mirrors lib/dropBoxes.ts.

enum DropBoxMediaStatus: String, Codable {
    case visible, pending, hidden
}

struct DropBox: Identifiable, Equatable {
    let id: UUID
    var title: String
    var emoji: String?
    let createdBy: UUID
    var createdByName: String
    var archivedAt: Date?
    let createdAt: Date
    var items: [DropBoxMedia]

    var isArchived: Bool { archivedAt != nil }
    /// capturedAt-first sort (EXIF timestamp from migration 0174) falling back
    /// to upload time, newest first — mirrors web's dropBoxes.ts sort logic.
    var sortedItems: [DropBoxMedia] {
        items.sorted { a, b in
            let ta = a.capturedAt ?? a.createdAt
            let tb = b.capturedAt ?? b.createdAt
            return ta > tb
        }
    }
    var count: Int { items.count }

    func canManage(isAdmin: Bool, viewerId: UUID?) -> Bool {
        isAdmin || createdBy == viewerId
    }
}

struct DropBoxMedia: Identifiable, Equatable {
    let id: UUID
    let boxId: UUID
    var url: String
    var thumbnailUrl: String?
    var mediaType: String   // "image" | "video"
    var status: DropBoxMediaStatus
    let uploadedBy: UUID
    var uploadedByName: String
    /// EXIF capture time (migration 0174) — nil on older rows. Used for sort + display.
    var capturedAt: Date?
    /// User the photo is credited to (migration 0180) — may differ from uploader.
    var creditUserId: UUID?
    var creditUserName: String?
    let createdAt: Date

    var isVideo: Bool { mediaType == "video" }
    /// The url the grid should render — the small preview when we have one.
    var displayUrl: String { thumbnailUrl ?? url }
    /// Display name for attribution: credited user if set, otherwise uploader.
    var attributionName: String { creditUserName ?? uploadedByName }
}
