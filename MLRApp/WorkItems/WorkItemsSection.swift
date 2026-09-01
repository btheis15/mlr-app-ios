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
            .buttonStyle(.pressable)
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
        // Resolved through the one helper that handles `custom` — indexing the
        // fixed tier table directly renders a custom item's chip blank.
        let urgency = item.isDone ? nil : WorkUrgencyDisplay(item: item)
        if urgency != nil || item.peopleNeeded != nil || item.commentCount > 0 || item.isRecurring {
            HStack(spacing: 6) {
                if let urgency {
                    chip(text: "\(urgency.emoji) \(urgency.label)", color: urgency.color)
                }
                if let years = item.recurEveryYears {
                    chip(text: years == 1 ? "🔁 Yearly" : "🔁 Every \(years)y",
                         color: Color.mlrTextMuted)
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
    /// ⚠️ Fixed tiers only. A `custom` item's colour comes from its own
    /// `customColor` — resolve through `WorkUrgencyDisplay`, which is the one
    /// place that knows the difference.
    var uiColor: Color {
        switch self {
        case .asap:       return Color.mlrDanger
        // "This year" is ORANGE and "Next year" yellow (web #545) — the two
        // used to share a colour and were indistinguishable on a card.
        case .thisYear:   return .orange
        case .nextYear:   return Color.mlrWarning
        case .niceToHave: return Color.mlrSuccess
        case .custom:     return Color.mlrTextMuted
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

    @State private var houseCounts: [EventHouseItemCount] = []

    private var coveredCount: Int { items.filter(\.isDone).count }

    /// Resort-wide items — `house_id` null.
    private var resortItems: [WorkItem] { items.filter { $0.houseId == nil } }

    /// Houses whose items this viewer can actually see, in the RPC's order.
    private var visibleHouseGroups: [(String, [WorkItem])] {
        houseCounts.compactMap { count in
            let mine = items.filter { $0.houseId == count.houseId }
            guard !mine.isEmpty else { return nil }
            return ("\(count.houseEmoji ?? "🏠") \(count.houseName)", mine)
        }
    }

    /// ⚠️ Houses with items this viewer CAN'T see. Their rows are RLS-invisible,
    /// so without this the section would silently vanish and the event would
    /// look like it had no plan for that house. The count comes from a DEFINER
    /// function, so we can say a plan exists without leaking what's in it.
    private var lockedHouses: [EventHouseItemCount] {
        houseCounts.filter { count in
            count.itemCount > 0 && !items.contains { $0.houseId == count.houseId }
        }
    }

    @ViewBuilder
    private func scopeGroup(title: String, items groupItems: [WorkItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.mlrScaled(12, weight: .semibold))
                .foregroundStyle(Color.mlrTextMuted)
            VStack(spacing: 0) {
                ForEach(groupItems) { item in
                    WorkItemRow(
                        item: item,
                        checking: checking == item.id,
                        onCheck: { Task { await check(item: item) } },
                        onEdit: env.isAdmin ? { editing = item } : nil
                    )
                    if item.id != groupItems.last?.id {
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .cardStyle()
        }
    }

    private func lockedHouseRow(_ house: EventHouseItemCount) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.mlrScaled(12))
                .foregroundStyle(Color.mlrTextMuted)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(house.houseEmoji ?? "🏠") \(house.houseName) · \(house.itemCount) item\(house.itemCount == 1 ? "" : "s") planned")
                    .font(.mlrScaled(13, weight: .medium))
                Text("Details only visible to that house")
                    .font(.mlrScaled(11))
                    .foregroundStyle(Color.mlrTextMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

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
                // Grouped by SCOPE: "🌲 Around the Resort" first, then one group
                // per house.
                if !resortItems.isEmpty {
                    scopeGroup(title: "🌲 Around the Resort", items: resortItems)
                }
                ForEach(visibleHouseGroups, id: \.0) { name, groupItems in
                    scopeGroup(title: name, items: groupItems)
                }
                ForEach(lockedHouses) { house in
                    lockedHouseRow(house)
                }

                Text("\(coveredCount)/\(items.count) covered")
                    .font(.caption)
                    .foregroundStyle(Color.mlrTextMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

    /// ⚠️ Refetches the COUNTS too, not just the items. After unlinking an item
    /// the counts are what tell the locked-house rows whether they still belong,
    /// so leaving them stale strands a "2 items planned" line for a house that
    /// now has none.
    private func load() async {
        loading = true
        async let fetched = env.workItemsService.fetchEventItems(eventId: event.id)
        async let counts = env.workItemsService.fetchEventHouseCounts(eventId: event.id)
        (items, houseCounts) = await (fetched, counts)
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
