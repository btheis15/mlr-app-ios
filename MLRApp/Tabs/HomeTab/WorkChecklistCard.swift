import SwiftUI

// MARK: - WorkChecklistCard
//
// The work checklist card on Home (Communication section). Any signed-in member
// can add items and check them off; admins can tap a row to edit/delete. Open
// items preview to 5 with "show N more"; done items collapse into a count.
// Mirrors the web WorkChecklist component.

struct WorkChecklistCard: View {
    @Environment(AppEnvironment.self) private var env

    @State private var showAll = false
    @State private var checking: UUID? = nil
    @State private var composing = false
    @State private var editing: WorkItem? = nil

    private let preview = 5

    private var open: [WorkItem] { env.workItemsService.openItems }
    private var done: [WorkItem] { env.workItemsService.doneItems }
    private var visible: [WorkItem] { showAll ? open : Array(open.prefix(preview)) }
    private var hiddenCount: Int { open.count - preview }

    var body: some View {
        VStack(spacing: 0) {
            header

            if !open.isEmpty {
                Divider()
                ForEach(visible) { item in
                    WorkItemRow(
                        item: item,
                        checking: checking == item.id,
                        onCheck: { Task { await check(item: item) } },
                        onEdit: env.isAdmin ? { editing = item } : nil
                    )
                    Divider().padding(.leading, 14)
                }
                if hiddenCount > 0 {
                    Button {
                        withAnimation { showAll.toggle() }
                    } label: {
                        Text(showAll ? "Show less" : "Show \(hiddenCount) more item\(hiddenCount == 1 ? "" : "s") ›")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(showAll ? Color.mlrTextMuted : Color.mlrPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !done.isEmpty && !open.isEmpty {
                Divider()
                Text("✅ \(done.count) item\(done.count == 1 ? "" : "s") done")
                    .font(.caption)
                    .foregroundStyle(Color.mlrTextMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
        .cardStyle()
        .task { await env.workItemsService.fetchItems() }
        .sheet(isPresented: $composing) {
            WorkItemComposer { Task { await env.workItemsService.fetchItems() } }
        }
        .sheet(item: $editing) { item in
            WorkItemComposer(item: item) { Task { await env.workItemsService.fetchItems() } }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("🔧").font(.system(size: 18))
            VStack(alignment: .leading, spacing: 1) {
                Text("Work Checklist")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.mlrText)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.mlrTextMuted)
            }
            Spacer()
            Button {
                if env.isSignedIn { composing = true } else { env.authService.promptSignIn() }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
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
        return "\(open.count) open" + (done.isEmpty ? "" : " · \(done.count) done")
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
}
