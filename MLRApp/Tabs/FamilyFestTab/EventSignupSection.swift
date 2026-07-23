import SwiftUI

// MARK: - EventSignupSection (migrations 0135/0136/0143)
//
// Member-facing sign-ups for a schedule event. Renders nothing unless the event
// is taking sign-ups. Supports the three modes — headcount (one running list),
// interval (auto-generated time slots), and slots (admin-defined list) — with
// per-slot capacity, custom columns, and a roster of who's in. Individual
// sign-up only for now; team sign-ups (signupTeamSize > 1) and admin authoring
// of the sign-up config remain a follow-up (both are web-side today).

struct EventSignupSection: View {
    let item: ScheduleItem
    @Environment(AppEnvironment.self) private var env

    @State private var signups: [ScheduleSignup] = []
    @State private var slots: [ScheduleSlot] = []
    @State private var loading = true
    @State private var busy = false
    @State private var fieldPrompt: FieldPrompt?
    @State private var errorText: String?

    private var itemUUID: UUID? { UUID(uuidString: item.id) }
    private var myId: UUID? { env.currentProfile?.id }
    private var mode: String { item.signupMode ?? "interval" }

    var body: some View {
        if item.signupEnabled {
            DetailSection(icon: "person.crop.circle.badge.checkmark", title: "Sign up") {
                VStack(alignment: .leading, spacing: 12) {
                    if let instr = item.signupInstructions?.blankToNil {
                        Text(instr)
                            .font(.mlrScaled(13))
                            .foregroundStyle(Color.mlrFestInk.opacity(0.8))
                    }
                    if item.signupTeamSize ?? 1 > 1 {
                        Text("This event signs up in teams of \(item.signupTeamSize!) — use the web app to enter a team.")
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
        let rows = signups.filter { key.matches($0) }
        let mine = rows.first { $0.userId == myId }
        let full = capacity.map { rows.count >= $0 } ?? false

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.mlrScaled(14, weight: .semibold))
                    .foregroundStyle(Color.mlrFest)
                Spacer()
                Text(capacity.map { "\(rows.count)/\($0)" } ?? "\(rows.count)")
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
            if !rows.isEmpty {
                Text(rows.map(\.name).joined(separator: ", "))
                    .font(.mlrScaled(12))
                    .foregroundStyle(Color.mlrFestInk.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            } else if full {
                Text("Full").font(.mlrScaled(12)).foregroundStyle(Color.mlrDanger)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mlrFest.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Actions

    private func startSignUp(_ key: SlotKey) {
        if item.signupFields.isEmpty {
            Task { await performSignUp(slotStart: key.slotStart, slotId: key.slotId, fields: [:]) }
        } else {
            fieldPrompt = FieldPrompt(slotStart: key.slotStart, slotId: key.slotId)
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
        signups = await s
        slots = await sl
        loading = false
    }

    // MARK: Helpers

    private struct SlotKey {
        let slotStart: String?
        let slotId: UUID?
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

private extension String {
    /// Trimmed, or nil when blank (local — the app's nilIfBlank is fileprivate).
    var blankToNil: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
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
