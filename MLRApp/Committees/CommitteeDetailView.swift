import SwiftUI
import AppIntents

// MARK: - CommitteeDetailView
// The roster IS the membership (migration 0057): you're a member if your account
// is linked to a roster entry, or you're an app admin. Leads are leads of a role
// (roster `roles` like "Meals · Lead") — there's no separate committee-member
// "Lead" or "Chat members" list anymore. App admins can add/remove people and
// edit their roles here; anyone signed in can email a whole committee or a role.

struct CommitteeDetailView: View {
    @Environment(AppEnvironment.self) private var env

    let committee: Committee

    @State private var roster: [CommitteeRosterEntry] = []
    @State private var isLoading = true
    @State private var editing: CommitteeRosterEntry? = nil
    @State private var addingNew = false
    @State private var showEmail = false
    @State private var selectedProfile: Profile?
    @State private var reviewingIds: Set<UUID> = []
    @State private var showMyAreas = false
    @State private var confirmLeave = false
    @State private var leaving = false

    /// Canonical area order for role-based committees (matches the web).
    private let festAreas = [
        "Meals",
        "Entertainment & Games",
        "Art & Decorating",
        "Merchandise, Fundraising & Polling",
        "Logistics, Scheduling & Finance",
    ]

    private var roleBased: Bool { committee.slug == "family-fest" || roster.contains { !$0.roles.isEmpty } }
    private var canManage: Bool { env.isAdmin }   // app admins have universal privileges

    /// A lead of this committee (per the roster) may also review join requests —
    /// matching the web app, which gates approval on `isAdmin || committee lead`.
    private var iAmLead: Bool {
        guard let me = env.currentProfile else { return false }
        return roster.contains { $0.linkedUserId == me.id && $0.isLead }
    }
    private var canReview: Bool { env.isAdmin || iAmLead }

    /// My own linked roster entry, if I'm on this committee's roster.
    private var myEntry: CommitteeRosterEntry? {
        guard let me = env.currentProfile else { return nil }
        return roster.first { $0.linkedUserId == me.id }
    }

    /// The areas I currently work in (roster roles with the " · Lead" suffix stripped).
    private var myAreas: [String] {
        (myEntry?.roles ?? []).map {
            $0.hasSuffix(" · Lead") ? String($0.dropLast(" · Lead".count)) : $0
        }
    }

    /// Pending join requests scoped to this committee.
    private var pendingForCommittee: [CommitteeJoinRequest] {
        env.committeeService.pendingRequests.filter { $0.committeeId == committee.id }
    }

    /// Member = linked roster account, or an app admin.
    private var isMember: Bool {
        env.isAdmin || (env.currentProfile.map { me in roster.contains { $0.linkedUserId == me.id } } ?? false)
    }

    private var allEmails: [String] {
        roster.compactMap { $0.effectiveEmail?.trimmedNonEmpty }
    }

