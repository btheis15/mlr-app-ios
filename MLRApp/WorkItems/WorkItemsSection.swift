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
    /// Tap the row to open the detail sheet (comments + media). Falls back to
    /// `onEdit` when not provided (e.g. the event sheet's admin edit).
    var onOpen: (() -> Void)? = nil

    private var tapAction: (() -> Void)? { onOpen ?? onEdit }

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
                            .font(.mlrScaled(11, weight: .bold))
                            .foregroundStyle(Color.mlrPrimary)
                    } else if checking {
                        Circle().fill(Color.mlrPrimary).frame(width: 10, height: 10)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(onCheck == nil || item.isDone || checking)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.mlrScaled(14, weight: .medium))
                    .strikethrough(item.isDone)
                    .foregroundStyle(item.isDone ? Color.mlrTextMuted : Color.mlrText)
                if let notes = item.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(Color.mlrTextMuted)
                        .lineLimit(2)
                }
                badges
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let media = item.media.first {
                mediaThumb(media)
            }

            if tapAction != nil {
                Image(systemName: "chevron.right")
                    .font(.mlrScaled(12, weight: .semibold))
                    .foregroundStyle(Color.mlrTextSubtle)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { tapAction?() }
    }

    @ViewBuilder
    private var badges: some View {
        let showUrgency = item.urgency != nil && !item.isDone
        if showUrgency || item.peopleNeeded != nil || item.commentCount > 0 {
            HStack(spacing: 6) {
                if let urgency = item.urgency, !item.isDone {
                    chip(text: "\(urgency.emoji) \(urgency.label)", color: urgency.uiColor)
                }
                if let needed = item.peopleNeeded {
                    chip(text: "👥 \(needed) needed", color: Color.mlrTextMuted)
                }
                if item.commentCount > 0 {
                    chip(text: "💬 \(item.commentCount)", color: Color.mlrTextMuted)
                }
            }
        }
    }

    private func chip(text: String, color: Color) -> some View {
        Text(text)
            .font(.mlrScaled(10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func mediaThumb(_ media: WorkItemMedia) -> some View {
        ZStack {
            if media.isVideo {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.mlrCard)
                    .overlay(Image(systemName: "film").font(.mlrScaled(14)).foregroundStyle(Color.mlrPrimary))
            } else {
                MediaThumb(url: media.url)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Urgency colour (UI layer)

extension WorkUrgency {
    var uiColor: Color {
        switch self {
        case .asap:       return Color.mlrDanger
        case .thisYear:   return Color.mlrWarning
        case .niceToHave: return Color.mlrSuccess
        }
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
                            .font(.mlrScaled(13, weight: .semibold))
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
