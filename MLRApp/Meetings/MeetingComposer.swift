import SwiftUI

// MARK: - MeetingComposer (migrations 0116/0119)
//
// Bottom-sheet composer for creating a meeting. Two modes:
//   • "Find a time" — propose up to 10 candidate slots that members vote on
//     (Yes / If-need-be / No), optionally emailing the voting link.
//   • "Set a time now" — one known time, straight to scheduled (no voting), with
//     the Google Meet link right here.
// Only shown to organizers (admin, or a committee/area Lead — the DB enforces it).

struct MeetingComposer: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let scope: MeetingScope
    /// e.g. "Meals" or "MJT House" — shown in the header for context.
    let roomLabel: String
    /// For a committee: let the organizer aim the meeting at the whole committee
    /// (value nil) or a single role. Empty → use scope.area as-is.
    var areaOptions: [AreaOption] = []
    var onCreated: () -> Void = {}

    struct AreaOption: Identifiable, Hashable {
        let value: String?
        let label: String
        var id: String { value ?? "__all__" }
    }

    private enum Mode: String, CaseIterable { case vote, now
        var label: String { self == .vote ? "Find a time" : "Set a time now" }
    }
    private enum SlotKind: String, CaseIterable { case time, range
        var label: String { self == .time ? "Times" : "Dates" }
    }

    private static let durations = [30, 45, 60, 90, 120]
    private static func durationLabel(_ d: Int) -> String {
        d < 60 ? "\(d) min" : d == 60 ? "1 hr" : "\(d / 60) hr"
    }
    private static let maxSlots = 10

    private struct SlotDraft: Identifiable {
        let id = UUID()
        var start: Date = defaultStart()
        var durationMin: Int = 60
        var endDate: Date = defaultStart()
    }
    private static func defaultStart() -> Date {
        Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date()) ?? Date()
    }

    @State private var mode: Mode = .vote
    @State private var area: String?
    @State private var title = ""
    @State private var note = ""
    @State private var slotKind: SlotKind
    @State private var slots: [SlotDraft] = [SlotDraft()]
    @State private var hasDeadline = false
    @State private var respondBy = Date()
    @State private var emailEveryone = false

    // "Set a time now" state
    @State private var nowStart = defaultStart()
    @State private var nowDuration = 60
    @State private var meetUrl = ""

    @State private var saving = false
    @State private var errorText: String?

    init(scope: MeetingScope, roomLabel: String, areaOptions: [AreaOption] = [], onCreated: @escaping () -> Void = {}) {
        self.scope = scope
        self.roomLabel = roomLabel
        self.areaOptions = areaOptions
        self.onCreated = onCreated
        // Default the audience + slot kind.
        if let first = areaOptions.first {
            _area = State(initialValue: first.value)
        } else if case let .committee(_, _, a) = scope {
            _area = State(initialValue: a)
        } else {
            _area = State(initialValue: nil)
        }
        if case .family = scope {
            _slotKind = State(initialValue: .range)
        } else {
            _slotKind = State(initialValue: .time)
        }
    }

    private var effectiveScope: MeetingScope {
        if case let .committee(id, slug, _) = scope, !areaOptions.isEmpty {
            return .committee(committeeId: id, slug: slug, area: area)
        }
        return scope
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    field("What's the meeting?") {
                        TextField("e.g. Plan the Saturday cookout", text: $title)
                            .fieldStyle()
                    }

                    if areaOptions.count > 1 {
                        field("Who's this for?") {
                            Picker("Who's this for?", selection: $area) {
                                ForEach(areaOptions) { Text($0.label).tag($0.value) }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fieldStyle()
                        }
                    }

                    field("Note (optional)") {
                        TextField("Agenda, what to bring, anything to add…", text: $note, axis: .vertical)
                            .lineLimit(2...4)
                            .fieldStyle()
                    }

                    if mode == .vote { voteSection } else { nowSection }
                }
                .padding(20)
            }
            .background(Color.mlrSurface)
            .navigationTitle("📅 Schedule a meeting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) { footer }
        }
    }

    // MARK: - Vote mode

    private var voteSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Kind", selection: $slotKind) {
                ForEach(SlotKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            field(slotKind == .range ? "Date options (up to \(Self.maxSlots))" : "Time options (up to \(Self.maxSlots))") {
                VStack(spacing: 10) {
                    ForEach($slots) { $slot in
                        slotRow($slot)
                    }
                    if slots.count < Self.maxSlots {
                        Button {
                            slots.append(SlotDraft())
                        } label: {
                            Text(slotKind == .range ? "+ Add another date range" : "+ Add another time")
                                .font(.mlrScaled(14, weight: .semibold))
                                .foregroundStyle(Color.mlrPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $hasDeadline) {
                    Text("Set a respond-by date")
                        .font(.mlrScaled(14, weight: .medium))
                        .foregroundStyle(Color.mlrText)
                }
                .tint(Color.mlrPrimary)
                if hasDeadline {
                    DatePicker("Respond by", selection: $respondBy, in: Date()..., displayedComponents: .date)
                        .font(.mlrBody)
                }
            }

            Toggle(isOn: $emailEveryone) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("📧 Also email everyone a link to vote")
                        .font(.mlrScaled(14, weight: .medium))
                        .foregroundStyle(Color.mlrText)
                    Text("Sends a heads-up email with a button that opens this. Only reaches members with email alerts on.")
                        .font(.mlrScaled(11))
                        .foregroundStyle(Color.mlrTextMuted)
                }
            }
            .tint(Color.mlrPrimary)
            .padding(12)
            .background(Color.mlrCard)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.mlrBorder, lineWidth: 1))
        }
    }

    @ViewBuilder
    private func slotRow(_ slot: Binding<SlotDraft>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if slotKind == .range {
                HStack {
                    DatePicker("", selection: slot.start, in: Date()..., displayedComponents: .date)
                        .labelsHidden()
                    Text("to").font(.mlrScaled(12)).foregroundStyle(Color.mlrTextMuted)
                    DatePicker("", selection: slot.endDate, in: Date()..., displayedComponents: .date)
                        .labelsHidden()
                    Spacer()
                    removeButton(slot)
                }
            } else {
                HStack {
                    DatePicker("", selection: slot.start, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                    Spacer()
                    removeButton(slot)
                }
                HStack(spacing: 8) {
                    Text("Length").font(.mlrScaled(12)).foregroundStyle(Color.mlrTextMuted)
                    Picker("Length", selection: slot.durationMin) {
                        ForEach(Self.durations, id: \.self) { Text(Self.durationLabel($0)).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
        .padding(10)
        .background(Color.mlrCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.mlrBorder, lineWidth: 1))
    }

    @ViewBuilder
    private func removeButton(_ slot: Binding<SlotDraft>) -> some View {
        if slots.count > 1 {
            Button {
                slots.removeAll { $0.id == slot.wrappedValue.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.mlrScaled(12, weight: .semibold))
                    .foregroundStyle(Color.mlrTextMuted)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Now mode

    private var nowSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            field("When") {
                VStack(alignment: .leading, spacing: 8) {
                    DatePicker("Meeting time", selection: $nowStart, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .font(.mlrBody)
                    HStack(spacing: 8) {
                        Text("Length").font(.mlrScaled(12)).foregroundStyle(Color.mlrTextMuted)
                        Picker("Length", selection: $nowDuration) {
                            ForEach(Self.durations, id: \.self) { Text(Self.durationLabel($0)).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Google Meet link (optional)")
                    .font(.mlrScaled(14, weight: .semibold))
                    .foregroundStyle(Color.mlrText)
                Text("Tap Create Google Meet, add it in the event and Save, then paste the link here. You can also set the time now and add the link later.")
                    .font(.mlrScaled(11))
                    .foregroundStyle(Color.mlrTextMuted)
                if let gcal = MeetingsService.googleCalendarCreateUrl(
                    title: title.isEmpty ? "Meeting" : title,
                    startsAt: nowStart, durationMin: nowDuration,
                    details: (note.isEmpty ? "" : note + "\n\n") + "Scheduled from the MLR app — add Google Meet, then paste the link back in the app.") {
                    Link(destination: gcal) {
                        Text("📅 Create Google Meet ↗")
                            .font(.mlrScaled(14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Color.mlrAccent)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                TextField("https://meet.google.com/…", text: $meetUrl)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .fieldStyle()
                if !nowValidLink {
                    Text("That doesn't look like a Google Meet link — double-check it, or leave it blank.")
                        .font(.mlrScaled(11, weight: .medium))
                        .foregroundStyle(Color.mlrAccent)
                }
            }
            .padding(12)
            .background(Color.mlrCard)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.mlrBorder, lineWidth: 1))

            Text("Everyone in \(roomLabel) gets notified, and — if there's a link — an email with the meeting details.")
                .font(.mlrScaled(11))
                .foregroundStyle(Color.mlrTextMuted)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            if let errorText {
                Text(errorText).font(.mlrScaled(13, weight: .medium)).foregroundStyle(Color.mlrDanger)
            }
            Button { Task { await submit() } } label: {
                Text(saving ? "Saving…" : mode == .vote ? "Propose meeting" : "Set the meeting")
                    .primaryButton()
            }
            .disabled(saving)
            .opacity(saving ? 0.5 : 1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var nowValidLink: Bool {
        meetUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || MeetingsService.looksLikeMeetLink(meetUrl)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: label)
            content()
        }
    }

    private func submit() async {
        errorText = nil
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { errorText = "Add a title first."; return }
        saving = true
        defer { saving = false }
        do {
            if mode == .vote {
                let cal = Calendar.current
                var inputs: [MeetingSlotInput] = []
                for s in slots {
                    if slotKind == .range {
                        let start = cal.startOfDay(for: s.start)
                        let end = cal.startOfDay(for: s.endDate)
                        if end < start { errorText = "An end date can't be before its start date."; return }
                        inputs.append(MeetingSlotInput(startsAt: start, durationMin: 60, endsAt: end))
                    } else {
                        inputs.append(MeetingSlotInput(startsAt: s.start, durationMin: s.durationMin, endsAt: nil))
                    }
                }
                guard !inputs.isEmpty else {
                    errorText = slotKind == .range ? "Add at least one date range." : "Add at least one date & time."
                    return
                }
                try await env.meetingsService.createMeeting(
                    scope: effectiveScope, title: t,
                    description: note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                    slots: inputs,
                    respondBy: hasDeadline ? Self.ymd(respondBy) : nil,
                    emailEveryone: emailEveryone)
            } else {
                if !nowValidLink { errorText = "That doesn't look like a Google Meet link."; return }
                try await env.meetingsService.createScheduledMeeting(
                    scope: effectiveScope, title: t,
                    description: note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                    startsAt: nowStart, durationMin: nowDuration,
                    meetUrl: meetUrl.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank)
            }
            Haptics.success()
            onCreated()
            dismiss()
        } catch {
            errorText = "Couldn't save. Please try again."
            print("[MeetingComposer] submit error: \(error)")
        }
    }

    private static func ymd(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
