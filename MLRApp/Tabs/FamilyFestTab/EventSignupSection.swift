import SwiftUI

// MARK: - EventSignupSection (migrations 0135/0136/0143/0167/0158)
//
// Member-facing sign-ups for a schedule event. Renders nothing unless the event
// is taking sign-ups. Supports the three modes — headcount (one running list),
// interval (auto-generated time slots), and slots (admin-defined list) — with
// per-slot capacity, custom columns, and a roster of who's in. A manager
// (admin/fest-editor, or the item's own lead/crew) can also hide the roster
// from everyone else (0167) and send an on-demand "starts soon" nudge to one
// slot (0158). Individual sign-up only for now; team sign-ups (signupTeamSize
// > 1) remain a follow-up.

struct EventSignupSection: View {
    let item: ScheduleItem
    @Environment(AppEnvironment.self) private var env

    @State private var signups: [ScheduleSignup] = []
    @State private var slots: [ScheduleSlot] = []
    @State private var counts: [String: Int] = [:]
    @State private var loading = true
    @State private var busy = false
    @State private var fieldPrompt: FieldPrompt?
    @State private var teamPrompt: FieldPrompt?
    @State private var errorText: String?
    // Names-hidden reveal (migration 0167) — per-mount only, never persisted,
    // so re-opening this card starts hidden again on purpose.
    @State private var revealed = false

    private var itemUUID: UUID? { UUID(uuidString: item.id) }
    private var myId: UUID? { env.currentProfile?.id }
    private var mode: String { item.signupMode ?? "interval" }

    /// Same predicate as ExpandableScheduleRow's canEditItem — admin/fest-editor
    /// OR this item's own lead/crew.
    private var canManage: Bool {
        guard env.isSignedIn else { return false }
        let me = env.currentProfile?.id
        return env.isAdmin
            || env.festContentService.userCanEditFest
            || (item.leadUserId != nil && item.leadUserId == me)
            || (me != nil && item.crewUserIds.contains(me!))
    }
    /// Hidden from THIS viewer entirely — RLS already limits their fetch to
    /// just their own row, so the header count needs the counts RPC instead.
    private var namesHidden: Bool { item.signupHideNames && !canManage }
    /// A manager can reveal — but defaults to hiding it from themselves too,
    /// so running a "surprise" event doesn't spoil it until they choose to look.
    private var canRevealNames: Bool { item.signupHideNames && canManage }
    private var managerHiding: Bool { canRevealNames && !revealed }

