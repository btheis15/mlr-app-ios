import SwiftUI
import Supabase

// MARK: - AnnouncementBanner
// Mirrors web app's components/AnnouncementBanner.tsx.
// Reads announcements from seed data + Supabase `announcements` table,
// filters expired ones, and renders dismissible banners at the top of Home.
//
// Usage: place at the top of HomeView's scroll content:
//   AnnouncementBannerStack()

// MARK: - Banner Stack (the public entry point)

/// Renders all active, non-dismissed, non-expired announcements in a VStack.
/// Place at the top of the Home scroll view.
struct AnnouncementBannerStack: View {
    @Environment(AppEnvironment.self) private var env
    @State private var dbAnnouncements: [Announcement] = []
    @State private var isLoading = true
    @State private var channel: RealtimeChannelV2? = nil
    // Admin edit-in-place (RLS: author or app admin may update/expire).
    @State private var editing: Announcement? = nil
    @State private var endTarget: Announcement? = nil
    @State private var actionError: String? = nil

    /// Only DB rows are admin-posted; `Announcement.seed` (the hard-coded
    /// "Welcome to MLR" banner) is never editable.
    private func canEdit(_ a: Announcement) -> Bool {
        env.isAdmin && dbAnnouncements.contains { $0.id == a.id }
    }

    private var visible: [Announcement] {
        let all = Announcement.seed + dbAnnouncements
        return all.filter { announcement in
            announcement.showBanner &&
            !announcement.isExpired &&
            !env.dismissedAnnouncementIds.contains(announcement.id) &&
            !isHiddenForEvent(announcement)
        }
    }

    /// Mirrors web's `isHiddenForEventTarget()` (migration 0096) — hides the
    /// banner ONLY from someone who explicitly RSVP'd "Can't make it" to the
    /// linked event; a no-response (or Going/Maybe) member still sees it.
    private func isHiddenForEvent(_ announcement: Announcement) -> Bool {
        guard announcement.excludeNotAttending, let eventId = announcement.eventId else { return false }
        return env.eventsService.attendances[eventId]?.effectiveStatus() == .notGoing
    }

    var body: some View {
        VStack(spacing: 12) {
            ForEach(visible) { announcement in
                AnnouncementBannerRow(
                    announcement: announcement,
                    onDismiss: { dismiss(announcement) },
                    onEdit: canEdit(announcement) ? { editing = announcement } : nil,
                    onEnd: canEdit(announcement) ? { endTarget = announcement } : nil
                )
            }
        }
        .sheet(item: $editing) { a in
            AnnouncementEditSheet(announcement: a) { await loadFromDB() }
        }
        .confirmationDialog("End this banner now?", isPresented: Binding(get: { endTarget != nil },
                                                                         set: { if !$0 { endTarget = nil } }),
                            titleVisibility: .visible) {
            Button("End now", role: .destructive) {
                if let a = endTarget { Task { await endNow(a) } }
                endTarget = nil
            }
            Button("Keep showing", role: .cancel) { endTarget = nil }
        } message: { Text("It disappears for everyone. Emails or notifications already sent can\u{2019}t be recalled.") }
        .alert("Couldn\u{2019}t end the banner", isPresented: Binding(get: { actionError != nil },
                                                                    set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(actionError ?? "") }
        .task {
            await loadFromDB()
            await subscribeRealtime()
        }
        .onDisappear {
            if let channel { Task { await supabase.removeChannel(channel) } }
            channel = nil
        }
    }

    /// Live-update banners when an admin posts or expires an announcement —
    /// matching the web `announcements-banner` channel.
    private func subscribeRealtime() async {
        guard channel == nil else { return }
        let ch = supabase.channel("announcements-banner")
        channel = ch
        ch.onPostgresChange(AnyAction.self, schema: "public", table: "announcements") { _ in
            Task { @MainActor in await loadFromDB() }
        }
        await ch.subscribe()
    }

    private func dismiss(_ announcement: Announcement) {
        withAnimation(.easeInOut(duration: 0.2)) {
            var ids = env.dismissedAnnouncementIds
            ids.insert(announcement.id)
            env.dismissedAnnouncementIds = ids
        }
    }

    /// Expire now: sets `expires_at` to the current time (the same field the
    /// banner already filters on), then refreshes.
    @MainActor
    private func endNow(_ a: Announcement) async {
        do {
            try await supabase.from("announcements")
                .update(["expires_at": ISO8601DateFormatter().string(from: Date())])
                .eq("id", value: a.id).execute()
            Haptics.success()
            await loadFromDB()
        } catch {
            actionError = EditorError.message(error)
            Haptics.error()
        }
    }

    @MainActor
    private func loadFromDB() async {
        do {
            let rows: [Announcement] = try await supabase
                .from("announcements")
                .select("*")
                .order("created_at", ascending: false)
                .execute()
                .value
            dbAnnouncements = rows
        } catch {
            print("[AnnouncementBanner] fetch error: \(error)")
        }
        isLoading = false
    }
}

// MARK: - Individual banner row

private struct AnnouncementBannerRow: View {
    let announcement: Announcement
    let onDismiss: () -> Void
    var onEdit: (() -> Void)? = nil
    var onEnd: (() -> Void)? = nil

