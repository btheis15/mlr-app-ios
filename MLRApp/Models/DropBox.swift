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
    /// Newest-first (falls back to upload time — captured-at EXIF sorting is
    /// a web-only refinement, migration 0174, not mirrored here).
    var sortedItems: [DropBoxMedia] { items.sorted { $0.createdAt > $1.createdAt } }
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
    let createdAt: Date

    var isVideo: Bool { mediaType == "video" }
    /// The url the grid should render — the small preview when we have one.
    var displayUrl: String { thumbnailUrl ?? url }
}