    var body: some View {
        if item.signupEnabled {
            DetailSection(icon: "person.crop.circle.badge.checkmark", title: "Sign up") {
                VStack(alignment: .leading, spacing: 12) {
                    if canRevealNames {
                        Button(revealed ? "🙈 Hide again" : "👀 Show participants") { revealed.toggle() }
                            .font(.mlrScaled(12, weight: .semibold))
                            .foregroundStyle(Color.mlrFest)
                    }
                    if let instr = item.signupInstructions?.blankToNil {
                        Text(instr)
                            .font(.mlrScaled(13))
                            .foregroundStyle(Color.mlrFestInk.opacity(0.8))
                    }
                    if let ts = item.signupTeamSize, ts > 1 {
                        Text("Signs up in teams of \(ts).")
                            .font(.mlrScaled(12))
                            .foregroundStyle(Color.mlrFest.opacity(0.7))
                    }
                    if namesHidden {
                        Text("🙈 Who's signed up is a surprise — you'll see the headcount and your own spot, not everyone's name.")
                            .font(.mlrScaled(12))
                            .foregroundStyle(Color.mlrFest.opacity(0.7))
                    } else if managerHiding {
                        Text("🙈 You're keeping this one a surprise for yourself too — tap \"Show participants\" above when you're ready.")
                            .font(.mlrScaled(12))
                            .foregroundStyle(Color.mlrFest.opacity(0.7))
                    }
                    if !env.isSignedIn {
                        Text("Sign in to sign up.")
                            .font(.mlrScaled(13))
                            .foregroundStyle(Color.mlrFest.opacity(0.7))
                    } else if loading {
                        ProgressView()
                    } else {
                        content
                    }
                    if let errorText {
                        Text(errorText).font(.mlrScaled(12)).foregroundStyle(Color.mlrDanger)
                    }
                }
            }
            .task(id: item.id) { await reload() }
            .sheet(item: $fieldPrompt) { prompt in
                SignupFieldsSheet(fields: item.signupFields) { values in
                    Task { await performSignUp(slotStart: prompt.slotStart, slotId: prompt.slotId, fields: values) }
                }
            }
            .sheet(item: $teamPrompt) { prompt in
                TeamSignupSheet(teamSize: item.signupTeamSize ?? 2) { members, teamName in
                    Task { await performTeamSignUp(slotStart: prompt.slotStart, slotId: prompt.slotId,
                                                   members: members, teamName: teamName) }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case "headcount":
            slotRow(title: countedTitle, key: SlotKey(slotStart: nil, slotId: nil),
                    capacity: item.signupCapacity)
        case "slots":
            if slots.isEmpty {
                Text("No slots yet.").font(.mlrScaled(13)).foregroundStyle(Color.mlrFest.opacity(0.6))
            } else {
                ForEach(slots) { slot in
                    slotRow(title: slotLabel(slot),
                            key: SlotKey(slotStart: nil, slotId: slot.id),
                            capacity: slot.capacity ?? item.signupCapacity)
                }
            }
        default: // interval
            let starts = SignupsService.computeSlots(startTime: item.signupStartTime,
                                                     endTime: item.signupEndTime,
                                                     minutes: item.signupSlotMinutes)
            if starts.isEmpty {
                Text("No time slots configured.").font(.mlrScaled(13)).foregroundStyle(Color.mlrFest.opacity(0.6))
            } else {
                ForEach(starts, id: \.self) { start in
                    slotRow(title: MLRFormat.time(start),
                            key: SlotKey(slotStart: start, slotId: nil),
                            capacity: item.signupCapacity)
                }
            }
        }
    }

    private var countedTitle: String {
        "Who's in"
    }

    private func slotLabel(_ slot: ScheduleSlot) -> String {
        if let label = slot.label?.blankToNil { return label }
        let start = MLRFormat.time(slot.startTime)
        if let end = slot.endTime?.blankToNil { return "\(start)–\(MLRFormat.time(end))" }
        return start
    }

    // MARK: Slot row

    @ViewBuilder
    private func slotRow(title: String, key: SlotKey, capacity: Int?) -> some View {
        // A manager hiding names from themselves still sees THEIR own linked
        // entry, or anyone they personally typed in (addedBy) — same guarantee
        // a regular member gets automatically from RLS. Only rows someone else
        // added stay behind "Show participants."
        let allRows = signups.filter { key.matches($0) }
        let visibleRows = managerHiding
            ? allRows.filter { $0.userId == myId || $0.addedBy == myId }
            : allRows
        let hiddenCount = managerHiding ? allRows.count - visibleRows.count : 0
        // The real headcount when hidden from THIS viewer entirely (RLS limits
        // `allRows` to just our own row in that case) — from the counts RPC.
        let count = namesHidden ? (counts[key.countKey] ?? 0) : allRows.count
        let mine = allRows.first { $0.userId == myId }
        let full = capacity.map { count >= $0 } ?? false

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.mlrScaled(14, weight: .semibold))
                    .foregroundStyle(Color.mlrFest)
                Spacer()
                Text(capacity.map { "\(count)/\($0)" } ?? "\(count)")
                    .font(.mlrScaled(12, weight: .medium))
                    .foregroundStyle(Color.mlrFest.opacity(0.7))
                    .contentTransition(.numericText())
                if let mine {
                    Button("Cancel") { Task { await cancel(mine) } }
                        .font(.mlrScaled(12, weight: .semibold))
                        .foregroundStyle(Color.mlrDanger)
                        .disabled(busy)
                } else {
                    Button("Sign up") { startSignUp(key) }
                        .font(.mlrScaled(12, weight: .bold))
                        .foregroundStyle(full ? Color.mlrFest.opacity(0.4) : Color.mlrFest)
                        .disabled(busy || full)
                }
            }
            if canManage && count > 0 {
                NotifySlotButton { minutes, email in
                    guard let itemUUID else { return 0 }
                    return try await env.signupsService.sendSlotReminderNow(
                        itemId: itemUUID, slotStart: key.slotStart, slotId: key.slotId,
                        minutes: minutes, email: email)
                }
            }
            if !visibleRows.isEmpty {
                Text(visibleRows.map(\.name).joined(separator: ", "))
                    .font(.mlrScaled(12))
                    .foregroundStyle(Color.mlrFestInk.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            } else if full {
                Text("Full").font(.mlrScaled(12)).foregroundStyle(Color.mlrDanger)
            }
            if hiddenCount > 0 {
                Text("+ \(hiddenCount) more hidden until you tap \"Show participants.\"")
                    .font(.mlrScaled(11))
                    .italic()
                    .foregroundStyle(Color.mlrFest.opacity(0.5))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mlrFest.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Actions

    private func startSignUp(_ key: SlotKey) {
        if (item.signupTeamSize ?? 1) > 1 {
            teamPrompt = FieldPrompt(slotStart: key.slotStart, slotId: key.slotId)
        } else if item.signupFields.isEmpty {
            Task { await performSignUp(slotStart: key.slotStart, slotId: key.slotId, fields: [:]) }
        } else {
            fieldPrompt = FieldPrompt(slotStart: key.slotStart, slotId: key.slotId)
        }
    }

    private func performTeamSignUp(slotStart: String?, slotId: UUID?, members: [Profile], teamName: String?) async {
        guard let itemUUID, !busy else { return }
        busy = true; errorText = nil
        defer { busy = false }
        // The signer (userId nil = caller) plus the picked teammates.
        var team: [SignupsService.TeamMemberInput] = [.init(userId: env.currentProfile?.id, name: nil)]
        team += members.map { .init(userId: $0.id, name: $0.displayName) }
        do {
            try await env.signupsService.signUpTeam(itemId: itemUUID, slotStart: slotStart, slotId: slotId,
                                                    members: team, teamName: teamName)
            await reload()
        } catch {
            errorText = "Couldn't sign up the team. Try again."
        }
    }

    private func performSignUp(slotStart: String?, slotId: UUID?, fields: [String: String]) async {
        guard let itemUUID, !busy else { return }
        busy = true; errorText = nil
        defer { busy = false }
        do {
            try await env.signupsService.signUp(itemId: itemUUID, slotStart: slotStart, slotId: slotId, fields: fields)
            await reload()
        } catch {
            errorText = "Couldn't sign up. Try again."
        }
    }

    private func cancel(_ signup: ScheduleSignup) async {
        guard !busy else { return }
        busy = true; errorText = nil
        defer { busy = false }
        do {
            try await env.signupsService.remove(signupId: signup.id)
            await reload()
        } catch {
            errorText = "Couldn't cancel. Try again."
        }
    }

    private func reload() async {
        guard let itemUUID else { loading = false; return }
        loading = true
        async let s = env.signupsService.fetchSignups(itemId: itemUUID)
        async let sl = mode == "slots" ? env.signupsService.fetchSlots(itemId: itemUUID) : []
        async let c = namesHidden ? env.signupsService.fetchSignupCounts(itemId: itemUUID) : [:]
        signups = await s
        slots = await sl
        counts = await c
        loading = false
    }

    // MARK: Helpers

    private struct SlotKey {
        let slotStart: String?
        let slotId: UUID?
        /// Matches web's counts-RPC key: slot id, "HH:MM" start, or "headcount".
        var countKey: String { slotId?.uuidString ?? slotStart ?? "headcount" }
        func matches(_ s: ScheduleSignup) -> Bool {
            if let slotId { return s.slotId == slotId }
            if let slotStart { return s.slotStart == slotStart }
            return s.slotId == nil && s.slotStart == nil   // headcount bucket
        }
    }

    struct FieldPrompt: Identifiable {
        let id = UUID()
        let slotStart: String?
        let slotId: UUID?
    }
}

// MARK: - NotifySlotButton (migrations 0158/0165/0166)
//
// A manager's on-demand "your time is soon" nudge for one slot — no lead-time
// picker (a manual send always states the slot's real day/time, resolved
// server-side; see the web 0165 incident note), just Send + an optional email.

private struct NotifySlotButton: View {
    let send: (Int?, Bool) async throws -> Int

    @State private var open = false
    @State private var busy = false
    @State private var email = false
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !open {
                Button("🔔 Notify this slot") { open = true; result = nil }
                    .font(.mlrScaled(11, weight: .semibold))
                    .foregroundStyle(Color.mlrAccent)
            } else {
                HStack(spacing: 8) {
                    Button(busy ? "Sending…" : "Send reminder") {
                        Task {
                            busy = true
                            defer { busy = false }
                            do {
                                let n = try await send(nil, email)
                                result = "✓ Sent to \(n) \(n == 1 ? "person" : "people")"
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                open = false
                            } catch {
                                result = "Couldn't send. Try again."
                            }
                        }
                    }
                    .font(.mlrScaled(11, weight: .semibold))
                    .foregroundStyle(Color.mlrAccent)
                    .disabled(busy)
                    Button("Cancel") { open = false }
                        .font(.mlrScaled(11))
                        .foregroundStyle(Color.mlrFest.opacity(0.5))
                }
                Toggle("Also email anyone signed up with an account", isOn: $email)
                    .font(.mlrScaled(11))
                    .toggleStyle(.switch)
            }
            if let result {
                Text(result).font(.mlrScaled(11, weight: .semibold)).foregroundStyle(Color.mlrAccent)
            }
        }
    }
}

private extension String {
    /// Trimmed, or nil when blank (local — the app's nilIfBlank is fileprivate).
    var blankToNil: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - Team sign-up sheet

/// Pick your teammates (the signer is added automatically) + an optional team name.
private struct TeamSignupSheet: View {
    let teamSize: Int
    let onSubmit: ([Profile], String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var teamName = ""
    @State private var mates: [Profile] = []

    private var needed: Int { max(1, teamSize - 1) }   // minus the signer

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section("Team name (optional)") { TextField("e.g. The Ringers", text: $teamName) }
                    Section {
                        Text("Pick \(needed) teammate\(needed == 1 ? "" : "s") — you're already on the team.")
                            .font(.mlrScaled(13)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxHeight: 160)
                MemberMultiPicker(selected: $mates)
            }
            .navigationTitle("Sign up a team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sign up") {
                        onSubmit(mates, teamName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : teamName)
                        dismiss()
                    }
                    .disabled(mates.isEmpty)
                }
            }
        }
    }
}

