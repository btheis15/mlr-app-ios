import Foundation
// Re-export Supabase so anything that `import MLRCore`s also gets the Supabase
// API (SupabaseClient, auth, PostgREST, realtime) without a separate import.
@_exported import Supabase

// MARK: - Supabase client
//
// Client-safe public values — the key is designed to ship in apps; RLS gates all
// data access. Same values as NEXT_PUBLIC_SUPABASE_URL +
// NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY in the web app's Vercel env.

private enum SupabaseConfig {
    static let url    = "https://vrksrpzlslrcjvbzchfg.supabase.co"
    static let apiKey = "sb_publishable_XHnrbQ8FHY4xEtAGrk45JQ_Kw0rLlqJ"
}

public let supabase = SupabaseClient(
    supabaseURL: URL(string: SupabaseConfig.url)!,
    supabaseKey: SupabaseConfig.apiKey
)
