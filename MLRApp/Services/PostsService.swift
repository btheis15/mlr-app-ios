import Foundation
import Supabase

private let postStorageBase = "https://vrksrpzlslrcjvbzchfg.supabase.co/storage/v1/object/public/post-photos"

// MARK: - PostsService

@Observable
@MainActor
final class PostsService {
    var posts: [Post] = []
    var isLoading: Bool = false
    var error: String? = nil

    private var realtimeChannel: RealtimeChannelV2? = nil

    /// Posts select with author, media, and tags joins (matches web PostsView).
    static let postSelect = """
        id, author_id, text, image_path, status, created_at, occurred_at,
        profiles!author_id(display_name, avatar_url),
        post_media(storage_path, media_type, position),
        post_tags(tagged_user_id, profiles!tagged_user_id(display_name))
        """

    // MARK: - Fetch

    /// Load posts joined with author name/avatar.
    /// Returns visible posts, plus the current user's own pending/hidden posts.
    func fetchPosts(userId: UUID?) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let rows: [PostRow] = try await supabase
                .from("posts")
                .select(Self.postSelect)
                .order("occurred_at", ascending: false)
                .execute()
                .value
            posts = rows.map(\.toPost)
        } catch {
            self.error = "Couldn't load posts."
            print("[PostsService] fetchPosts error: \(error)")
        }
    }

    // MARK: - Create

    /// Create a post with optional media (in order), tagged members, and a
    /// backdated timeline anchor. `media` entries are (storagePath, mediaType).
    func createPost(
        text: String?,
        authorId: UUID,
        media: [(path: String, type: String)] = [],
        tagIds: [UUID] = [],
        occurredAt: Date? = nil
    ) async throws {
        struct NewPostId: Decodable { let id: UUID }
        var params: [String: AnyJSON] = [
            "author_id": .string(authorId.uuidString),
            "status":    .string("visible")
        ]
        if let text, !text.isEmpty { params["text"] = .string(text) }
        if let occurredAt {
            params["occurred_at"] = .string(ISO8601DateFormatter().string(from: occurredAt))
        }

        let created: NewPostId = try await supabase
            .from("posts")
            .insert(params)
            .select("id")
            .single()
            .execute()
            .value

        if !media.isEmpty {
            let rows: [[String: AnyJSON]] = media.enumerated().map { idx, m in
                [
                    "post_id": .string(created.id.uuidString),
                    "storage_path": .string(m.path),
                    "media_type": .string(m.type),
                    "position": .integer(idx)
                ]
            }
            try await supabase.from("post_media").insert(rows).execute()
        }

        if !tagIds.isEmpty {
            let rows: [[String: AnyJSON]] = tagIds.map {
                ["post_id": .string(created.id.uuidString), "tagged_user_id": .string($0.uuidString)]
            }
            try await supabase.from("post_tags").insert(rows).execute()
        }

        await fetchPosts(userId: authorId)
    }

    /// Edit a post's caption + timeline date (author or admin; RLS enforces).
    func updatePost(id: UUID, text: String?, occurredAt: Date?) async throws {
        var params: [String: AnyJSON] = [
            "text": text.flatMap { $0.isEmpty ? nil : $0 }.map(AnyJSON.string) ?? .null
        ]
        if let occurredAt {
            params["occurred_at"] = .string(ISO8601DateFormatter().string(from: occurredAt))
        }
        try await supabase
            .from("posts")
            .update(params)
            .eq("id", value: id.uuidString)
            .execute()
        await fetchPosts(userId: nil)
    }

    // MARK: - Comments

    func fetchComments(postId: UUID) async throws -> [PostComment] {
        let rows: [PostCommentRow] = try await supabase
            .from("post_comments")
            .select("""
                id, post_id, author_id, text, status, created_at,
                profiles!author_id(display_name, avatar_url)
            """)
            .eq("post_id", value: postId.uuidString)
            .order("created_at", ascending: true)
            .execute()
            .value
        return rows.map(\.toComment)
    }

    func addComment(postId: UUID, text: String, authorId: UUID, mentionedIds: [UUID] = []) async throws -> PostComment {
        let params: [String: AnyJSON] = [
            "post_id":   .string(postId.uuidString),
            "author_id": .string(authorId.uuidString),
            "text":      .string(text),
            "status":    .string("visible")
        ]
        let row: PostCommentRow = try await supabase
            .from("post_comments")
            .insert(params)
            .select("""
                id, post_id, author_id, text, status, created_at,
                profiles!author_id(display_name, avatar_url)
            """)
            .single()
            .execute()
            .value

        // Record who was @mentioned so the server can notify them (post_comment_mentions).
        if !mentionedIds.isEmpty {
            let rows: [[String: AnyJSON]] = mentionedIds.map {
                ["comment_id": .string(row.id.uuidString), "mentioned_user_id": .string($0.uuidString)]
            }
            try? await supabase.from("post_comment_mentions").insert(rows).execute()
        }
        return row.toComment
    }

    // MARK: - Reactions

    func addReaction(postId: UUID, emoji: String, userId: UUID) async throws {
        let params: [String: AnyJSON] = [
            "post_id": .string(postId.uuidString),
            "user_id": .string(userId.uuidString),
            "emoji":   .string(emoji)
        ]
        // PK is (post_id, user_id) — one reaction per user per post; upserting
        // switches the emoji rather than adding a second row.
        try await supabase
            .from("post_reactions")
            .upsert(params, onConflict: "post_id,user_id")
            .execute()
    }

    func removeReaction(postId: UUID, emoji: String, userId: UUID) async throws {
        try await supabase
            .from("post_reactions")
            .delete()
            .eq("post_id", value: postId.uuidString)
            .eq("user_id", value: userId.uuidString)
            .eq("emoji", value: emoji)
            .execute()
    }

    func fetchReactions(postId: UUID) async throws -> [PostReaction] {
        let reactions: [PostReaction] = try await supabase
            .from("post_reactions")
            .select("*")
            .eq("post_id", value: postId.uuidString)
            .execute()
            .value
        return reactions
    }

    // MARK: - Reporting

    func reportContent(targetType: String, targetId: UUID, reason: String?) async throws {
        struct ReportParams: Encodable {
            let p_entity_type: String
            let p_entity_id: String
            let p_reason: String?
        }
        try await supabase
            .rpc("report_content", params: ReportParams(
                p_entity_type: targetType,
                p_entity_id: targetId.uuidString,
                p_reason: reason
            ))
            .execute()
    }

    // MARK: - Realtime

    func subscribeToRealtime() {
        guard realtimeChannel == nil else { return }
        let channel = supabase.channel("posts-feed")
        realtimeChannel = channel

        Task {
            channel.onPostgresChange(InsertAction.self, schema: "public", table: "posts") { [weak self] action in
                guard let self else { return }
                Task { @MainActor in
                    let record = action.record
                    guard let idStr = record["id"]?.stringValue,
                          let id = UUID(uuidString: idStr)
                    else { return }
                    if let row: PostRow = try? await supabase
                        .from("posts")
                        .select(Self.postSelect)
                        .eq("id", value: id.uuidString)
                        .single()
                        .execute()
                        .value
                    {
                        let post = row.toPost
                        if !self.posts.contains(where: { $0.id == post.id }) {
                            self.posts.insert(post, at: 0)
                        }
                    }
                }
            }
            // Comments and reactions change the counts shown on each card — reload
            // the feed when they change, matching the web `posts-feed` channel.
            for table in ["post_comments", "post_reactions", "post_media", "post_tags"] {
                channel.onPostgresChange(AnyAction.self, schema: "public", table: table) { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor in await self.fetchPosts(userId: nil) }
                }
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

// MARK: - Row shapes for joined selects

private struct PostCommentRow: Decodable {
    let id: UUID
    let postId: UUID
    let authorId: UUID
    let text: String
    let status: ContentStatus
    let createdAt: Date
    let profiles: PostRow.AuthorInfo?

    enum CodingKeys: String, CodingKey {
        case id
        case postId = "post_id"
        case authorId = "author_id"
        case text, status
        case createdAt = "created_at"
        case profiles
    }

    var toComment: PostComment {
        PostComment(
            id: id,
            postId: postId,
            authorId: authorId,
            authorName: profiles?.name ?? "Member",
            authorAvatarUrl: profiles?.avatarUrl,
            text: text,
            status: status,
            createdAt: createdAt
        )
    }
}

private struct PostRow: Decodable {
    let id: UUID
    let authorId: UUID
    let text: String?
    let imageUrl: String?
    let status: ContentStatus
    let createdAt: Date
    let occurredAt: Date?
    let profiles: AuthorInfo?
    let postMedia: [PostMediaRow]?
    let postTags: [PostTagRow]?

    enum CodingKeys: String, CodingKey {
        case id
        case authorId = "author_id"
        case text
        case imageUrl = "image_path"
        case status
        case createdAt = "created_at"
        case occurredAt = "occurred_at"
        case profiles
        case postMedia = "post_media"
        case postTags = "post_tags"
    }

    struct AuthorInfo: Decodable {
        let name: String?
        let avatarUrl: String?
        enum CodingKeys: String, CodingKey {
            case name = "display_name"
            case avatarUrl = "avatar_url"
        }
    }

    struct PostTagRow: Decodable {
        let taggedUserId: UUID
        let profiles: AuthorInfo?
        enum CodingKeys: String, CodingKey {
            case taggedUserId = "tagged_user_id"
            case profiles
        }
    }

    struct PostMediaRow: Decodable {
        let storagePath: String
        let mediaType: String?
        let position: Int?
        enum CodingKeys: String, CodingKey {
            case storagePath = "storage_path"
            case mediaType = "media_type"
            case position
        }
        // Full URL: media server paths already start with http;
        // Supabase Storage paths need the public URL base prepended.
        var resolvedUrl: String {
            storagePath.hasPrefix("http") ? storagePath : "\(postStorageBase)/\(storagePath)"
        }
    }

    /// All media URLs in position order (legacy image_path as a fallback).
    var resolvedMediaUrls: [String] {
        if let media = postMedia, !media.isEmpty {
            return media.sorted { ($0.position ?? 0) < ($1.position ?? 0) }.map(\.resolvedUrl)
        }
        if let imageUrl { return [imageUrl] }
        return []
    }

    var toPost: Post {
        let urls = resolvedMediaUrls
        return Post(
            id: id,
            authorId: authorId,
            authorName: profiles?.name ?? "Member",
            authorAvatarUrl: profiles?.avatarUrl,
            text: text,
            imageUrl: urls.first,
            mediaUrls: urls,
            tags: (postTags ?? []).map { PostTag(id: $0.taggedUserId, name: $0.profiles?.name ?? "Member") },
            status: status,
            occurredAt: occurredAt,
            createdAt: createdAt
        )
    }
}
