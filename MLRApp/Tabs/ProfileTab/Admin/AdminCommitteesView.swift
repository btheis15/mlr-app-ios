import SwiftUI

// MARK: - AdminCommitteesView
// Admin overview of every committee: pending join-request queue with per-committee
// badge counts. Tapping a row opens CommitteeDetailView (which includes the
// member-manage sheet for admins). Mirrors web /admin/committees.

struct AdminCommitteesView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var loading = true

    private var committees: [Committee] {
        env.committeeService.committees.sorted { $0.name < $1.name }
    }

    private func pendingCount(for committee: Committee) -> Int {
        env.committeeService.pendingRequests.filter { $0.committeeId == committee.id }.count
    }

    private var totalPending: Int {
        env.committeeService.pendingRequests.count
    }

    var body: some View {
        Group {
            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if committees.isEmpty {
                ContentUnavailableView("No committees", systemImage: "person.3")
            } else {
                List(committees) { committee in
                    NavigationLink(destination: CommitteeDetailView(committee: committee)) {
                        HStack(spacing: 12) {
                            Text(committee.emoji ?? "👥")
                                .font(.mlrScaled(22))
                                .frame(width: 40, height: 40)
                                .background(Color.mlrInfo.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 10))

                            Text(committee.name)
                                .font(.mlrScaled(15, weight: .semibold))
                                .foregroundStyle(Color.mlrText)

                            Spacer()

                            let pending = pendingCount(for: committee)
                            if pending > 0 {
                                Text("\(pending)")
                                    .font(.mlrScaled(12, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.mlrDanger)
                                    .clipShape(Capsule())
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle(totalPending > 0 ? "Committees (\(totalPending) pending)" : "Committees")
        .navigationBarTitleDisplayMode(.large)
        .task {
            if env.committeeService.committees.isEmpty {
                await env.committeeService.fetchCommittees()
            }
            try? await env.committeeService.fetchPendingRequests()
            loading = false
        }
        .refreshable {
            await env.committeeService.fetchCommittees()
            try? await env.committeeService.fetchPendingRequests()
        }
    }
}
