import SwiftUI

// MARK: - AdminMembersView
//
// Admin member directory (migration 0008 admin_members()): the full roster WITH
// private emails and each member's house — data a normal directory can't show.
// Search by name / email / household; tap a member to manage them (promote,
// assign house, edit info, remove) via the shared MemberSheetView. Mirrors the
// web AdminMembers screen.

struct AdminMembersView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var members: [AdminMemberRow] = []
    @State private var query = ""
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var selected: Profile?

    private var shown: [AdminMemberRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return members }
        return members.filter {
            [$0.name, $0.email, $0.household].compactMap { $0 }.contains { $0.lowercased().contains(q) }
        }
    }

    private var adminCount: Int { members.filter(\.isAdmin).count }

    var body: some View {
        List {
            if let loadError {
                Section { Label(loadError, systemImage: "xmark.circle").foregroundStyle(Color.mlrWarning) }
            }
            if isLoading && members.isEmpty {
                ForEach(0..<6, id: \.self) { _ in SkeletonShape(height: 40, cornerRadius: 8).listRowSeparator(.hidden) }
            } else {
                Section {
                    ForEach(shown) { m in
                        Button { Task { await open(m) } } label: { row(m) }
                            .buttonStyle(.plain)
                    }
                } footer: {
                    Text("\(members.count) member\(members.count == 1 ? "" : "s") · \(adminCount) admin\(adminCount == 1 ? "" : "s")")
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Name, email, or household")
        .navigationTitle("Members")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { AdminFamilyRosterView() } label: {
                    Label("Family roster", systemImage: "person.crop.rectangle.stack.fill")
                }
                .tint(Color.mlrPrimary)
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $selected, onDismiss: { Task { await load() } }) { profile in
            MemberSheetView(member: profile)
        }
    }

    private func row(_ m: AdminMemberRow) -> some View {
        HStack(spacing: 12) {
            AvatarView(url: m.avatarUrl, size: .small)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(m.displayNameOrEmail).font(.mlrScaled(15, weight: .medium)).foregroundStyle(Color.mlrText)
                    if m.isAdmin {
                        Text("Admin").font(.mlrScaled(10, weight: .bold))
                            .foregroundStyle(Color.mlrPrimary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.mlrPrimaryLight).clipShape(Capsule())
                    }
                }
                let subtitle = [m.houseName, m.email].compactMap { $0?.nilIfEmpty }.joined(separator: " · ")
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(Color.mlrTextMuted).lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.mlrTextSubtle)
        }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            members = try await supabase.rpc("admin_members").execute().value
        } catch {
            loadError = "Couldn't load members."
            print("[AdminMembers] load error: \(error)")
        }
    }

    /// Fetch the full profile so MemberSheetView's sections (bio/contact/pay) fill in.
    private func open(_ m: AdminMemberRow) async {
        if let p: Profile = try? await supabase
            .from("profiles").select("*").eq("id", value: m.id.uuidString).single().execute().value {
            selected = p
        }
    }
}

// MARK: - Row model (admin_members RPC)

struct AdminMemberRow: Decodable, Identifiable {
    let id: UUID
    let name: String?
    let avatarUrl: String?
    let household: String?
    let email: String?
    let isAdmin: Bool
    let houseName: String?

    var displayNameOrEmail: String { name?.nilIfEmpty ?? email ?? "Member" }

    enum CodingKeys: String, CodingKey {
        case id, email, household
        case name = "display_name"
        case avatarUrl = "avatar_url"
        case isAdmin = "is_admin"
        case houseName = "house_name"
    }
}

private extension String {
    var nilIfEmpty: String? { trimmingCharacters(in: .whitespaces).isEmpty ? nil : self }
}
