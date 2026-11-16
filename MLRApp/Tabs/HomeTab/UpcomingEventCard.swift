import SwiftUI

// MARK: - UpcomingEventCard
// Spotlights the nearest upcoming non-Family-Fest event on Home.
// Mirrors components/UpcomingEvents.tsx.

struct UpcomingEventCard: View {
    let event: ResortEvent
    let attendance: EventAttendance?
    /// Optional caller-managed optimistic status override (Home manages it at top level).
    var currentStatusOverride: AttendanceStatus? = nil
    let onAttendanceChange: (AttendanceStatus) async -> Void

    @Environment(AppEnvironment.self) private var env
    @State private var showEventSheet = false
    @State private var attendees: [FestAttendee] = []

    private var displayStatus: AttendanceStatus? {
        currentStatusOverride ?? attendance?.effectiveStatus()
    }

    private var kindEmoji: String {
        switch event.kind {
        case .familyFest:  return "🎉"
        case .workWeekend: return "🔨"
        case .holiday:     return "🎄"
        case .custom:      return "📅"
        }
    }

    private var kindTint: Color {
        switch event.kind {
        case .familyFest:  return Color.mlrFest
        case .workWeekend: return Color.mlrCampfire
        case .holiday:     return Color.mlrPrimary
        case .custom:      return Color.mlrLake
        }
    }

    private var goingPeople: [AvatarPerson] {
        attendees.filter { $0.status == .going }.map {
            AvatarPerson(id: $0.id.uuidString, name: $0.name, url: $0.profile?.avatarUrl)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("Up next", color: .mlrCampfire)
            MLRCard(.hero) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        IconTile(emoji: kindEmoji, accent: kindTint, size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.title)
                                .font(.system(.title3, design: .serif, weight: .semibold))
                                .foregroundStyle(Color.mlrText)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 6) {
                                Text(MLRFormat.dateRange(start: event.startDate, end: event.endDate))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Color.mlrTextMuted)
                                if let d = Self.parse(event.startDate) {
                                    Text("·").foregroundStyle(Color.mlrTextSubtle)
                                    RelativeDue(d).font(.subheadline.weight(.semibold))
                                }
                            }
                            EventWeatherBadge(isoDate: event.startDate)
                            if let location = event.location {
                                Text(location)
                                    .font(.footnote)
                                    .foregroundStyle(Color.mlrTextSubtle)
                            }
                        }
                    }

                    if let desc = event.description {
                        Text(desc)
                            .font(.subheadline)
                            .foregroundStyle(Color.mlrTextMuted)
                            .lineLimit(2)
                    }

                    if env.isSignedIn {
                        // Shared/Components/AttendanceControl.swift: three equal segments.
                        AttendanceControlStateless(
                            selection: displayStatus,
                            isEnabled: true,
                            onSelect: { status in
                                Haptics.select()
                                Task { await onAttendanceChange(status) }
                            }
                        )
                    } else {
                        SignInChip()
                    }

                    Button { showEventSheet = true } label: {
                        HStack(spacing: 10) {
                            if !goingPeople.isEmpty {
                                AvatarStack(goingPeople, max: 5, size: 30, total: goingPeople.count)
                            } else {
                                Image(systemName: "person.2").foregroundStyle(Color.mlrPrimary)
                            }
                            Text("Who's going")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.mlrPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.mlrTextSubtle)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Who's going")
                }
            }
        }
        .task(id: event.id) { attendees = await env.eventsService.fetchAttendeesWithDays(eventId: event.id) }
        .sheet(isPresented: $showEventSheet) {
            EventSheet(event: event)
        }
    }

    private static func parse(_ iso: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/Chicago")
        return f.date(from: String(iso.prefix(10)))
    }
}

// MARK: - EventKindBadge

struct EventKindBadge: View {
    let kind: EventKind

    var body: some View {
        Text(label)
            .font(.mlrScaled(11, weight: .semibold))
            .foregroundStyle(tintColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tintColor.opacity(0.12))
            .clipShape(Capsule())
    }

    private var label: String {
        switch kind {
        case .familyFest:  return "Family Fest"
        case .workWeekend: return "Work Weekend"
        case .holiday:     return "Holiday"
        case .custom:      return "Event"
        }
    }

    private var tintColor: Color {
        switch kind {
        case .familyFest:  return Color.mlrFest
        case .workWeekend: return Color.mlrAccent
        case .holiday:     return Color.mlrPrimary
        case .custom:      return Color.mlrInfo
        }
    }
}

// AttendanceControl / AttendanceControlStateless — Shared/Components/AttendanceControl.swift
// SignInChip — Shared/Components/GuardView.swift
