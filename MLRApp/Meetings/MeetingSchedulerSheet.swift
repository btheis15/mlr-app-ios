import SwiftUI

// MARK: - MeetingSchedulerSheet (migrations 0116–0122)
//
// For an OPEN meeting: every member marks Yes / If-need-be / No on each proposed
// time, sees live tallies + the best slot, and taps Save. The organizer (or an
// admin) also gets a "Pick this time" action per slot → a guided in-sheet step
// (Google Meet link paste OR create a real Event), then finalize. For a
// SCHEDULED meeting: the chosen time + a Join button (or View the event).

/// Lightweight room member for name resolution + the "everyone can make it" count.
struct MeetingMember: Identifiable, Equatable {
    let id: UUID
    let name: String
    var avatarUrl: String? = nil
}

struct MeetingSchedulerSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let meeting: Meeting
    let members: [MeetingMember]
    /// Room size, for the "everyone can make it" badge.
    let memberCount: Int
    /// isAdmin || createdByMe — gates Finalize / Cancel / Delete.
    let canManage: Bool
    /// Reload the room's meetings after a write.
    var onChanged: () -> Void = {}

    private enum Outcome: String { case call, event }

    @State private var draft: [UUID: MeetingAvailability] = [:]
    @State private var expanded: UUID?
    @State private var finalizing: MeetingSlot?
    @State private var meetUrl = ""
    @State private var outcome: Outcome = .call
    @State private var eventKind: EventKind = .workWeekend
    @State private var eventTitle = ""
    @State private var eventLocation = ""
    @State private var saving = false
    @State private var errorText: String?
    @State private var confirmCancel = false
    @State private var confirmDelete = false

    private var uid: UUID? { env.currentProfile?.id }
    private var isOpen: Bool { meeting.status == .open }
    private var chosen: MeetingSlot? { meeting.slots.first { $0.id == meeting.chosenSlotId } }

    private var dirty: Bool {
        meeting.slots.contains { (draft[$0.id]) != (meeting.myAnswers[$0.id]) }
    }
    private var answeredAll: Bool { meeting.slots.allSatisfy { draft[$0.id] != nil } }

    var body: some View {
        NavigationStack {
            Group {
                if let finalizing { finalizeStep(finalizing) } else { mainSheet }
            }
            .background(Color.mlrSurface)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .onAppear {
            draft = meeting.myAnswers
            meetUrl = meeting.meetUrl ?? ""
            eventTitle = meeting.title
            outcome = meeting.scopeType == "family" ? .event : .call
        }
    }

    // MARK: - Main sheet

    private var mainSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let d = meeting.description, !d.isEmpty {
                    Text(d).font(.mlrBody).foregroundStyle(Color.mlrText.opacity(0.75))
                }
                if meeting.status == .scheduled, let chosen { scheduledCard(chosen) }
                if meeting.status == .cancelled {
                    Text("This meeting was cancelled.")
                        .font(.mlrScaled(14)).foregroundStyle(Color.mlrTextMuted)
                        .frame(maxWidth: .infinity)
                        .padding(12).background(Color.mlrCard).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                if isOpen {
                    SectionLabel(text: "Which times work?")
                    ForEach(meeting.slots) { slotCard($0) }
                }
                if canManage && meeting.status != .cancelled { manageButtons }
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) { if isOpen { saveBar } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title).font(.mlrScaled(20, weight: .bold)).foregroundStyle(Color.mlrText)
            Text(headerSubtitle).font(.mlrScaled(12)).foregroundStyle(Color.mlrTextMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerSubtitle: String {
        switch meeting.status {
        case .scheduled: return "Scheduled ✓"
        case .cancelled: return "Cancelled"
        case .open:      return "Mark when you're free · \(meeting.respondentCount) responded"
        }
    }

    private func scheduledCard(_ chosen: MeetingSlot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("📅 \(Self.formatSlot(chosen))")
                .font(.mlrScaled(14, weight: .semibold)).foregroundStyle(Color.mlrPrimary)
            if meeting.createdEventId != nil {
                Text("Added to the resort calendar — find it on the Events tab.")
                    .font(.mlrScaled(12)).foregroundStyle(Color.mlrTextMuted)
            } else if let url = meeting.meetUrl, let link = URL(string: url) {
                Link(destination: link) { joinLabel("Join the meeting ↗") }
            } else {
                Text("No join link yet.").font(.mlrScaled(12)).foregroundStyle(Color.mlrTextMuted)
            }
            if canManage && meeting.createdEventId == nil {
                Button {
                    meetUrl = meeting.meetUrl ?? ""
                    outcome = .call
                    finalizing = chosen
                } label: {
                    Text(meeting.meetUrl != nil ? "Change time or link" : "Add the Meet link")
                        .font(.mlrScaled(12, weight: .semibold))
                        .foregroundStyle(Color.mlrText.opacity(0.7))
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(Color.mlrSurface).clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.mlrBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(Color.mlrPrimary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.mlrPrimary.opacity(0.2), lineWidth: 1))
    }

    private func joinLabel(_ text: String) -> some View {
        Text(text)
            .font(.mlrScaled(14, weight: .semibold)).foregroundStyle(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(Color.mlrPrimary).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Slot card

    private func slotCard(_ s: MeetingSlot) -> some View {
        let isBest = isOpen && s.id == meeting.bestSlotId && s.score > 0
        let everyone = s.yes.count >= memberCount && memberCount > 0
        let mine = draft[s.id]
        let isExpanded = expanded == s.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(Self.formatSlot(s)).font(.mlrScaled(14, weight: .semibold)).foregroundStyle(Color.mlrText)
                Spacer()
                if isBest {
                    Text(everyone ? "✅ Everyone" : "Best so far")
                        .font(.mlrScaled(11, weight: .semibold)).foregroundStyle(Color.mlrPrimary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.mlrPrimary.opacity(0.15)).clipShape(Capsule())
                }
            }

            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded = isExpanded ? nil : s.id }
            } label: {
                HStack(spacing: 12) {
                    Text("✅ \(s.yes.count)")
                    Text("🤔 \(s.ifNeedBe.count)")
                    Text("✕ \(s.no.count)")
                    if s.yes.count + s.ifNeedBe.count + s.no.count > 0 {
                        Text(isExpanded ? "hide" : "who?").foregroundStyle(Color.mlrText.opacity(0.4))
                    }
                }
                .font(.mlrScaled(12)).foregroundStyle(Color.mlrTextMuted)
            }
            .buttonStyle(.plain)

            if isExpanded { whoReacted(s) }

            if isOpen {
                HStack(spacing: 6) {
                    ForEach(MeetingAvailability.allCases, id: \.self) { opt in
                        availButton(opt, selected: mine == opt, slotId: s.id)
                    }
                }
            }

            if isOpen && canManage {
                Button {
                    meetUrl = ""
                    outcome = meeting.scopeType == "family" ? .event : .call
                    finalizing = s
                } label: {
                    Text("Pick this time →")
                        .font(.mlrScaled(12, weight: .semibold)).foregroundStyle(Color.mlrPrimary)
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background(Color.mlrPrimary.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.mlrPrimary.opacity(0.2), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(isBest ? Color.mlrPrimary.opacity(0.05) : Color.mlrCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isBest ? Color.mlrPrimary.opacity(0.3) : Color.mlrBorder, lineWidth: 1))
    }

    private func availButton(_ opt: MeetingAvailability, selected: Bool, slotId: UUID) -> some View {
        Button {
            draft[slotId] = opt
            Haptics.select()
        } label: {
            Text(opt.label)
                .font(.mlrScaled(12, weight: .semibold))
                .foregroundStyle(selected ? .white : Color.mlrText.opacity(0.55))
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(selected ? availColor(opt) : Color.mlrSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? availColor(opt) : Color.mlrBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func availColor(_ opt: MeetingAvailability) -> Color {
        switch opt {
        case .yes:      return Color.mlrPrimary
        case .ifNeedBe: return Color.mlrSun
        case .no:       return Color.mlrText
        }
    }

    @ViewBuilder
    private func whoReacted(_ s: MeetingSlot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !s.yes.isEmpty { whoLine("Yes:", s.yes, Color.mlrPrimary) }
            if !s.ifNeedBe.isEmpty { whoLine("If need be:", s.ifNeedBe, Color.mlrSun) }
            if !s.no.isEmpty { whoLine("No:", s.no, Color.mlrTextMuted) }
        }
        .padding(.top, 4)
        .overlay(alignment: .top) { Divider() }
    }

    private func whoLine(_ label: String, _ ids: [UUID], _ color: Color) -> some View {
        (Text(label).font(.mlrScaled(11, weight: .semibold)).foregroundColor(color)
         + Text(" " + ids.map(who).joined(separator: ", ")).font(.mlrScaled(11)).foregroundColor(Color.mlrText))
    }

    private func who(_ id: UUID) -> String {
        if let uid, id == uid { return "You" }
        return members.first { $0.id == id }?.name ?? "A member"
    }

    // MARK: - Manage / save bars

    private var manageButtons: some View {
        HStack(spacing: 8) {
            if isOpen {
                Button { confirmCancel = true } label: {
                    Text("Cancel meeting").font(.mlrScaled(12, weight: .semibold))
                        .foregroundStyle(Color.mlrText.opacity(0.7))
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(Color.mlrCard).clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.mlrBorder, lineWidth: 1))
                }
                .buttonStyle(.plain).disabled(saving)
            }
            Button { confirmDelete = true } label: {
                Text("Delete").font(.mlrScaled(12, weight: .semibold)).foregroundStyle(Color.mlrDanger)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(Color.mlrCard).clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.mlrBorder, lineWidth: 1))
            }
            .buttonStyle(.plain).disabled(saving)
        }
        .confirmationDialog("Cancel \"\(meeting.title)\"? Members will see it as cancelled.", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel meeting", role: .destructive) { Task { await cancel() } }
        }
        .confirmationDialog("Delete \"\(meeting.title)\"? This removes everyone's answers for good.", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        }
    }

    private var saveBar: some View {
        VStack(spacing: 8) {
            if let errorText { Text(errorText).font(.mlrScaled(13, weight: .medium)).foregroundStyle(Color.mlrDanger) }
            Button { Task { await saveAvailability() } } label: {
                Text(saveLabel).primaryButton()
            }
            .disabled(saving || !dirty)
            .opacity((saving || !dirty) ? 0.5 : 1)
        }
        .padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
    }

    private var saveLabel: String {
        if saving { return "Saving…" }
        if dirty { return "Save my availability" }
        return answeredAll ? "Saved ✓" : "Save my availability"
    }

    // MARK: - Finalize step

    private func finalizeStep(_ slot: MeetingSlot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(outcome == .event ? "Create the event" : "Set the meeting")
                        .font(.mlrScaled(20, weight: .bold)).foregroundStyle(Color.mlrText)
                    Text(Self.formatSlot(slot)).font(.mlrScaled(12)).foregroundStyle(Color.mlrTextMuted)
                }

                Picker("Outcome", selection: $outcome) {
                    Text("Schedule a call").tag(Outcome.call)
                    Text("Create an event").tag(Outcome.event)
                }
                .pickerStyle(.segmented)

                if outcome == .event { eventForm } else { callForm(slot) }
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) { finalizeBar(slot) }
    }

    @ViewBuilder
    private var eventForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Event title")
                TextField("e.g. Work Weekend", text: $eventTitle).fieldStyle()
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Kind")
                Picker("Kind", selection: $eventKind) {
                    Text("Work Weekend").tag(EventKind.workWeekend)
                    Text("Holiday").tag(EventKind.holiday)
                    Text("Other event").tag(EventKind.custom)
                }
                .pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading).fieldStyle()
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Location (optional)")
                TextField("e.g. Up North", text: $eventLocation).fieldStyle()
            }
            Text("Everyone who said Yes or If-need-be for this option gets added to the event as Going/Maybe — they'll be asked to confirm once it's official.")
                .font(.mlrScaled(11)).foregroundStyle(Color.mlrTextMuted)
        }
    }

    private func callForm(_ slot: MeetingSlot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("1. Create the Google Meet").font(.mlrScaled(14, weight: .semibold)).foregroundStyle(Color.mlrText)
                Text("Opens a Google Calendar event, already filled in with this time. Tap \"Add Google Meet\", then Save — you'll get a join link.")
                    .font(.mlrScaled(11)).foregroundStyle(Color.mlrTextMuted)
                if let gcal = MeetingsService.googleCalendarCreateUrl(
                    title: meeting.title, startsAt: slot.startsAt, durationMin: slot.durationMin,
                    details: (meeting.description.map { $0 + "\n\n" } ?? "") + "Scheduled from the MLR app — add Google Meet, then paste the link back in the app.") {
                    Link(destination: gcal) {
                        Text("📅 Create Google Meet ↗")
                            .font(.mlrScaled(14, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(Color.mlrAccent).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .padding(12).background(Color.mlrCard).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.mlrBorder, lineWidth: 1))

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "2. Paste the Meet link here")
                TextField("https://meet.google.com/…", text: $meetUrl)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .fieldStyle()
                if !validLink {
                    Text("That doesn't look like a Google Meet link — double-check it, or skip for now.")
                        .font(.mlrScaled(11, weight: .medium)).foregroundStyle(Color.mlrAccent)
                }
                Text("No link yet? Tap Set the meeting to lock the time now — you can add the link later.")
                    .font(.mlrScaled(11)).foregroundStyle(Color.mlrTextMuted)
            }
        }
    }

    private func finalizeBar(_ slot: MeetingSlot) -> some View {
        VStack(spacing: 8) {
            if let errorText { Text(errorText).font(.mlrScaled(13, weight: .medium)).foregroundStyle(Color.mlrDanger) }
            Button {
                Task { outcome == .event ? await finalizeAsEvent(slot) : await finalizeCall(slot) }
            } label: {
                Text(saving ? "Saving…" : outcome == .event ? "Create the event" : "Set the meeting").primaryButton()
            }
            .disabled(saving || (outcome == .event ? eventTitle.trimmingCharacters(in: .whitespaces).isEmpty : !validLink))
            .opacity(saving ? 0.5 : 1)
            Button { finalizing = nil; errorText = nil } label: {
                Text("← Back").font(.mlrScaled(14, weight: .semibold)).foregroundStyle(Color.mlrText.opacity(0.7))
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(Color.mlrSurface).clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.mlrBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
    }

    private var validLink: Bool {
        meetUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || MeetingsService.looksLikeMeetLink(meetUrl)
    }

    // MARK: - Writes

    private func guardWrite() -> Bool {
        if env.isPreviewing { return false }   // writes would land as the real admin
        return true
    }

    private func saveAvailability() async {
        guard guardWrite() else { return }
        errorText = nil; saving = true; defer { saving = false }
        do {
            try await env.meetingsService.setMyAvailability(meetingId: meeting.id, answers: draft)
            onChanged()
        } catch {
            errorText = "Couldn't save your availability."
        }
    }

    private func finalizeCall(_ slot: MeetingSlot) async {
        guard guardWrite() else { return }
        errorText = nil; saving = true; defer { saving = false }
        do {
            try await env.meetingsService.finalizeMeeting(meetingId: meeting.id, slotId: slot.id, meetUrl: meetUrl)
            Haptics.success(); onChanged(); dismiss()
        } catch {
            errorText = "Couldn't set the meeting."
        }
    }

    private func finalizeAsEvent(_ slot: MeetingSlot) async {
        guard guardWrite() else { return }
        errorText = nil; saving = true; defer { saving = false }
        do {
            try await env.meetingsService.finalizeMeetingAsEvent(
                meetingId: meeting.id, slotId: slot.id, kind: eventKind,
                title: eventTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : eventTitle,
                location: eventLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : eventLocation)
            Haptics.success(); onChanged(); dismiss()
        } catch {
            errorText = "Couldn't create the event."
        }
    }

    private func cancel() async {
        guard guardWrite() else { return }
        saving = true; defer { saving = false }
        do { try await env.meetingsService.cancelMeeting(meetingId: meeting.id); onChanged(); dismiss() }
        catch { errorText = "Couldn't cancel." }
    }

    private func delete() async {
        guard guardWrite() else { return }
        saving = true; defer { saving = false }
        do { try await env.meetingsService.deleteMeeting(meetingId: meeting.id); onChanged(); dismiss() }
        catch { errorText = "Couldn't delete." }
    }

    // MARK: - Formatting

    static func formatSlot(_ s: MeetingSlot) -> String {
        let f = DateFormatter()
        if let end = s.endsAt {
            f.dateFormat = "EEE, MMM d"
            return "\(f.string(from: s.startsAt)) – \(f.string(from: end))"
        }
        f.dateFormat = "EEE, MMM d, h:mm a"
        let when = f.string(from: s.startsAt)
        let len = s.durationMin < 60 ? "\(s.durationMin) min" : s.durationMin == 60 ? "1 hr" : "\(s.durationMin / 60) hr"
        return "\(when) · \(len)"
    }
}
