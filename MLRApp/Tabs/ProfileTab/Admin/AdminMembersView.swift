import SwiftUI

// MARK: - AdminMember
// Row data returned by the `admin_members()` RPC.

struct AdminMember: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let email: String
    var isAdmin: Bool
    var betaTester: Bool  // kept for DB compat; not surfaced in UI
    var avatarUrl: String?
    var houseId: UUID?    // the member's house (migration 0064), admin-assigned
    var houseName: String?

    enum CodingKeys: String, CodingKey {
        case id, name, email
        case isAdmin    = "is_admin"
        case betaTester = "beta_tester"
        case avatarUrl  = "avatar_url"
        case houseId    = "house_id"
        case houseName  = "house_name"
    }

    // Lenient decode: a single member with a null email/name (or any missing
    // optional) must not fail the whole list. created_at is ignored (unused).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Member"
        email = (try? c.decode(String.self, forKey: .email)) ?? ""
        isAdmin = (try? c.decode(Bool.self, forKey: .isAdmin)) ?? false
        betaTester = (try? c.decode(Bool.self, forKey: .betaTester)) ?? false
        avatarUrl = try? c.decode(String.self, forKey: .avatarUrl)
        houseId = try? c.decodeIfPresent(UUID.self, forKey: .houseId)
        houseName = try? c.decodeIfPresent(String.self, forKey: .houseName)
    }
}

// MARK: - AdminMembersView

struct AdminMembersView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var members: [AdminMember] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var error: String? = nil
    @State private var memberToRemove: AdminMember? = nil
    @State private var showRemoveAlert = false

    private var currentUserId: UUID? { env.currentProfile?.id }

    private var filtered: [AdminMember] {
        guard !searchText.isEmpty else { return members }
        let q = searchText.lowercased()
        return members.filter {
            $0.name.lowercased().contains(q) || $0.email.lowercased().contains(q)
        }
    }

    // MARK: - Body

    var body: some View {
        List {
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.mlrDanger)
                        .font(.subheadline)
                }
            }

            if isLoading && members.isEmpty {
                ForEach(0..<8, id: \.self) { _ in
                    memberSkeleton
                }
            }

            ForEach(filtered) { member in
                MemberRow(
                    member: member,
                    currentUserId: currentUserId,
                    houses: env.housesService.houses,
                    onToggleAdmin: { Task { await toggleAdmin(member) } },
                    onToggleBeta: { Task { await toggleBeta(member) } },
                    onSetHouse: { hid in Task { await setHouse(member, houseId: hid) } },
                    onRemove: {
                        memberToRemove = member
                        showRemoveAlert = true
                    }
                )
            }
        }
        .searchable(text: $searchText, prompt: "Search members")
        .navigationTitle("Members")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    AdminSignInsView()
                } label: {
                    Label("Sign-Ins", systemImage: "clock.arrow.circlepath")
                        .font(.mlrScaled(14))
                }
            }
        }
        .refreshable {
            await loadMembers()
        }
        .task {
            await loadMembers()
            if env.housesService.houses.isEmpty { await env.housesService.fetchHouses() }
        }
        .alert("Remove member?", isPresented: $showRemoveAlert, presenting: memberToRemove) { m in
            Button("Remove \(m.name)", role: .destructive) {
                Task { await removeMember(m) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { m in
            Text("This permanently removes \(m.name)'s account and all their data. This cannot be undone.")
        }
    }

    // MARK: - Skeleton

    private var memberSkeleton: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.mlrCard)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(Color.mlrCard).frame(height: 13).frame(maxWidth: 150)
                RoundedRectangle(cornerRadius: 4).fill(Color.mlrCard).frame(height: 11).frame(maxWidth: 200)
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(Color.mlrSurface)
    }

    // MARK: - Actions

    @MainActor
    private func loadMembers() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let result: [AdminMember] = try await supabase
                .rpc("admin_members")
                .execute()
                .value
            members = result.sorted { $0.name < $1.name }
        } catch {
            self.error = "Couldn't load members."
        }
    }

    @MainActor
    private func toggleAdmin(_ member: AdminMember) async {
        guard member.id != currentUserId else { return }
        let newValue = !member.isAdmin
        do {
            struct P: Encodable { let target: String; let value: Bool }
            try await supabase
                .rpc("set_admin", params: P(target: member.id.uuidString, value: newValue))
                .execute()
            if let idx = members.firstIndex(of: member) {
                members[idx].isAdmin = newValue
            }
        } catch {
            self.error = "Couldn't update admin role."
        }
    }

    @MainActor
    private func toggleBeta(_ member: AdminMember) async {
        let newValue = !member.betaTester
        do {
            struct P: Encodable { let target: String; let value: Bool }
            try await supabase
                .rpc("set_beta_tester", params: P(target: member.id.uuidString, value: newValue))
                .execute()
            if let idx = members.firstIndex(of: member) {
                members[idx].betaTester = newValue
            }
        } catch {
            self.error = "Couldn't update beta-tester status."
        }
    }

    @MainActor
    private func setHouse(_ member: AdminMember, houseId: UUID?) async {
        do {
            try await env.housesService.setMemberHouse(target: member.id, houseId: houseId)
            if let idx = members.firstIndex(of: member) {
                members[idx].houseId = houseId
                members[idx].houseName = houseId.flatMap { hid in
                    env.housesService.houses.first { $0.id == hid }?.name
                }
            }
        } catch {
            self.error = "Couldn't update house."
        }
    }

    @MainActor
    private func removeMember(_ member: AdminMember) async {
        guard !member.isAdmin, member.id != currentUserId else { return }
        do {
            try await supabase
                .rpc("delete_member", params: ["target": member.id.uuidString])
                .execute()
            members.removeAll { $0.id == member.id }
        } catch {
            self.error = "Couldn't remove member."
        }
    }
}

