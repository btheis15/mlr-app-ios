import SwiftUI

// MARK: - AdminCommitteesView
// Admin management of the committee TAXONOMY (migration 0112): create / edit /
// archive committees and their roles (areas = chat channels). "Delete" = archive
// (restorable), never destroy. Tapping a committee still opens CommitteeDetailView
// for members + the join-request queue. Mirrors web AdminCommittees.tsx.

struct AdminCommitteesView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var loading = true
    @State private var creating = false
    @State private var editing: Committee?
    @State private var committeeToArchive: Committee?
    @State private var committeeToDelete: Committee?
    @State private var error: String?

    private var live: [Committee] { env.committeeService.liveCommittees }
    private var archived: [Committee] { env.committeeService.archivedCommittees }

    private func pendingCount(for c: Committee) -> Int {
        env.committeeService.pendingRequests.filter { $0.committeeId == c.id }.count
    }

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if let error {
                        Section {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Color.mlrDanger).font(.subheadline)
                        }
                    }

                    Section {
                        ForEach(live) { committee in
                            NavigationLink(destination: CommitteeDetailView(committee: committee)) {
                                committeeRow(committee)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    committeeToArchive = committee
                                } label: { Label("Delete", systemImage: "archivebox") }
                                Button { editing = committee } label: {
                                    Label("Edit", systemImage: "pencil")
                                }.tint(Color.mlrInfo)
                            }
                        }
                        if live.isEmpty {
                            Text("No committees yet — tap + to create one.")
                                .font(.mlrCaption).foregroundStyle(Color.mlrTextMuted)
                        }
                    } header: {
                        Text("Committees")
                    } footer: {
                        Text("Swipe a committee to edit its details + roles, or to delete (archive). Tap it to manage members and join requests.")
                    }

                    if !archived.isEmpty {
                        Section {
                            ForEach(archived) { committee in
                                HStack(spacing: 12) {
                                    Text(committee.emoji ?? "👥").font(.mlrScaled(20)).opacity(0.6)
                                    Text(committee.name)
                                        .font(.mlrScaled(15))
                                        .foregroundStyle(Color.mlrTextMuted)
                                    Spacer()
                                    Button("Restore") { Task { await restore(committee) } }
                                        .font(.mlrScaled(13, weight: .semibold))
                                        .buttonStyle(.borderless)
                                    Button("Delete forever") { committeeToDelete = committee }
                                        .font(.mlrScaled(13, weight: .semibold))
                                        .buttonStyle(.borderless)
                                        .tint(Color.mlrDanger)
                                }
                            }
                        } header: {
                            Text("Archived")
                        } footer: {
                            Text("Restore brings a committee fully back, roster and all. Delete forever erases it — and all its chat history — permanently; there's no undo.")
                        }
                    }
                }
            }
        }
        .navigationTitle("Committees")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { creating = true } label: { Image(systemName: "plus") }
            }
        }
        .task {
            if env.committeeService.committees.isEmpty { await env.committeeService.fetchCommittees() }
            try? await env.committeeService.fetchPendingRequests()
            loading = false
        }
        .refreshable {
            await env.committeeService.fetchCommittees()
            try? await env.committeeService.fetchPendingRequests()
        }
        .sheet(isPresented: $creating) { CommitteeEditor(committee: nil) }
        .sheet(item: $editing) { CommitteeEditor(committee: $0) }
        .alert("Delete committee?", isPresented: .constant(committeeToArchive != nil), presenting: committeeToArchive) { c in
            Button("Delete \(c.name)", role: .destructive) { Task { await archive(c) } }
            Button("Cancel", role: .cancel) { committeeToArchive = nil }
        } message: { c in
            Text("Archives \(c.name) — it's hidden from the app and its chats go read-only, but the roster is kept and you can Restore it anytime.")
        }
        .alert("Delete forever?", isPresented: .constant(committeeToDelete != nil), presenting: committeeToDelete) { c in
            Button("Delete \(c.name) forever", role: .destructive) { Task { await delete(c) } }
            Button("Cancel", role: .cancel) { committeeToDelete = nil }
        } message: { c in
            Text("Permanently deletes \(c.name) and ALL its chat history, roster, and roles. This can't be undone — use Restore instead if you just want it back.")
        }
    }

    private func committeeRow(_ committee: Committee) -> some View {
        HStack(spacing: 12) {
            Text(committee.emoji ?? "👥")
                .font(.mlrScaled(22))
                .frame(width: 40, height: 40)
                .background(Color.mlrInfo.mlrTint(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(committee.name)
                .font(.mlrScaled(15, weight: .semibold))
                .foregroundStyle(Color.mlrText)
            Spacer()
            let pending = pendingCount(for: committee)
            if pending > 0 {
                Text("\(pending)")
                    .font(.mlrScaled(12, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.mlrDanger).clipShape(Capsule())
            }
        }
        .padding(.vertical, 2)
    }

    private func archive(_ c: Committee) async {
        committeeToArchive = nil
        do { try await env.committeeService.archiveCommittee(id: c.id); await env.committeeService.fetchCommittees() }
        catch { self.error = "Couldn\u{2019}t archive \(c.name). \(EditorError.message(error))" }
    }

    private func restore(_ c: Committee) async {
        do { try await env.committeeService.restoreCommittee(id: c.id); await env.committeeService.fetchCommittees() }
        catch { self.error = "Couldn\u{2019}t restore \(c.name). \(EditorError.message(error))" }
    }

    private func delete(_ c: Committee) async {
        committeeToDelete = nil
        do { try await env.committeeService.deleteCommittee(id: c.id); await env.committeeService.fetchCommittees() }
        catch { self.error = "Couldn\u{2019}t delete \(c.name). \(EditorError.message(error))" }
    }
}

// MARK: - CommitteeEditor (create + edit details + manage roles)

struct CommitteeEditor: View {
    @Environment(AppEnvironment.self) private var env

    struct Values: Equatable {
        var name = ""
        var emoji: String? = "🌲"
        var description = ""
    }

    let committee: Committee?
    /// Called after a successful save (the in-place pencil uses it to refresh).
    var onSaved: (() -> Void)?

    @State private var draft: EditorDraft<Values>

    // Roles (edit mode only).
    @State private var areas: [CommitteeArea] = []
    @State private var newArea = ""
    @State private var areaError: String?
    @State private var editingArea: CommitteeArea?
    @State private var areaToDelete: CommitteeArea?

    init(committee: Committee?, onSaved: (() -> Void)? = nil) {
        self.committee = committee
        self.onSaved = onSaved
        _draft = State(initialValue: EditorDraft(Values(
            name: committee?.name ?? "", emoji: committee?.emoji ?? "🌲",
            description: committee?.description ?? "")))
    }

    private var editing: Bool { committee != nil }
    private var canSave: Bool { !draft.value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var liveAreas: [CommitteeArea] { areas.filter { !$0.isArchived } }
    private var archivedAreas: [CommitteeArea] { areas.filter { $0.isArchived } }

    var body: some View {
        EditorSheet(title: editing ? "Edit committee" : "New committee",
                    isDirty: draft.isDirty,
                    canSave: canSave,
                    save: { try await save() }) {
            Section {
                EditorTextField("Name", text: $draft.value.name, placeholder: "e.g. Meals", limit: 60, required: true)
                EditorEmojiField("Emoji", emoji: $draft.value.emoji)
                EditorLongText("Description (optional)", text: $draft.value.description,
                               placeholder: "What's this committee about?", limit: 300, lines: 2...4)
            }

            if editing { rolesSection }
        }
        .task { if editing { await loadAreas() } }
        .sheet(item: $editingArea) { area in
            if let committee {
                RoleEditSheet(committee: committee, area: area) { await loadAreas() }
            }
        }
        .alert("Delete role forever?", isPresented: .constant(areaToDelete != nil), presenting: areaToDelete) { a in
            Button("Delete \(a.area) forever", role: .destructive) { Task { await deleteArea(a.area) } }
            Button("Cancel", role: .cancel) { areaToDelete = nil }
        } message: { a in
            Text("Permanently erases the \"\(a.area)\" role and its chat history for everyone. This can't be undone — use Restore instead if you just want it back.")
        }
    }

    // MARK: Roles manager

    @ViewBuilder
    private var rolesSection: some View {
        Section {
            ForEach(liveAreas) { area in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(area.area).font(.mlrScaled(15))
                        if let d = area.description, !d.isEmpty {
                            Text(d).font(.mlrCaption).foregroundStyle(Color.mlrTextMuted)
                        }
                    }
                    Spacer()
                    Menu {
                        Button { editingArea = area } label: {
                            Label("Edit (rename / describe)", systemImage: "pencil")
                        }
                        Button(role: .destructive) { Task { await archiveArea(area.area) } } label: {
                            Label("Delete role (archive)", systemImage: "archivebox")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(Color.mlrTextSubtle)
                    }
                }
            }
            HStack {
                TextField("Add a role", text: $newArea)
                Button("Add") { Task { await addArea() } }
                    .disabled(newArea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let areaError {
                Text(areaError).font(.caption).foregroundStyle(Color.mlrDanger)
            }
        } header: {
            Text("Roles")
        } footer: {
            Text("Each role is its own chat channel. \"General\" is the committee-wide channel and always exists.")
        }

        if !archivedAreas.isEmpty {
            Section("Archived roles") {
                ForEach(archivedAreas) { area in
                    HStack {
                        Text(area.area).font(.mlrScaled(15)).foregroundStyle(Color.mlrTextMuted)
                        Spacer()
                        Button("Restore") { Task { await restoreArea(area.area) } }
                            .font(.mlrScaled(13, weight: .semibold)).buttonStyle(.borderless)
                        Button("Delete forever") { areaToDelete = area }
                            .font(.mlrScaled(13, weight: .semibold))
                            .buttonStyle(.borderless)
                            .tint(Color.mlrDanger)
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func save() async throws {
        let n = draft.value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = draft.value.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = (draft.value.emoji?.isEmpty ?? true) ? "🌲" : draft.value.emoji!
        if let committee {
            try await env.committeeService.updateCommittee(id: committee.id, name: n, emoji: e, description: d)
        } else {
            _ = try await env.committeeService.createCommittee(name: n, emoji: e, description: d)
        }
        await env.committeeService.fetchCommittees()
        onSaved?()
    }

    private func loadAreas() async {
        guard let committee else { return }
        areas = await env.committeeService.fetchCommitteeAreas(slug: committee.slug, includeArchived: true)
    }

    private func addArea() async {
        guard let committee else { return }
        let a = newArea.trimmingCharacters(in: .whitespacesAndNewlines)
        areaError = nil
        do {
            try await env.committeeService.addCommitteeArea(committeeId: committee.id, area: a)
            newArea = ""
            await loadAreas()
        } catch {
            areaError = friendly(error)
        }
    }

    private func deleteArea(_ area: String) async {
        guard let committee else { return }
        areaToDelete = nil
        do { try await env.committeeService.deleteCommitteeArea(committeeId: committee.id, area: area); await loadAreas() }
        catch { areaError = friendly(error) }
    }

    private func archiveArea(_ area: String) async {
        guard let committee else { return }
        do { try await env.committeeService.archiveCommitteeArea(committeeId: committee.id, area: area); await loadAreas() }
        catch { areaError = friendly(error) }
    }

    private func restoreArea(_ area: String) async {
        guard let committee else { return }
        do { try await env.committeeService.restoreCommitteeArea(committeeId: committee.id, area: area); await loadAreas() }
        catch { areaError = friendly(error) }
    }

    /// Surface the server's validation message (reserved names, duplicates, etc.).
    private func friendly(_ error: Error) -> String {
        let m = EditorError.message(error)
        return m.isEmpty ? "That role name isn't allowed." : m
    }
}

// MARK: - RoleEditSheet (rename + description, migrations 0073/0112 rename + 0179 description)

struct RoleEditSheet: View {
    @Environment(AppEnvironment.self) private var env

    let committee: Committee
    let area: CommitteeArea
    let onSaved: () async -> Void

    struct Values: Equatable {
        var name: String
        var description: String
    }

    @State private var draft: EditorDraft<Values>

    init(committee: Committee, area: CommitteeArea, onSaved: @escaping () async -> Void) {
        self.committee = committee
        self.area = area
        self.onSaved = onSaved
        _draft = State(initialValue: EditorDraft(Values(name: area.area, description: area.description ?? "")))
    }

    var body: some View {
        EditorSheet(title: "Edit role",
                    isDirty: draft.isDirty,
                    canSave: !draft.value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    save: { try await save() }) {
            Section {
                EditorTextField("Role name", text: $draft.value.name, placeholder: "e.g. Meals", limit: 60, required: true)
                EditorLongText("Description (optional)", text: $draft.value.description,
                               placeholder: "What's this role for?", limit: 300, lines: 2...4)
            }
        }
    }

    private func save() async throws {
        let newName = draft.value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let newDescription = draft.value.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if newName != area.area {
            try await env.committeeService.renameCommitteeArea(committeeId: committee.id, old: area.area, new: newName)
        }
        // Description is written against the (possibly new) name, mirroring web.
        try await env.committeeService.setCommitteeAreaDescription(committeeId: committee.id, area: newName, description: newDescription)
        await onSaved()
    }
}
