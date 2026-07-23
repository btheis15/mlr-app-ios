import SwiftUI

// MARK: - EventsView
// The resort calendar. Events grouped by month, an Upcoming/Past toggle,
// per-event RSVP via EventCard → EventSheet, admin "Create event".

struct EventsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var filter: TimeFilter = .upcoming
    @State private var selectedEvent: ResortEvent?
    @State private var showComposer = false
    @State private var showMeetingComposer = false
    @State private var meetingRefreshID = 0
    @State private var hasLoaded = false
    // Private activities + games (#397) — visible only to the viewer.
    @State private var activities: [PrivateActivity] = []
    @State private var showActivityComposer = false
    @State private var selectedActivity: PrivateActivity?

    enum TimeFilter: String, CaseIterable {
        case upcoming = "Upcoming"
        case past = "Past"
    }

    private var events: [ResortEvent] {
        env.eventsService.events
    }

    private var filteredEvents: [ResortEvent] {
        let today = Calendar.current.startOfDay(for: .now)
        switch filter {
        case .upcoming:
            return events
                .filter { ($0.endDateParsed ?? $0.startDateParsed ?? .distantPast) >= today }
                .sorted { ($0.startDateParsed ?? .distantFuture) < ($1.startDateParsed ?? .distantFuture) }
        case .past:
            return events
                .filter { ($0.endDateParsed ?? $0.startDateParsed ?? .distantFuture) < today }
                .sorted { ($0.startDateParsed ?? .distantPast) > ($1.startDateParsed ?? .distantPast) }
        }
    }

    // Group into [monthLabel: [events]] preserving order
    private var grouped: [(month: String, events: [ResortEvent])] {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMMM yyyy"
        fmt.timeZone = TimeZone(identifier: "America/Chicago")

        var order: [String] = []
        var map: [String: [ResortEvent]] = [:]
        for event in filteredEvents {
            let key = event.startDateParsed.map { fmt.string(from: $0) } ?? "Scheduled"
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(event)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            // spacing 0 so the family date-poll card collapses to nothing when idle.
            VStack(spacing: 0) {
                // Active family-wide date poll (#328) — every signed-in member sees it.
                MeetingSectionBar(scope: .family, members: [], surface: .card, refreshID: meetingRefreshID)
                Group {
                    if env.eventsService.isLoading && !hasLoaded {
                        ScrollView {
                            VStack(spacing: 16) {
                                ForEach(0..<4, id: \.self) { _ in SkeletonCard(height: 120) }
                            }
                            .padding(.vertical, 16)
                        }
                    } else {
                        eventList
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Events")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Filter", selection: $filter) {
                        ForEach(TimeFilter.allCases, id: \.self) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
                if env.isSignedIn {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            // Anyone can start an invite-only activity / game (#397).
                            Button {
                                showActivityComposer = true
                            } label: {
                                Label("Create an activity or game", systemImage: "gamecontroller")
                            }
                            if env.isAdmin {
                                Button {
                                    showComposer = true
                                } label: {
                                    Label("Create event", systemImage: "calendar.badge.plus")
                                }
                                Button {
                                    showMeetingComposer = true
                                } label: {
                                    Label("Propose dates (poll the family)", systemImage: "calendar.badge.clock")
                                }
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .tint(Color.mlrPrimary)
                    }
                }
            }
            .sheet(item: $selectedEvent) { event in
                EventSheet(event: event)
            }
            .sheet(isPresented: $showComposer) {
                EventComposer()
            }
            .sheet(isPresented: $showMeetingComposer) {
                MeetingComposer(scope: .family, roomLabel: "the whole family") {
                    meetingRefreshID += 1
                }
            }
            .sheet(isPresented: $showActivityComposer) {
                PrivateActivityComposer { Task { await loadActivities() } }
            }
            .sheet(item: $selectedActivity) { activity in
                PrivateActivitySheet(activityId: activity.id) { Task { await loadActivities() } }
            }
            .task {
                if !hasLoaded {
                    await env.eventsService.fetchEvents()
                    if let userId = await env.authService.userId {
                        await env.eventsService.fetchAttendance(userId: userId)
                    }
                    await loadActivities()
                    hasLoaded = true
                }
                env.eventsService.subscribeToRealtime(userId: env.currentProfile?.id)
            }
            .onDisappear { env.eventsService.unsubscribeFromRealtime() }
        }
    }

    // MARK: - List

    private var eventList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24, pinnedViews: [.sectionHeaders]) {
                activitiesSection
                if filteredEvents.isEmpty {
                    Text(filter == .upcoming ? "Nothing on the calendar yet." : "No past events.")
                        .font(.mlrCaption)
                        .foregroundStyle(Color.mlrTextMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }
                ForEach(grouped, id: \.month) { group in
                    Section {
                        VStack(spacing: 12) {
                            ForEach(group.events) { event in
                                EventCard(
                                    event: event,
                                    summary: env.eventsService.summaries[event.id],
                                    myStatus: env.eventsService.attendances[event.id]?.effectiveStatus()
                                ) {
                                    selectedEvent = event
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    } header: {
                        Text(group.month)
                            .font(.mlrScaled(13, weight: .bold))
                            .foregroundStyle(Color.mlrTextMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color(.systemGroupedBackground))
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .refreshable {
            await env.eventsService.fetchEvents()
            if let userId = await env.authService.userId {
                await env.eventsService.fetchAttendance(userId: userId)
            }
            await loadActivities()
        }
    }

    // MARK: - Private activities & games

    @ViewBuilder
    private var activitiesSection: some View {
        if !activities.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Games & activities")
                    .font(.mlrScaled(13, weight: .bold))
                    .foregroundStyle(Color.mlrTextMuted)
                ForEach(activities) { activity in
                    Button { selectedActivity = activity } label: { PrivateActivityRow(activity: activity) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func loadActivities() async {
        activities = await env.privateActivitiesService.fetchActivities().filter { !$0.isArchived }
    }

    // MARK: - Empty

    private var emptyState: some View {
        ContentUnavailableView {
            Label(filter == .upcoming ? "Nothing on the calendar" : "No past events",
                  systemImage: "calendar")
        } description: {
            Text(filter == .upcoming
                 ? "When events get scheduled, they'll show up here."
                 : "Past events will appear here after they wrap.")
        } actions: {
            if env.isAdmin && filter == .upcoming {
                Button("Create Event") { showComposer = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.mlrPrimary)
            }
        }
    }
}
