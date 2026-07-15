import SwiftUI
import AVKit
import Kingfisher
import Supabase

// MARK: - ChatMedia
//
// One attachment on a chat message (committee or house), mirroring the web
// ChatMedia. Photos/videos render inline; anything else (PDFs, docs, …) shows as
// a tappable file chip. Decoded from the *_message_media rows embedded in the
// message select (storage_path / media_type / file_name / …). Old sticker/GIF
// rows still decode (rendered as a plain chip / image) even though the composer
// no longer offers them.

struct ChatMedia: Identifiable, Equatable, Hashable, Decodable {
    let url: String        // storage_path — a mini URL (or, for old rows, a Tenor URL / sticker id)
    let type: String       // "image" | "video" | "file" | "sticker" | "gif"
    var width: Int?
    var height: Int?
    var name: String?      // original filename, for "file" attachments
    var position: Int

    var id: String { "\(position)|\(url)" }

    var isImage: Bool { type == "image" || type == "gif" }
    var isVideo: Bool { type == "video" }
    var isFile: Bool { type == "file" }

    init(url: String, type: String, width: Int? = nil, height: Int? = nil, name: String? = nil, position: Int = 0) {
        self.url = url; self.type = type; self.width = width; self.height = height; self.name = name; self.position = position
    }

    enum CodingKeys: String, CodingKey {
        case url = "storage_path"
        case type = "media_type"
        case width, height
        case name = "file_name"
        case position
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        type = (try? c.decode(String.self, forKey: .type)) ?? "image"
        width = try? c.decodeIfPresent(Int.self, forKey: .width)
        height = try? c.decodeIfPresent(Int.self, forKey: .height)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        position = (try? c.decodeIfPresent(Int.self, forKey: .position)) ?? 0
    }
}

// MARK: - ChatReaction
//
// An iMessage-style tapback on a chat message: one emoji per member per message
// (the tables have PK (message_id, user_id)). Decoded from the embedded
// *_message_reactions rows. The pickable set mirrors the web app.

let chatReactionEmojis = ["👍", "❤️", "😂", "😮", "😢", "🎉"]

struct ChatReaction: Identifiable, Equatable, Hashable, Decodable {
    let userId: UUID
    let emoji: String

    var id: String { "\(userId.uuidString)|\(emoji)" }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case emoji
    }
}

/// Group reactions into (emoji, count) in first-seen order — drives the pills.
func chatReactionCounts(_ reactions: [ChatReaction]) -> [(emoji: String, count: Int)] {
    var order: [String] = []
    var counts: [String: Int] = [:]
    for r in reactions {
        if counts[r.emoji] == nil { order.append(r.emoji) }
        counts[r.emoji, default: 0] += 1
    }
    return order.map { (emoji: $0, count: counts[$0] ?? 0) }
}

// MARK: - ChatReactionsSheet
//
// "Who reacted" list (Facebook/Messenger-style): every reactor with their
// avatar, name, and the emoji they used. Tapping your own row removes your
// reaction. Names/avatars are resolved from the chat's roster.

struct ChatReactionsSheet: View {
    let reactions: [ChatReaction]
    let roster: [Profile]
    var myUserId: UUID?
    var onToggle: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    private func profile(_ id: UUID) -> Profile? { roster.first { $0.id == id } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(reactions) { r in
                        let isMe = r.userId == myUserId
                        HStack(spacing: 12) {
                            AvatarView(url: profile(r.userId)?.avatarUrl, size: .small)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(isMe ? "You" : (profile(r.userId)?.name ?? "Member"))
                                    .font(.mlrScaled(15, weight: .medium))
                                    .foregroundStyle(Color.mlrText)
                                if isMe {
                                    Text("Tap to remove")
                                        .font(.caption)
                                        .foregroundStyle(Color.mlrTextMuted)
                                }
                            }
                            Spacer()
                            Text(r.emoji).font(.mlrScaled(22))
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isMe { onToggle(r.emoji); dismiss() }
                        }
                    }
                } header: {
                    Text("\(reactions.count) \(reactions.count == 1 ? "reaction" : "reactions")")
                }
            }
            .navigationTitle("Reactions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }
}

// Build media-row inserts for a chat message's attachments — the shared shape
// for both committee_message_media and house_message_media.
func chatMediaRows(messageId: UUID, media: [ChatMedia]) -> [[String: AnyJSON]] {
    media.enumerated().map { i, m in
        [
            "message_id":   .string(messageId.uuidString),
            "storage_path": .string(m.url),
            "media_type":   .string(m.type),
            "width":        m.width.map { AnyJSON.integer($0) } ?? .null,
            "height":       m.height.map { AnyJSON.integer($0) } ?? .null,
            "file_name":    m.name.map { AnyJSON.string($0) } ?? .null,
            "position":     .integer(i),
        ]
    }
}

// MARK: - ChatMediaView
//
// Renders a message's attachments in a bubble: images/GIFs inline (Kingfisher),
// videos in an inline player, and files (PDFs, docs, …) as a tappable chip that
// opens the file. Shared by the committee + house chat bubbles.

struct ChatMediaView: View {
    let media: [ChatMedia]
    let isOwn: Bool

    var body: some View {
        VStack(alignment: isOwn ? .trailing : .leading, spacing: 4) {
            ForEach(media) { m in
                switch m.type {
                case "image", "gif":
                    if let url = URL(string: m.url) {
                        KFImage(url)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: 220, maxHeight: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                case "video":
                    if let url = URL(string: m.url) {
                        VideoPlayer(player: AVPlayer(url: url))
                            .frame(width: 220, height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                case "file":
                    fileChip(name: m.name ?? "File", urlString: m.url)
                default:
                    // Old sticker rows (web-only) — the composer no longer makes these.
                    Text(m.type == "sticker" ? "Sticker" : "Attachment")
                        .font(.mlrCaption)
                        .foregroundStyle(Color.mlrTextMuted)
                }
            }
        }
    }

    @ViewBuilder
    private func fileChip(name: String, urlString: String) -> some View {
        if let url = URL(string: urlString) {
            Link(destination: url) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.fill")
                        .font(.mlrScaled(18))
                        .foregroundStyle(isOwn ? Color.white : Color.mlrPrimary)
                    Text(name)
                        .font(.mlrScaled(14, weight: .medium))
                        .foregroundStyle(isOwn ? Color.white : Color.mlrText)
                        .lineLimit(1)
                    Image(systemName: "arrow.down.circle")
                        .font(.mlrScaled(13))
                        .foregroundStyle(isOwn ? Color.white.opacity(0.8) : Color.mlrTextMuted)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: 240, alignment: .leading)
                .background(isOwn ? Color.white.opacity(0.18) : Color.mlrSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}
