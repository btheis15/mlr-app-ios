import Foundation
import SwiftUI
import Supabase

private let postStorageBase = "https://vrksrpzlslrcjvbzchfg.supabase.co/storage/v1/object/public/post-photos"

// MARK: - PostsService

@Observable
@MainActor
final class PostsService {
    var posts: [Post] = []
    var isLoading: Bool = false
    var error: String? = nil

    /// Posts per page of the main feed.
    static let pageSize = 20
    /// More (older) pages may exist on the server.
    private(set) var hasMore: Bool = true
    private(set) var isLoadingMore: Bool = false
    /// When the first page last loaded successfully (nil = never this launch).
    private(set) var lastRefreshAt: Date? = nil
    /// Bumped after every completed fetch/page so the view can refresh reactions.
    private(set) var dataVersion: Int = 0
    /// Set by the feed view while the reader is scrolled away from the top: new
    /// posts from other people then wait in `pendingNewPosts` instead of
    /// shoving the list down.
    var holdNewPosts: Bool = false
    private(set) var pendingNewPosts: [Post] = []

    private var realtimeChannel: RealtimeChannelV2? = nil
    private var inFlight = 0
    private var refreshDebounce: Task<Void, Never>? = nil

    /// Posts select with author, media, and tags joins (matches web PostsView).
    static let postSelect = """
        id, author_id, text, image_path, status, created_at, occurred_at,
        profiles!author_id(display_name, avatar_url),
        post_media(storage_path, media_type, position),
        post_tags(tagged_user_id, profiles!tagged_user_id(display_name))
        """

    // MARK: - Fetch

    /// Load page one (newest posts) joined with author name/avatar and merge it
    /// into `posts` in place: changed posts update, vanished ones drop, already
    /// loaded older pages stay. RLS decides visibility (visible posts, plus the
    /// current user's own pending/hidden ones).
    /// `holdNew`: park genuinely new posts in `pendingNewPosts` (realtime
    /// refreshes while the reader is mid-scroll) instead of inserting them.
    func fetchPosts(userId: UUID?, holdNew: Bool = false) async {
        inFlight += 1
        isLoading = true
        error = nil
        defer { inFlight -= 1; isLoading = inFlight > 0 }
        do {
            let rows: [PostRow] = try await supabase
                .from("posts")
                .select(Self.postSelect)
                .order("occurred_at", ascending: false)
                .order("id", ascending: false)
                .range(from: 0, to: Self.pageSize - 1)
                .execute()
                .value
            applyFirstPage(rows.map(\.toPost), holdNew: holdNew)
            lastRefreshAt = .now
            dataVersion += 1
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
            self.error = "Couldn't load posts."
            print("[PostsService] fetchPosts error: \(error)")
        }
    }

