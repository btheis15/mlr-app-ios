import SwiftUI

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

    /// Member = linked roster account, or an app admin.
    private var isMember: Bool {
        env.isAdmin || (env.currentProfile.map { me in roster.contains { $0.linkedUserId == me.id } } ?? false)
    }

    private var allEmails: [String] {
        roster.compactMap { $0.email?.trimmedNonEmpty }
    }

    /// Roster people who have an email, mapped for the email composer. Areas come
    /// from their roles (lead suffix stripped) so the composer's "By Role" works.
    private var emailRecipients: [CommitteeEmailComposer.Recipient] {
        roster.compactMap { e in
            guard let email = e.email?.trimmedNonEmpty else { return nil }
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
                            .font(.system(size: 15, weight: .semibold))
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
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.mlrPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.mlrPrimary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }

                rosterSection
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(committee.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
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

    private var chatLink: some View {
        NavigationLink {
            CommitteeChatView(committee: committee, members: [])
        } label: {
            Label("Open committee chat", systemImage: "bubble.left.and.bubble.right.fill")
                .primaryButton()
        }
        .buttonStyle(.plain)
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
            if canManage {
                Button { editing = entry } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16))
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
                if let phone = entry.phone?.trimmedNonEmpty {
                    if let url = URL(string: "tel:\(phone)") {
                        Link(destination: url) {
                            Image(systemName: "phone.fill").font(.system(size: 13)).foregroundStyle(Color.mlrPrimary)
                        }
                    }
                    if let sms = URL(string: "sms:\(phone)") {
                        Link(destination: sms) {
                            Image(systemName: "message.fill").font(.system(size: 13)).foregroundStyle(Color.mlrInfo)
                        }
                    }
                }
                if let email = entry.email?.trimmedNonEmpty, let url = URL(string: "mailto:\(email)") {
                    Link(destination: url) {
                        Image(systemName: "envelope.fill").font(.system(size: 13)).foregroundStyle(Color.mlrTextMuted)
                    }
                }
            }
        }
    }

    // MARK: - Data

    private func load() async {
        isLoading = true
        roster = (try? await env.committeeService.fetchRoster(slug: committee.slug)) ?? roster
        isLoading = false
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
