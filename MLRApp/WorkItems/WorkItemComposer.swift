import SwiftUI

// MARK: - WorkItemComposer
//
// Add/edit sheet for a work checklist item. Any signed-in member can add items;
// admins get the status toggle + delete when editing. Mirrors the web
// WorkItemComposer (people-needed stepper 0–20 where 0 = "Any" → nil, optional
// event link in add mode unless pre-linked).

struct WorkItemComposer: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let item: WorkItem?
    let preLinkedEventId: String?
    let onSaved: () -> Void

    @State private var title: String
    @State private var notes: String
    @State private var peopleNeeded: Int
    @State private var status: WorkItemStatus
    @State private var selectedEventId: String?
    @State private var pending = false
    @State private var errorText: String?

    init(item: WorkItem? = nil, preLinkedEventId: String? = nil, onSaved: @escaping () -> Void) {
        self.item = item
        self.preLinkedEventId = preLinkedEventId
        self.onSaved = onSaved
        _title        = State(initialValue: item?.title ?? "")
        _notes        = State(initialValue: item?.notes ?? "")
        _peopleNeeded = State(initialValue: item?.peopleNeeded ?? 0)
        _status       = State(initialValue: item?.status ?? .open)
        _selectedEventId = State(initialValue: preLinkedEventId)
    }

    private var editing: Bool { item != nil }
    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !pending
    }
    private var linkableEvents: [ResortEvent] {
        guard !editing, preLinkedEventId == nil else { return [] }
        return env.eventsService.upcomingEvents
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    taskSection
                    peopleSection
                    if !linkableEvents.isEmpty { eventLinkSection }
                    if editing && env.isAdmin { statusSection }

                    Button {
                        Task { await submit() }
                    } label: {
                        Text(pending ? "Saving…" : (editing ? "Save changes" : "Add to checklist"))
                            .primaryButton()
                    }
                    .disabled(!canSubmit)
                    .opacity(canSubmit ? 1 : 0.5)

                    if editing && env.isAdmin {
                        Button {
                            Task { await remove() }
                        } label: {
                            Text("Remove from checklist")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.mlrDanger)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.mlrDanger.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(pending)
                    }

                    if let errorText {
                        Text(errorText)
                            .font(.mlrCaption)
                            .foregroundStyle(Color.mlrDanger)
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(editing ? "Edit item" : "Add work item")
            .navigationBarTitleDisplayMode(.inline)
            .tint(Color.mlrPrimary)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Sections

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Task")
            TextField("e.g. \"Caulk windows on the red & white cabin\"", text: $title)
                .fieldStyle()
            TextField("Extra details (optional)", text: $notes, axis: .vertical)
                .lineLimit(3...6)
                .fieldStyle()
        }
    }

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "How many people needed? (optional)")
            HStack {
                Text("People needed")
                    .font(.mlrBody)
                    .foregroundStyle(Color.mlrTextMuted)
                Spacer()
                HStack(spacing: 16) {
                    stepperButton("minus", enabled: peopleNeeded > 0) {
                        peopleNeeded = max(0, peopleNeeded - 1)
                    }
                    Text(peopleNeeded == 0 ? "Any" : "\(peopleNeeded)")
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .frame(minWidth: 36)
                    stepperButton("plus", enabled: peopleNeeded < 20) {
                        peopleNeeded = min(20, peopleNeeded + 1)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .cardStyle()
        }
    }

    private func stepperButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(enabled ? Color.mlrPrimary : Color.mlrTextSubtle)
                .frame(width: 32, height: 32)
                .background(Color.mlrSurface)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.mlrBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var eventLinkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Link to an event (optional)")
            VStack(spacing: 6) {
                ForEach(linkableEvents) { ev in
                    Button {
                        selectedEventId = selectedEventId == ev.id ? nil : ev.id
                    } label: {
                        HStack(spacing: 10) {
                            Text(ev.emoji ?? "📅")
                            Text(ev.title)
                                .font(.system(size: 14, weight: selectedEventId == ev.id ? .semibold : .regular))
                                .foregroundStyle(selectedEventId == ev.id ? Color.mlrPrimary : Color.mlrText)
                            Spacer()
                            if selectedEventId == ev.id {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Color.mlrPrimary)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(selectedEventId == ev.id ? Color.mlrPrimary.opacity(0.1) : Color.mlrCard)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(selectedEventId == ev.id ? Color.mlrPrimary.opacity(0.3) : Color.mlrBorder, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Status")
            HStack(spacing: 8) {
                ForEach([WorkItemStatus.open, .done], id: \.self) { s in
                    Button {
                        status = s
                    } label: {
                        Text(s == .open ? "⬜ Open" : "✅ Done")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(status == s ? .white : Color.mlrTextMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(status == s ? Color.mlrPrimary : Color.mlrCard)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Actions

    private func submit() async {
        guard canSubmit else { return }
        guard env.isSignedIn else { env.authService.promptSignIn(); return }
        pending = true
        errorText = nil
        defer { pending = false }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let needed = peopleNeeded > 0 ? peopleNeeded : nil

        do {
            if let item {
                try await env.workItemsService.updateItem(
                    id: item.id,
                    title: trimmedTitle,
                    notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                    category: item.category,
                    status: status,
                    peopleNeeded: needed
                )
            } else {
                let newId = try await env.workItemsService.createItem(
                    title: trimmedTitle,
                    notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                    category: nil,
                    peopleNeeded: needed
                )
                if let eventId = selectedEventId {
                    try await env.workItemsService.addToEvent(eventId: eventId, itemId: newId)
                }
            }
            onSaved()
            dismiss()
        } catch {
            errorText = "Couldn't save. Check your connection and try again."
            print("[WorkItemComposer] submit error: \(error)")
        }
    }

    private func remove() async {
        guard let item else { return }
        pending = true
        errorText = nil
        defer { pending = false }
        do {
            try await env.workItemsService.deleteItem(id: item.id)
            onSaved()
            dismiss()
        } catch {
            errorText = "Couldn't remove the item. Please try again."
            print("[WorkItemComposer] remove error: \(error)")
        }
    }
}
