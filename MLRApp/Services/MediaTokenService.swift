import Foundation

// MARK: - MediaToken
//
// The client half of media-server auth (media-server/media-auth.js in the web
// repo). Every `/f` read on the mini can require a signed `?t=` token; the
// server has been held at MEDIA_AUTH=report specifically because iOS could
// not attach one — enforcement 403s every photo/video otherwise. See
// docs/ios-parity-2026-08.md §0 (web repo) for the full incident history
// behind each rule below; most were learned the hard way on the web app.

actor MediaToken {
    static let shared = MediaToken()

    /// The mini's public endpoint for issuing tokens. Always DuckDNS — never
    /// the retired Tailscale Funnel host (see `mediaHosts` below for why that
    /// distinction matters even though this constant only picks one).
    private static let mediaBase = URL(string: "https://mlr-media.duckdns.org")!

    /// Hosts whose URLs get a `?t=` appended. Matched by HOST, never by
    /// string prefix — a prefix check is exactly what silently un-signed
    /// every photo on the web app for hours when the configured base URL and
    /// the stored URLs disagreed.
    static let mediaHosts: Set<String> = [
        "mlr-media.duckdns.org",
        "brians-mac-mini.tail49943c.ts.net",   // retired; still accepted so old rows sign
    ]

    private struct TokenResponse: Decodable {
        let token: String
        let expiresAt: Date
        let ttlHours: Double?
    }

    private var token: String?
    private var expiresAt: Date = .distantPast
    private var inFlight: Task<String?, Never>?

    /// Usable for at least another minute, so a URL being built right now can't expire mid-flight.
    private var isFresh: Bool { token != nil && expiresAt.timeIntervalSinceNow > 60 }

    /// Fetch (or return the cached) token. Pass `force: true` on every app
    /// open — see the warning on `MediaTokenService.refresh()`. Returns nil
    /// when signed out, not yet approved by an admin (403 `pendingApproval`),
    /// or the mini is unreachable; `MediaToken.signed` falls back to the
    /// original unsigned URL in that case rather than nil-ing it out.
    func ensure(force: Bool, accessToken: @escaping @Sendable () async -> String?) async -> String? {
        if !force, isFresh { return token }
        if let inFlight { return await inFlight.value }

        let task = Task<String?, Never> { [weak self] in
            guard let self else { return nil }
            guard let jwt = await accessToken() else { return nil }

            var request = URLRequest(url: Self.mediaBase.appending(path: "media-token"))
            request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
            // Never let this answer from the URL cache: the body is
            // identical all day, so a cached/revalidated response is exactly
            // how the web client once ended up holding no token at all.
            request.cachePolicy = .reloadIgnoringLocalCacheData

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { return nil }

                if http.statusCode == 403 {
                    // Signed in, but not yet approved by an admin. Not an
                    // error — the verified-member gate is what should explain
                    // this to the member; we just hold no token.
                    await self.clear()
                    return nil
                }
                guard (200...299).contains(http.statusCode) else { return nil }

                let decoded = try Self.decoder.decode(TokenResponse.self, from: data)
                await self.store(decoded.token, expires: decoded.expiresAt)
                return decoded.token
            } catch {
                print("[MediaToken] media-token fetch failed: \(error)")
                return nil
            }
        }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    private func store(_ token: String, expires: Date) { self.token = token; self.expiresAt = expires }
    private func clear() { token = nil; expiresAt = .distantPast }

    /// The endpoint's `expiresAt` carries milliseconds ("…T00:00:00.000Z");
    /// JSONDecoder's plain `.iso8601` strategy has no fractional-seconds
    /// support and would fail to parse it, silently losing every token.
    private static let decoder: JSONDecoder = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = fractional.date(from: raw) ?? whole.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unrecognized date format: \(raw)")
        }
        return dec
    }()

    /// THE function every image/video URL in the app must pass through.
    /// Untouched when the host isn't ours, when `/assets/*` (public by
    /// design), when there's no token yet, or when it's already signed
    /// (idempotent — never double-appends `?t=`).
    nonisolated static func signed(_ url: URL?, token: String?) -> URL? {
        guard let url else { return nil }
        guard let host = url.host, mediaHosts.contains(host) else { return url }
        if url.path.hasPrefix("/assets/") { return url }
        guard let token else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        guard !items.contains(where: { $0.name == "t" }) else { return url }
        items.append(URLQueryItem(name: "t", value: token))
        components.queryItems = items
        return components.url ?? url
    }
}

// MARK: - MediaTokenService
//
// @Observable holder so views re-render the instant the token lands.
// `env.mediaTokenService.url(_:)` reads `token` inside the view body, which
// is what makes SwiftUI's Observation tracking pick up the change the moment
// `refresh()` assigns it — a URL built during render before the token landed
// would otherwise stay unsigned forever.

@Observable
@MainActor
final class MediaTokenService {
    private(set) var token: String?

    /// Call once from the app root's `.task` AND every time `scenePhase`
    /// becomes `.active`. Always forces a live fetch.
    ///
    /// A cached token is only a GUESS about what the server currently
    /// accepts. It carries its own 24h expiry, so if the signing key ever
    /// changes, a client that skips this keeps confidently signing with a
    /// dead key and every photo 403s for up to a day with no self-healing —
    /// that exact bug took the web app's photos down fleet-wide. One small
    /// authenticated request per app-open buys automatic recovery instead.
    func refresh() async {
        token = await MediaToken.shared.ensure(force: true) {
            try? await supabase.auth.session.accessToken
        }
    }

    /// Sign a raw media URL string for display. Returns the URL untouched
    /// when it isn't ours to sign, or when the token hasn't landed yet —
    /// never nil just because there's no token, so a photo still attempts to
    /// load (correctly, while MEDIA_AUTH=report; gracefully, once it's `on`).
    func url(_ raw: String?) -> URL? {
        guard let raw, let u = URL(string: raw) else { return nil }
        return MediaToken.signed(u, token: token)
    }
}
