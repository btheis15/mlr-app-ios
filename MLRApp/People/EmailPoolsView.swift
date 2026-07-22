import SwiftUI

// MARK: - EmailPoolsView (migrations 0028/0123/0124)
//
// The People-tab "Email members" front door: pick a pool (the whole family, the
// public directory, App Admins, your house, or a committee — with By-Role), then
// hand off to EmailMembersView. Mirrors the web EmailMembers pool picker.

struct EmailPoolsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var loadingPool: String?
    @State private var presented: PresentedPool?

    private struct PresentedPool: Identifiable {
        let id = UUID()
        let title: String
        let recipients: [EmailRecipient]
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Everyone") {
                    poolRow("Whole family", icon: "person.3.fill", key: "family") {
                        await env.familyRosterService.allMemberRecipients()
                    }
                    poolRow("Public directory", icon: "book.fill", key: "directory") {
                        await env.familyRosterService.directoryRecipients()
                    }
                    poolRow("App admins", icon: "star.fill", key: "admins") {
                        await env.familyRosterService.adminRecipients()
                    }
                    if let hid = env.currentProfile?.houseId {
                        poolRow("My house", icon: "house.fill", key: "house") {
                            await env.familyRosterService.houseRecipients(houseId: hid)
                        }
                    }
                }
                if !env.committeeService.committees.isEmpty {
                    Section("By committee (pick a role inside)") {
                        ForEach(env.committeeService.committees) { committee in
                            poolRow(committee.name, icon: committee.emoji.map { _ in "" } ?? "person.2.fill",
                                    emoji: committee.emoji, key: "c-\(committee.id)") {
                                await env.familyRosterService.committeeRecipients(committeeId: committee.id)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Email members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { if env.committeeService.committees.isEmpty { await env.committeeService.fetchCommittees() } }
            .sheet(item: $presented) { pool in
                EmailMembersView(title: pool.title, recipients: pool.recipients)
            }
        }
    }

    private func poolRow(_ title: String, icon: String, emoji: String? = nil, key: String,
                         load: @escaping () async -> [EmailRecipient]) -> some View {
        Button {
            Task {
                loadingPool = key
                let recipients = await load()
                loadingPool = nil
                presented = PresentedPool(title: title, recipients: recipients)
            }
        } label: {
            HStack(spacing: 12) {
                if let emoji, !emoji.isEmpty {
                    Text(emoji).font(.mlrScaled(18))
                } else {
                    Image(systemName: icon).foregroundStyle(Color.mlrPrimary).frame(width: 24)
                }
                Text(title).font(.mlrScaled(15)).foregroundStyle(Color.mlrText)
                Spacer()
                if loadingPool == key { ProgressView() }
                else { Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.mlrTextSubtle) }
            }
        }
        .buttonStyle(.plain)
        .disabled(loadingPool != nil)
    }
}
