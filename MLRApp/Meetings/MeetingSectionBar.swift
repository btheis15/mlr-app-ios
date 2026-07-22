import SwiftUI

// MARK: - MeetingSectionBar (migration 0116)
//
// The active-meeting bar pinned at the top of a committee/house chat room (and
// embedded as a card on the committee detail + Events pages). Scheduling a NEW
// meeting lives in the room's ⋯ menu; this component is only the RESPONSE
// surface — it shows the currently active (open, else upcoming scheduled)
// meeting so every member can mark availability and, for the organizer, finalize
// it. Renders nothing when there's no live meeting, so the chat stays clean.

struct MeetingSectionBar: View {
    @Environment(AppEnvironment.self) private var env

    let scope: MeetingScope
    /// Room roster — for name resolution + the "everyone can make it" count.
    let members: [MeetingMember]
    /// "chat" = a flush top-of-room bar; "card" = a rounded card for a page.
    var surface: Surface = .chat
    /// Bump from the parent (e.g. after creating a meeting) to force a refetch.
    var refreshID: Int = 0

    enum Surface { case chat, card }

    @State private var meetings: [Meeting] = []
    @State private var openMeeting: Meeting?
    @State private var subscriberID = UUID()
    @State private var isSubscribed = false

    private var featured: Meeting? {
        meetings.first { $0.status == .open }
            ?? meetings.first { $0.status == .scheduled && chosenInFuture($0) }
    }

    var body: some View {
        Group {
            if let featured {
                // Self-padding so callers can embed us in a spacing-0 container:
                // idle → this whole Group renders nothing and adds no gap.
                Button { openMeeting = featured } label: { bar(featured) }
                    .buttonStyle(.plain)
                    .padding(.horizontal, surface == .chat ? 12 : 16)
                    .padding(.top, surface == .chat ? 8 : 12)
                    .padding(.bottom, surface == .chat ? 8 : 0)
                    .background(surface == .chat ? Color.mlrCard : Color.clear)
                    .overlay(alignment: .bottom) {
                        if surface == .chat { Divider() }
                    }
            }
        }
        .task(id: refreshID) { await reload() }
        .onDisappear { unsubscribeIfNeeded() }
        .sheet(item: $openMeeting) { m in
            MeetingSchedulerSheet(
                meeting: m,
                members: members,
                memberCount: members.count,
                canManage: env.isAdmin || m.createdByMe,
                onChanged: { Task { await reload() } }
            )
        }
    }

    private func bar(_ m: Meeting) -> some View {
        HStack(spacing: 10) {
            Text("📅").font(.mlrScaled(18))
            VStack(alignment: .leading, spacing: 2) {
                Text(m.title).font(.mlrScaled(14, weight: .semibold)).foregroundStyle(Color.mlrText)
                    .lineLimit(1)
                Text(m.status == .open ? "Mark when you're free · \(m.respondentCount) responded" : "Meeting scheduled — tap for details")
                    .font(.mlrScaled(12)).foregroundStyle(Color.mlrTextMuted).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.mlrScaled(13, weight: .semibold)).foregroundStyle(Color.mlrPrimary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.mlrPrimary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.mlrPrimary.opacity(0.2), lineWidth: 1))
    }

    private func reload() async {
        meetings = await env.meetingsService.fetchMeetings(scope: scope, uid: env.currentProfile?.id)
        // Keep an open sheet in sync with the freshly-fetched data.
        if let open = openMeeting {
            openMeeting = meetings.first { $0.id == open.id }
        }
        // Only hold a live realtime channel while this room actually has a
        // meeting — idle rooms (the common case) cost nothing. Subscribing so a
        // still-open meeting's tallies stay live; released once none remain.
        if meetings.isEmpty {
            unsubscribeIfNeeded()
        } else if !isSubscribed {
            isSubscribed = true
            env.meetingsService.subscribe(scope: scope, subscriber: subscriberID) {
                Task { await reload() }
            }
        }
    }

    private func unsubscribeIfNeeded() {
        guard isSubscribed else { return }
        isSubscribed = false
        env.meetingsService.unsubscribe(scope: scope, subscriber: subscriberID)
    }

    private func chosenInFuture(_ m: Meeting) -> Bool {
        guard let slot = m.slots.first(where: { $0.id == m.chosenSlotId }) else { return false }
        return slot.startsAt > Date()
    }
}
