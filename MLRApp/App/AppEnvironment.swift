import Foundation
import Supabase

// MARK: - Supabase credentials
// ─────────────────────────────────────────────────────────────────────────────
// Paste your project values below. Both are client-safe public values — the
// key is designed to ship in apps; RLS gates all data access.
//
// Find them at: supabase.com → your project → Project Settings → API
//   • Project URL       → url below
//   • anon/public key (eyJ…) OR publishable key (sb_publishable_…) → apiKey
//
// Same values as NEXT_PUBLIC_SUPABASE_URL + NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
// in the web app's Vercel environment variables.
// ─────────────────────────────────────────────────────────────────────────────
private enum SupabaseConfig {
    static let url    = "https://vrksrpzlslrcjvbzchfg.supabase.co"
    static let apiKey = "sb_publishable_XHnrbQ8FHY4xEtAGrk45JQ_Kw0rLlqJ"
}

let supabase = SupabaseClient(
    supabaseURL: URL(string: SupabaseConfig.url)!,
    supabaseKey: SupabaseConfig.apiKey
)

// MARK: - App Environment

@Observable
final class AppEnvironment {
    var authService: AuthService
    var postsService: PostsService
    var eventsService: EventsService
    var notificationsService: NotificationsService
    var committeeService: CommitteeService
    var cabinService: CabinService
    var helpService: HelpService
    var pushService: PushService
    var mediaService: MediaService
    var workItemsService: WorkItemsService
    var housesService: HousesService
    var festContentService: FestContentService
    var appImagesService: AppImagesService
    var pollsService: PollsService

    // Resolved once per session
    var currentProfile: Profile?

    // MARK: - Admin "view as" preview (device-local, UI-only)
    //
    // Changes only what the app SHOWS — never the account or any data write.
    // guest → the signed-out/guest experience; member → a regular member view
    // (admin controls hidden); off → the real account. Entering requires being a
    // real admin; exiting is always allowed. Persisted device-locally.
    enum PreviewMode: String { case off, member, guest }
    static let previewKey = "mlr-preview-as"

    var previewMode: PreviewMode = {
        guard let raw = UserDefaults.standard.string(forKey: AppEnvironment.previewKey),
              let m = PreviewMode(rawValue: raw) else { return .off }
        return m
    }()

    /// When previewing as a SPECIFIC member (not the generic member/guest view),
    /// who it is — so "my stuff" reads (callout completions, committee membership)
    /// show exactly what that person sees. In-memory only (not persisted).
    var previewMember: Profile? = nil

    /// The id whose personal data should drive the UI: the previewed member while
    /// previewing a specific person, otherwise the real signed-in user.
    var effectiveUserId: UUID? { previewMember?.id ?? currentProfile?.id }

    /// Whether an admin is currently viewing the app as someone else.
    var isPreviewing: Bool { previewMode != .off }

    /// The signed-in account's REAL admin flag, ignoring any active preview — the
    /// gate for entering a preview (and for showing the Preview-As entry).
    var realIsAdmin: Bool { currentProfile?.isAdmin ?? false }

    /// Effective admin — false while previewing so admin-only UI hides.
    var isAdmin: Bool { previewMode == .off ? realIsAdmin : false }

    /// Effective sign-in — false while previewing as a guest so guest gating shows.
    var isSignedIn: Bool { previewMode == .guest ? false : authService.isSignedIn }

    /// Switch the generic preview. Entering (member/guest) is admin-only; exiting
    /// is free. Clears any specific-person preview.
    func setPreview(_ mode: PreviewMode) {
        if mode != .off && !realIsAdmin { return }
        previewMode = mode
        previewMember = nil
        let defaults = UserDefaults.standard
        if mode == .off { defaults.removeObject(forKey: Self.previewKey) }
        else { defaults.set(mode.rawValue, forKey: Self.previewKey) }
        Task { await reloadPreviewScopedData() }
    }

    /// Preview as a specific member (admin-only) — pass nil to clear. Puts the app
    /// in a non-admin member view scoped to that person's data. Not persisted.
    func setPreviewMember(_ member: Profile?) {
        if member != nil && !realIsAdmin { return }
        previewMember = member
        if member != nil { previewMode = .member }
        else if previewMode == .member { previewMode = .off }
        UserDefaults.standard.removeObject(forKey: Self.previewKey)   // specific person isn't persisted
        Task { await reloadPreviewScopedData() }
    }

    /// Reload the personal data that differs per member (callout completions,
    /// committee memberships) for whoever the UI is currently scoped to.
    @MainActor
    func reloadPreviewScopedData() async {
        guard let uid = effectiveUserId else { return }
        await festContentService.fetchMyCalloutCompletions(userId: uid, useLocal: previewMember == nil)
        await committeeService.fetchMyMemberships(userId: uid)
    }

    // Help contact — loaded from resort_config (migration 0082), falls back to
    // the HelpContact enum so the Help page always shows something.
    var helpContactName:  String = HelpContact.name
    var helpContactPhone: String = HelpContact.phone
    var helpContactEmail: String = HelpContact.email

