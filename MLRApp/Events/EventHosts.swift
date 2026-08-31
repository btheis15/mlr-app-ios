import SwiftUI
import Supabase

// MARK: - Event hosts (migration 0209)
//
// An event has zero or more hosts, each a PERSON or a whole COMMITTEE.
//
//   | hosts                        | who may change it + RSVP others        |
//   |------------------------------|----------------------------------------|
//   | none                         | any signed-in member                   |
//   | person host(s)               | those people                           |
//   | committee host, has leads    | that committee's Leads only            |
//   | committee host, no leads     | any member of it                       |
//
// …always plus an app admin and the event's creator.
//
// ⚠️ DO NOT RE-IMPLEMENT THAT RULE IN SWIFT. It needs the viewer's committee
// memberships, which of those they lead, AND whether each committee has any
// leads at all. Ask `my_event_permissions` — one call answers a whole calendar.

struct EventHost: Identifiable, Equatable {
    let id: UUID
    let eventId: String
    let userId: UUID?
    let committeeId: UUID?
    let displayName: String
    let emoji: String?
    let slug: String?

    var isCommittee: Bool { committeeId != nil }
}

struct EventPermissions: Equatable {
    var canManage = false
    /// ⚠️ Separate and NARROWER than `canManage` — the same rule MINUS the "any
    /// member" fallback, because deleting an event takes every RSVP with it.
    /// Use this for the Delete button, never `canManage`.
    var canDelete = false
}

@Observable
@MainActor
final class EventHostsService {

    private(set) var hostsByEvent: [String: [EventHost]] = [:]
    private(set) var permissionsByEvent: [String: EventPermissions] = [:]

    func hosts(for eventId: String) -> [EventHost] { hostsByEvent[eventId] ?? [] }
    func permissions(for eventId: String) -> EventPermissions {
        permissionsByEvent[eventId] ?? EventPermissions()
    }

    /// Load hosts + permissions for a whole calendar in two calls.
    func load(eventIds: [String]) async {
        guard !eventIds.isEmpty else { return }
        async let hosts = fetchHosts(eventIds)
        async let perms = fetchPermissions(eventIds)
        let (h, p) = await (hosts, perms)

        // ⚠️ Merge rather than replace. Loading one event's panel must not wipe
        // the calendar's other entries, and an event with no hosts has to end up
        // with an explicit empty array — otherwise "not loaded" and "no host"
        // are indistinguishable and the panel says "Nobody yet" forever.
        for id in eventIds { hostsByEvent[id] = h[id] ?? [] }
        for id in eventIds { permissionsByEvent[id] = p[id] ?? EventPermissions() }
    }

    private func fetchHosts(_ ids: [String]) async -> [String: [EventHost]] {
        struct P: Encodable { let p_event_ids: [String] }
        struct Row: Decodable {
            let id: UUID
            let eventId: String
            let userId: UUID?
            let committeeId: UUID?
            let displayName: String?
            let emoji: String?
            let slug: String?
            enum CodingKeys: String, CodingKey {
                case id, emoji, slug
                case eventId = "event_id"
                case userId = "user_id"
                case committeeId = "committee_id"
                case displayName = "display_name"
            }
        }
        do {
            let rows: [Row] = try await supabase
                .rpc("event_hosts_for", params: P(p_event_ids: ids)).execute().value
            var out: [String: [EventHost]] = [:]
            for r in rows {
                out[r.eventId, default: []].append(EventHost(
                    id: r.id, eventId: r.eventId, userId: r.userId,
                    committeeId: r.committeeId,
                    displayName: r.displayName ?? "Someone",
                    emoji: r.emoji, slug: r.slug
                ))
            }
            return out
        } catch {
            // ⚠️ Read RLS on `event_hosts` is members-only, so a guest gets an
            // empty list. Render no host line at all rather than a partial one
            // that implies the event has nobody running it.
            return [:]
        }
    }

    private func fetchPermissions(_ ids: [String]) async -> [String: EventPermissions] {
        struct P: Encodable { let p_event_ids: [String] }
        struct Row: Decodable {
            let eventId: String
            let canManage: Bool
            let canDelete: Bool
            enum CodingKeys: String, CodingKey {
                case eventId = "event_id"
                case canManage = "can_manage"
                case canDelete = "can_delete"
            }
        }
        do {
            let rows: [Row] = try await supabase
                .rpc("my_event_permissions", params: P(p_event_ids: ids)).execute().value
            return Dictionary(uniqueKeysWithValues: rows.map {
                ($0.eventId, EventPermissions(canManage: $0.canManage, canDelete: $0.canDelete))
            })
        } catch {
            return [:]
        }
    }

    /// ⚠️ `event_id` is TEXT, not uuid — synthesized events (`family-fest-2026`)
    /// can carry hosts too.
    @discardableResult
    func addHost(eventId: String, userId: UUID? = nil, committeeId: UUID? = nil) async throws -> UUID {
        struct P: Encodable { let p_event_id: String; let p_user_id: String?; let p_committee_id: String? }
        let id: UUID = try await supabase.rpc("add_event_host", params: P(
            p_event_id: eventId,
            p_user_id: userId?.uuidString,
            p_committee_id: committeeId?.uuidString
        )).execute().value
        await load(eventIds: [eventId])
        return id
    }

