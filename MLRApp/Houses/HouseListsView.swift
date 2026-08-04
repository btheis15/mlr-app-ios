import SwiftUI

// MARK: - HouseListsView
// Shared lists for a house (migration 0169) — a grocery run, a cabin close-up
// checklist, a packing list. ANY member can create a list and add/check/edit/
// delete ANY item on it. Reached from the House Hub. Mirrors web's
// HouseListsScreen → HouseLists.

struct HouseListsView: View {
    @Environment(AppEnvironment.self) private var env
    let house: House

    @State private var lists: [HouseList] = []
    @State private var loading = true
    @State private var creating = false

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if lists.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(lists) { list in
                        NavigationLink(destination: HouseListDetailView(house: house, listId: list.id, lists: $lists)) {
                            row(list)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Lists")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { creating = true } label: { Image(systemName: "plus") }
            }
        }
        .task {
            await reload()
            env.housesService.subscribeToLists(houseId: house.id) {
                Task { await reload() }
            }
        }
        .onDisappear { env.housesService.unsubscribeFromLists(houseId: house.id) }
        .refreshable { await reload() }
        .sheet(isPresented: $creating) {
            HouseListEditSheet(house: house, list: nil) { await reload() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("📝").font(.mlrScaled(40))
            Text("No lists yet").font(.mlrScaled(17, weight: .semibold))
            Text("Start a grocery run, a packing list, or a checklist your house shares.")
                .font(.mlrCaption).foregroundStyle(Color.mlrTextMuted)
                .multilineTextAlignment(.center)
            Button { creating = true } label: {
                Label("New list", systemImage: "plus")
                    .font(.mlrScaled(15, weight: .semibold))
                    .foregroundStyle(Color.mlrPrimary)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.mlrPrimary.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.pressable)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ list: HouseList) -> some View {
        HStack(spacing: 12) {
            Text(list.emoji).font(.mlrScaled(24))
            VStack(alignment: .leading, spacing: 2) {
                Text(list.title).font(.mlrScaled(16, weight: .semibold)).foregroundStyle(Color.mlrText)
                Text(list.summary).font(.mlrCaption).foregroundStyle(Color.mlrTextMuted)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func reload() async {
        lists = await env.housesService.fetchLists(houseId: house.id)
        loading = false
    }
}

// MARK: - HouseListDetailView

private struct HouseListDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let house: House
    let listId: UUID
    @Binding var lists: [HouseList]

    @State private var newItemText = ""
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var busyItemIds: Set<UUID> = []
    @State private var error: String?

    private var listIndex: Int? { lists.firstIndex { $0.id == listId } }
    private var list: HouseList? { listIndex.map { lists[$0] } }

    var body: some View {
        Group {
            if let list {
                List {
                    if let note = list.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                        Section { Text(note).font(.mlrCaption).foregroundStyle(Color.mlrTextMuted) }
                    }

                    Section {
                        HStack {
                            TextField("Add an item…", text: $newItemText)
                                .onSubmit { Task { await addItem() } }
                            Button {
                                Task { await addItem() }
                            } label: {
                                Image(systemName: "plus.circle.fill").foregroundStyle(Color.mlrPrimary)
                            }
                            .disabled(newItemText.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }

                    if !list.sortedItems.isEmpty {
                        Section {
                            ForEach(list.sortedItems) { item in
                                itemRow(item)
                            }
                        }
                    }

                    if list.progress.done > 0 {
                        Section {
                            Button("Clear checked items") { Task { await clearChecked() } }
                            Button("Uncheck everything") { Task { await uncheckAll() } }
                        }
                    }

                    if let error {
                        Section { Text(error).font(.mlrCaption).foregroundStyle(Color.mlrDanger) }
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle(list.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button { editing = true } label: { Label("Edit list", systemImage: "pencil") }
                            Button(role: .destructive) { confirmDelete = true } label: {
                                Label("Delete list", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .sheet(isPresented: $editing) {
                    HouseListEditSheet(house: house, list: list) { await reload() }
                }
                .alert("Delete this list?", isPresented: $confirmDelete) {
                    Button("Delete", role: .destructive) { Task { await deleteList() } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Everyone on \(house.name) loses this list and its items — no undo.")
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: HouseListItem) -> some View {
        HStack(spacing: 10) {
            Button { Task { await toggle(item) } } label: {
                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.mlrScaled(20))
                    .foregroundStyle(item.isChecked ? Color.mlrPrimary : Color.mlrTextSubtle)
            }
            .buttonStyle(.plain)
            .disabled(busyItemIds.contains(item.id))

            VStack(alignment: .leading, spacing: 1) {
                Text(item.text)
                    .font(.mlrScaled(15))
                    .foregroundStyle(item.isChecked ? Color.mlrTextMuted : Color.mlrText)
                    .strikethrough(item.isChecked)
                if item.isChecked, let name = item.checkedByName {
                    Text("by \(name)").font(.mlrScaled(11)).foregroundStyle(Color.mlrTextSubtle)
                }
            }
            Spacer()
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { Task { await delete(item) } } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func reload() async {
        lists = await env.housesService.fetchLists(houseId: house.id)
    }

    private func addItem() async {
        guard let list else { return }
        let text = newItemText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        newItemText = ""
        do {
            try await env.housesService.addListItem(listId: list.id, text: text)
            await reload()
        } catch {
            self.error = "Couldn't add that item."
        }
    }

    private func toggle(_ item: HouseListItem) async {
        guard let idx = listIndex else { return }
        busyItemIds.insert(item.id)
        defer { busyItemIds.remove(item.id) }
        // Optimistic flip so a checkbox never waits on the round-trip.
        if let itemIdx = lists[idx].items.firstIndex(where: { $0.id == item.id }) {
            lists[idx].items[itemIdx].checkedAt = item.isChecked ? nil : .now
            lists[idx].items[itemIdx].checkedBy = item.isChecked ? nil : env.currentProfile?.id
        }
        do {
            try await env.housesService.setListItemChecked(id: item.id, checked: !item.isChecked)
            await reload()
        } catch {
            self.error = "Couldn't update that item."
            await reload()
        }
    }

    private func delete(_ item: HouseListItem) async {
        do {
            try await env.housesService.deleteListItem(id: item.id)
            await reload()
        } catch {
            self.error = "Couldn't delete that item."
        }
    }

    private func clearChecked() async {
        guard let list else { return }
        do { try await env.housesService.clearCheckedListItems(listId: list.id); await reload() }
        catch { self.error = "Couldn't clear checked items." }
    }

    private func uncheckAll() async {
        guard let list else { return }
        do { try await env.housesService.uncheckListItems(listId: list.id); await reload() }
        catch { self.error = "Couldn't uncheck items." }
    }

    private func deleteList() async {
        guard let list else { return }
        do {
            try await env.housesService.deleteList(id: list.id)
            await reload()
            dismiss()
        } catch {
            self.error = "Couldn't delete this list."
        }
    }
}

// MARK: - HouseListEditSheet (create or rename/re-emoji a list)

private struct HouseListEditSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let house: House
    let list: HouseList?     // nil = creating a new list
    let onSaved: () async -> Void

    @State private var title: String
    @State private var emoji: String
    @State private var note: String
    @State private var saving = false
    @State private var error: String?

    init(house: House, list: HouseList?, onSaved: @escaping () async -> Void) {
        self.house = house
        self.list = list
        self.onSaved = onSaved
        _title = State(initialValue: list?.title ?? "")
        _emoji = State(initialValue: list?.emoji ?? "📝")
        _note = State(initialValue: list?.note ?? "")
    }

    private var isNew: Bool { list == nil }
    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty && !saving }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("e.g. Weekend groceries", text: $title) }
                Section("Emoji") {
                    TextField("📝", text: $emoji)
                        .onChange(of: emoji) { _, new in if let f = new.first { emoji = String(f) } }
                }
                Section("Note (optional)") {
                    TextField("What this list is for", text: $note, axis: .vertical).lineLimit(1...3)
                }
                if let error {
                    Text(error).font(.mlrCaption).foregroundStyle(Color.mlrDanger)
                }
            }
            .navigationTitle(isNew ? "New list" : "Edit list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Create" : "Save") { Task { await save() } }.disabled(!canSave)
                }
            }
        }
    }

    private func save() async {
        saving = true; error = nil
        defer { saving = false }
        let t = title.trimmingCharacters(in: .whitespaces)
        let e = emoji.isEmpty ? "📝" : emoji
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if let list {
                try await env.housesService.updateList(id: list.id, title: t, emoji: e, note: n.isEmpty ? nil : n)
            } else {
                try await env.housesService.createList(houseId: house.id, title: t, emoji: e, note: n.isEmpty ? nil : n)
            }
            await onSaved()
            dismiss()
        } catch {
            self.error = "Couldn't save. Try again."
        }
    }
}