    var body: some View {
        MLRCard(.tinted(kindColor), padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: kindSymbol, accent: kindColor, size: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(announcement.title)
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(Color.mlrText)

                    if let body = announcement.body, !body.isEmpty {
                        Text(body)
                            .font(.subheadline)
                            .foregroundStyle(Color.mlrTextMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Admin edit-in-place (admin-posted banners only).
                if let onEdit, let onEnd {
                    Menu {
                        Button { onEdit() } label: { Label("Edit text", systemImage: "pencil") }
                        Button(role: .destructive) { onEnd() } label: { Label("End now", systemImage: "stop.circle") }
                    } label: {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(kindColor.opacity(0.75))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .padding(.vertical, -10)
                    .accessibilityLabel("Edit announcement")
                }

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.mlrScaled(12, weight: .semibold))
                        .foregroundStyle(Color.mlrTextMuted)
                        .padding(6)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Dismiss")
            }
        }
    }

    private var kindSymbol: String {
        switch announcement.kind {
        case .info:    return "house.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .urgent:  return "exclamationmark.octagon.fill"
        case .fest:    return "tent.fill"
        }
    }

    // MARK: Kind colors

    private var kindColor: Color {
        switch announcement.kind {
        case .info:    return Color.mlrPrimary
        case .warning: return Color.mlrWarning
        case .urgent:  return Color.mlrDanger
        case .fest:    return Color.mlrFest
        }
    }

    private var kindTextColor: Color {
        switch announcement.kind {
        case .info:    return Color.mlrPrimary
        case .warning: return Color(hex: "#92400e") // amber-800
        case .urgent:  return Color(hex: "#991b1b") // red-800
        case .fest:    return Color.mlrFest
        }
    }

    private var kindBackgroundColor: Color {
        switch announcement.kind {
        case .info:    return Color.mlrPrimaryLight
        case .warning: return Color(hex: "#fffbeb") // amber-50
        case .urgent:  return Color(hex: "#fef2f2") // red-50
        case .fest:    return Color.mlrFestLight
        }
    }
}

// MARK: - Edit sheet (text only)
// Edits title/body of an admin-posted banner. Severity, expiry and the send
// channels are left alone (already sent); use "End now" to retire it early.

private struct AnnouncementEditSheet: View {
    let announcement: Announcement
    let onSaved: () async -> Void
    @State private var draft: EditorDraft<[String]>   // [title, body]

    init(announcement: Announcement, onSaved: @escaping () async -> Void) {
        self.announcement = announcement; self.onSaved = onSaved
        _draft = State(initialValue: EditorDraft([announcement.title, announcement.body ?? ""]))
    }

    private var title: Binding<String> { Binding(get: { draft.value[0] }, set: { draft.value[0] = $0 }) }
    private var body_: Binding<String> { Binding(get: { draft.value[1] }, set: { draft.value[1] = $0 }) }

    var body: some View {
        EditorSheet(
            title: "Edit announcement",
            isDirty: draft.isDirty,
            canSave: !draft.value[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            save: {
                let t = draft.value[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let b = draft.value[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let fields: [String: AnyJSON] = ["title": .string(t), "body": b.isEmpty ? .null : .string(b)]
                try await supabase.from("announcements").update(fields).eq("id", value: announcement.id).execute()
                await onSaved()
            }
        ) {
            Section {
                EditorTextField("Title", text: title, limit: 120, required: true)
                EditorLongText("Body", text: body_, lines: 2...6)
            } footer: {
                Text("Only the wording changes. Emails and notifications already sent are not re-sent.")
            }
        }
    }
}

// MARK: - Announcement seed note
// `Announcement.seed` is defined in SeedData.swift (the extension at the bottom
// of that file). This file just reads it — no redeclaration needed here.

// MARK: - Preview

#if DEBUG
struct AnnouncementBanner_Previews: PreviewProvider {
    static let env: AppEnvironment = {
        let e = AppEnvironment()
        return e
    }()

    static var previews: some View {
        VStack(spacing: 0) {
            AnnouncementBannerRow(
                announcement: Announcement(
                    id: "p1",
                    title: "Welcome to Muskellunge Lake Resort",
                    body: "Browse freely — sign in when you're ready to RSVP or chat.",
                    kind: .info,
                    expiresAt: nil,
                    createdAt: nil
                ),
                onDismiss: {}
            )

            AnnouncementBannerRow(
                announcement: Announcement(
                    id: "p2",
                    title: "Family Fest starts July 26!",
                    body: "Pack your bags — a week on the lake.",
                    kind: .fest,
                    expiresAt: nil,
                    createdAt: nil
                ),
                onDismiss: {}
            )

            AnnouncementBannerRow(
                announcement: Announcement(
                    id: "p3",
                    title: "Dock closed for repairs",
                    body: "Expected back by Friday afternoon.",
                    kind: .warning,
                    expiresAt: nil,
                    createdAt: nil
                ),
                onDismiss: {}
            )

            AnnouncementBannerRow(
                announcement: Announcement(
                    id: "p4",
                    title: "Urgent: water main break",
                    body: "Use bottled water until further notice.",
                    kind: .urgent,
                    expiresAt: nil,
                    createdAt: nil
                ),
                onDismiss: {}
            )
        }
        .environment(env)
        .previewDisplayName("AnnouncementBanner kinds")
    }
}
#endif
