import Foundation
import Supabase

// MARK: - CommentsLiveChannel
// Realtime for ONE open comments sheet. Same channel pattern as PostsService's
// "posts-feed" channel (and EventChat): build the channel, register the
// postgres-change handlers inside a Task, then subscribe; tear down with
// `supabase.removeChannel`. The handlers only report WHAT changed — the sheet
// merges (never wholesale reloads), so optimistic rows and in-flight reaction
// toggles are not clobbered.
//
// Created per sheet (not per post) so nothing leaks past dismiss: the sheet
// calls `stop()` from `onDisappear`.

@MainActor
final class CommentsLiveChannel {
    private var channel: RealtimeChannelV2?

    /// - onCommentsChanged: a comment (or one of its attachments) for this post
    ///   was inserted/updated, so the sheet should fetch and merge.
    /// - onCommentDeleted: a comment row was deleted (id from the old record;
    ///   realtime cannot filter DELETEs by post_id, so the sheet checks
    ///   membership).
    /// - onReactionChanged: a `comment_reactions` row changed for this comment id.
    func start(
        postId: UUID,
        onCommentsChanged: @escaping @MainActor () -> Void,
        onCommentDeleted: @escaping @MainActor (UUID) -> Void,
        onReactionChanged: @escaping @MainActor (UUID) -> Void
    ) {
        guard channel == nil else { return }
        let ch = supabase.channel("post-comments-\(postId.uuidString)")
        channel = ch

        Task {
            ch.onPostgresChange(
                AnyAction.self,
                schema: "public",
                table: "post_comments",
                filter: "post_id=eq.\(postId.uuidString)"
            ) { _ in
                Task { @MainActor in onCommentsChanged() }
            }
            // DELETE payloads carry only the primary key, so the post_id filter
            // above never matches them — listen table-wide for deletes.
            ch.onPostgresChange(DeleteAction.self, schema: "public", table: "post_comments") { action in
                guard let idStr = action.oldRecord["id"]?.stringValue,
                      let id = UUID(uuidString: idStr) else { return }
                Task { @MainActor in onCommentDeleted(id) }
            }
            // Attachments are inserted AFTER the comment row, so refresh when they land.
            ch.onPostgresChange(AnyAction.self, schema: "public", table: "post_comment_media") { _ in
                Task { @MainActor in onCommentsChanged() }
            }
            // comment_reactions has no post column: table-wide, the sheet ignores
            // ids it doesn't show.
            ch.onPostgresChange(AnyAction.self, schema: "public", table: "comment_reactions") { action in
                let record: [String: AnyJSON]
                switch action {
                case .insert(let a): record = a.record
                case .update(let a): record = a.record
                case .delete(let a): record = a.oldRecord
                }
                guard let idStr = record["comment_id"]?.stringValue,
                      let id = UUID(uuidString: idStr) else { return }
                Task { @MainActor in onReactionChanged(id) }
            }
            await ch.subscribe()
        }
    }

    func stop() {
        guard let ch = channel else { return }
        channel = nil
        Task { await supabase.removeChannel(ch) }
    }
}
