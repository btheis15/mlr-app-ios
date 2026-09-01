import SwiftUI
import Supabase

// MARK: - Verifying members (migrations 0181–0184, 0213)
//
// Anyone can sign up with any email address. Until an admin confirms they're
// really family, a new account sees only what a signed-out visitor sees (0183
// swapped 29 SELECT policies) and can write nothing at all (0213). This is the
// screen that lets them in.
//
// ⚠️ The DB column is `profiles.approved`; every label here says "verified".
// Deliberate and documented — Supabase's email OTP already owns the word
// "verified" for the address itself. Don't unify them.

struct AdminVerifyMembersView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var members: [Profile] = []
    @State private var loading = true
    @State private var busyId: UUID?
    @State private var showOnlyUnverified = true
    @State private var error: String?

    private var unverified: [Profile] { members.filter { !$0.approved } }
    private var shown: [Profile] { showOnlyUnverified ? unverified : members }

    var body: some View {
        List {
            Section {
                if unverified.isEmpty {
                    Label("Everyone's verified.", systemImage: "checkmark.seal.fill")
                        .font(.mlrScaled(13))
                        .foregroundStyle(Color.mlrSuccess)
                } else {
                    Label("\(unverified.count) \(unverified.count == 1 ? "person needs" : "people need") verifying",
                          systemImage: "person.badge.clock")
                        .font(.mlrScaled(13, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                Toggle("Only show unverified", isOn: $showOnlyUnverified)
            } footer: {
                Text("\(members.count - unverified.count) verified · \(unverified.count) not verified")
            }

            Section {
                if loading {
                    HStack { ProgressView(); Text("Loading…").foregroundStyle(Color.mlrTextMuted) }
                } else if shown.isEmpty {
                    Text(showOnlyUnverified ? "Nobody's waiting." : "No members found.")
                        .font(.mlrScaled(13))
                        .foregroundStyle(Color.mlrTextMuted)
                } else {
                    ForEach(shown) { member in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.name.isEmpty ? member.email : member.name)
                                    .font(.mlrScaled(15, weight: .medium))
                                if !member.email.isEmpty {
                                    Text(member.email)
                                        .font(.mlrScaled(11))
                                        .foregroundStyle(Color.mlrTextMuted)
                                }
                                if let joined = member.createdAt {
                                    Text("Signed up \(joined.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.mlrScaled(10))
                                        .foregroundStyle(Color.mlrTextSubtle)
                                }
                            }
                            Spacer(minLength: 0)
                            if busyId == member.id {
                                ProgressView()
                            } else if member.approved {
                                Button("Un-verify") { Task { await set(member, false) } }
                                    .font(.mlrScaled(12, weight: .semibold))
                                    .foregroundStyle(Color.mlrDanger)
                                    .buttonStyle(.borderless)
                            } else {
                                Button {
                                    Task { await set(member, true) }
                                } label: {
                                    Label("Verify", systemImage: "checkmark")
                                        .font(.mlrScaled(12, weight: .semibold))
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.mlrScaled(13)).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Verify members")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            members = try await supabase.from("profiles")
                .select("*")
                .order("created_at", ascending: false)
                .execute().value
            error = nil
        } catch {
            // ⚠️ Says so rather than rendering an empty list. An empty verify
            // queue and a failed read look identical, and one of them means
            // somebody is waiting.
            self.error = "Couldn't load the member list."
        }
    }

    private func set(_ member: Profile, _ value: Bool) async {
        busyId = member.id
        error = nil
        defer { busyId = nil }
        struct P: Encodable { let p_user: String; let p_value: Bool }
        do {
            try await supabase.rpc("set_member_approved",
                                   params: P(p_user: member.id.uuidString, p_value: value))
                .execute()
            await load()
            Haptics.success()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
