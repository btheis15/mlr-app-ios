import SwiftUI
import Kingfisher

// MARK: - OnThisDayCard
//
// Members-only "on this day" garnish for Home: a photo post from a PRIOR year
// within ±3 days of today's month-day. The pick is DETERMINISTIC (day-of-year %
// candidate count, stable id sort) so it's the same for everyone on a given day
// and rotates naturally year to year. Self-hides for guests and when there's no
// candidate — never an error state. Mirrors the web OnThisDayCard.

struct OnThisDayCard: View {
    @Environment(AppEnvironment.self) private var env

    struct Memory: Equatable {
        let id: UUID
        let year: Int
        let caption: String
        let thumbUrl: String
    }

    private static let bucketBase =
        "https://vrksrpzlslrcjvbzchfg.supabase.co/storage/v1/object/public/post-photos"
    private static let windowDays = 3
    private static let yearLen = 365

    @State private var memory: Memory?

    var body: some View {
        if env.isSignedIn, let memory {
            card(memory)
                .task { await load() }   // refresh silently on reappear
        } else {
            Color.clear.frame(height: 0).task { await load() }
        }
    }

    private func card(_ m: Memory) -> some View {
        HStack(spacing: 12) {
            Group {
                if let url = URL(string: m.thumbUrl) {
                    KFImage(url)
                        .placeholder { Color.mlrCard }
                        .setProcessor(DownsamplingImageProcessor(size: CGSize(width: 144, height: 144)))
                        .scaleFactor(UIScreen.main.scale)
                        .fade(duration: 0.2)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.mlrCard
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("🕰️").font(.mlrScaled(13))
                    Text("On this day in \(String(m.year))")
                        .font(.mlrScaled(14, weight: .semibold))
                        .foregroundStyle(Color.mlrText)
                }
                Text(m.caption)
                    .font(.caption)
                    .foregroundStyle(Color.mlrTextMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .cardStyle()
    }

    // MARK: - Load

    private func load() async {
        guard env.isSignedIn else { return }
        let picked = await Self.fetchTodaysMemory()
        if picked != memory { memory = picked }
    }

    // MARK: - Fetch + deterministic pick

    private struct PostRow: Decodable {
        let id: UUID
        let text: String?
        let imagePath: String?
        let occurredAt: Date?
        let createdAt: Date
        let status: String?
        enum CodingKeys: String, CodingKey {
            case id, text, status
            case imagePath = "image_path"
            case occurredAt = "occurred_at"
            case createdAt = "created_at"
        }
    }

    private struct MediaRow: Decodable {
        let postId: UUID
        let storagePath: String
        let mediaType: String
        let position: Int
        enum CodingKeys: String, CodingKey {
            case postId = "post_id"
            case storagePath = "storage_path"
            case mediaType = "media_type"
            case position
        }
    }

    private static func fetchTodaysMemory() async -> Memory? {
        async let postsTask: [PostRow]? = try? await supabase
            .from("posts")
            .select("id, text, image_path, occurred_at, created_at, status")
            .order("occurred_at", ascending: false)
            .execute().value
        async let mediaTask: [MediaRow]? = try? await supabase
            .from("post_media")
            .select("post_id, storage_path, media_type, position")
            .order("position", ascending: true)
            .execute().value

        guard let posts = await postsTask else { return nil }
        let media = await mediaTask ?? []

        var firstImageByPost: [UUID: String] = [:]
        for m in media where m.mediaType != "video" {
            if firstImageByPost[m.postId] == nil { firstImageByPost[m.postId] = m.storagePath }
        }

        let cal = Calendar.current
        let now = Date()
        let currentYear = cal.component(.year, from: now)
        let todayDoy = dayOfYear(now, cal: cal)

        var candidates: [Memory] = []
        for p in posts {
            if let s = p.status, s != "visible" { continue }
            let occurred = p.occurredAt ?? p.createdAt
            let year = cal.component(.year, from: occurred)
            if year >= currentYear { continue }
            if circularDayDistance(dayOfYear(occurred, cal: cal), todayDoy) > windowDays { continue }
            guard let path = firstImageByPost[p.id] ?? p.imagePath else { continue }
            let caption = (p.text?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? "A memory from back then."
            candidates.append(Memory(id: p.id, year: year, caption: caption, thumbUrl: resolveURL(path)))
        }
        guard !candidates.isEmpty else { return nil }
        candidates.sort { $0.id.uuidString < $1.id.uuidString } // stable order
        return candidates[todayDoy % candidates.count]
    }

    private static func resolveURL(_ path: String) -> String {
        path.hasPrefix("http") ? path : "\(bucketBase)/\(path)"
    }

    /// Day-of-year in a fixed reference year for a year-agnostic month-day compare.
    private static func dayOfYear(_ d: Date, cal: Calendar) -> Int {
        let comps = cal.dateComponents([.month, .day], from: d)
        var ref = DateComponents(); ref.year = 2001; ref.month = comps.month; ref.day = comps.day
        var startC = DateComponents(); startC.year = 2001; startC.month = 1; startC.day = 1
        guard let refDate = cal.date(from: ref), let startDate = cal.date(from: startC) else { return 0 }
        return (cal.dateComponents([.day], from: startDate, to: refDate).day ?? 0)
    }

    private static func circularDayDistance(_ a: Int, _ b: Int) -> Int {
        let diff = abs(a - b)
        return min(diff, yearLen - diff)
    }
}
