import SwiftUI

// MARK: - CabinBookingsView
// The signed-in member's own cabin booking history with status badges.
// Pending bookings can be cancelled. New requests via CabinRequestSheet.

struct CabinBookingsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var hasLoaded = false
    @State private var showRequestSheet = false
    @State private var cancellingId: UUID?
    @State private var actionError: String?
    /// True when the signed-in (non-admin) member approves ≥1 place — shows the
    /// "Requests to approve" entry (migration 0114/0120).
    @State private var isApprover = false

    private var bookings: [CabinBooking] { env.cabinService.myBookings }

    var body: some View {
        NavigationStack {
            Group {
                if !env.isSignedIn {
                    SignInWall { placeholderList }
                } else if !hasLoaded && bookings.isEmpty {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(0..<3, id: \.self) { _ in SkeletonCard(height: 100) }
                        }
                        .padding(.vertical, 16)
                    }
                } else if bookings.isEmpty {
                    emptyState
                } else {
                    bookingList
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("My Cabin Stays")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                // Non-admin approvers reach the requests for the place(s) they
                // approve here (admins use the admin panel).
                if isApprover && !env.isAdmin {
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink { AdminCabinBookings() } label: {
                            Label("Requests to approve", systemImage: "tray.full")
                        }
                        .tint(Color.mlrPrimary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showRequestSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .tint(Color.mlrPrimary)
                }
            }
            .sheet(isPresented: $showRequestSheet) {
                CabinRequestSheet()
            }
            .alert("Couldn't cancel", isPresented: .constant(actionError != nil)) {
                Button("OK") { actionError = nil }
            } message: {
                Text(actionError ?? "")
            }
            .task {
                if !hasLoaded {
                    await env.cabinService.fetchCabins()
                    if let userId = await env.authService.userId {
                        await env.cabinService.fetchMyBookings(userId: userId)
                    }
                    hasLoaded = true
                }
                if let userId = env.currentProfile?.id {
                    env.cabinService.subscribeMyBookings(userId: userId)
                    if !env.isAdmin {
                        isApprover = !(await env.cabinService.fetchMyApproverCabinIds(userId: userId)).isEmpty
                    }
                }
            }
            .onDisappear { env.cabinService.unsubscribeMyBookings() }
        }
    }

    // MARK: - List

    private var bookingList: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(bookings) { booking in
                    BookingCard(
                        booking: booking,
                        isCancelling: cancellingId == booking.id,
                        onCancel: { Task { await cancel(booking) } }
                    )
                }
            }
            .padding(16)
        }
        .refreshable {
            if let userId = await env.authService.userId {
                await env.cabinService.fetchMyBookings(userId: userId)
            }
        }
    }

    private var placeholderList: some View {
        VStack(spacing: 12) {
            ForEach(0..<2, id: \.self) { _ in SkeletonCard(height: 100) }
        }
        .padding(.vertical, 16)
    }

    // MARK: - Empty

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No cabin stays yet", systemImage: "house")
        } description: {
            Text("Request a cabin for your next visit and track its status here.")
        } actions: {
            Button("Request a Cabin") { showRequestSheet = true }
                .buttonStyle(.borderedProminent)
                .tint(Color.mlrPrimary)
        }
    }

    // MARK: - Cancel

    private func cancel(_ booking: CabinBooking) async {
        cancellingId = booking.id
        defer { cancellingId = nil }
        do {
            try await env.cabinService.cancelBooking(bookingId: booking.id)
        } catch {
            actionError = "Couldn't cancel this stay. Try again."
            print("[CabinBookings] cancel error: \(error)")
        }
    }
}

// MARK: - Booking Card

private struct BookingCard: View {
    @Environment(AppEnvironment.self) private var env
    let booking: CabinBooking
    let isCancelling: Bool
    let onCancel: () -> Void

