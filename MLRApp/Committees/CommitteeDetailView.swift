import SwiftUI

// MARK: - CommitteeDetailView
// Committee header, member roster with lead badges, join status, a Chat
// entry (approved members only), and an admin/lead pending-request queue.

struct CommitteeDetailView: View {
    @Environment(AppEnvironment.self) private var env

    let committee: Committee

    @State private var members: [CommitteeMember] = []
    @State private var roster: [CommitteeRosterEntry] = []
    @State private var pending: [CommitteeJoinRequest] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var actionInFlight: Set<UUID> = []
    @State private var joining = false
    @State private var requested = false
    @State private var selectedJoinArea: String?
    @State private var managingMember: CommitteeMember?
    @State private var showEmail = false

    private var myMembership: CommitteeMember? {
        env.committeeService.myMemberships.first { $0.committeeId == committee.id }
    }

    private var isMember: Bool { myMembership != nil }

    private var canManage: Bool {
        env.isAdmin || myMembership?.role == .lead || myMembership?.role == .admin
    }

    /// Any member of this committee (or an app admin) can email the roster.
    private var canEmail: Bool { isMember || env.isAdmin }

    /// Areas in use on this committee — drives the join picker + manage suggestions.
    private var committeeAreas: [String] {
        Array(Set(members.flatMap(\.areas))).sorted()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                // Chat is always reachable (the chat view itself handles
                // non-members); a request-to-join prompt shows below for guests.
                chatLink

                if !isMember {
                    joinPrompt
                }

                if canManage && !pending.isEmpty {
                    pendingSection
                }

                // The full roster — everyone on the committee, grouped by area.
                rosterSection

                // Chat-access management (leads/admins only).
                if canManage {
                    membersSection
                }

                if canEmail && !members.isEmpty {
                    Button {
                        showEmail = true
                    } label: {
                        Label("Email these members", systemImage: "envelope.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.mlrPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.mlrPrimary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(committee.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: $showEmail) {
            CommitteeEmailComposer(committee: committee, members: members)
        }
        .sheet(item: $managingMember) { member in
            CommitteeMemberManageSheet(
                committee: committee,
                member: member,
                suggestedAreas: committeeAreas
            ) {
                Task { members = (try? await env.committeeService.fetchMembers(committeeId: committee.id)) ?? members }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Text(committee.emoji ?? "📋")
                    .font(.system(size: 40))
                VStack(alignment: .leading, spacing: 3) {
                    Text(committee.name)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.mlrText)
                    if committee.isPrivate == true {
                        Label("Private committee", systemImage: "lock.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.mlrTextMuted)
                    }
                }
            }
            if let desc = committee.description, !desc.isEmpty {
                Text(desc)
                    .font(.mlrBody)
                    .foregroundStyle(Color.mlrTextMuted)
            }
        }
    }

    // MARK: - Chat / Join

    private var chatLink: some View {
        NavigationLink {
            CommitteeChatView(committee: committee, members: members)
        } label: {
            Label("Open committee chat", systemImage: "bubble.left.and.bubble.right.fill")
                .primaryButton()
        }
        .buttonStyle(.plain)
    }

    private var joinPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(requested ? "Your request is pending a lead's approval."
                 : "Join to see the chat and pitch in.")
                .font(.mlrCaption)
                .foregroundStyle(Color.mlrTextMuted)

            // Area picker — optional preference for which area you'd help with.
            if !requested && !committeeAreas.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Which area are you interested in? (optional)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mlrTextMuted)
                    FlowChips(options: committeeAreas, selection: $selectedJoinArea)
                }
            }

            Button {
                Task { await requestJoin() }
            } label: {
                if joining {
                    ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Color.mlrPrimary).clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Text(requested ? "Requested" : "Request to join")
                        .primaryButton()
                }
            }
            .buttonStyle(.plain)
            .disabled(joining || requested)
            .opacity(requested ? 0.6 : 1)
        }
        .padding(16)
        .cardStyle()
    }

    // MARK: - Pending requests (manage)

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Pending requests")
            VStack(spacing: 10) {
                ForEach(pending) { request in
                    HStack(spacing: 12) {
                        if let profile = request.profile {
                            AvatarView(profile: profile, size: .small)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Color.mlrText)
                                if let area = request.requestedArea, !area.isEmpty {
                                    Text(area)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Color.mlrPrimary)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.mlrPrimaryLight)
                                        .clipShape(Capsule())
                                }
                                if let note = request.note, !note.isEmpty {
                                    Text(note)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.mlrTextMuted)
                                        .lineLimit(2)
                                }
                            }
                        } else {
                            Text("Member")
                                .font(.system(size: 15))
                                .foregroundStyle(Color.mlrText)
                        }
                        Spacer()
                        if actionInFlight.contains(request.id) {
                            ProgressView()
                        } else {
                            Button { Task { await decide(request, approve: true) } } label: {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(Color.mlrSuccess)
                            }
                            .buttonStyle(.plain)
                            Button { Task { await decide(request, approve: false) } } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(Color.mlrDanger)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                    .background(Color.mlrCard)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    // MARK: - Roster (everyone on the committee, grouped by area)

    /// Canonical area order for role-based committees (matches the web).
    private let festAreas = [
        "Meals",
        "Entertainment & Games",
        "Art & Decorating",
        "Merchandise, Fundraising & Polling",
        "Logistics, Scheduling & Finance",
    ]

    private var isRoleBased: Bool { roster.contains { !$0.roles.isEmpty } }

    @ViewBuilder
    private var rosterSection: some View {
        if isLoading && roster.isEmpty {
            SkeletonRow()
        } else if !roster.isEmpty {
            if isRoleBased {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel(text: "Roles & who's on them")
                    ForEach(festAreas, id: \.self) { area in
                        let inArea = roster
                            .filter { $0.roles.contains(area) || $0.roles.contains("\(area) · Lead") }
                            .sorted { a, b in
                                a.roles.contains("\(area) · Lead") && !b.roles.contains("\(area) · Lead")
                            }
                        if !inArea.isEmpty {
                            areaCard(area: area, entries: inArea)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "Members (\(roster.count))")
                    VStack(spacing: 0) {
                        ForEach(roster) { entry in
                            rosterRow(entry, showLead: entry.isLead)
                            if entry.id != roster.last?.id { Divider().padding(.leading, 52) }
                        }
                    }
                    .background(Color.mlrCard)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }

    private func areaCard(area: String, entries: [CommitteeRosterEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(area)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.mlrText)
            VStack(spacing: 0) {
                ForEach(entries) { entry in
                    rosterRow(entry, showLead: entry.roles.contains("\(area) · Lead"))
                    if entry.id != entries.last?.id { Divider().padding(.leading, 52) }
                }
            }
        }
        .padding(14)
        .background(Color.mlrCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func rosterRow(_ entry: CommitteeRosterEntry, showLead: Bool) -> some View {
        HStack(spacing: 12) {
            AvatarView(url: entry.isLinked ? entry.profile?.avatarUrl : nil, size: .small)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.mlrText)
                if entry.isPending {
                    Text("Pending verification")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.mlrTextMuted)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.mlrTextMuted.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            Spacer()
            if showLead {
                Text("Lead")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.mlrPrimary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.mlrPrimaryLight)
                    .clipShape(Capsule())
            }
            rosterContact(entry)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Tap-to-call / text / email for a roster slot (signed-in members only).
    @ViewBuilder
    private func rosterContact(_ entry: CommitteeRosterEntry) -> some View {
        if env.isSignedIn {
            HStack(spacing: 10) {
                if let phone = entry.phone, !phone.isEmpty,
                   let url = URL(string: "tel:\(phone)") {
                    Link(destination: url) {
                        Image(systemName: "phone.fill").font(.system(size: 13)).foregroundStyle(Color.mlrPrimary)
                    }
                    if let sms = URL(string: "sms:\(phone)") {
                        Link(destination: sms) {
                            Image(systemName: "message.fill").font(.system(size: 13)).foregroundStyle(Color.mlrInfo)
                        }
                    }
                }
                if let email = entry.email, !email.isEmpty,
                   let url = URL(string: "mailto:\(email)") {
                    Link(destination: url) {
                        Image(systemName: "envelope.fill").font(.system(size: 13)).foregroundStyle(Color.mlrTextMuted)
                    }
                }
            }
        }
    }

    // MARK: - Members

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Chat members (\(members.count))")
            if isLoading {
                SkeletonRow()
            } else if members.isEmpty {
                Text("No members yet.")
                    .font(.mlrCaption)
                    .foregroundStyle(Color.mlrTextMuted)
            } else {
                VStack(spacing: 0) {
                    ForEach(sortedMembers) { member in
                        memberRow(member)
                        if member.id != sortedMembers.last?.id {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .background(Color.mlrCard)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var sortedMembers: [CommitteeMember] {
        members.sorted { a, b in
            let rank: (CommitteeRole?) -> Int = { role in
                switch role { case .lead: return 0; case .admin: return 1; default: return 2 }
            }
            return rank(a.role) < rank(b.role)
        }
    }

    private func memberRow(_ member: CommitteeMember) -> some View {
        HStack(spacing: 12) {
            if let profile = member.profile {
                AvatarView(profile: profile, size: .medium)
            } else {
                AvatarView(url: nil, size: .medium)
            }
            VStack(alignment: .leading, spacing: 4) {
                if let profile = member.profile {
                    PrivateName(profile: profile, font: .system(size: 16, weight: .medium))
                } else {
                    Text("Member").foregroundStyle(Color.mlrText)
                }
                if !member.areas.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(member.areas, id: \.self) { area in
                            Text(area)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.mlrPrimary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.mlrPrimaryLight)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            Spacer()
            if member.role == .lead {
                Text("Lead")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.mlrPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.mlrPrimaryLight)
                    .clipShape(Capsule())
            }
            if canManage {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.mlrTextSubtle)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { if canManage { managingMember = member } }
    }

    // MARK: - Data

    private func load() async {
        isLoading = true
        loadError = nil
        // The roster (everyone) is the public display; committee_members backs
        // chat access + management. Load both; the roster is the headline list.
        roster = (try? await env.committeeService.fetchRoster(slug: committee.slug)) ?? roster
        do {
            members = try await env.committeeService.fetchMembers(committeeId: committee.id)
        } catch {
            loadError = "Couldn't load members."
            print("[CommitteeDetail] members error: \(error)")
        }
        if canManage {
            pending = (try? await fetchPendingForCommittee()) ?? []
        }
        isLoading = false
    }

    private func fetchPendingForCommittee() async throws -> [CommitteeJoinRequest] {
        try await supabase
            .from("committee_join_requests")
            .select("""
                id, committee_id, user_id, status, message, requested_area, created_at,
                profiles!user_id(id, display_name, contact_email, avatar_url, phone, is_admin,
                                 beta_tester, willing_to_help, intro_seen,
                                 email_alerts, push_level, push_types,
                                 notif_types, push_prompted, created_at)
            """)
            .eq("committee_id", value: committee.id.uuidString)
            .eq("status", value: "pending")
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    private func requestJoin() async {
        guard env.isSignedIn else { env.authService.promptSignIn(); return }
        joining = true
        defer { joining = false }
        do {
            try await env.committeeService.requestJoin(
                committeeId: committee.id, note: nil, requestedArea: selectedJoinArea
            )
            requested = true
        } catch {
            print("[CommitteeDetail] requestJoin error: \(error)")
        }
    }

    private func decide(_ request: CommitteeJoinRequest, approve: Bool) async {
        actionInFlight.insert(request.id)
        defer { actionInFlight.remove(request.id) }
        do {
            if approve {
                try await env.committeeService.approveJoin(requestId: request.id)
            } else {
                try await env.committeeService.declineJoin(requestId: request.id)
            }
            pending.removeAll { $0.id == request.id }
            if approve {
                members = (try? await env.committeeService.fetchMembers(committeeId: committee.id)) ?? members
            }
        } catch {
            print("[CommitteeDetail] decide error: \(error)")
        }
    }
}

// MARK: - FlowChips
// A simple single-select chip row (horizontally scrollable). Tapping the
// selected chip clears the selection.

private struct FlowChips: View {
    let options: [String]
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { option in
                    let on = selection == option
                    Button {
                        selection = on ? nil : option
                    } label: {
                        Text(option)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(on ? .white : Color.mlrText)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(on ? Color.mlrPrimary : Color.mlrCard)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(on ? Color.mlrPrimary : Color.mlrBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