    /// Roster people who have an email, mapped for the email composer. Areas come
    /// from their roles (lead suffix stripped) so the composer's "By Role" works.
    private var emailRecipients: [CommitteeEmailComposer.Recipient] {
        roster.compactMap { e in
            guard let email = e.effectiveEmail?.trimmedNonEmpty else { return nil }
            let areas = e.roles.map { $0.hasSuffix(" · Lead") ? String($0.dropLast(" · Lead".count)) : $0 }
            return CommitteeEmailComposer.Recipient(id: e.id, name: e.displayName, email: email, areas: Array(Set(areas)))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if isMember {
                    chatLink
                }

                // Email sits right under the chat entry.
                if env.isSignedIn && !allEmails.isEmpty {
                    Button {
                        showEmail = true
                    } label: {
                        Label("Email these members", systemImage: "envelope.fill")
                            .font(.mlrScaled(15, weight: .semibold))
                            .foregroundStyle(Color.mlrPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.mlrPrimary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }

                if canManage {
                    Button { addingNew = true } label: {
                        Label("Add a member", systemImage: "person.badge.plus")
                            .font(.mlrScaled(15, weight: .semibold))
                            .foregroundStyle(Color.mlrPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.mlrPrimary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }

                if canReview && !pendingForCommittee.isEmpty {
                    joinRequestsSection
                }

                if myEntry != nil {
                    selfServiceSection
                }

                rosterSection
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(committee.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task {
            await load()
            // Live-update the roster when members are added/removed anywhere
            // (e.g. from the web app or another device), matching web behavior.
            env.committeeService.subscribeToRoster(slug: committee.slug) {
                Task { await load() }
            }
            // Live-update pending join requests + membership for managers.
            env.committeeService.subscribeToManagement(slug: committee.slug, committeeId: committee.id) {
                Task { await load() }
            }
        }
        .onDisappear {
            env.committeeService.unsubscribeFromRoster(slug: committee.slug)
            env.committeeService.unsubscribeFromManagement(slug: committee.slug)
        }
        .sheet(item: $editing) { entry in
            RosterEditSheet(committee: committee, entry: entry, areas: festAreas, roleBased: roleBased) {
                Task { await load() }
            }
        }
        .sheet(isPresented: $addingNew) {
            RosterEditSheet(committee: committee, entry: nil, areas: festAreas, roleBased: roleBased) {
                Task { await load() }
            }
        }
        .sheet(isPresented: $showEmail) {
            CommitteeEmailComposer(committee: committee, presetRecipients: emailRecipients)
        }
        .sheet(item: $selectedProfile) { profile in
            MemberSheetView(member: profile)
        }
        .sheet(isPresented: $showMyAreas) {
            MyCommitteeAreasSheet(
                committeeId: committee.id,
                allAreas: festAreas,
                current: myAreas
            ) { Task { await load() } }
        }
        .confirmationDialog("Leave \(committee.name)?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave committee", role: .destructive) { Task { await leave() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll be removed from the roster and lose access to its chats. You can request to rejoin later.")
        }
    }

    // MARK: - Self-service (my membership)

    private var selfServiceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Your membership")

            if roleBased {
                if !myAreas.isEmpty {
                    FlowChips(items: myAreas)
                }
                Button { showMyAreas = true } label: {
                    Label(myAreas.isEmpty ? "Choose your areas" : "Edit your areas",
                          systemImage: "checklist")
                        .font(.mlrScaled(15, weight: .semibold))
                        .foregroundStyle(Color.mlrPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.mlrPrimary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }

            Button { confirmLeave = true } label: {
                HStack {
                    if leaving { ProgressView().tint(Color.mlrDanger) }
                    Label("Leave committee", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.mlrScaled(15, weight: .semibold))
                        .foregroundStyle(Color.mlrDanger)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.mlrDanger.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(leaving)
        }
    }

    private func leave() async {
        leaving = true
        defer { leaving = false }
        do {
            try await env.committeeService.leaveCommittee(committeeId: committee.id)
            if let uid = env.currentProfile?.id {
                await env.committeeService.fetchMyMemberships(userId: uid)
            }
            await load()
        } catch {
            print("[CommitteeDetail] leave error: \(error)")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Text(committee.emoji ?? "📋")
                    .font(.mlrScaled(40))
                VStack(alignment: .leading, spacing: 3) {
                    Text(committee.name)
                        .font(.mlrScaled(22, weight: .bold))
                        .foregroundStyle(Color.mlrText)
                    if committee.isPrivate == true {
                        Label("Private committee", systemImage: "lock.fill")
                            .font(.mlrScaled(12))
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

    private var chatLink: some View {
        NavigationLink {
            CommitteeChatView(committee: committee, members: [])
        } label: {
            Label("Open committee chat", systemImage: "bubble.left.and.bubble.right.fill")
                .primaryButton()
        }
        .buttonStyle(.plain)
    }

    // MARK: - Join requests

    private var joinRequestsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Join requests (\(pendingForCommittee.count))")
            VStack(spacing: 0) {
                ForEach(pendingForCommittee) { req in
                    joinRequestRow(req)
                    if req.id != pendingForCommittee.last?.id { Divider().padding(.leading, 52) }
                }
            }
            .background(Color.mlrCard)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private func joinRequestRow(_ req: CommitteeJoinRequest) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(url: req.profile?.avatarUrl, size: .small)
            VStack(alignment: .leading, spacing: 4) {
                Text(req.profile?.displayName ?? "Member")
                    .font(.mlrScaled(15, weight: .medium))
                    .foregroundStyle(Color.mlrText)
                if !req.areas.isEmpty {
                    FlowChips(items: req.areas)
                }
                if let note = req.note?.trimmedNonEmpty {
                    Text(note)
                        .font(.mlrScaled(13))
                        .foregroundStyle(Color.mlrTextMuted)
                }
            }
            Spacer()
            if reviewingIds.contains(req.id) {
                ProgressView()
            } else {
                HStack(spacing: 10) {
                    Button { review(req, approve: false) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.mlrScaled(24))
                            .foregroundStyle(Color.mlrTextSubtle)
                    }
                    .buttonStyle(.plain)
                    Button { review(req, approve: true) } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.mlrScaled(24))
                            .foregroundStyle(Color.mlrPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func review(_ req: CommitteeJoinRequest, approve: Bool) {
        reviewingIds.insert(req.id)
        Task {
            do {
                if approve {
                    try await env.committeeService.approveJoin(requestId: req.id)
                } else {
                    try await env.committeeService.declineJoin(requestId: req.id)
                }
                // Approving inserts a membership row and links the roster slot —
                // refresh so the new member shows up immediately.
                await load()
            } catch {
                print("[CommitteeDetailView] review join request error: \(error)")
            }
            reviewingIds.remove(req.id)
        }
    }

    // MARK: - Roster

    @ViewBuilder
    private var rosterSection: some View {
        if isLoading && roster.isEmpty {
            SkeletonRow()
        } else if roster.isEmpty {
            Text("No one's on this committee yet.")
                .font(.mlrCaption)
                .foregroundStyle(Color.mlrTextMuted)
        } else if roleBased {
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
                // Anyone on the roster with no area assigned yet.
                let unassigned = roster.filter { $0.roles.isEmpty }
                if !unassigned.isEmpty {
                    plainCard(title: "On the committee", entries: unassigned)
                }
            }
        } else {
            plainCard(title: "Members (\(roster.count))", entries: roster)
        }
    }

    private func areaCard(area: String, entries: [CommitteeRosterEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(area)
                .font(.mlrScaled(15, weight: .semibold))
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

    private func plainCard(title: String, entries: [CommitteeRosterEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: title)
            VStack(spacing: 0) {
                ForEach(entries) { entry in
                    rosterRow(entry, showLead: entry.isLead)
                    if entry.id != entries.last?.id { Divider().padding(.leading, 52) }
                }
            }
            .background(Color.mlrCard)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    @ViewBuilder
    private func rosterRow(_ entry: CommitteeRosterEntry, showLead: Bool) -> some View {
        HStack(spacing: 12) {
            // Linked members open their full profile on tap.
            Button {
                if let uid = entry.linkedUserId { openProfile(uid) }
            } label: {
                AvatarView(url: entry.isLinked ? entry.profile?.avatarUrl : nil, size: .small)
            }
            .buttonStyle(.plain)
            .disabled(!entry.isLinked)

            VStack(alignment: .leading, spacing: 3) {
                Button {
                    if let uid = entry.linkedUserId { openProfile(uid) }
                } label: {
                    Text(entry.displayName)
                        .font(.mlrScaled(15, weight: .medium))
                        .foregroundStyle(Color.mlrText)
                }
                .buttonStyle(.plain)
                .disabled(!entry.isLinked)
                if entry.isPending {
                    Text("Pending verification")
                        .font(.mlrScaled(10, weight: .medium))
                        .foregroundStyle(Color.mlrTextMuted)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.mlrTextMuted.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            Spacer()
            if showLead {
                Text("Lead")
                    .font(.mlrScaled(11, weight: .bold))
                    .foregroundStyle(Color.mlrPrimary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.mlrPrimaryLight)
                    .clipShape(Capsule())
            }
            rosterContact(entry)
            if canManage {
                Button { editing = entry } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.mlrScaled(16))
                        .foregroundStyle(Color.mlrTextSubtle)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func rosterContact(_ entry: CommitteeRosterEntry) -> some View {
        if env.isSignedIn {
            HStack(spacing: 10) {
                if let phone = entry.effectivePhone?.trimmedNonEmpty {
                    if let url = URL(string: "tel:\(phone)") {
                        Link(destination: url) {
                            Image(systemName: "phone.fill").font(.mlrScaled(13)).foregroundStyle(Color.mlrPrimary)
                        }
                    }
                    if let sms = URL(string: "sms:\(phone)") {
                        Link(destination: sms) {
                            Image(systemName: "message.fill").font(.mlrScaled(13)).foregroundStyle(Color.mlrInfo)
                        }
                    }
                }
                if let email = entry.effectiveEmail?.trimmedNonEmpty, let url = URL(string: "mailto:\(email)") {
                    Link(destination: url) {
                        Image(systemName: "envelope.fill").font(.mlrScaled(13)).foregroundStyle(Color.mlrTextMuted)
                    }
                }
            }
        }
    }

    // MARK: - Data

    private func load() async {
        isLoading = true
        roster = (try? await env.committeeService.fetchRoster(slug: committee.slug)) ?? roster
        // Managers (admins / committee leads) also see and act on pending join requests.
        if env.isAdmin || iAmLead {
            try? await env.committeeService.fetchPendingRequests()
        }
        isLoading = false
    }

    /// Fetch a linked member's full profile and open the member sheet.
    private func openProfile(_ userId: UUID) {
        Task {
            let profile: Profile? = try? await supabase
                .from("profiles")
                .select()
                .eq("id", value: userId.uuidString)
                .single()
                .execute()
                .value
            if let profile { selectedProfile = profile }
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - Wrapping area chips

/// The requested areas as small pills that wrap onto multiple lines.
private struct FlowChips: View {
    let items: [String]
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.mlrScaled(11, weight: .semibold))
                    .foregroundStyle(Color.mlrPrimary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.mlrPrimaryLight)
                    .clipShape(Capsule())
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? max(0, x - spacing) : maxWidth,
                      height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x - bounds.minX + size.width > bounds.width && x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
