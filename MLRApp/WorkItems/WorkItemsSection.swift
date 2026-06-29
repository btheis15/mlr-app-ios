import SwiftUI

// MARK: - WorkItemRow
//
// A single checklist row: round checkbox, title (+ notes, "👥 n needed"),
// strikethrough when done, optional admin edit chevron. Reused by the Home
// card and the event sheet.

struct WorkItemRow: View {
    let item: WorkItem
    var checking: Bool = false
    var onCheck: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Checkbox
            Button {
                onCheck?()
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(item.isDone ? Color.mlrPrimary : Color.mlrBorder, lineWidth: 2)
                        .frame(width: 20, height: 20)
                    if item.isDone {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.mlrPrimary)
                    } else if checking {
                        Circle().fill(Color.mlrPrimary).frame(width: 10, height: 10)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(onCheck == nil || item.isDone || checking)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 14, weight: .medium))
                    .strikethrough(item.isDone)
                    .foregroundStyle(item.isDone ? Color.mlrTextMuted : Color.mlrText)
                if let notes = item.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(Color.mlrTextMuted)
                }
                if let needed = item.peopleNeeded {
                    Text("👥 \(needed) needed")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.mlrTextMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.mlrCard)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if onEdit != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.mlrTextSubtle)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { onEdit?() }
    }
}

// MARK: - EventWorkItemsSection
//
// The "Work items planned" block inside an event sheet. Loads the items linked
// to the event, lets any member check them off (optimistic), and lets admins
// add one (pre-linked to this event) or edit existing items.

struct EventWorkItemsSection: View {
    @Environment(AppEnvironment.self) private var env
    let event: ResortEvent

    @State private var items: [WorkItem] = []
    @State private var loading = true
    @State private var checking: UUID? = nil
    @State private var showAdd = false
    @State private var editing: WorkItem? = nil

    private var coveredCount: Int { items.filter(\.isDone).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Work items planned")
                Spacer()
                if env.isAdmin {
                    Button { showAdd = true } label: {
                        Text("+ Add")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.mlrPrimary)
                    }
                }
            }

            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else if items.isEmpty {
                Text(env.isAdmin ? "No work items yet — tap + Add to plan one." : "No work items yet.")
                    .font(.mlrCaption)
                    .foregroundStyle(Color.mlrTextMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        WorkItemRow(
                            item: item,
                            checking: checking == item.id,
                            onCheck: { Task { await check(item: item) } },
                            onEdit: env.isAdmin ? { editing = item } : nil
                        )
                        if item.id != items.last?.id {
                            Divider().padding(.leading, 14)
                        }
                    }
                    if !items.isEmpty {
                        Divider().padding(.leading, 14)
                        Text("\(coveredCount)/\(items.count) covered")
                            .font(.caption)
                            .foregroundStyle(Color.mlrTextMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                }
                .cardStyle()
            }
        }
        .task { await load() }
        .sheet(isPresented: $showAdd) {
            WorkItemComposer(preLinkedEventId: event.id) { Task { await load() } }
        }
        .sheet(item: $editing) { item in
            WorkItemComposer(item: item) { Task { await load() } }
        }
    }

    private func load() async {
        loading = true
        items = await env.workItemsService.fetchEventItems(eventId: event.id)
        loading = false
    }

    private func check(item: WorkItem) async {
        guard env.isSignedIn else { env.authService.promptSignIn(); return }
        guard !item.isDone else { return }
        checking = item.id
        defer { checking = nil }
        // Optimistic
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].status = .done
        }
        do {
            try await env.workItemsService.markDone(id: item.id)
            await load()
        } catch {
            await load() // revert from source of truth
        }
    }
}
