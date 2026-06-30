import SwiftUI
import Supabase

// MARK: - AppImagesService
//
// Admin-editable site images (the Home logo, the Family Fest cover, …) stored as
// URLs in the shared `app_images` table (migration 0054), with the actual files
// in the public `site-assets` storage bucket. Both web + iOS read the URL and
// fall back to the bundled asset when it's unset/unreachable — so the app never
// shows a broken image, even pre-migration or offline. Edits sync web ↔ iOS like
// the rest of the Family Fest content.
//
// Known keys (see SiteImageKey) map to a bundled fallback asset name.

enum SiteImageKey {
    static let homeLogo  = "home_logo"
    static let festCover = "fest_cover"
}

@Observable
@MainActor
final class AppImagesService {
    /// key → public URL string (only keys with a non-empty URL are present).
    private(set) var urls: [String: String] = [:]
    private(set) var loaded = false

    func load(force: Bool = false) async {
        if loaded && !force { return }
        do {
            let rows: [AppImageRow] = try await supabase
                .from("app_images")
                .select("key, url")
                .execute()
                .value
            var map: [String: String] = [:]
            for r in rows {
                if let u = r.url?.trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty {
                    map[r.key] = u
                }
            }
            urls = map
            loaded = true
        } catch {
            // Missing table / offline ⇒ keep whatever we have; views fall back
            // to the bundled assets.
        }
    }

    func reload() async { await load(force: true) }

    /// The live URL for a key, or nil to use the bundled fallback.
    func url(for key: String) -> URL? {
        guard let s = urls[key], let u = URL(string: s) else { return nil }
        return u
    }

    /// Whether the signed-in member may edit site images (admin / fest committee).
    func canEdit() async -> Bool {
        do {
            return try await supabase.rpc("can_edit_fest").execute().value
        } catch {
            return false
        }
    }

    /// Save (upsert) a key's URL.
    func save(key: String, url: String) async throws {
        let uid = try? await supabase.auth.session.user.id
        var row: [String: AnyJSON] = [
            "key": .string(key),
            "url": .string(url),
            "updated_at": .string(ISO8601DateFormatter().string(from: Date())),
        ]
        row["updated_by"] = uid.map { .string($0.uuidString) } ?? .null
        try await supabase.from("app_images").upsert(row, onConflict: "key").execute()
        urls[key] = url
    }

    /// Clear a key → both apps revert to the bundled fallback.
    func reset(key: String) async throws {
        try await supabase.from("app_images").delete().eq("key", value: key).execute()
        urls[key] = nil
    }
}

private struct AppImageRow: Decodable {
    let key: String
    let url: String?
}

// MARK: - SiteImage
//
// A resizable image that prefers the admin-set URL for `key` and falls back to
// the bundled `fallback` asset (shown immediately while the remote loads, and if
// it fails). Apply `.scaledToFit()`/`.frame(…)`/clipping at the call site.

struct SiteImage: View {
    @Environment(AppEnvironment.self) private var env
    let key: String
    let fallback: String

    var body: some View {
        if let url = env.appImagesService.url(for: key) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable()
                case .failure:
                    Image(fallback).resizable()
                case .empty:
                    Image(fallback).resizable()
                @unknown default:
                    Image(fallback).resizable()
                }
            }
        } else {
            Image(fallback).resizable()
        }
    }
}