// MARK: - Tournament entry card (migrations 0144–0154)
//
// A "🏆 Tournament" CTA for a fest schedule activity with `tournamentEnabled`
// (migration 0147) — mirrors web's TournamentSection mount on
// FestScheduleDetail/FestWeek's EventRow/FestStatus's TodayEvent. Tapping it
// pushes the shared TournamentContainerView with `.schedule(id:)` as the host
// (the same tournament backend private activities already use on iOS).

struct TournamentEntryCard: View {
    let item: ScheduleItem
    let canManage: Bool

    var body: some View {
        if item.tournamentEnabled, let uuid = UUID(uuidString: item.id) {
            NavigationLink {
                TournamentContainerView(host: .schedule(id: uuid), canManage: canManage)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "trophy.fill")
                        .font(.mlrScaled(22, weight: .bold))
                        .foregroundStyle(Color.mlrFest)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tournament")
                            .font(.mlrScaled(15, weight: .bold))
                            .foregroundStyle(Color.mlrFest)
                        Text("Bracket, standings, and live scores")
                            .font(.mlrScaled(12))
                            .foregroundStyle(Color.mlrFestInk.opacity(0.65))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.mlrScaled(12, weight: .semibold))
                        .foregroundStyle(Color.mlrFest.opacity(0.5))
                }
                .padding(12)
                .background(Color.mlrFest.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.mlrFest.opacity(0.2), lineWidth: 1))
            }
            .buttonStyle(.pressable)
        }
    }
}

// MARK: - Custom fields sheet

private struct SignupFieldsSheet: View {
    let fields: [SignupField]
    let onSubmit: ([String: String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                ForEach(fields) { field in
                    TextField(field.label, text: Binding(
                        get: { values[field.id] ?? "" },
                        set: { values[field.id] = $0 }
                    ))
                }
            }
            .navigationTitle("A few details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sign up") { onSubmit(values); dismiss() }
                }
            }
        }
    }
}
