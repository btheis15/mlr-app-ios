import SwiftUI
import UIKit
import Supabase

// MARK: - PhoneFormat
//
// One phone field for the editor: accept anything typed, normalise to E.164
// (US default) for `phone_tel`, and format `phone_display`.

enum PhoneFormat {
    struct Result: Equatable { let e164: String; let display: String }

    /// nil when the input cannot be a real number.
    static func normalize(_ raw: String) -> Result? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        if trimmed.hasPrefix("+") && !digits.hasPrefix("1") {
            guard (8...15).contains(digits.count) else { return nil }
            return Result(e164: "+" + digits, display: "+" + digits)
        }
        var national = digits
        if national.count == 11, national.hasPrefix("1") { national.removeFirst() }
        guard national.count == 10 else { return nil }
        let chars = Array(national)
        // NANP: area code and exchange cannot start with 0 or 1.
        guard !"01".contains(chars[0]), !"01".contains(chars[3]) else { return nil }
        let a = String(chars[0..<3]), b = String(chars[3..<6]), c = String(chars[6..<10])
        return Result(e164: "+1" + national, display: "(\(a)) \(b)-\(c)")
    }
}

// MARK: - LocalPlacesService
//
// Database-backed Local Places (migration 0225, `public.local_places`). Reads
// everyone; writes are admin-only under RLS. The table may not exist yet, so a
// read ERROR falls back to the in-code list (read-only); a successful read that
// returns zero rows is an honest empty list, never the seed.

@Observable
@MainActor
final class LocalPlacesService {
    nonisolated static let publicSnapshotKey = "local-places-public"

    /// Every row the viewer can see (admins include hidden ones), ordered group, position, name.
    private(set) var places: [LocalPlace] = []
    private(set) var hasLoaded = false
    /// False when the table could not be read (missing / offline): showing the seed list.
    private(set) var isEditable = false
    /// Admins see hidden rows (with a marker); members never do.
    private(set) var showsHidden = false

    private var cacheUserId: UUID?   // writes only happen for a real admin (controls hide while previewing)

    /// Rows the public screen shows.
    var visiblePlaces: [LocalPlace] { showsHidden ? places : places.filter(\.isActive) }

    func load(env: AppEnvironment) async {
        let uid = env.effectiveUserId
        let seesHidden = env.isAdmin
        let key = DiskCache.key("local-places", user: uid)
        cacheUserId = uid
        showsHidden = seesHidden

        // Paint the last snapshot instantly, refresh quietly.
        if !hasLoaded, let cached = DiskCache.load([LocalPlace].self, key: key) {
            places = cached
            isEditable = true
            hasLoaded = true
        }
        do {
            let rows: [LocalPlace] = try await supabase
                .from("local_places")
                .select()
                .order("place_group")
                .order("position")
                .order("name")
                .execute()
                .value
            applyRefreshed {
                self.places = rows
                self.isEditable = true
                self.hasLoaded = true
            }
            if !env.isPreviewing {
                DiskCache.save(rows, key: key)
                DiskCache.save(rows.filter(\.isActive), key: Self.publicSnapshotKey)
            }
        } catch {
            // Missing table / offline. Keep a cached list if we painted one;
            // otherwise fall back to the in-code list, read-only.
            if places.isEmpty || !hasLoaded {
                places = LocalPlace.seed
                isEditable = false
            }
            hasLoaded = true
        }
    }

    // MARK: Writes (all throw; callers show the real error)

    /// Insert (new) or update. New rows get a unique slug and go to the end of their section.
    @discardableResult
    func save(_ place: LocalPlace, isNew: Bool) async throws -> LocalPlace {
        var p = place
        p.name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        p.placeGroup = Self.normalizeGroup(p.placeGroup)
        if isNew {
            p.position = (places.filter { $0.placeGroup == p.placeGroup }.map(\.position).max() ?? -1) + 1
            let base = Self.slugify(p.name)
            var attempt = 0
            while true {
                let candidate = attempt == 0 ? base : "\(base)-\(attempt + 1)"
                if places.contains(where: { $0.slug == candidate }) { attempt += 1; continue }
                p.slug = candidate
                do {
                    let saved: LocalPlace = try await supabase.from("local_places")
                        .insert(try await payload(p))
                        .select().single().execute().value
                    upsertLocal(saved)
                    return saved
                } catch let e as PostgrestError where e.code == "23505" && attempt < 8 {
                    attempt += 1   // someone else took the slug; try the next number
                }
            }
        } else {
            let saved: LocalPlace = try await supabase.from("local_places")
                .update(try await payload(p))
                .eq("id", value: p.id)
                .select().single().execute().value
            upsertLocal(saved)
            return saved
        }
    }

