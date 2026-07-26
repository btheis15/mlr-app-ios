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
            // Emoji medallion on a tinted gradient chip.
            Text(activity.emoji?.nilBlank ?? "🎲")
                .font(.mlrScaled(26))
                .frame(width: 46, height: 46)
                .background(
                    LinearGradient(colors: [Color.mlrPrimary.opacity(0.18), Color.mlrLake.opacity(0.10)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(activity.title)
                        .font(.mlrScaled(16, weight: .semibold))
                        .foregroundStyle(Color.mlrText)
                        .lineLimit(1)
                    if activity.tournamentEnabled {
                        // Gold gradient tournament pill.
                        Label("Tournament", systemImage: "trophy.fill")
                            .font(.mlrScaled(9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2.5)
                            .background(
                                LinearGradient(colors: [.mlrFestGold, .mlrSun],
                                               startPoint: .leading, endPoint: .trailing)
                            )
                            .clipShape(Capsule())
                            .labelStyle(.titleAndIcon)
                    }
                }
                HStack(spacing: 6) {
                    Text(subtitle)
                        .font(.mlrScaled(12))
                        .foregroundStyle(Color.mlrTextMuted)
                        .lineLimit(1)
                        .numericTransition()
                    InitialsStack(names: goingNames)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.mlrScaled(12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .cardStyle(cornerRadius: 14, elevation: .medium)
    }

    private var goingNames: [String] {
        activity.members.filter { $0.rsvp == .going }.map(\.name)
    }

    private var subtitle: String {
        var bits: [String] = []
        if let start = activity.startsAt { bits.append(MLRFormat.shortDate(start)) }
        if activity.goingCount > 0 { bits.append("\(activity.goingCount) going") }
        else { bits.append("\(activity.members.count) invited") }
        return bits.joined(separator: " · ")
    }
}

/// Small overlapping circles with member initials — the "who's in" garnish for
/// rows/heroes. (Activity members carry no avatar URLs, so initials stand in.)
struct InitialsStack: View {
    let names: [String]
    var max: Int = 3
    var diameter: CGFloat = 18

    var body: some View {
        if !names.isEmpty {
            HStack(spacing: -diameter * 0.35) {
                ForEach(Array(names.prefix(max).enumerated()), id: \.offset) { _, name in
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: diameter * 0.5, weight: .bold))
                        .foregroundStyle(Color.mlrPrimary)
                        .frame(width: diameter, height: diameter)
                        .background(Color.mlrPrimaryLight)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.mlrCard, lineWidth: 1.5))
                }
                if names.count > max {
                    Text("+\(names.count - max)")
                        .font(.system(size: diameter * 0.45, weight: .semibold))
                        .foregroundStyle(Color.mlrTextMuted)
                        .padding(.leading, diameter * 0.45)
                }
            }
            .accessibilityHidden(true)
        }
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let quickEmojis = ["🎲", "🏆", "🎯", "🃏", "🏐", "⛳️", "🏓", "🎱", "🥏", "🪃"]

    /// The activity as it will appear in the Events list — updates live as you type.
    private var composerPreview: some View {
        HStack(spacing: 12) {
            Text(emoji.nilBlank ?? "🎲")
                .font(.mlrScaled(26))
                .frame(width: 46, height: 46)
                .background(
                    LinearGradient(colors: [Color.mlrPrimary.opacity(0.18), Color.mlrLake.opacity(0.10)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title.nilBlank ?? "Your activity")
                        .font(.mlrScaled(16, weight: .semibold))
                        .foregroundStyle(title.nilBlank == nil ? Color.mlrTextSubtle : Color.mlrText)
                        .lineLimit(1)
                    if tournamentEnabled {
                        Label("Tournament", systemImage: "trophy.fill")
                            .font(.mlrScaled(9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2.5)
                            .background(LinearGradient(colors: [.mlrFestGold, .mlrSun], startPoint: .leading, endPoint: .trailing))
                            .clipShape(Capsule())
                    }
                }
                Text(previewSubtitle)
                    .font(.mlrScaled(12))
                    .foregroundStyle(Color.mlrTextMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .cardStyle(cornerRadius: 14, elevation: .medium)
        .animation(reduceMotion ? nil : MLRMotion.spring, value: tournamentEnabled)
    }

    private var previewSubtitle: String {
        var bits: [String] = []
        if hasDate { bits.append(MLRFormat.shortDate(startsAt)) }
        if let loc = location.nilBlank { bits.append(loc) }
        let count = invited.count + typedNames.count
        bits.append(count == 0 ? "Invite-only" : "\(count) invited")
        return bits.joined(separator: " · ")
    }

    var body: some View {
        NavigationStack {
            Form {
                // Live preview — the activity exactly as it will appear (2.1).
                Section {
                    composerPreview
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section("Activity") {
                    TextField("Title (e.g. Baggo tournament)", text: $title)
                    // Emoji quick-pick + free-text.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Self.quickEmojis, id: \.self) { e in
                                Button {
                                    emoji = e
                                } label: {
                                    Text(e)
                                        .font(.mlrScaled(22))
                                        .frame(width: 38, height: 38)
                                        .background(emoji == e ? Color.mlrPrimaryLight : Color.mlrSurface)
                                        .clipShape(Circle())
                                        .overlay(Circle().stroke(emoji == e ? Color.mlrPrimary : Color.clear, lineWidth: 1.5))
                                }
                                .buttonStyle(.pressable)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .mlrFeedback(.selection, trigger: emoji)
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
                    if tournamentEnabled {
                        Label("Brackets, round-robins & standings turn on for this activity — you'll seed players and generate the draw from the activity page.", systemImage: "trophy.fill")
                            .font(.mlrScaled(12))
                            .foregroundStyle(Color.mlrFestGold)
                            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : MLRMotion.spring, value: tournamentEnabled)
                Section("Invite") {
                    Button { showPicker = true } label: {
                        Label(invited.isEmpty ? "Add app members" : "\(invited.count) added", systemImage: "person.badge.plus")
                    }
                    // Invited members as removable avatar chips.
                    ForEach(invited) { p in
                        HStack(spacing: 10) {
                            AvatarView(profile: p, size: .small)
                            Text(p.displayName).font(.mlrScaled(14))
                            Spacer()
                            Button { invited.removeAll { $0.id == p.id } } label: {
                                Image(systemName: "minus.circle").foregroundStyle(Color.mlrTextSubtle)
                            }.buttonStyle(.pressable)
                        }
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
                            }.buttonStyle(.pressable)
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

// MARK: - Edit sheet

private struct EditPrivateActivitySheet: View {
    let activity: PrivateActivity
    let onSaved: () -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var emoji: String
    @State private var location: String
    @State private var description: String
    @State private var hasDate: Bool
    @State private var startsAt: Date
    @State private var saving = false

    init(activity: PrivateActivity, onSaved: @escaping () -> Void) {
        self.activity = activity
        self.onSaved = onSaved
        _title = State(initialValue: activity.title)
        _emoji = State(initialValue: activity.emoji ?? "")
        _location = State(initialValue: activity.location ?? "")
        _description = State(initialValue: activity.description ?? "")
        _hasDate = State(initialValue: activity.startsAt != nil)
        _startsAt = State(initialValue: activity.startsAt ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Activity") {
                    TextField("Title", text: $title)
                    TextField("Emoji (optional)", text: $emoji)
                    TextField("Where (optional)", text: $location)
                    TextField("Details (optional)", text: $description, axis: .vertical).lineLimit(1...4)
                }
                Section {
                    Toggle("Set a date & time", isOn: $hasDate)
                    if hasDate { DatePicker("Starts", selection: $startsAt) }
                }
            }
            .navigationTitle("Edit activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() async {
        saving = true; defer { saving = false }
        try? await env.privateActivitiesService.update(
            id: activity.id,
            title: title.trimmingCharacters(in: .whitespaces),
            emoji: emoji.nilBlank,
            description: description.nilBlank,
            location: location.nilBlank,
            startsAt: hasDate ? startsAt : nil,
            clearStart: !hasDate,
            tournamentEnabled: nil)
        onSaved()
        dismiss()
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
    @State private var showEdit = false
    @State private var confettiTrigger = 0

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
                            Button { showEdit = true } label: { Label("Edit details", systemImage: "pencil") }
                            Button { showInvite = true } label: { Label("Invite people", systemImage: "person.badge.plus") }
                            Button(role: .destructive) { Task { await archiveOrDelete(activity) } } label: {
                                Label(activity.isArchived ? "Delete" : "Archive", systemImage: "archivebox")
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
            .sheet(isPresented: $showInvite) { InviteToActivitySheet(activityId: activityId) { Task { await reload() } } }
            .sheet(isPresented: $showEdit) {
                if let activity { EditPrivateActivitySheet(activity: activity) { Task { await reload(); onChanged() } } }
            }
            .task { await reload() }
        }
    }

    @ViewBuilder
    private func content(_ activity: PrivateActivity) -> some View {
        List {
            // Hero header — mesh band with the emoji medallion + who's hosting.
            Section {
                heroHeader(activity)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

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

            // My RSVP — confetti + success haptic celebrate a fresh "Going".
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
                    HStack(spacing: 10) {
                        Text(String(m.name.prefix(1)).uppercased())
                            .font(.mlrScaled(13, weight: .bold))
                            .foregroundStyle(Color.mlrPrimary)
                            .frame(width: 28, height: 28)
                            .background(Color.mlrPrimaryLight)
                            .clipShape(Circle())
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
                            }.buttonStyle(.pressable)
                        }
                    }
                }
            }

            if activity.tournamentEnabled {
                Section {
                    NavigationLink {
                        TournamentContainerView(host: .activity(id: activityId), canManage: canManage)
                    } label: {
                        tournamentCTA
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
        }
        .overlay(ConfettiView(trigger: confettiTrigger).allowsHitTesting(false))
    }

    /// Mesh hero band: emoji medallion, title, hosts, going count.
    private func heroHeader(_ activity: PrivateActivity) -> some View {
        ZStack(alignment: .bottomLeading) {
            MeshHeroBackground(theme: .accent(.mlrPrimary))
            VStack(alignment: .leading, spacing: 6) {
                Text(activity.emoji?.nilBlank ?? "🎲")
                    .font(.mlrScaled(44))
                    .frame(width: 68, height: 68)
                    .background(.white.opacity(0.9))
                    .clipShape(Circle())
                    .shadow(.medium)
                Text(activity.title)
                    .font(.mlrScaled(26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 8) {
                    if !activity.hostNames.isEmpty {
                        Text("Hosted by \(activity.hostNames.joined(separator: ", "))")
                            .font(.mlrScaled(12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                    }
                    Text("· \(activity.goingCount) going")
                        .font(.mlrScaled(12, weight: .semibold))
                        .foregroundStyle(.white)
                        .numericTransition()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .heroOverlayScrim()
        }
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: MLRRadius.card))
    }

    /// Gold gradient tournament CTA card.
    private var tournamentCTA: some View {
        HStack(spacing: 12) {
            Image(systemName: "trophy.fill")
                .font(.mlrScaled(26, weight: .bold))
                .symbolEffect(.pulse, options: .repeat(1), value: activity?.tournamentEnabled)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tournament")
                    .font(.mlrScaled(17, weight: .bold, design: .rounded))
                Text(tournamentStatusLine)
                    .font(.mlrScaled(12, weight: .medium))
                    .opacity(0.9)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.mlrScaled(13, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .gradientCard(
            LinearGradient(colors: [.mlrFestGold, .mlrSun],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            cornerRadius: MLRRadius.card, elevation: .medium)
    }

    private var tournamentStatusLine: String {
        "Bracket, standings & the big board →"
    }

    // MARK: Actions

    private func reload() async {
        loading = activity == nil
        let all = await env.privateActivitiesService.fetchActivities()
        activity = all.first { $0.id == activityId }
        loading = false
    }
    private func setRsvp(_ rsvp: ActivityRsvp) async {
        let wasGoing = activity?.myMembership(viewerId: me)?.rsvp == .going
        try? await env.privateActivitiesService.setRsvp(activityId: activityId, rsvp: rsvp)
        await reload(); onChanged()
        // Celebrate a FRESH "Going" (not re-taps of an existing one).
        if rsvp == .going && !wasGoing {
            confettiTrigger += 1
            Haptics.success()
        }
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
