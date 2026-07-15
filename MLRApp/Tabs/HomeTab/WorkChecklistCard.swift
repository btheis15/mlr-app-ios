import SwiftUI

// MARK: - WorkChecklistCard
//
// The work checklist card on Home. Any signed-in member can add items and check
// them off; tap a row to open its detail (photos + comments). Items are grouped
// into an "Around the resort" (MLR) section and the viewer's house section(s)
// (migration 0066), ordered by urgency (0069). Open items preview to 5 with
// "show N more"; done items collapse into a count. Mirrors the web WorkChecklist.

struct WorkChecklistCard: View {
    @Environment(AppEnvironment.self) private var env

    @State private var cardOpen = false
    @State private var showAll = false
    @State private var doneExpanded = false
    @State private var checking: UUID? = nil
    @State private var composing = false
    @State private var opened: WorkItem? = nil

    private let preview = 5

    private var open: [WorkItem] { env.workItemsService.openItems }
    private var done: [WorkItem] { env.workItemsService.doneItems }
    private var total: Int { open.count + done.count }
    private var asapCount: Int { open.filter { $0.urgency == .asap }.count }

    /// Open items ordered by section (MLR first, then houses by position), then
    /// urgency, then newest-first.
    private var orderedOpen: [WorkItem] {
        open.sorted { a, b in
            let ra = sectionRank(a), rb = sectionRank(b)
            if ra != rb { return ra < rb }
            let ua = a.urgency?.rank ?? 3, ub = b.urgency?.rank ?? 3
            if ua != ub { return ua < ub }
            return a.createdAt > b.createdAt
        }
    }
    private var visible: [WorkItem] { showAll ? orderedOpen : Array(orderedOpen.prefix(preview)) }
    private var hiddenCount: Int { orderedOpen.count - preview }
    private var hasHouseSections: Bool { open.contains { $0.houseId != nil } }