    @State private var calendarAdded = false
    @State private var canPickRoom = false   // cabin has named rooms + none assigned yet
    @State private var showPickRoom = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(booking.cabin?.name ?? "Cabin")
                        .font(.mlrScaled(17, weight: .bold))
                        .foregroundStyle(Color.mlrText)
                    Label(
                        "\(MLRFormat.shortDateISO(booking.checkIn)) – \(MLRFormat.shortDateISO(booking.checkOut))",
                        systemImage: "calendar"
                    )
                    .font(.mlrScaled(13))
                    .foregroundStyle(Color.mlrTextMuted)
                }
                Spacer()
                StatusBadge(status: booking.status)
            }

            HStack(spacing: 16) {
                Label("\(booking.nightCount) night\(booking.nightCount == 1 ? "" : "s")",
                      systemImage: "moon.fill")
                Label("\(booking.guests) guest\(booking.guests == 1 ? "" : "s")",
                      systemImage: "person.2.fill")
            }
            .font(.mlrScaled(12))
            .foregroundStyle(Color.mlrTextMuted)

            if let note = booking.note, !note.isEmpty {
                Text(note)
                    .font(.mlrScaled(13))
                    .foregroundStyle(Color.mlrText)
            }

            if let adminNote = booking.adminNote, !adminNote.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "text.bubble.fill")
                        .font(.mlrScaled(11))
                    Text(adminNote)
                        .font(.mlrScaled(12))
                }
                .foregroundStyle(Color.mlrTextMuted)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.mlrSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if booking.status == .pending {
                Button(role: .destructive, action: onCancel) {
                    if isCancelling {
                        ProgressView().tint(Color.mlrDanger)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    } else {
                        Text("Cancel request")
                            .font(.mlrScaled(14, weight: .semibold))
                            .foregroundStyle(Color.mlrDanger)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                }
                .buttonStyle(.plain)
                .background(Color.mlrDanger.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .disabled(isCancelling)
            }

            // Self-service room pick (migration 0106) — when the cabin has named
            // rooms and this booking hasn't been assigned one yet.
            if canPickRoom && (booking.status == .pending || booking.status == .approved) {
                Button { showPickRoom = true } label: {
                    Label("Choose your room", systemImage: "bed.double.fill")
                        .font(.mlrScaled(14, weight: .semibold))
                        .foregroundStyle(Color.mlrPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.mlrPrimary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }

            if booking.status == .approved {
                Button { Task { await addStayToCalendar() } } label: {
                    Label(calendarAdded ? "Added to Calendar ✓" : "Add to Calendar",
                          systemImage: calendarAdded ? "checkmark.circle.fill" : "calendar.badge.plus")
                        .font(.mlrScaled(14, weight: .semibold))
                        .foregroundStyle(calendarAdded ? Color.mlrSuccess : Color.mlrPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background((calendarAdded ? Color.mlrSuccess : Color.mlrPrimary).opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(calendarAdded)
            }
        }
        .padding(16)
        .background(Color.mlrCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .task(id: booking.id) { await checkRoomEligibility() }
        .sheet(isPresented: $showPickRoom) {
            PickMyRoomSheet(booking: booking) {
                Task {
                    if let uid = env.currentProfile?.id {
                        await env.cabinService.fetchMyBookings(userId: uid)
                    }
                    await checkRoomEligibility()
                }
            }
        }
    }

    /// Show "Choose your room" only when the cabin is broken into named rooms and
    /// this booking has none attached yet (cancelled/denied excluded).
    private func checkRoomEligibility() async {
        guard booking.status == .pending || booking.status == .approved else {
            canPickRoom = false; return
        }
        let rooms = await env.cabinService.fetchCabinRooms(cabinId: booking.cabinId)
        guard !rooms.isEmpty else { canPickRoom = false; return }
        let held = await env.cabinService.fetchBookingRooms(bookingId: booking.id)
        canPickRoom = held.isEmpty
    }

    private func addStayToCalendar() async {
        do {
            _ = try await CalendarService.shared.addEvent(
                title: "\(booking.cabin?.name ?? "Cabin") — Muskellunge Lake Resort",
                startISO: booking.checkIn,
                endISO: booking.checkOut,
                location: "Muskellunge Lake Resort",
                notes: booking.note
            )
            Haptics.success()
            calendarAdded = true
        } catch {
            Haptics.error()
        }
    }
}

// MARK: - Status Badge

private struct StatusBadge: View {
    let status: BookingStatus

    private var color: Color {
        switch status.color {
        case "green": return .mlrSuccess
        case "amber": return .mlrWarning
        case "red":   return .mlrDanger
        default:      return .mlrTextMuted
        }
    }

    var body: some View {
        Text(status.label)
            .font(.mlrScaled(11, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.14))
            .clipShape(Capsule())
    }
}