    func removeHost(id: UUID, eventId: String) async throws {
        struct P: Encodable { let p_id: String }
        try await supabase.rpc("remove_event_host", params: P(p_id: id.uuidString)).execute()
        await load(eventIds: [eventId])
    }
}

// MARK: - The host panel
//
// ⚠️ THE PANEL OWNS ITS LIST. It loads on appear and refetches after every
// add/remove; anything passed in is a first-paint seed only. On the web this
// shipped rendering a value threaded from the parent, only one of three surfaces
// refreshed it, and picking a committee wrote the row while the panel still said
// "Nobody yet". That was the SECOND time this shape hit that screen — a rule
// saying "the parent must refetch" does not survive the next caller.

struct EventHostsPanel: View {
    @Environment(AppEnvironment.self) private var env
    let eventId: String
    /// Synthesized events have no `events` row and are permanently hostless —
    /// don't offer the editor there at all.
    var isSynthesized: Bool = false

    @State private var picking = false
    @State private var working = false
    @State private var error: String?
    @State private var notice: String?

    private var service: EventHostsService { env.eventHostsService }
    private var hosts: [EventHost] { service.hosts(for: eventId) }
    private var canManage: Bool { service.permissions(for: eventId).canManage }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hosts.isEmpty {
                // ⚠️ "No host" is a COMPLETE ANSWER, not an unfinished form. A
                // holiday weekend has nobody running it, and blank is the
                // default for every event — so this describes how the event
                // currently works rather than nagging about a gap.
                Text("Everyone's event — nobody in particular is running it.")
                    .font(.mlrScaled(12))
                    .foregroundStyle(Color.mlrTextMuted)
            } else {
                ForEach(hosts) { host in
                    HStack(spacing: 8) {
                        Text(host.isCommittee ? (host.emoji ?? "👥") : "👤")
                            .font(.mlrScaled(13))
                        Text(host.displayName)
                            .font(.mlrScaled(13, weight: .medium))
                        if host.isCommittee {
                            Text("committee")
                                .font(.mlrScaled(10))
                                .foregroundStyle(Color.mlrTextMuted)
                        }
                        Spacer()
                        if canManage, !isSynthesized {
                            Button {
                                Task { await remove(host) }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(Color.mlrDanger)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            if canManage, !isSynthesized {
                Button {
                    picking = true
                } label: {
                    Label(hosts.isEmpty ? "Give this to someone" : "Add another host",
                          systemImage: "person.badge.plus")
                        .font(.mlrScaled(12, weight: .semibold))
                }
                .buttonStyle(.borderless)

                if !hosts.isEmpty {
                    Text("Removing the last host hands the event back to the whole family.")
                        .font(.mlrScaled(11))
                        .foregroundStyle(Color.mlrTextMuted)
                }
            }

            if let notice {
                Text(notice).font(.mlrScaled(11)).foregroundStyle(.orange)
            }
            if let error {
                Text(error).font(.mlrScaled(11)).foregroundStyle(.red)
            }
        }
        .disabled(working)
        .sheet(isPresented: $picking) {
            EventHostPicker(eventId: eventId) { Task { await reload() } }
        }
        .task { await reload() }
    }

    private func reload() async {
        await service.load(eventIds: [eventId])
    }

    private func remove(_ host: EventHost) async {
        working = true
        error = nil
        notice = nil
        defer { working = false }
        let before = hosts.count
        do {
            try await service.removeHost(id: host.id, eventId: eventId)
            // ⚠️ A write that returns no error but changes nothing must SAY SO.
            // Silent success and silent failure look identical, which is what
            // made the original web bug need a database query to diagnose.
            if service.hosts(for: eventId).count == before {
                notice = "That didn't change anything — you may no longer be able to edit this event."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Picking a host

private struct EventHostPicker: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let eventId: String
    let onDone: () -> Void

    @State private var search = ""
    @State private var people: [Profile] = []
    @State private var working = false
    @State private var error: String?

    private var committees: [Committee] { env.committeeService.committees }

    private var filteredPeople: [Profile] {
        guard !search.isEmpty else { return people }
        return people.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }
    private var filteredCommittees: [Committee] {
        guard !search.isEmpty else { return committees }
        return committees.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("A committee") {
                    ForEach(filteredCommittees) { c in
                        Button {
                            Task { await add(committeeId: c.id) }
                        } label: {
                            Label(c.name, systemImage: "person.3.fill")
                        }
                    }
                }
                Section("A person") {
                    ForEach(filteredPeople) { p in
                        Button {
                            Task { await add(userId: p.id) }
                        } label: {
                            Label(p.name, systemImage: "person.fill")
                        }
                    }
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.mlrScaled(13)).foregroundStyle(.red)
                    }
                }
            }
            .searchable(text: $search)
            .navigationTitle("Who's running this?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .disabled(working)
            .task {
                await env.committeeService.fetchCommittees()
                people = (try? await supabase.from("profiles")
                    .select("*").order("display_name", ascending: true)
                    .execute().value) ?? []
            }
        }
    }

    private func add(userId: UUID? = nil, committeeId: UUID? = nil) async {
        working = true
        error = nil
        defer { working = false }
        do {
            try await env.eventHostsService.addHost(eventId: eventId,
                                                    userId: userId,
                                                    committeeId: committeeId)
            Haptics.success()
            onDone()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
