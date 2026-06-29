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

    // MARK: - Fetch

    /// Load posts joined with author name/avatar.
    /// Returns visible posts, plus the current user's own pending/hidden posts.
    func fetchPosts(userId: UUID?) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let query = supabase
                .from("posts")
                .select("""
                    id, author_id, text, image_path, status, created_at,
                    profiles!author_id(display_name, avatar_url),
                    post_media(storage_path, media_type, position)
                """)
                .order("created_at", ascending: false)

            // RLS handles filtering: visible to all, or author sees their own
            let rows: [PostRow] = try await query.execute().value
            posts = rows.map(\.toPost)
        } catch {
            self.error = "Couldn't load posts."
            print("[PostsService] fetchPosts error: \(error)")
        }
    }

    // MARK: - Create

    func createPost(text: String?, imageUrl: String?, authorId: UUID) async throws {
        var params: [String: AnyJSON] = [
            "author_id": .string(authorId.uuidString),
            "status":    .string("visible")
        ]
        if let text, !text.isEmpty { params["text"] = .string(text) }
        if let imageUrl             { params["image_path"] = .string(imageUrl) }

        let row: PostRow = try await supabase
            .from("posts")
            .insert(params)
            .select("""
                id, author_id, text, image_path, status, created_at,
                profiles!author_id(display_name, avatar_url)
            """)
            .single()
            .execute()
            .value
        posts.insert(row.toPost, at: 0)
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

    func addComment(postId: UUID, text: String, authorId: UUID) async throws -> PostComment {
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
                        .select("""
                            id, author_id, text, image_path, status, created_at,
                            profiles!author_id(display_name, avatar_url)
                        """)
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
    let profiles: AuthorInfo?
    let postMedia: [PostMediaRow]?

    enum CodingKeys: String, CodingKey {
        case id
        case authorId = "author_id"
        case text
        case imageUrl = "image_path"
        case status
        case createdAt = "created_at"
        case profiles
        case postMedia = "post_media"
    }

    struct AuthorInfo: Decodable {
        let name: String?
        let avatarUrl: String?
        enum CodingKeys: String, CodingKey {
            case name = "display_name"
            case avatarUrl = "avatar_url"
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

    var resolvedImageUrl: String? {
        // Prefer the first post_media image over the legacy image_path column.
        if let media = postMedia, !media.isEmpty {
            let sorted = media.sorted { ($0.position ?? 0) < ($1.position ?? 0) }
            return sorted.first?.resolvedUrl
        }
        return imageUrl
    }

    var toPost: Post {
        Post(
            id: id,
            authorId: authorId,
            authorName: profiles?.name ?? "Member",
            authorAvatarUrl: profiles?.avatarUrl,
            text: text,
            imageUrl: resolvedImageUrl,
            status: status,
            createdAt: createdAt
        )
    }
}
