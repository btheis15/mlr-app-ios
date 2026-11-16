import SwiftUI

// MARK: - AdminHousesView
//
// Admin management for Houses (migration 0064): create, rename, re-emoji, and
// delete houses. Member assignment lives on each member's profile (People tab).
// Deleting a house un-assigns its members (their MLR access is unaffected) and
// removes its house-only chat + work items.

struct AdminHousesView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var model = EditorListModel<House>()
    @State private var counts: [UUID: Int] = [:]
    @State private var editing: House?
    @State private var creating = false

    var body: some View {
        List {
            if model.items.isEmpty {
                Section {
                    Text("No houses yet — tap + to create one.")
                        .font(.mlrCaption)
                        .foregroundStyle(Color.mlrTextMuted)
                } footer: { footer }
            } else {
                EditorListSection(model) { house in
                    Button { editing = house } label: {
                        HStack(spacing: 12) {
                            Text(house.emoji).font(.mlrScaled(24))
                                .frame(width: 40, height: 40)
                                .background(Color.mlrPrimary.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(house.name)
                                    .font(.mlrScaled(15, weight: .semibold))
                                    .foregroundStyle(Color.mlrText)
                                if !house.description.isEmpty {
                                    Text(house.description)
                                        .font(.caption)
                                        .foregroundStyle(Color.mlrTextMuted)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.mlrScaled(12, weight: .semibold))
                                .foregroundStyle(Color.mlrTextSubtle)
                        }
                    }
                }
                Section { EmptyView() } footer: { footer }
            }
        }
        .editorListChrome(model)
        .navigationTitle("Houses")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { creating = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New house")
            }
        }
        .task {
            refreshTitle()
            model.persistOrder = { ids in try await env.housesService.saveHouseOrder(ids: ids) }
            model.commitDelete = { house in try await env.housesService.deleteHouse(id: house.id) }
            model.replace(env.housesService.houses)
            await env.housesService.fetchHouses()
            counts = await env.housesService.memberCounts()
            refreshTitle()
        }
        .onChange(of: env.housesService.houses) { _, new in model.replace(new) }
        .refreshable {
            await env.housesService.fetchHouses()
            counts = await env.housesService.memberCounts()
            refreshTitle()
        }
        .sheet(isPresented: $creating) {
            HouseEditor(house: nil, position: (env.housesService.houses.map(\.position).max() ?? -1) + 1)
        }
        .sheet(item: $editing) { house in
            HouseEditor(house: house, position: house.position)
        }
    }

    private var footer: some View {
        Text("A house is a private group with its own chat and work items. Assign members from each person's profile in the People tab. Deleting a house un-assigns its members and removes its chat and house-only work items.")
    }

    /// Delete confirmation names how many members are assigned; re-pointed at fresh counts.
    private func refreshTitle() {
        let c = counts
        model.title = { house in
            let n = c[house.id] ?? 0
            return n == 0 ? house.name
                : "\(house.name) (\(n) member\(n == 1 ? "" : "s") assigned)"
        }
    }
}

// MARK: - HouseEditor

private struct HouseEditor: View {
    @Environment(AppEnvironment.self) private var env

    struct Values: Equatable {
        var name = ""
        var emoji: String? = "🏠"
        var description = ""
    }

    let house: House?
    let position: Int

    @State private var draft: EditorDraft<Values>

    init(house: House?, position: Int) {
        self.house = house
        self.position = position
        _draft = State(initialValue: EditorDraft(Values(
            name: house?.name ?? "", emoji: house?.emoji ?? "🏠", description: house?.description ?? "")))
    }

    private var editing: Bool { house != nil }
    private var trimmedName: String { draft.value.name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        EditorSheet(title: editing ? "Edit house" : "New house",
                    isDirty: draft.isDirty,
                    canSave: !trimmedName.isEmpty,
                    save: { try await save() }) {
            Section {
                EditorTextField("Name", text: $draft.value.name, placeholder: "e.g. MJT House", limit: 60, required: true)
                EditorEmojiField("Emoji", emoji: $draft.value.emoji)
                EditorLongText("Description (optional)", text: $draft.value.description,
                               placeholder: "What's this house about?", limit: 200, lines: 2...4)
            }
        }
    }

    private func save() async throws {
        let slug = house?.slug ?? Self.slugify(trimmedName)
        guard !slug.isEmpty else { throw HouseEditorError.badName }
        let emoji = (draft.value.emoji?.isEmpty ?? true) ? "🏠" : draft.value.emoji!
        try await env.housesService.saveHouse(
            id: house?.id,
            slug: slug,
            name: trimmedName,
            emoji: emoji,
            description: draft.value.description.trimmingCharacters(in: .whitespacesAndNewlines),
            position: position
        )
    }

    private enum HouseEditorError: LocalizedError {
        case badName
        var errorDescription: String? { "Use at least one letter or number in the name." }
    }

    /// Lowercase, spaces → hyphens, strip anything but a-z0-9 and hyphen.
    static func slugify(_ s: String) -> String {
        let lower = s.lowercased()
        var out = ""
        for ch in lower {
            if ch.isLetter || ch.isNumber { out.append(ch) }
            else if ch == " " || ch == "-" || ch == "_" { out.append("-") }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
