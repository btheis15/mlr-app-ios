import SwiftUI

// MARK: - CommitteesView
// Browse committees. "My committees" highlighted at top, the rest below.
// Join via requestJoin (pending badge shown), tap → CommitteeDetailView.

struct CommitteesView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var hasLoaded = false
    @State private var pendingRequestIds: Set<UUID> = []
    @State private var joiningIds: Set<UUID> = []
    @State private var actionError: String?
    @State private var joinSheetCommittee: Committee?

    private var committees: [Committee] { env.committeeService.committees }
    private var myMemberships: [CommitteeMember] { env.committeeService.myMemberships }

    private var myCommitteeIds: Set<UUID> {
        Set(myMemberships.map(\.committeeId))
    }

    private var myCommittees: [Committee] {
        committees.filter { myCommitteeIds.contains($0.id) }
    }

    private var otherCommittees: [Committee] {
        committees.filter { !myCommitteeIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if env.committeeService.isLoading && !hasLoaded {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(0..<5, id: \.self) { _ in SkeletonCard(height: 90) }
                        }
                        .padding(.vertical, 16)
                    }
                } else if let error = env.committeeService.error, committees.isEmpty {
                    errorState(error)
                } else if committees.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Committees")
            .alert("Couldn't join", isPresented: .constant(actionError != nil)) {
                Button("OK") { actionError = nil }
            } message: {
                Text(actionError ?? "")
            }
            .sheet(item: $joinSheetCommittee) { committee in
                CommitteeJoinSheet(committee: committee) {
                    pendingRequestIds.insert(committee.id)
                }
            }
            .task {
                guard !hasLoaded else { return }
                await env.committeeService.fetchCommittees()
                if let userId = await env.authService.userId {
                    await env.committeeService.fetchMyMemberships(userId: userId)
                }
                hasLoaded = true
            }
        }
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !myCommittees.isEmpty {
                    section(title: "My committees", committees: myCommittees, isMember: true)
                }
                section(
                    title: myCommittees.isEmpty ? "All committees" : "Join a committee",
                    committees: otherCommittees,
                    isMember: false
                )
            }
            .padding(.vertical, 16)
        }
        .refreshable {
            await env.committeeService.fetchCommittees()
            if let userId = await env.authService.userId {
                await env.committeeService.fetchMyMemberships(userId: userId)
            }
        }
    }

    private func section(title: String, committees: [Committee], isMember: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: title)
                .padding(.horizontal, 16)
            VStack(spacing: 10) {
                ForEach(committees) { committee in
                    CommitteeRowCard(
                        committee: committee,
                        isMember: isMember,
                        isPending: pendingRequestIds.contains(committee.id),
                        isJoining: joiningIds.contains(committee.id),
                        onJoin: {
                            guard env.isSignedIn else { env.authService.promptSignIn(); return }
                            joinSheetCommittee = committee
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Empty / error

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No committees yet", systemImage: "person.3")
        } description: {
            Text("Committees help organize the work behind the resort and Family Fest.")
        }
    }

    private func errorState(_ message: String) -> some View {
        ErrorStateView(title: "Couldn't load committees", message: message) {
            Task { await env.committeeService.fetchCommittees() }
        }
    }
}

// MARK: - Committee Row Card

private struct CommitteeRowCard: View {
    let committee: Committee
    let isMember: Bool
    let isPending: Bool
    let isJoining: Bool
    let onJoin: () -> Void

    var body: some View {
        NavigationLink {
            CommitteeDetailView(committee: committee)
        } label: {
            HStack(spacing: 14) {
                Text(committee.emoji ?? "📋")
                    .font(.mlrScaled(30))
                    .frame(width: 48, height: 48)
                    .background(Color.mlrPrimaryLight)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(committee.name)
                            .font(.mlrScaled(16, weight: .semibold))
                            .foregroundStyle(Color.mlrText)
                        if committee.isPrivate == true {
                            Image(systemName: "lock.fill")
                                .font(.mlrScaled(10))
                                .foregroundStyle(Color.mlrTextMuted)
                        }
                    }
                    if let desc = committee.description, !desc.isEmpty {
                        Text(desc)
                            .font(.mlrScaled(13))
                            .foregroundStyle(Color.mlrTextMuted)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer()

                trailing
            }
            .padding(14)
            .background(Color.mlrCard)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var trailing: some View {
        if isMember {
            Image(systemName: "chevron.right")
                .font(.mlrScaled(13, weight: .semibold))
                .foregroundStyle(Color.mlrTextSubtle)
        } else if isPending {
            Text("Pending")
                .font(.mlrScaled(12, weight: .semibold))
                .foregroundStyle(Color.mlrWarning)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.mlrWarning.opacity(0.12))
                .clipShape(Capsule())
        } else {
            Button(action: onJoin) {
                if isJoining {
                    ProgressView().tint(Color.mlrPrimary)
                        .frame(width: 54)
                } else {
                    Text("Join")
                        .font(.mlrScaled(13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.mlrPrimary)
                        .clipShape(Capsule())
                }
            }
            .buttonStyle(.plain)
            .disabled(isJoining)
        }
    }
}

// MARK: - Committee Join Sheet
// Requesting to join. For role-based committees (areas derived from the roster,
// e.g. Family Fest) the requester can pick the area(s) they'd like to help with;
// those are applied when an admin/lead approves. Committees with no roles just
// show a plain request button.

struct CommitteeJoinSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let committee: Committee
    let onRequested: () -> Void

    @State private var areaOptions: [String] = []
    @State private var selected: Set<String> = []
    @State private var note: String = ""
    @State private var isLoading = true
    @State private var isSubmitting = false
    @State private var error: String?

    /// Role-based committees (Family Fest) expose areas from the roster — a
    /// requester must pick at least one so leads know where they'd fit before
    /// approving. Committees with no roles skip the picker entirely.
    private var isRoleBased: Bool { !areaOptions.isEmpty }

    /// Role-based committees require an area before the request can be sent.
    private var needsAreaSelection: Bool { isRoleBased && selected.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Request to join \(committee.name). A committee lead or admin will review it.")
                        .font(.mlrCaption)
                        .foregroundStyle(Color.mlrTextMuted)
                }

                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if isRoleBased {
                    Section {
                        ForEach(areaOptions, id: \.self) { area in
                            Button {
                                if selected.contains(area) { selected.remove(area) }
                                else { selected.insert(area) }
                            } label: {
                                HStack {
                                    Text(area).foregroundStyle(Color.mlrText)
                                    Spacer()
                                    if selected.contains(area) {
                                        Image(systemName: "checkmark")
                                            .font(.mlrScaled(14, weight: .semibold))
                                            .foregroundStyle(Color.mlrPrimary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Which areas do you want to help with?")
                    } footer: {
                        if needsAreaSelection {
                            Text("Pick at least one area to send your request.")
                                .foregroundStyle(Color.mlrDanger)
                        }
                    }
                }

                Section("Add a note (optional)") {
                    TextField("Anything the leads should know?", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                }

                if let error {
                    Text(error).font(.mlrCaption).foregroundStyle(Color.mlrDanger)
                }
            }
            .navigationTitle("Join \(committee.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Request") { Task { await submit() } }
                        .disabled(isSubmitting || needsAreaSelection)
                }
            }
            .task { await loadAreas() }
        }
    }

    private func loadAreas() async {
        isLoading = true
        let roster = (try? await env.committeeService.fetchRoster(slug: committee.slug)) ?? []
        // Areas = the committee's roles with the " · Lead" suffix stripped, deduped
        // in first-seen order (mirrors the web join UI).
        var seen = Set<String>()
        var ordered: [String] = []
        for role in roster.flatMap(\.roles) {
            let area = role.hasSuffix(" · Lead") ? String(role.dropLast(" · Lead".count)) : role
            if !area.isEmpty && !seen.contains(area) { seen.insert(area); ordered.append(area) }
        }
        areaOptions = ordered
        isLoading = false
    }

    private func submit() async {
        guard !needsAreaSelection else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            try await env.committeeService.requestJoin(
                committeeId: committee.id,
                note: trimmed.isEmpty ? nil : trimmed,
                requestedAreas: Array(selected)
            )
            onRequested()
            dismiss()
        } catch {
            self.error = "Couldn't send your request. Try again."
            print("[CommitteeJoinSheet] request error: \(error)")
        }
    }
}