    func delete(_ place: LocalPlace) async throws {
        try await supabase.from("local_places").delete().eq("id", value: place.id).execute()
        places.removeAll { $0.id == place.id }
        persistSnapshot()
    }

    /// Persist a new full order: real `position` values, numbered within each group.
    func saveOrder(ids: [String]) async throws {
        let byId = Dictionary(uniqueKeysWithValues: places.map { ($0.id, $0) })
        var counters: [String: Int] = [:]
        var changes: [(String, Int)] = []
        for id in ids {
            guard let p = byId[id] else { continue }
            let pos = counters[p.placeGroup, default: 0]
            counters[p.placeGroup] = pos + 1
            if p.position != pos { changes.append((id, pos)) }
        }
        for (id, pos) in changes {
            try await supabase.from("local_places").update(["position": pos]).eq("id", value: id).execute()
            if let i = places.firstIndex(where: { $0.id == id }) { places[i].position = pos }
        }
        places = Self.sorted(places)
        persistSnapshot()
    }

    /// Upload a photo to `site-assets/local-places/…` (same code AppImagesAdminView uses).
    func uploadImage(_ image: UIImage, using media: MediaService) async throws -> String {
        try await media.uploadSiteImage(image: image, key: "local-places")
    }

    // MARK: Helpers

    private func upsertLocal(_ p: LocalPlace) {
        if let i = places.firstIndex(where: { $0.id == p.id }) { places[i] = p } else { places.append(p) }
        places = Self.sorted(places)
        persistSnapshot()
    }

    private func persistSnapshot() {
        guard isEditable else { return }
        DiskCache.save(places, key: DiskCache.key("local-places", user: cacheUserId))
        DiskCache.save(places.filter(\.isActive), key: Self.publicSnapshotKey)
    }

    private func payload(_ p: LocalPlace) async throws -> [String: AnyJSON] {
        func s(_ v: String?) -> AnyJSON {
            let t = v?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? .null : .string(t)
        }
        let uid = try? await supabase.auth.session.user.id
        return [
            "slug": .string(p.slug),
            "name": .string(p.name),
            "category": s(p.category),
            "place_group": .string(p.placeGroup),
            "locality": s(p.locality),
            "address": s(p.address),
            "blurb": s(p.blurb),
            "emoji": s(p.emoji),
            "accent": .string(p.accent),
            "image_url": s(p.imageUrl),
            "website": s(p.website),
            "menu_url": s(p.menuUrl),
            "order_url": s(p.orderUrl),
            "phone_display": s(p.phoneDisplay),
            "phone_tel": s(p.phoneTel),
            "internal_href": s(p.internalHref),
            "internal_cta": s(p.internalCta),
            "booking_url": s(p.bookingUrl),
            "booking_cta": s(p.bookingCta),
            "rates_url": s(p.ratesUrl),
            "rates_cta": s(p.ratesCta),
            "position": .integer(p.position),
            "is_active": .bool(p.isActive),
            "updated_at": .string(ISO8601DateFormatter().string(from: Date())),
            "updated_by": uid.map { .string($0.uuidString) } ?? .null,
        ]
    }

    nonisolated static func sorted(_ rows: [LocalPlace]) -> [LocalPlace] {
        rows.sorted {
            if $0.placeGroup != $1.placeGroup { return $0.placeGroup < $1.placeGroup }
            if $0.position != $1.position { return $0.position < $1.position }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    nonisolated static func normalizeGroup(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.isEmpty ? "food" : t
    }

    nonisolated static func slugify(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        var out = ""
        var lastDash = false
        for ch in folded {
            if ch.isLetter || ch.isNumber, ch.isASCII { out.append(ch); lastDash = false }
            else if !lastDash, !out.isEmpty { out.append("-"); lastDash = true }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "place" : out
    }
}