    @MainActor
    func loadHelpContact() async {
        guard let data = try? await supabase
            .from("resort_config").select("help_contact_name,help_contact_phone,help_contact_email")
            .limit(1).single().execute().data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if let v = json["help_contact_name"]  as? String, !v.isEmpty { helpContactName  = v }
        if let v = json["help_contact_phone"] as? String, !v.isEmpty { helpContactPhone = v }
        if let v = json["help_contact_email"] as? String, !v.isEmpty { helpContactEmail = v }
    }

    // Dismissed announcement IDs (persisted in UserDefaults)
    var dismissedAnnouncementIds: Set<String> {
        get {
            let arr = UserDefaults.standard.stringArray(forKey: "dismissed_announcements") ?? []
            return Set(arr)
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: "dismissed_announcements")
        }
    }

    // Static hooks so background notification-action handlers (which run without
    // the SwiftUI environment) can reach the live services. Set in init().
    static weak var activeEventsService: EventsService?
    static weak var activeHelpService: HelpService?
    static weak var activeCommitteeService: CommitteeService?
    static weak var activeWorkItemsService: WorkItemsService?

    init() {
        authService          = AuthService()
        postsService         = PostsService()
        eventsService        = EventsService()
        notificationsService = NotificationsService()
        committeeService     = CommitteeService()
        cabinService         = CabinService()
        helpService          = HelpService()
        pushService          = PushService()
        mediaService         = MediaService()
        workItemsService     = WorkItemsService()
        housesService        = HousesService()
        festContentService   = FestContentService()
        appImagesService     = AppImagesService()
        pollsService         = PollsService()

        AppEnvironment.activeEventsService    = eventsService
        AppEnvironment.activeHelpService      = helpService
        AppEnvironment.activeCommitteeService = committeeService
        AppEnvironment.activeWorkItemsService = workItemsService
    }

    // Load the signed-in profile after auth.
    //
    // The profile row is created by a DB trigger when the OTP is verified, so on a
    // fresh sign-in it may not be visible yet due to replication lag. We fetch as an
    // array (never throws on zero rows), retry once for that race, and fall back to a
    // minimal email-derived profile so the user always renders as signed in — matching
    // the web app, which uses .maybeSingle() with the same fallback.
    @MainActor
    func loadProfile() async {
        guard let user = try? await supabase.auth.session.user else {
            currentProfile = nil
            housesService.myHouse = nil
            return
        }

        // Fetch the row; retry once for replication lag on a fresh verify; fall back
        // to a minimal email-derived profile so the user always renders as signed in.
        var resolved = await fetchProfile(id: user.id)
        if resolved == nil {
            try? await Task.sleep(for: .milliseconds(600))
            resolved = await fetchProfile(id: user.id)
        }
        currentProfile = resolved ?? Self.fallbackProfile(id: user.id, email: user.email ?? "")

        // Resolve the member's house so the Home/Feed "Your house" surfaces can read
        // it directly (see HousesService.myHouse).
        await refreshMyHouse()
    }

    /// Resolve the signed-in member's house into `housesService.myHouse`.
    @MainActor
    func refreshMyHouse() async {
        guard let hid = currentProfile?.houseId else {
            housesService.myHouse = nil
            return
        }
        housesService.myHouse = await housesService.house(withId: hid)
    }

    private func fetchProfile(id: UUID) async -> Profile? {
        do {
            let rows: [Profile] = try await supabase
                .from("profiles")
                .select("*")
                .eq("id", value: id.uuidString)
                .limit(1)
                .execute()
                .value
            return rows.first
        } catch {
            print("[AppEnvironment] loadProfile error: \(error)")
            return nil
        }
    }

    private static func fallbackProfile(id: UUID, email: String) -> Profile {
        let name = email.split(separator: "@").first.map(String.init) ?? "Member"
        return Profile(
            id: id,
            name: name,
            email: email,
            phone: nil,
            birthday: nil,
            bio: nil,
            avatarUrl: nil,
            venmoHandle: nil,
            zelleHandle: nil,
            appleCashHandle: nil,
            emailAlerts: true,
            pushLevel: nil,
            pushTypes: [],
            notifTypes: [],
            pushPrompted: false,
            isAdmin: false,
            betaTester: false,
            willingToHelp: false,
            introSeen: true,
            createdAt: nil
        )
    }

    /// Start the app-wide notifications subscription so the Activity tab badge and
    /// list stay live no matter which screen is open. Safe to call repeatedly.
    @MainActor
    func startNotificationsRealtime() async {
        guard let uid = currentProfile?.id else { return }
        notificationsService.subscribeToRealtime(userId: uid)
        await notificationsService.fetchUnreadCount(userId: uid)
    }

    @MainActor
    func signOut() async {
        notificationsService.unsubscribeFromRealtime()
        notificationsService.notifications = []
        notificationsService.unreadCount = 0
        await authService.signOut()
        currentProfile = nil
        housesService.myHouse = nil
    }
}

