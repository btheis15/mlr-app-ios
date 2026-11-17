import SwiftUI

// MARK: - AdminView
// Admin hub — entry point to all admin sub-screens.

struct AdminView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showInvite = false
    @State private var query = ""

    // MARK: Tool model

    private enum Action {
        case push(() -> AnyView)
        case sheetInvite
        case link(URL)
    }

    private struct Tool: Identifiable {
        let id: String
        let title: String
        let description: String
        let icon: String
        let color: Color
        var keywords: String = ""
        var badge: Int = 0
        let action: Action
    }

    private struct ToolGroup: Identifiable {
        let id: String
        let title: String
        let icon: String
        let blurb: String
        let tools: [Tool]
    }

    private func push<V: View>(_ make: @escaping () -> V) -> Action { .push { AnyView(make()) } }

    /// Join-request count comes straight from the committee service's already
    /// loaded queue (the same data Admin → Committees shows). Verification and
    /// moderation counts have no loaded service data, so they get no badge
    /// rather than a new request.
    private var joinRequestCount: Int { env.committeeService.pendingRequests.count }

    private var groups: [ToolGroup] {
        let people: [Tool] = [
            // Until an admin verifies a new signup they see only what a
            // signed-out visitor sees (0183) and can write nothing (0213) —
            // so this is the row that actually lets someone into the app.
            Tool(id: "verify", title: "Verify members",
                 description: "Confirm a new signup is really family, so the app opens up for them",
                 icon: "checkmark.seal.fill", color: Color.mlrSuccess, keywords: "approve signup",
                 action: push { AdminVerifyMembersView() }),
            // Per-member actions (make admin, assign house) live on individual profile
            // sheets in the People tab; this row is the directory + overview.
            Tool(id: "members", title: "Members",
                 description: "Directory with emails · promote admins · edit a member's info",
                 icon: "person.2.fill", color: Color.mlrPineText, keywords: "directory roster people",
                 action: push { AdminMembersView() }),
            Tool(id: "houses", title: "Houses",
                 description: "Create houses, reorder them, and assign members",
                 icon: "house.fill", color: Color.mlrAccent,
                 action: push { AdminHousesView() }),
            Tool(id: "committees", title: "Committees & Join Requests",
                 description: "Rosters and pending join request queue",
                 icon: "person.3.fill", color: Color.mlrInfo, keywords: "roles lead",
                 badge: joinRequestCount,
                 action: push { AdminCommitteesView() }),
            Tool(id: "signins", title: "Recent Sign-Ins",
                 description: "See who has signed in and from where",
                 icon: "clock.arrow.circlepath", color: Color.mlrInfo, keywords: "login activity",
                 action: push { AdminSignInsView() }),
            Tool(id: "preview", title: "Preview As",
                 description: "See the app as a member or a guest",
                 icon: "eye.fill", color: Color.mlrWarning, keywords: "view as impersonate",
                 action: push { PreviewAsView() }),
            Tool(id: "invite", title: "Invite People",
                 description: "Branded welcome email · signs them straight in",
                 icon: "envelope.badge.fill", color: Color.mlrPineText, keywords: "email welcome",
                 action: .sheetInvite),
        ]

        var content: [Tool] = [
            Tool(id: "moderation", title: "Content Review",
                 description: "Review flagged posts and comments",
                 icon: "shield.lefthalf.filled", color: Color.mlrDanger, keywords: "moderation flagged",
                 action: push { AdminModerationView() }),
            Tool(id: "eventchats", title: "Event chats",
                 description: "Reopen an archived event chat",
                 icon: "archivebox.fill", color: Color.mlrInfo,
                 action: push { AdminEventChatsView() }),
            Tool(id: "callouts", title: "Home Callouts",
                 description: "Swipeable cards above the fest spotlight",
                 icon: "rectangle.stack.fill", color: Color.mlrFest, keywords: "home cards",
                 action: push { AdminCalloutsView() }),
            Tool(id: "broadcast", title: "Broadcast",
                 description: "Banner, Activity feed, and/or email — in one send",
                 icon: "megaphone.fill", color: Color.mlrAccent, keywords: "announcement send",
                 action: push { AdminBroadcastComposer() }),
            Tool(id: "scheduled", title: "Scheduled",
                 description: "Upcoming & recent scheduled broadcasts",
                 icon: "clock.badge.checkmark", color: Color.mlrInfo, keywords: "broadcast later",
                 action: push { AdminScheduledBroadcasts() }),
            Tool(id: "fest", title: "Family Fest Planner",
                 description: "Schedule, dinners, dues & payees — the master editor",
                 icon: "star.fill", color: Color.mlrFest,
                 action: push { FamilyFestPlannerView() }),
            Tool(id: "images", title: "App Images",
                 description: "Swap the Home logo and Family Fest cover",
                 icon: "photo.stack.fill", color: Color.mlrPineText, keywords: "logo cover photo",
                 action: push { AppImagesAdminView() }),
            Tool(id: "logofx", title: "Logo effects",
                 description: "Falling leaves and snow on the Home logo: seasons and dates",
                 icon: "snowflake", color: Color.mlrLake, keywords: "autumn winter snow leaves season schedule",
                 action: push { AdminLogoFXView() }),
        ]
        if let url = URL(string: "https://docs.google.com/forms/create") {
            content.append(Tool(id: "form", title: "Create a Google Form",
                                description: "Survey, poll, or sign-up — then link it from a callout",
                                icon: "doc.text.fill", color: Color.mlrInfo, keywords: "survey",
                                action: .link(url)))
        }

        let places: [Tool] = [
            Tool(id: "bookings", title: "Cabin Bookings",
                 description: "Approve or deny cabin stay requests",
                 icon: "house.lodge.fill", color: Color.mlrWarning, keywords: "stay requests",
                 action: push { AdminCabinBookings() }),
            Tool(id: "cabins", title: "Cabins",
                 description: "Edit cabins, rooms, beds, and availability",
                 icon: "house.lodge", color: Color.mlrPineText, keywords: "rooms beds",
                 action: push { AdminCabinDetails() }),
            Tool(id: "local-places", title: "Local Places",
                 description: "Add, edit, reorder or hide the nearby spots members see",
                 icon: "mappin.and.ellipse", color: Color.mlrInfo, keywords: "restaurants golf coffee phone menu",
                 action: push { AdminLocalPlacesView() }),
        ]

        var system: [Tool] = [
            Tool(id: "help", title: "Help Contact",
                 description: "Who the Help page says to text or call",
                 icon: "phone.fill", color: Color.mlrAccent,
                 action: push { AdminHelpContactView() }),
            Tool(id: "notiftest", title: "Notification Test",
                 description: "Ping one member, track who's confirmed",
                 icon: "bell.badge.fill", color: Color.mlrPineText, keywords: "push",
                 action: push { NotificationTestView() }),
        ]
        // Hidden from every admin except lib/owner.ts's OWNER_EMAIL — see
        // MLRApp/Shared/Utilities/Owner.swift. Restarting the mac mini is
        // an infrastructure control, not app content, so it's narrower
        // than the broader `profiles.is_admin` every app admin has.
        if isOwner(env.currentProfile?.email) {
            system.append(Tool(id: "system", title: "System",
                               description: "Media server status · pull latest & restart (owner)",
                               icon: "server.rack", color: Color.mlrTextMuted, keywords: "mac mini server restart",
                               action: push { AdminSystemView() }))
        }

        return [
            ToolGroup(id: "people", title: "People", icon: "person.2.fill",
                  blurb: "Who's in, who's verified, and where they belong", tools: people),
            ToolGroup(id: "content", title: "Content", icon: "square.and.pencil",
                  blurb: "What members see and hear from the resort", tools: content),
            ToolGroup(id: "places", title: "Places & things", icon: "house.lodge.fill",
                  blurb: "Cabins, stays and nearby places", tools: places),
            ToolGroup(id: "system", title: "System", icon: "gearshape.fill",
                  blurb: "Contact details, tests and server controls", tools: system),
        ]
    }

    /// Groups narrowed by the search text (title, description, keywords).
    private var visibleGroups: [ToolGroup] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return groups }
        return groups.compactMap { g in
            let hit = g.tools.filter { "\($0.title) \($0.description) \($0.keywords)".lowercased().contains(q) }
            return hit.isEmpty ? nil : ToolGroup(id: g.id, title: g.title, icon: g.icon, blurb: g.blurb, tools: hit)
        }
    }

    var body: some View {
        List {
            ForEach(visibleGroups) { group in
                Section {
                    ForEach(group.tools) { tool in row(for: tool).listRowBackground(Color.mlrCard) }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(group.title, systemImage: group.icon)
                            .font(.mlrSectionTitle)
                            .foregroundStyle(Color.mlrText)
                            .textCase(nil)
                        Text(group.blurb)
                            .font(.mlrCaption13)
                            .foregroundStyle(Color.mlrTextMuted)
                            .textCase(nil)
                    }
                }
            }
            if visibleGroups.isEmpty {
                Text("No admin tools match \u{201C}\(query)\u{201D}.")
                    .font(.mlrCaption)
                    .foregroundStyle(Color.mlrTextMuted)
            }
        }
        .environment(\.defaultMinListRowHeight, 46)
        .listSectionSpacing(10)
        .contentMargins(.bottom, 96, for: .scrollContent)
        .mlrBackdrop()
        .navigationTitle("Admin")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search admin tools")
        .sheet(isPresented: $showInvite) {
            AdminInviteView()
        }
        .task {
            // The same call Admin -> Committees makes; feeds the join-request badge.
            try? await env.committeeService.fetchPendingRequests()
        }
    }

    @ViewBuilder
    private func row(for tool: Tool) -> some View {
        switch tool.action {
        case .push(let make):
            NavigationLink(destination: make()) {
                adminRow(icon: tool.icon, iconColor: tool.color, title: tool.title,
                         description: tool.description, badge: tool.badge)
            }
        case .sheetInvite:
            Button { showInvite = true } label: {
                adminRow(icon: tool.icon, iconColor: tool.color, title: tool.title,
                         description: tool.description, badge: tool.badge)
            }
            .buttonStyle(.pressable)
        case .link(let url):
            Link(destination: url) {
                adminRow(icon: tool.icon, iconColor: tool.color, title: tool.title,
                         description: tool.description, badge: tool.badge)
            }
        }
    }

    // MARK: - Row builders

    private func adminRow(
        icon: String,
        iconColor: Color,
        title: String,
        description: String,
        badge: Int = 0
    ) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: icon, accent: iconColor, size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.mlrScaled(16, weight: .semibold))
                    .foregroundStyle(Color.mlrText)
                Text(description)
                    .font(.mlrCaption13)
                    .foregroundStyle(Color.mlrTextMuted)
            }
            Spacer(minLength: 0)
            if badge > 0 {
                Text("\(badge)")
                    .font(.mlrScaled(12, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.mlrDanger).clipShape(Capsule())
                    .contentTransition(.numericText())
                    .accessibilityLabel("\(badge) waiting")
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack {
        AdminView()
    }
    .environment(AppEnvironment())
}

// MARK: - InPlaceEditPencil
//
// The one shared "edit in place" control: a small pencil that sits next to the
// thing itself for people with edit rights. If an `EditPencil` later lands in
// EditorKit.swift, replace this struct's body with it (call sites stay as is).

