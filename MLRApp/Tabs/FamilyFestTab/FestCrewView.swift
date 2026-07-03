import SwiftUI
import Charts

// MARK: - FestCrewView
// Who's coming to Family Fest — driven by the real per-day RSVPs on the
// family-fest-2026 event (no placeholder households). Each member shows the
// days they're making it. Tap "RSVP your days" to set your own.

struct FestCrewView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var attendees: [FestAttendee] = []
    @State private var loading = true
    @State private var festEvent: ResortEvent?
    @State private var showRSVP = false

    // The fest runs Mon–Fri (Jul 27–31). Day pills use these in order.
    private let festDays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]

    var body: some View {
        Group {
            if !env.isSignedIn {
                FestSignInNotice(message: "Sign in to see who's coming and RSVP your days.")
            } else {
                crewContent
            }
        }
        .task { await load() }
        .sheet(isPresented: $showRSVP, onDismiss: { Task { await load() } }) {
            if let festEvent { EventSheet(event: festEvent) }
        }
    }

    private var crewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(headerText)
                        .font(.festSerif(14))
                        .foregroundStyle(Color.mlrFest.opacity(0.7))
                    Spacer()
                    Button {
                        showRSVP = true
                    } label: {
                        Label("RSVP your days", systemImage: "calendar.badge.plus")
                            .font(.mlrScaled(14, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.mlrFest)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(festEvent == nil)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                if loading {
                    ProgressView().tint(Color.mlrFest)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                } else if attendees.isEmpty {
                    Text("No RSVPs yet — be the first! Tap \u{201C}RSVP your days.\u{201D}")
                        .font(.festSerif(14))
                        .foregroundStyle(Color.mlrFest.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                } else {
                    attendanceChart
                        .padding(.horizontal, 16)

                    VStack(spacing: 10) {
                        ForEach(attendees) { attendee in
                            AttendeeCard(attendee: attendee, festDays: festDays)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
        }
        .background(Color.mlrFestParchment)
    }

    private var attendanceChart: some View {
        let short = ["Monday": "Mon", "Tuesday": "Tue", "Wednesday": "Wed",
                     "Thursday": "Thu", "Friday": "Fri"]
        let counts = festDays.map { day -> (day: String, count: Int) in
            (short[day] ?? day,
             attendees.filter { $0.goingDays(allDays: festDays).contains(day) }.count)
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Who's here each day")
                .font(.festSerif(13))
                .foregroundStyle(Color.mlrFest.opacity(0.7))
            Chart(counts, id: \.day) { item in
                BarMark(x: .value("Day", item.day), y: .value("Coming", item.count))
                    .foregroundStyle(Color.mlrFest)
                    .cornerRadius(4)
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 120)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color.mlrFestParchment)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.mlrFest.opacity(0.18), lineWidth: 1))
    }

    private var headerText: String {
        let n = attendees.count
        return loading ? "Loading the crew…" : "\(n) \(n == 1 ? "person" : "people") coming"
    }

    private func load() async {
        loading = true
        if env.eventsService.events.isEmpty { await env.eventsService.fetchEvents() }
        festEvent = env.eventsService.events.first(where: { $0.isFamilyFest })
        attendees = await env.eventsService.fetchAttendeesWithDays(eventId: FamilyFestConfig.id)
            .sorted { $0.profile.name < $1.profile.name }
        loading = false
    }
}

// MARK: - Attendee Card

private struct AttendeeCard: View {
    let attendee: FestAttendee
    let festDays: [String]

    private let shortDay: [String: String] = [
        "Monday": "Mon", "Tuesday": "Tue", "Wednesday": "Wed",
        "Thursday": "Thu", "Friday": "Fri"
    ]

    var body: some View {
        let going = attendee.goingDays(allDays: festDays)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AvatarView(profile: attendee.profile, size: .small)
                PrivateName(profile: attendee.profile, font: .festSerif(15, weight: .bold))
                    .foregroundStyle(Color.mlrFest)
                Spacer()
                if attendee.isWholeWeek {
                    Text("All week")
                        .font(.mlrScaled(11, weight: .semibold))
                        .foregroundStyle(Color.mlrFest)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.mlrFest.opacity(0.12))
                        .clipShape(Capsule())
                } else if attendee.status == .maybe {
                    Text("Maybe")
                        .font(.mlrScaled(11, weight: .semibold))
                        .foregroundStyle(Color.mlrFest.opacity(0.7))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.mlrFest.opacity(0.08))
                        .clipShape(Capsule())
                }
            }

            HStack(spacing: 5) {
                ForEach(festDays, id: \.self) { day in
                    let on = going.contains(day)
                    Text(shortDay[day] ?? day)
                        .font(.mlrScaled(11, weight: .semibold))
                        .foregroundStyle(on ? Color.white : Color.mlrFest.opacity(0.35))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(on ? Color.mlrFest : Color.mlrFest.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mlrFestParchment)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.mlrFest.opacity(0.18), lineWidth: 1)
        )
    }
}

// MARK: - Fest Sign-In Notice
// A parchment-styled, message-only sign-in placeholder for the Family Fest
// section. (The project-wide generic `SignInWall<Content>` lives in
// Shared/Components/GuardView.swift — this is the FF-themed sibling.)

struct FestSignInNotice: View {
    let message: String

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.mlrScaled(36))
                .foregroundStyle(Color.mlrFest.opacity(0.4))
            Text(message)
                .font(.festSerif(15))
                .foregroundStyle(Color.mlrFest.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mlrFestParchment)
    }
}
