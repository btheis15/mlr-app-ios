import SwiftUI

// MARK: - HouseCalendarView
// The house calendar: a month grid + an agenda of who's staying and when, with
// resort-wide MLR events overlaid on both so a house never misses a family-wide
// gathering. Members add their own stays; overlapping stays show who's up at the
// same time. Reuses EventCard / EventSheet for the resort-event overlay + RSVP.

struct HouseCalendarView: View {
    @Environment(AppEnvironment.self) private var env

    let house: House

    @State private var stays: [HouseStay] = []
    @State private var loading = true
    @State private var monthAnchor: Date = .now

    @State private var showComposer = false
    @State private var editingStay: HouseStay?
    @State private var selectedStay: HouseStay?
    @State private var selectedEvent: ResortEvent?
    @State private var selectedDay: String?

    private var today: String { HouseStay.iso.string(from: .now) }
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }

    // Day → stays / events covering it.
    private var staysByDay: [String: [HouseStay]] {
        var map: [String: [HouseStay]] = [:]
        for s in stays { for d in s.days() { map[d, default: []].append(s) } }
        return map
    }
    private var eventsByDay: [String: [ResortEvent]] {
        var map: [String: [ResortEvent]] = [:]
        for e in env.eventsService.events {
            guard let start = e.startDateParsed else { continue }
            let end = e.endDateParsed ?? start
            var d = start
            var i = 0
            while d <= end && i < 366 {
                map[HouseStay.iso.string(from: d), default: []].append(e)
                guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
                d = next; i += 1
            }
        }
        return map
    }

    private var upcomingStays: [HouseStay] { stays.filter { !$0.isPast(today) } }
    private var pastStays: [HouseStay] { stays.filter { $0.isPast(today) }.reversed() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                monthGrid
                addButton
                resortOverlay
                agenda
            }
            .padding(16)
        }
        .background(Color.mlrSurface)
        .navigationTitle("\(house.name) calendar")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if env.eventsService.events.isEmpty { await env.eventsService.fetchEvents() }
            if let uid = env.currentProfile?.id { await env.eventsService.fetchAttendance(userId: uid) }
            await reload()
            env.housesService.subscribeToStays(houseId: house.id) { Task { await reload() } }
        }
        .onDisappear { env.housesService.unsubscribeFromStays(houseId: house.id) }
        .sheet(isPresented: $showComposer) {
            HouseStayComposer(houseId: house.id, houseName: house.name) { Task { await reload() } }
        }
        .sheet(item: $editingStay) { stay in
            HouseStayComposer(houseId: house.id, houseName: house.name, existing: stay) { Task { await reload() } }
        }
        .sheet(item: $selectedStay) { stay in
            HouseStayDetail(
                stay: stay,
                canEdit: canEdit(stay),
                onEdit: { selectedStay = nil; editingStay = stay },
                onDelete: {
                    try? await env.housesService.deleteStay(id: stay.id)
                    await reload()
                }
            )
        }
        .sheet(item: $selectedEvent) { event in
            EventSheet(event: event)
        }
        .sheet(item: dayItem) { day in
            HouseDaySheet(
                day: day.value,
                stays: staysByDay[day.value] ?? [],
                events: eventsByDay[day.value] ?? [],
                onOpenStay: { selectedDay = nil; selectedStay = $0 },
                onOpenEvent: { selectedDay = nil; selectedEvent = $0 },
                onAdd: { selectedDay = nil; showComposer = true }
            )
        }
    }

    // Wrap the ISO-day string so it's Identifiable for .sheet(item:).
    private var dayItem: Binding<DayKey?> {
        Binding(get: { selectedDay.map { DayKey(value: $0) } }, set: { selectedDay = $0?.value })
    }

    private func canEdit(_ stay: HouseStay) -> Bool {
        if env.currentProfile?.isAdmin == true { return true }
        return env.currentProfile?.id == stay.createdBy
    }

    private func reload() async {
        stays = await env.housesService.fetchStays(houseId: house.id)
        loading = false
    }

    // MARK: - Month grid

    private var monthGrid: some View {
        let comps = cal.dateComponents([.year, .month], from: monthAnchor)
        let year = comps.year ?? 2026
        let month = comps.month ?? 1
        let firstOfMonth = cal.date(from: DateComponents(year: year, month: month, day: 1)) ?? monthAnchor
        let leading = (cal.component(.weekday, from: firstOfMonth) - 1) // 0 = Sunday
        let daysInMonth = cal.range(of: .day, in: .month, for: firstOfMonth)?.count ?? 30
        let cells: [String?] = Array(repeating: nil, count: leading)
            + (1...daysInMonth).map { HouseStay.iso.string(from: cal.date(from: DateComponents(year: year, month: month, day: $0))!) }

        return VStack(spacing: 8) {
            HStack {
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(monthTitle(firstOfMonth)).font(.mlrScaled(15, weight: .bold))
                Spacer()
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
            }
            .foregroundStyle(Color.mlrPrimary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(["S", "M", "T", "W", "T", "F", "S"].indices, id: \.self) { i in
                    Text(["S", "M", "T", "W", "T", "F", "S"][i])
                        .font(.mlrScaled(10, weight: .semibold))
                        .foregroundStyle(Color.mlrTextSubtle)
                }
                ForEach(cells.indices, id: \.self) { i in
                    if let iso = cells[i] {
                        dayCell(iso)
                    } else {
                        Color.clear.frame(height: 40)
                    }
                }
            }

            HStack(spacing: 16) {
                legendDot(Color.mlrPrimary, "House stay")
                legendDot(Color.mlrAccent, "Resort event")
            }
            .font(.mlrScaled(10))
            .foregroundStyle(Color.mlrTextMuted)
        }
        .padding(14)
        .cardStyle()
    }

    private func dayCell(_ iso: String) -> some View {
        let dayNum = Int(iso.suffix(2)) ?? 0
        let hasStay = !(staysByDay[iso] ?? []).isEmpty
        let hasEvent = !(eventsByDay[iso] ?? []).isEmpty
        let isToday = iso == today
        return Button { selectedDay = iso } label: {
            VStack(spacing: 2) {
                Text("\(dayNum)")
                    .font(.mlrScaled(13, weight: isToday ? .bold : .regular))
                    .foregroundStyle(isToday ? Color.mlrPrimary : Color.mlrText)
                HStack(spacing: 2) {
                    if hasStay { Circle().fill(Color.mlrPrimary).frame(width: 5, height: 5) }
                    if hasEvent { Circle().fill(Color.mlrAccent).frame(width: 5, height: 5) }
                }
                .frame(height: 6)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(isToday ? Color.mlrPrimaryLight : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
        }
    }

    private func monthTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        f.timeZone = TimeZone(identifier: "America/Chicago")
        return f.string(from: date)
    }

    private func shiftMonth(_ delta: Int) {
        if let d = cal.date(byAdding: .month, value: delta, to: monthAnchor) { monthAnchor = d }
    }

    // MARK: - Add button

    private var addButton: some View {
        Button { showComposer = true } label: {
            Label("Add my stay", systemImage: "plus")
                .font(.mlrScaled(15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.mlrPrimary)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Resort overlay

    @ViewBuilder
    private var resortOverlay: some View {
        let upcoming = env.eventsService.upcomingEvents
        if !upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("🌲 Happening across the resort").font(.mlrScaled(15, weight: .bold))
                Text("Resort-wide events show on every house calendar — tap to RSVP so you don't miss them.")
                    .font(.mlrCaption).foregroundStyle(Color.mlrTextMuted)
                ForEach(upcoming.prefix(4)) { event in
                    EventCard(
                        event: event,
                        summary: env.eventsService.summaries[event.id],
                        myStatus: env.eventsService.attendances[event.id]?.effectiveStatus(),
                        onTap: { selectedEvent = event }
                    )
                }
            }
        }
    }

    // MARK: - Agenda

    private var agenda: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("🏡 Who's staying").font(.mlrScaled(15, weight: .bold))
            if loading {
                ForEach(0..<3, id: \.self) { _ in SkeletonCard(height: 64) }
            } else if upcomingStays.isEmpty {
                VStack(spacing: 4) {
                    Text("No stays on the calendar yet.").font(.mlrBody).foregroundStyle(Color.mlrTextMuted)
                    Text("Add yours so the rest of \(house.name) knows when you'll be up.")
                        .font(.mlrCaption).foregroundStyle(Color.mlrTextSubtle).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(24).cardStyle()
            } else {
                ForEach(upcomingStays) { stay in
                    StayRow(stay: stay, today: today) { selectedStay = stay }
                }
            }

            if !pastStays.isEmpty {
                DisclosureGroup("Earlier stays (\(pastStays.count))") {
                    ForEach(pastStays) { stay in
                        StayRow(stay: stay, today: today) { selectedStay = stay }
                    }
                }
                .font(.mlrScaled(14, weight: .semibold))
                .tint(Color.mlrTextMuted)
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - DayKey (Identifiable wrapper for .sheet(item:))

private struct DayKey: Identifiable {
    let value: String
    var id: String { value }
}

// MARK: - Stay row

private struct StayRow: View {
    let stay: HouseStay
    let today: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                AvatarView(url: stay.authorAvatarUrl, size: .medium)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(stay.label).font(.mlrScaled(15, weight: .semibold)).foregroundStyle(Color.mlrText)
                        if stay.isActive(on: today) {
                            Text("On now")
                                .font(.mlrScaled(10, weight: .bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.mlrPrimaryLight).foregroundStyle(Color.mlrPrimary)
                                .clipShape(Capsule())
                        }
                    }
                    Text(stay.dateRangeLabel).font(.mlrCaption).foregroundStyle(Color.mlrTextMuted)
                    Text(stay.headCount > 1 ? "\(stay.authorName) · \(stay.headCount) people" : stay.authorName)
                        .font(.mlrCaption).foregroundStyle(Color.mlrTextSubtle).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.mlrScaled(13)).foregroundStyle(Color.mlrTextSubtle)
            }
            .padding(12)
            .cardStyle()
        }
        .buttonStyle(.plain)
    }
}
