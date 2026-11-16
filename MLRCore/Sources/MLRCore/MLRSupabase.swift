import Foundation
// Re-export Supabase so anything that `import MLRCore`s also gets the Supabase
// API (SupabaseClient, auth, PostgREST, realtime) without a separate import.
@_exported import Supabase

// MARK: - Supabase client
//
// Client-safe public values — the key is designed to ship in apps; RLS gates all
// data access. Same values as NEXT_PUBLIC_SUPABASE_URL +
// NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY in the web app's Vercel env.

/// Which backend this build talks to. ONE switch: the client, and every storage
/// URL the app builds, derive from it.
///
/// ⚠️ The two are separate databases until the cutover. A build on `.mini` and
/// the web app on `.cloud` do not see each other's posts, chats or RSVPs, so a
/// `.mini` build is for the owner's testing only until the web app moves too.
public enum MLRBackend {
    /// Supabase Cloud (project vrksrpzlslrcjvbzchfg): what the web app uses today.
    case cloud
    /// Self-hosted Supabase on the Mac mini, public at mlr-media.duckdns.org.
    case mini

    public static let current: MLRBackend = .mini

    public var url: String {
        switch self {
        case .cloud: return "https://vrksrpzlslrcjvbzchfg.supabase.co"
        case .mini:  return "https://mlr-media.duckdns.org"
        }
    }

    var apiKey: String {
        switch self {
        case .cloud: return "sb_publishable_XHnrbQ8FHY4xEtAGrk45JQ_Kw0rLlqJ"
        case .mini:  return "sb_publishable_4o_eBvJd8VPzXZxyY3Osbo_s8e1Smpo"
        }
    }

    /// Public base URL of a storage bucket, e.g. `publicStorageBase("post-photos")`.
    public func publicStorageBase(_ bucket: String) -> String {
        "\(url)/storage/v1/object/public/\(bucket)"
    }
}

private enum SupabaseConfig {
    static let url    = MLRBackend.current.url
    static let apiKey = MLRBackend.current.apiKey
}

/// The Keychain name the session is saved under. supabase-swift derives it from
/// the backend's host by default, so pointing the app at a different address
/// would look for the session under a new name and sign everyone out. Pinning
/// it to the original cloud name means a member's saved session is found on
/// either backend (the mini holds a copy of the sessions), and they stay signed in.
private let pinnedSessionStorageKey = "sb-vrksrpzlslrcjvbzchfg-auth-token"

public let supabase = SupabaseClient(
    supabaseURL: URL(string: SupabaseConfig.url)!,
    supabaseKey: SupabaseConfig.apiKey,
    options: SupabaseClientOptions(
        auth: .init(storageKey: pinnedSessionStorageKey)
    )
)
