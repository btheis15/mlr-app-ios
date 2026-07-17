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
                        Section("Archived") {
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
                                }
                            }
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
    }

    private func committeeRow(_ committee: Committee) -> some View {
        HStack(spacing: 12) {
            Text(committee.emoji ?? "👥")
                .font(.mlrScaled(22))
                .frame(width: 40, height: 40)
                .background(Color.mlrInfo.opacity(0.12))
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
        catch { self.error = "Couldn't archive \(c.name)." }
    }

    private func restore(_ c: Committee) async {
        do { try await env.committeeService.restoreCommittee(id: c.id); await env.committeeService.fetchCommittees() }
        catch { self.error = "Couldn't restore \(c.name)." }
    }
}

// MARK: - CommitteeEditor (create + edit details + manage roles)

private struct CommitteeEditor: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let committee: Committee?

    @State private var name: String
    @State private var emoji: String
    @State private var description: String
    @State private var saving = false
    @State private var error: String?

    // Roles (edit mode only).
    @State private var areas: [CommitteeArea] = []
    @State private var newArea = ""
    @State private var areaError: String?
    @State private var renameTarget: String?
    @State private var renameText = ""

    init(committee: Committee?) {
        self.committee = committee
        _name = State(initialValue: committee?.name ?? "")
        _emoji = State(initialValue: committee?.emoji ?? "🌲")
        _description = State(initialValue: committee?.description ?? "")
    }

    private var editing: Bool { committee != nil }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !saving }
    private var liveAreas: [CommitteeArea] { areas.filter { !$0.isArchived } }
    private var archivedAreas: [CommitteeArea] { areas.filter { $0.isArchived } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("e.g. Meals", text: $name) }
                Section("Emoji") {
                    TextField("🌲", text: $emoji)
                        .onChange(of: emoji) { _, new in if let f = new.first { emoji = String(f) } }
                }
                Section("Description (optional)") {
                    TextField("What's this committee about?", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                }

                if editing { rolesSection }

                if let error {
                    Text(error).font(.caption).foregroundStyle(Color.mlrDanger)
                }
            }
            .navigationTitle(editing ? "Edit committee" : "New committee")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing ? "Save" : "Create") { Task { await save() } }.disabled(!canSave)
                }
            }
            .task { if editing { await loadAreas() } }
            .alert("Rename role", isPresented: .constant(renameTarget != nil), presenting: renameTarget) { _ in
                TextField("New name", text: $renameText)
                Button("Rename") { Task { await commitRename() } }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            } message: { _ in
                Text("Renames the role and its entire chat history.")
            }
        }
    }

    // MARK: Roles manager

    @ViewBuilder
    private var rolesSection: some View {
        Section {
            ForEach(liveAreas) { area in
                HStack {
                    Text(area.area).font(.mlrScaled(15))
                    Spacer()
                    Menu {
                        Button { renameTarget = area.area; renameText = area.area } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) { Task { await archiveArea(area.area) } } label: {
                            Label("Delete role", systemImage: "archivebox")
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
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func save() async {
        saving = true; error = nil
        defer { saving = false }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = emoji.isEmpty ? "🌲" : emoji
        do {
            if let committee {
                try await env.committeeService.updateCommittee(id: committee.id, name: n, emoji: e, description: d)
            } else {
                _ = try await env.committeeService.createCommittee(name: n, emoji: e, description: d)
            }
            await env.committeeService.fetchCommittees()
            dismiss()
        } catch {
            self.error = "Couldn't save the committee."
        }
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

    private func commitRename() async {
        guard let committee, let old = renameTarget else { return }
        let new = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renameTarget = nil
        areaError = nil
        guard !new.isEmpty, new != old else { return }
        do {
            try await env.committeeService.renameCommitteeArea(committeeId: committee.id, old: old, new: new)
            await loadAreas()
        } catch {
            areaError = friendly(error)
        }
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
        let m = (error as NSError).localizedDescription
        return m.isEmpty ? "That role name isn't allowed." : m
    }
}
