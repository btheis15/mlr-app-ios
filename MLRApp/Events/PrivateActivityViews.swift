import SwiftUI

// MARK: - Private activity views (migration 0150)
//
// Row (Events-tab list), create composer, and detail sheet for member-made
// invite-only activities. Mirrors PrivateActivityComposer.tsx / PrivateActivitySheet.tsx.

// MARK: Row

struct PrivateActivityRow: View {
    let activity: PrivateActivity
    var body: some View {
        HStack(spacing: 12) {
            Text(activity.emoji?.nilBlank ?? "🎲")
                .font(.mlrScaled(26))
                .frame(width: 44, height: 44)
                .background(Color.mlrPrimary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(activity.title)
                        .font(.mlrScaled(16, weight: .semibold))
                        .foregroundStyle(Color.mlrText)
                        .lineLimit(1)
                    if activity.tournamentEnabled {
                        Image(systemName: "trophy.fill")
                            .font(.mlrScaled(11))
                            .foregroundStyle(Color.mlrWarning)
                    }
                }
                Text(subtitle)
                    .font(.mlrScaled(12))
                    .foregroundStyle(Color.mlrTextMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.mlrScaled(12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color.mlrCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var subtitle: String {
        var bits: [String] = []
        if let start = activity.startsAt { bits.append(MLRFormat.shortDate(start)) }
        if activity.goingCount > 0 { bits.append("\(activity.goingCount) going") }
        else { bits.append("\(activity.members.count) invited") }
        return bits.joined(separator: " · ")
    }
}

// MARK: - Composer

struct PrivateActivityComposer: View {
    let onCreated: () -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var emoji = ""
    @State private var description = ""
    @State private var location = ""
    @State private var hasDate = false
    @State private var startsAt = Date()
    @State private var tournamentEnabled = false
    @State private var notify = true
    @State private var invited: [Profile] = []
    @State private var typedNames: [String] = []   // people not on the app yet
    @State private var typedName = ""
    @State private var showPicker = false
    @State private var creating = false
    @State private var errorText: String?

    private var canCreate: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty && !creating }

    var body: some View {
        NavigationStack {
            Form {
                Section("Activity") {
                    TextField("Title (e.g. Baggo tournament)", text: $title)
                    TextField("Emoji (optional)", text: $emoji)
                    TextField("Where (optional)", text: $location)
                    TextField("Details (optional)", text: $description, axis: .vertical).lineLimit(1...4)
                }
                Section {
                    Toggle("Set a date & time", isOn: $hasDate)
                    if hasDate {
                        DatePicker("Starts", selection: $startsAt)
                    }
                }
                Section {
                    Toggle("Run a tournament", isOn: $tournamentEnabled)
                } footer: {
                    Text("Turns on brackets/standings for this activity.")
                }
                Section("Invite") {
                    Button { showPicker = true } label: {
                        Label(invited.isEmpty ? "Add app members" : "\(invited.count) added", systemImage: "person.badge.plus")
                    }
                    ForEach(invited) { p in
                        Text(p.displayName).font(.mlrScaled(14))
                    }
                    // Add someone who isn't on the app yet (by name).
                    HStack {
                        TextField("Or add a name (not on the app)", text: $typedName)
                        Button("Add") {
                            let n = typedName.trimmingCharacters(in: .whitespaces)
                            guard !n.isEmpty else { return }
                            typedNames.append(n); typedName = ""
                        }
                        .disabled(typedName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    ForEach(typedNames, id: \.self) { name in
                        HStack {
                            Text(name).font(.mlrScaled(14))
                            Spacer()
                            Button { typedNames.removeAll { $0 == name } } label: {
                                Image(systemName: "minus.circle").foregroundStyle(Color.mlrTextSubtle)
                            }.buttonStyle(.plain)
                        }
                    }
                    Toggle("Notify people I add", isOn: $notify)
                }
                if let errorText {
                    Section { Text(errorText).font(.mlrScaled(13)).foregroundStyle(Color.mlrDanger) }
                }
            }
            .navigationTitle("New activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(creating ? "Creating…" : "Create") { Task { await create() } }.disabled(!canCreate)
                }
            }
            .sheet(isPresented: $showPicker) {
                MemberMultiPicker(selected: $invited)
            }
        }
    }

    private func create() async {
        creating = true; errorText = nil
        defer { creating = false }
        do {
            _ = try await env.privateActivitiesService.create(
                title: title.trimmingCharacters(in: .whitespaces),
                emoji: emoji.nilBlank,
                description: description.nilBlank,
                location: location.nilBlank,
                startsAt: hasDate ? startsAt : nil,
                tournamentEnabled: tournamentEnabled,
                members: invited.map { .init(userId: $0.id, name: $0.displayName) }
                    + typedNames.map { .init(userId: nil, name: $0) },
                notify: notify
            )
            onCreated()
            dismiss()
        } catch {
            errorText = "Couldn't create the activity. Try again."
        }
    }
}

// MARK: - Detail sheet

struct PrivateActivitySheet: View {
    let activityId: UUID
    var onChanged: () -> Void = {}

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var activity: PrivateActivity?
    @State private var loading = true
    @State private var busy = false
    @State private var showInvite = false

    private var me: UUID? { env.currentProfile?.id }
    private var canManage: Bool { activity?.canManage(viewerId: me, isAdmin: env.isAdmin) ?? false }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let activity {
                    content(activity)
                } else {
                    ContentUnavailableView("Activity unavailable", systemImage: "questionmark.circle")
                }
            }
            .navigationTitle(activity?.title ?? "Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if canManage, let activity {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button { showInvite = true } label: { Label("Invite people", systemImage: "person.badge.plus") }
                            Button(role: .destructive) { Task { await archiveOrDelete(activity) } } label: {
                                Label(activity.isArchived ? "Delete" : "Archive", systemImage: "archivebox")
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
            .sheet(isPresented: $showInvite) { InviteToActivitySheet(activityId: activityId) { Task { await reload() } } }
            .task { await reload() }
        }
    }

    @ViewBuilder
    private func content(_ activity: PrivateActivity) -> some View {
        List {
            Section {
                if let desc = activity.description?.nilBlank {
                    Text(desc).font(.mlrBody)
                }
                if let loc = activity.location?.nilBlank {
                    Label(loc, systemImage: "mappin.and.ellipse").font(.mlrScaled(14))
                }
                if let start = activity.startsAt {
                    Label(MLRFormat.longDate(start), systemImage: "calendar").font(.mlrScaled(14))
                }
            }

            // My RSVP
            if activity.myMembership(viewerId: me) != nil {
                Section("Are you in?") {
                    Picker("RSVP", selection: Binding(
                        get: { activity.myMembership(viewerId: me)?.rsvp ?? .maybe },
                        set: { rsvp in Task { await setRsvp(rsvp) } }
                    )) {
                        ForEach(ActivityRsvp.allCases, id: \.self) { Text("\($0.emoji) \($0.label)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }

            Section("Who's invited (\(activity.members.count))") {
                ForEach(activity.sortedMembers) { m in
                    HStack(spacing: 8) {
                        Text(m.name).font(.mlrScaled(15, weight: m.isHost ? .semibold : .regular))
                        if m.isHost {
                            Text("Host").font(.mlrScaled(10, weight: .bold)).foregroundStyle(Color.mlrPrimary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.mlrPrimaryLight).clipShape(Capsule())
                        }
                        Spacer()
                        if let r = m.rsvp { Text(r.emoji).font(.mlrScaled(14)) }
                        if canManage && m.userId != activity.createdBy {
                            Button { Task { await removeMember(m) } } label: {
                                Image(systemName: "minus.circle").foregroundStyle(Color.mlrTextSubtle)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }

            if activity.tournamentEnabled {
                Section("Tournament") {
                    NavigationLink {
                        TournamentContainerView(host: .activity(id: activityId), canManage: canManage)
                    } label: {
                        Label("Open tournament", systemImage: "trophy.fill")
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func reload() async {
        loading = activity == nil
        let all = await env.privateActivitiesService.fetchActivities()
        activity = all.first { $0.id == activityId }
        loading = false
    }
    private func setRsvp(_ rsvp: ActivityRsvp) async {
        try? await env.privateActivitiesService.setRsvp(activityId: activityId, rsvp: rsvp)
        await reload(); onChanged()
    }
    private func removeMember(_ m: PrivateActivityMember) async {
        try? await env.privateActivitiesService.removeMember(memberId: m.id)
        await reload(); onChanged()
    }
    private func archiveOrDelete(_ activity: PrivateActivity) async {
        if activity.isArchived {
            try? await env.privateActivitiesService.delete(id: activityId)
        } else {
            try? await env.privateActivitiesService.setArchived(id: activityId, archived: true)
        }
        onChanged(); dismiss()
    }
}

// MARK: - Invite sheet

private struct InviteToActivitySheet: View {
    let activityId: UUID
    let onInvited: () -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var selected: [Profile] = []
    @State private var busy = false

    var body: some View {
        NavigationStack {
            MemberMultiPicker(selected: $selected)
                .navigationTitle("Invite people")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(busy ? "Adding…" : "Add") { Task { await add() } }
                            .disabled(selected.isEmpty || busy)
                    }
                }
        }
    }

    private func add() async {
        busy = true; defer { busy = false }
        for p in selected {
            _ = try? await env.privateActivitiesService.addMember(
                activityId: activityId, member: .init(userId: p.id, name: p.displayName), notify: true)
        }
        onInvited(); dismiss()
    }
}

// MARK: - Member multi-picker

/// A searchable multi-select over the directory, backed by a live profiles fetch.
struct MemberMultiPicker: View {
    @Binding var selected: [Profile]
    @Environment(\.dismiss) private var dismiss
    @State private var all: [Profile] = []
    @State private var query = ""

    private var filtered: [Profile] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.displayName.lowercased().contains(q) }
    }

    var body: some View {
        List {
            ForEach(filtered) { p in
                Button {
                    if let i = selected.firstIndex(where: { $0.id == p.id }) { selected.remove(at: i) }
                    else { selected.append(p) }
                } label: {
                    HStack {
                        Text(p.displayName).foregroundStyle(Color.mlrText)
                        Spacer()
                        if selected.contains(where: { $0.id == p.id }) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.mlrPrimary)
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search people")
        .task {
            if all.isEmpty {
                let rows: [Profile] = (try? await supabase
                    .from("profiles")
                    .select("id, display_name, avatar_url, is_admin")
                    .order("display_name", ascending: true)
                    .execute().value) ?? []
                all = rows
            }
        }
    }
}

private extension String {
    var nilBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