    /// Load the next (older) page. Guarded against duplicate requests; stops
    /// for good when a short page comes back.
    func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading, !posts.isEmpty else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        // Pending posts sort above everything loaded, so they shift the server
        // offset even though they aren't in `posts` yet.
        let from = posts.count + pendingNewPosts.count
        do {
            let rows: [PostRow] = try await supabase
                .from("posts")
                .select(Self.postSelect)
                .order("occurred_at", ascending: false)
                .order("id", ascending: false)
                .range(from: from, to: from + Self.pageSize - 1)
                .execute()
                .value
            let known = Set(posts.map(\.id)).union(pendingNewPosts.map(\.id))
            let fresh = rows.map(\.toPost).filter { !known.contains($0.id) }
            if !fresh.isEmpty { posts.append(contentsOf: fresh) }
            if rows.count < Self.pageSize { hasMore = false }
            dataVersion += 1
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
            print("[PostsService] loadMore error: \(error)")
        }
    }

    /// Seed from a disk snapshot (instant paint). Only when nothing is loaded.
    func seed(from snapshot: [Post]) {
        guard posts.isEmpty, !snapshot.isEmpty else { return }
        posts = snapshot
        hasMore = snapshot.count >= Self.pageSize
    }

    /// Merge a fresh page one into the loaded list without replacing it wholesale.
    private func applyFirstPage(_ page: [Post], holdNew: Bool) {
        let pageIds = Set(page.map(\.id))
        let existingIds = Set(posts.map(\.id))
        let short = page.count < Self.pageSize

        // A deliberate refresh shows everything, including what was waiting.
        if !holdNew { pendingNewPosts = [] }
        // Genuinely new posts (not loaded, not already waiting).
        var visiblePage = page
        if holdNew {
            let waiting = Set(pendingNewPosts.map(\.id))
            let held = page.filter { !existingIds.contains($0.id) && !waiting.contains($0.id) }
            if !held.isEmpty, !posts.isEmpty {
                visiblePage.removeAll { p in held.contains { $0.id == p.id } }
                pendingNewPosts = (held + pendingNewPosts).sorted { $0.timelineDate > $1.timelineDate }
            }
        }

        // Older, already-loaded posts beyond the page stay put.
        var tail: [Post] = []
        if !short, let boundary = page.last?.timelineDate {
            tail = posts.filter { !pageIds.contains($0.id) && $0.timelineDate < boundary }
        }
        let merged = visiblePage.filter { p in !pendingNewPosts.contains { $0.id == p.id } } + tail
        let hadMore = hasMore
        hasMore = short ? false : (tail.isEmpty ? true : hadMore)
        if merged != posts {
            posts = merged
        }
    }

    /// Reveal posts that arrived while the reader was scrolled away.
    func revealPending() {
        guard !pendingNewPosts.isEmpty else { return }
        let known = Set(posts.map(\.id))
        let add = pendingNewPosts.filter { !known.contains($0.id) }
        pendingNewPosts = []
        posts.insert(contentsOf: add, at: 0)
    }

    /// One post by id, joined the same way the feed is. Used by the notification
    /// deep link — a push names a single post, which may not be in `posts` yet
    /// (or at all, if it was removed since). Returns nil rather than throwing so
    /// the caller can fall back to the feed.
    func fetchPost(id: UUID) async -> Post? {
        let row: PostRow? = try? await supabase
            .from("posts")
            .select(Self.postSelect)
            .eq("id", value: id.uuidString)
            .single()
            .execute()
            .value
        return row?.toPost
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

    /// Remove one media item from a post while editing. Accepts the display URL;
    /// strips the storage base back off since post_media stores the raw path.
    func removePostMedia(postId: UUID, displayUrl: String) async throws {
        let raw = displayUrl.hasPrefix("\(postStorageBase)/")
            ? String(displayUrl.dropFirst(postStorageBase.count + 1))
            : displayUrl
        try await supabase.from("post_media")
            .delete()
            .eq("post_id", value: postId.uuidString)
            .eq("storage_path", value: raw)
            .execute()
    }

    /// Append newly-uploaded media to an existing post (edit flow).
    func addPostMedia(postId: UUID, media: [(path: String, type: String)], startPosition: Int) async throws {
        guard !media.isEmpty else { return }
        let rows: [[String: AnyJSON]] = media.enumerated().map { idx, m in
            [
                "post_id": .string(postId.uuidString),
                "storage_path": .string(m.path),
                "media_type": .string(m.type),
                "position": .integer(startPosition + idx)
            ]
        }
        try await supabase.from("post_media").insert(rows).execute()
    }

    // MARK: - Comments

    private static let commentSelect = """
        id, post_id, author_id, text, status, created_at,
        profiles!author_id(display_name, avatar_url),
        post_comment_media(storage_path, media_type, position)
        """

    func fetchComments(postId: UUID) async throws -> [PostComment] {
        let rows: [PostCommentRow] = try await supabase
            .from("post_comments")
            .select(Self.commentSelect)
            .eq("post_id", value: postId.uuidString)
            .order("created_at", ascending: true)
            .execute()
            .value
        return rows.map(\.toComment)
    }

    /// Create a comment with optional media (in order). A photo/video-only
    /// comment (empty text) is allowed, same "text OR at least one file" rule
    /// as the post composer — the caller is responsible for enforcing that.
    func addComment(
        postId: UUID, text: String, authorId: UUID, mentionedIds: [UUID] = [],
        media: [(path: String, type: String)] = []
    ) async throws -> PostComment {
        let params: [String: AnyJSON] = [
            "post_id":   .string(postId.uuidString),
            "author_id": .string(authorId.uuidString),
            "text":      .string(text),
            "status":    .string("visible")
        ]
        var row: PostCommentRow = try await supabase
            .from("post_comments")
            .insert(params)
            .select(Self.commentSelect)
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

        // Attachments (0162), same pipeline as a post's media — the caller has
        // already uploaded each file to the mini under the default "posts"
        // category (inline-moderated), so this just records the rows.
        if !media.isEmpty {
            let mediaRows: [[String: AnyJSON]] = media.enumerated().map { idx, m in
                [
                    "comment_id":   .string(row.id.uuidString),
                    "storage_path": .string(m.path),
                    "media_type":   .string(m.type),
                    "position":     .integer(idx)
                ]
            }
            try await supabase.from("post_comment_media").insert(mediaRows).execute()
            row = try await supabase
                .from("post_comments")
                .select(Self.commentSelect)
                .eq("id", value: row.id.uuidString)
                .single()
                .execute()
                .value
        }
        return row.toComment
    }

    /// Delete a comment (author within the edit window, or admin — enforced by
    /// RLS). Hard delete, matching the web PostsView.
    func deleteComment(commentId: UUID) async throws {
        try await supabase
            .from("post_comments")
            .delete()
            .eq("id", value: commentId.uuidString)
            .execute()
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

    /// Who reacted, with display names (joined) — for the tap-to-expand reactor
    /// list under a post's reaction row. Mirrors chat's who-reacted affordance.
    func fetchReactors(postId: UUID) async -> [PostReactor] {
        struct Row: Decodable {
            let userId: UUID
            let emoji: String
            let profiles: P?
            struct P: Decodable {
                let name: String?
                enum CodingKeys: String, CodingKey { case name = "display_name" }
            }
            enum CodingKeys: String, CodingKey {
                case userId = "user_id"
                case emoji, profiles
            }
        }
        do {
            let rows: [Row] = try await supabase
                .from("post_reactions")
                .select("user_id, emoji, profiles!user_id(display_name)")
                .eq("post_id", value: postId.uuidString)
                .execute()
                .value
            return rows.map { PostReactor(userId: $0.userId, name: $0.profiles?.name ?? "Member", emoji: $0.emoji) }
        } catch {
            print("[PostsService] fetchReactors error: \(error)")
            return []
        }
    }

    /// Reactions for many posts in ONE query per chunk (not one request per post).
    /// Every requested id is present in the result, empty when nobody reacted.
    func fetchReactions(postIds: [UUID]) async throws -> [UUID: [PostReaction]] {
        var out: [UUID: [PostReaction]] = Dictionary(uniqueKeysWithValues: postIds.map { ($0, []) })
        let chunkSize = 50
        var start = 0
        while start < postIds.count {
            let chunk = Array(postIds[start..<min(start + chunkSize, postIds.count)])
            let rows: [PostReaction] = try await supabase
                .from("post_reactions")
                .select("*")
                .in("post_id", values: chunk.map(\.uuidString))
                .execute()
                .value
            for r in rows { out[r.postId, default: []].append(r) }
            start += chunkSize
        }
        return out
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
                    guard let idStr = action.record["id"]?.stringValue,
                          let id = UUID(uuidString: idStr),
                          let post = try? await self.fetchPostRow(id: id)
                    else { return }
                    self.receiveInserted(post)
                }
            }
            channel.onPostgresChange(UpdateAction.self, schema: "public", table: "posts") { [weak self] action in
                guard let self else { return }
                Task { @MainActor in
                    guard let idStr = action.record["id"]?.stringValue,
                          let id = UUID(uuidString: idStr)
                    else { return }
                    await self.receiveUpdated(id: id)
                }
            }
            channel.onPostgresChange(DeleteAction.self, schema: "public", table: "posts") { [weak self] action in
                guard let self else { return }
                Task { @MainActor in
                    guard let idStr = action.oldRecord["id"]?.stringValue,
                          let id = UUID(uuidString: idStr)
                    else { return }
                    self.removeLocally(id: id)
                }
            }
            // Comments and reactions change the counts shown on each card — refresh
            // page one when they change (debounced; matches the web `posts-feed`
            // channel). New posts found this way respect `holdNewPosts`.
            for table in ["post_comments", "post_reactions", "post_media", "post_tags"] {
                channel.onPostgresChange(AnyAction.self, schema: "public", table: table) { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor in self.scheduleQuietRefresh() }
                }
            }
            await channel.subscribe()
        }
    }

    /// Coalesce bursts of realtime events into one quiet page-one refresh.
    private func scheduleQuietRefresh() {
        refreshDebounce?.cancel()
        refreshDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self else { return }
            await self.fetchPosts(userId: nil, holdNew: self.holdNewPosts)
        }
    }

    /// One post's joined row, or nil when it is not visible to this member.
    /// Throws on network failure so callers can tell "gone" from "offline".
    private func fetchPostRow(id: UUID) async throws -> Post? {
        let rows: [PostRow] = try await supabase
            .from("posts")
            .select(Self.postSelect)
            .eq("id", value: id.uuidString)
            .execute()
            .value
        return rows.first?.toPost
    }

    private func receiveInserted(_ post: Post) {
        guard !posts.contains(where: { $0.id == post.id }),
              !pendingNewPosts.contains(where: { $0.id == post.id })
        else { return }
        let idx = posts.firstIndex { $0.timelineDate <= post.timelineDate } ?? posts.count
        // Belongs below the loaded pages: it arrives with paging.
        if idx == posts.count, hasMore, !posts.isEmpty { return }
        if idx == 0, holdNewPosts, !posts.isEmpty {
            pendingNewPosts = ([post] + pendingNewPosts).sorted { $0.timelineDate > $1.timelineDate }
            return
        }
        withAnimation(MLRMotion.reduceMotion ? nil : MLRMotion.spring) {
            posts.insert(post, at: idx)
        }
    }

    private func receiveUpdated(id: UUID) async {
        guard posts.contains(where: { $0.id == id }) || pendingNewPosts.contains(where: { $0.id == id })
        else { return }
        let fresh: Post?
        do { fresh = try await fetchPostRow(id: id) } catch { return }  // offline: keep what we have
        guard let fresh else { removeLocally(id: id); return }          // hidden / no longer visible
        if let i = posts.firstIndex(where: { $0.id == id }), posts[i] != fresh { posts[i] = fresh }
        if let i = pendingNewPosts.firstIndex(where: { $0.id == id }) { pendingNewPosts[i] = fresh }
    }

    private func removeLocally(id: UUID) {
        pendingNewPosts.removeAll { $0.id == id }
        guard posts.contains(where: { $0.id == id }) else { return }
        withAnimation(MLRMotion.reduceMotion ? nil : MLRMotion.spring) {
            posts.removeAll { $0.id == id }
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
    let postCommentMedia: [PostRow.PostMediaRow]?

    enum CodingKeys: String, CodingKey {
        case id
        case postId = "post_id"
        case authorId = "author_id"
        case text, status
        case createdAt = "created_at"
        case profiles
        case postCommentMedia = "post_comment_media"
    }

    var toComment: PostComment {
        let media = (postCommentMedia ?? []).sorted { ($0.position ?? 0) < ($1.position ?? 0) }
        return PostComment(
            id: id,
            postId: postId,
            authorId: authorId,
            authorName: profiles?.name ?? "Member",
            authorAvatarUrl: profiles?.avatarUrl,
            text: text,
            status: status,
            createdAt: createdAt,
            mediaUrls: media.map(\.resolvedUrl),
            mediaIsVideo: media.map(\.isVideo)
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
        /// Authoritative video flag from the stored media_type; falls back to the
        /// URL extension only when media_type is absent (legacy rows).
        var isVideo: Bool { mediaType == "video" || (mediaType == nil && resolvedUrl.isVideoURL) }
    }

    /// All media in position order (legacy image_path as a fallback), each with
    /// its resolved URL + video flag.
    var resolvedMedia: [(url: String, isVideo: Bool)] {
        if let media = postMedia, !media.isEmpty {
            return media.sorted { ($0.position ?? 0) < ($1.position ?? 0) }
                .map { ($0.resolvedUrl, $0.isVideo) }
        }
        if let imageUrl { return [(imageUrl, imageUrl.isVideoURL)] }
        return []
    }

    var toPost: Post {
        let media = resolvedMedia
        return Post(
            id: id,
            authorId: authorId,
            authorName: profiles?.name ?? "Member",
            authorAvatarUrl: profiles?.avatarUrl,
            text: text,
            imageUrl: media.first?.url,
            mediaUrls: media.map(\.url),
            mediaIsVideo: media.map(\.isVideo),
            tags: (postTags ?? []).map { PostTag(id: $0.taggedUserId, name: $0.profiles?.name ?? "Member") },
            status: status,
            occurredAt: occurredAt,
            createdAt: createdAt
        )
    }

}

// MARK: - Comment reactions (migration 0223)

extension PostsService {

    /// All reactions for a set of comments in ONE query, with reactor names.
    func fetchCommentReactions(commentIds: [UUID]) async -> [CommentReaction] {
        guard !commentIds.isEmpty else { return [] }
        struct Row: Decodable {
            let commentId: UUID
            let userId: UUID
            let emoji: String
            let profiles: P?
            struct P: Decodable {
                let name: String?
                enum CodingKeys: String, CodingKey { case name = "display_name" }
            }
            enum CodingKeys: String, CodingKey {
                case commentId = "comment_id"
                case userId = "user_id"
                case emoji, profiles
            }
        }
        do {
            let rows: [Row] = try await supabase
                .from("comment_reactions")
                .select("comment_id, user_id, emoji, profiles!user_id(display_name)")
                .in("comment_id", values: commentIds.map(\.uuidString))
                .execute()
                .value
            return rows.map { CommentReaction(commentId: $0.commentId, userId: $0.userId, emoji: $0.emoji, name: $0.profiles?.name) }
        } catch {
            print("[PostsService] fetchCommentReactions error: \(error)")
            return []
        }
    }

    /// Set (or switch to) my emoji on a comment — one row per member per comment.
    func setCommentReaction(commentId: UUID, emoji: String, userId: UUID) async throws {
        let params: [String: AnyJSON] = [
            "comment_id": .string(commentId.uuidString),
            "user_id":    .string(userId.uuidString),
            "emoji":      .string(emoji)
        ]
        try await supabase
            .from("comment_reactions")
            .upsert(params, onConflict: "comment_id,user_id")
            .execute()
    }

    /// Remove my reaction (tapping the emoji I already have).
    func removeCommentReaction(commentId: UUID, userId: UUID) async throws {
        try await supabase
            .from("comment_reactions")
            .delete()
            .eq("comment_id", value: commentId.uuidString)
            .eq("user_id", value: userId.uuidString)
            .execute()
    }
}