// MARK: - MemberRow

private struct MemberRow: View {
    let member: AdminMember
    let currentUserId: UUID?
    let houses: [House]
    let onToggleAdmin: () -> Void
    let onToggleBeta: () -> Void
    let onSetHouse: (UUID?) -> Void
    let onRemove: () -> Void

    private var isSelf: Bool { member.id == currentUserId }
    private var canRemove: Bool { !isSelf && !member.isAdmin }

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(url: member.avatarUrl, size: .medium, isAdmin: member.isAdmin)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(member.name)
                        .font(.mlrScaled(15, weight: .semibold))
                        .foregroundStyle(Color.mlrText)

                    if member.isAdmin {
                        badge("Admin", color: Color.mlrPrimary)
                    }
                    if let houseName = member.houseName {
                        badge("🏠 \(houseName)", color: Color.mlrAccent)
                    }
                    if member.betaTester {
                        badge("Beta", color: Color.mlrAccent)
                    }
                    if isSelf {
                        badge("You", color: Color.mlrInfo)
                    }
                }
                Text(member.email)
                    .font(.caption)
                    .foregroundStyle(Color.mlrTextMuted)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            if !isSelf {
                Button {
                    onToggleAdmin()
                } label: {
                    Label(
                        member.isAdmin ? "Remove admin" : "Make admin",
                        systemImage: member.isAdmin ? "shield.slash" : "shield.fill"
                    )
                }
            }

            Button {
                onToggleBeta()
            } label: {
                Label(
                    member.betaTester ? "Remove beta tester" : "Make beta tester",
                    systemImage: member.betaTester ? "testtube.2" : "testtube.2"
                )
            }

            if !houses.isEmpty {
                Menu {
                    Button {
                        onSetHouse(nil)
                    } label: {
                        Label("No house", systemImage: member.houseId == nil ? "checkmark" : "")
                    }
                    ForEach(houses) { house in
                        Button {
                            onSetHouse(house.id)
                        } label: {
                            Label("\(house.emoji) \(house.name)",
                                  systemImage: member.houseId == house.id ? "checkmark" : "")
                        }
                    }
                } label: {
                    Label("Assign house", systemImage: "house.fill")
                }
            }

            if canRemove {
                Divider()
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label("Remove member", systemImage: "trash")
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canRemove {
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if !isSelf {
                Button {
                    onToggleAdmin()
                } label: {
                    Label(member.isAdmin ? "Remove admin" : "Make admin", systemImage: "shield.fill")
                }
                .tint(Color.mlrPrimary)
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.mlrScaled(10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

#Preview {
    NavigationStack {
        AdminMembersView()
    }
    .environment(AppEnvironment())
}
