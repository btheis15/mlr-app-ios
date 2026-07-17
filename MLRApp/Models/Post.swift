import Foundation

// MARK: - Post

struct Post: Identifiable, Equatable {
    let id: UUID
    let authorId: UUID
    var authorName: String
    var authorAvatarUrl: String?
    var text: String?
    var imageUrl: String?          // first media / legacy image_path
    var mediaUrls: [String]        // all media, in order (carousel)
    var mediaIsVideo: [Bool] = []  // parallel to mediaUrls — from post_media.media_type
    var tags: [PostTag]            // tagged members
    var status: ContentStatus
    var occurredAt: Date?          // timeline anchor (backdated); falls back to createdAt
    var createdAt: Date

    /// The date the post sits at in the timeline.
    var timelineDate: Date { occurredAt ?? createdAt }

    /// Whether the media item at `index` is a video — using the authoritative
    /// `media_type` when known, falling back to the URL extension for legacy rows.
    /// Guessing from the URL alone is unreliable (media-server / query-string URLs
    /// carry no extension), which made videos load as images and spin forever.
    func isVideo(at index: Int) -> Bool {
        if index >= 0, index < mediaIsVideo.count { return mediaIsVideo[index] }
        if index >= 0, index < mediaUrls.count { return mediaUrls[index].isVideoURL }
        return false
    }
}

// A member tagged in a post (post_tags).
struct PostTag: Identifiable, Equatable {
    let id: UUID        // tagged_user_id
    let name: String
}

extension String {
    /// Whether this media URL points at a video (the Mac-mini media server
    /// transcodes uploads to .mp4). Used to pick VideoPlayer vs image rendering.
    var isVideoURL: Bool {
        let lower = (self as NSString).pathExtension.lowercased()
        return ["mp4", "mov", "m4v"].contains(lower)
    }
}

// MARK: - Post Comment

struct PostComment: Codable, Identifiable, Equatable {
    let id: UUID
    let postId: UUID
    let authorId: UUID
    var authorName: String
    var authorAvatarUrl: String?
    var text: String
    var status: ContentStatus
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case postId = "post_id"
        case authorId = "author_id"
        case authorName = "author_name"
        case authorAvatarUrl = "author_avatar_url"
        case text
        case status
        case createdAt = "created_at"
    }
}

// MARK: - Reaction

struct PostReaction: Codable, Identifiable, Equatable {
    // post_reactions has a composite PK (post_id, user_id) and no `id` column,
    // so identity is derived from those two — one reaction per user per post.
    let postId: UUID
    let userId: UUID
    var emoji: String
    var createdAt: Date

    var id: String { "\(postId.uuidString)-\(userId.uuidString)" }

    enum CodingKeys: String, CodingKey {
        case postId = "post_id"
        case userId = "user_id"
        case emoji
        case createdAt = "created_at"
    }
}

// MARK: - Post Reactor (who reacted, with name)

struct PostReactor: Identifiable, Equatable {
    let userId: UUID
    let name: String
    let emoji: String
    var id: String { "\(userId.uuidString)-\(emoji)" }
}

// MARK: - Content Status

enum ContentStatus: String, Codable {
    case visible
    case pending
    case hidden
}

// MARK: - Content Report

struct ContentReport: Codable, Identifiable {
    let id: UUID
    let reporterId: UUID
    let targetType: String
    let targetId: UUID
    var reason: String?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case reporterId = "reporter_id"
        case targetType = "target_type"
        case targetId = "target_id"
        case reason
        case createdAt = "created_at"
    }
}