    var body: some View {
        VStack(spacing: 0) {
            header

            if cardOpen {
                if total > 0 {
                    Gauge(value: Double(done.count), in: 0...Double(total)) {
                        EmptyView()
                    } currentValueLabel: {
                        Text("\(done.count)/\(total)")
                    }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(Color.mlrPrimary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    .accessibilityLabel("Work checklist progress")
                    .accessibilityValue("\(done.count) of \(total) done")
                }

                if !open.isEmpty {
                    Divider()
                    ForEach(Array(visible.enumerated()), id: \.element.id) { idx, item in
                        if idx == 0 || visible[idx - 1].houseId != item.houseId,
                           let h = sectionHeader(for: item) {
                            sectionHeaderView(emoji: h.emoji, name: h.name)
                        }
                        WorkItemRow(
                            item: item,
                            checking: checking == item.id,
                            onCheck: { Task { await check(item: item) } },
                            onOpen: { opened = item }
                        )
                        Divider().padding(.leading, 14)
                    }
                    if hiddenCount > 0 {
                        Button {
                            withAnimation { showAll.toggle() }
                        } label: {
                            Text(showAll ? "Show less" : "Show \(hiddenCount) more item\(hiddenCount == 1 ? "" : "s") ›")
                                .font(.mlrScaled(12, weight: .medium))
                                .foregroundStyle(showAll ? Color.mlrTextMuted : Color.mlrPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                    }
                } else if !done.isEmpty {
                    Divider()
                    Text("All caught up ✅")
                        .font(.mlrCaption)
                        .foregroundStyle(Color.mlrTextMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }

                if !done.isEmpty && !open.isEmpty {
                    Divider()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { doneExpanded.toggle() }
                    } label: {
                        HStack {
                            Text("✅ \(done.count) item\(done.count == 1 ? "" : "s") done")
                                .font(.caption)
                                .foregroundStyle(Color.mlrTextMuted)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.mlrScaled(11, weight: .semibold))
                                .foregroundStyle(Color.mlrTextSubtle)
                                .rotationEffect(.degrees(doneExpanded ? 90 : 0))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    if doneExpanded {
                        ForEach(done) { item in
                            Divider().padding(.leading, 14)
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.mlrScaled(13))
                                    .foregroundStyle(Color.mlrSuccess)
                                    .padding(.top, 1)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.mlrScaled(13))
                                        .foregroundStyle(Color.mlrTextMuted)
                                        .strikethrough(color: Color.mlrTextMuted)
                                    if let name = item.completedByName {
                                        let ago = item.completedAt.map { relativeTime($0) } ?? ""
                                        Text("By \(name)\(ago.isEmpty ? "" : " · \(ago)")")
                                            .font(.mlrScaled(11))
                                            .foregroundStyle(Color.mlrTextSubtle)
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .onTapGesture { opened = item }
                        }
                    }
                }
            }
        }
        .cardStyle()
        .task {
            await env.workItemsService.fetchItems()
            if env.housesService.houses.isEmpty { await env.housesService.fetchHouses() }
            env.workItemsService.subscribeToRealtime()
        }
        .onDisappear { env.workItemsService.unsubscribeFromRealtime() }
        .sheet(isPresented: $composing) {
            WorkItemComposer { Task { await env.workItemsService.fetchItems() } }
        }
        .sheet(item: $opened) { item in
            WorkItemDetailSheet(item: item) { Task { await env.workItemsService.fetchItems() } }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            // The whole bar (emoji + text + chevron) toggles the card open/closed.
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { cardOpen.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Text("🔧").font(.mlrScaled(18))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Work Checklist")
                            .font(.mlrScaled(15, weight: .semibold))
                            .foregroundStyle(Color.mlrText)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Color.mlrTextMuted)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.mlrScaled(13, weight: .semibold))
                        .foregroundStyle(Color.mlrTextSubtle)
                        .rotationEffect(.degrees(cardOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                if env.isSignedIn { composing = true } else { env.authService.promptSignIn() }
            } label: {
                Image(systemName: "plus")
                    .font(.mlrScaled(15, weight: .bold))
                    .foregroundStyle(Color.mlrPrimary)
                    .frame(width: 32, height: 32)
                    .background(Color.mlrPrimary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        if env.workItemsService.isLoading && open.isEmpty && done.isEmpty { return "Loading…" }
        if open.isEmpty && done.isEmpty { return "Nothing on the list yet" }
        if open.isEmpty { return "All \(done.count) item\(done.count == 1 ? "" : "s") done ✅" }
        var parts = "\(open.count) open"
        if done.count > 0 { parts += " · \(done.count) done" }
        if asapCount > 0 { parts += " · 🔴 \(asapCount) ASAP" }
        return parts
    }

    // MARK: - Sections

    private func sectionRank(_ item: WorkItem) -> Int {
        guard let hid = item.houseId else { return -1 }   // MLR sorts first
        return env.housesService.houses.first { $0.id == hid }?.position ?? 9_999
    }

    /// The section header for an item, or nil when the MLR list stands alone.
    private func sectionHeader(for item: WorkItem) -> (emoji: String, name: String)? {
        if let hid = item.houseId {
            if let h = env.housesService.houses.first(where: { $0.id == hid }) { return (h.emoji, h.name) }
            return ("🏠", "House")
        }
        return hasHouseSections ? ("🏕️", "Around the resort") : nil
    }

    private func sectionHeaderView(emoji: String, name: String) -> some View {
        HStack(spacing: 6) {
            Text(emoji).font(.mlrScaled(12))
            Text(name.uppercased())
                .font(.mlrScaled(11, weight: .bold))
                .foregroundStyle(Color.mlrTextMuted)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func check(item: WorkItem) async {
        guard env.isSignedIn else { env.authService.promptSignIn(); return }
        guard !item.isDone else { return }
        checking = item.id
        defer { checking = nil }
        if let idx = env.workItemsService.items.firstIndex(where: { $0.id == item.id }) {
            env.workItemsService.items[idx].status = .done
        }
        do {
            try await env.workItemsService.markDone(id: item.id)
            await env.workItemsService.fetchItems()
        } catch {
            await env.workItemsService.fetchItems()
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
