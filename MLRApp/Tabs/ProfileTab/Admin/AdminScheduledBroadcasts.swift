import SwiftUI
import Supabase

// MARK: - AdminScheduledBroadcasts
//
// The scheduled-broadcast queue (migration 0097): pending items about to fire,
// plus recently sent/failed ones. Per-row cancel (pending) and reschedule (edit
// send time, migration 0101). The send itself is server-side (pg_cron) — nothing
// to trigger here. Mirrors the web AdminScheduledBroadcasts. Realtime-refreshed
// like AdminCabinBookings.

struct AdminScheduledBroadcasts: View {
    @Environment(AppEnvironment.self) private var env
    @State private var items: [ScheduledBroadcast] = []
    @State private var isLoading = true
    @State private var actionError: String?
    @State private var rescheduling: ScheduledBroadcast?
    @State private var newDate = Date.now.addingTimeInterval(3600)
    @State private var channel: RealtimeChannelV2?

    private var pending: [ScheduledBroadcast] { items.filter(\.isPending) }
    private var history: [ScheduledBroadcast] { items.filter { !$0.isPending } }

    var body: some View {
        List {
            if let actionError {
                Section { Label(actionError, systemImage: "xmark.circle").foregroundStyle(Color.mlrWarning) }
            }

            if isLoading && items.isEmpty {
                ForEach(0..<3, id: \.self) { _ in SkeletonShape(height: 56, cornerRadius: 8) }
            } else if items.isEmpty {
                emptyState
            } else {
                if !pending.isEmpty {
                    Section("Scheduled") {
                        ForEach(pending) { item in row(item, showActions: true) }
                    }
                }
                if !history.isEmpty {
                    Section("Recent") {
                        ForEach(history) { item in row(item, showActions: false) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Scheduled")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await load() }
        .task { await load(); subscribe() }
        .sheet(item: $rescheduling) { item in
            rescheduleSheet(item)
        }
    }

    // MARK: - Row

    private func row(_ item: ScheduledBroadcast, showActions: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(item.kind == .announcement ? "Announcement" : "Notification",
                      systemImage: item.kind == .announcement ? "megaphone.fill" : "bell.badge.fill")
                    .font(.mlrScaled(11, weight: .semibold))
                    .foregroundStyle(Color.mlrTextMuted)
                Spacer()
                statusChip(item)
            }
            Text(item.payload.title)
                .font(.mlrScaled(15, weight: .semibold))
            if let body = item.payload.body, !body.isEmpty {
                Text(body).font(.caption).foregroundStyle(Color.mlrTextMuted).lineLimit(2)
            }
            if let label = item.payload.sourceLabel {
                Label(label, systemImage: "link").font(.caption2).foregroundStyle(Color.mlrInfo)
            }
            Text(sendLine(item))
                .font(.caption2)
                .foregroundStyle(Color.mlrTextSubtle)
            if let err = item.error, !err.isEmpty {
                Text(err).font(.caption2).foregroundStyle(Color.mlrDanger)
            }

            if showActions {
                HStack(spacing: 16) {
                    Button("Reschedule") {
                        newDate = max(item.scheduledAt, Date.now.addingTimeInterval(120))
                        rescheduling = item
                    }
                    .font(.mlrScaled(12, weight: .medium))
                    .foregroundStyle(Color.mlrPrimary)
                    Button("Cancel", role: .destructive) { Task { await cancel(item) } }
                        .font(.mlrScaled(12, weight: .medium))
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    private func statusChip(_ item: ScheduledBroadcast) -> some View {
        let color: Color = {
            switch item.statusLabel {
            case "Failed": return .mlrDanger
            case "Sent":   return .mlrSuccess
            default:        return .mlrWarning
            }
        }()
        return Text(item.statusLabel)
            .font(.mlrScaled(10, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private var emptyState: some View {
        Section {
            VStack(spacing: 14) {
                Image(systemName: "clock.badge")
                    .font(.mlrScaled(40, weight: .light))
                    .foregroundStyle(Color.mlrTextSubtle)
                Text("Nothing scheduled").font(.headline).foregroundStyle(Color.mlrTextMuted)
                Text("Schedule an announcement or notification for later from the Alerts or Notifications composer.")
                    .font(.caption).foregroundStyle(Color.mlrTextSubtle).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 40)
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Reschedule sheet

    private func rescheduleSheet(_ item: ScheduledBroadcast) -> some View {
        NavigationStack {
            Form {
                Section("Send at") {
                    DatePicker("Send at", selection: $newDate,
                               in: Date.now.addingTimeInterval(120)...,
                               displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                }
            }
            .navigationTitle("Reschedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { rescheduling = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await reschedule(item) } }.fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Data

    private func sendLine(_ item: ScheduledBroadcast) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        let when = item.sentAt ?? item.scheduledAt
        let verb = item.sentAt != nil ? "Sent" : "Sends"
        return "\(verb) \(f.string(from: when))"
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        items = await env.notificationsService.fetchScheduledBroadcasts()
    }

    private func cancel(_ item: ScheduledBroadcast) async {
        actionError = nil
        do {
            try await env.notificationsService.cancelScheduledBroadcast(id: item.id)
            await load()
        } catch { actionError = "Couldn't cancel." }
    }

    private func reschedule(_ item: ScheduledBroadcast) async {
        actionError = nil
        do {
            try await env.notificationsService.updateScheduledBroadcast(
                id: item.id, payload: item.payload, scheduledAt: newDate)
            rescheduling = nil
            await load()
        } catch { actionError = "Couldn't reschedule." }
    }

    private func subscribe() {
        guard channel == nil else { return }
        let ch = supabase.channel("admin-scheduled-broadcasts")
        channel = ch
        Task {
            ch.onPostgresChange(AnyAction.self, schema: "public", table: "scheduled_broadcasts") { _ in
                Task { @MainActor in await load() }
            }
            await ch.subscribe()
        }
    }
}
