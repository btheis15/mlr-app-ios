import SwiftUI
import Supabase

// MARK: - AdminCabinBookings
// Shows all cabin booking requests grouped by status (Pending first).
// Approve / Deny with optional admin note; Cancel for pending and approved stays;
// Edit dates / guests / notes via EditCabinBookingSheet (migration 0095).
// Mirrors web AdminCabinBookings + EditBookingSheet.

struct AdminCabinBookings: View {
    @Environment(AppEnvironment.self) private var env

    @State private var isLoading = false
    @State private var actionError: String? = nil
    @State private var editingBooking: CabinBooking? = nil

    private let statusOrder: [BookingStatus] = [.pending, .approved, .denied, .cancelled]

    private var grouped: [(status: BookingStatus, items: [CabinBooking])] {
        statusOrder.compactMap { status in
            let items = env.cabinService.allBookings.filter { $0.status == status }
            return items.isEmpty ? nil : (status: status, items: items)
        }
    }

    var body: some View {
        List {
            if let actionError {
                Section {
                    Label(actionError, systemImage: "xmark.circle")
                        .foregroundStyle(Color.mlrWarning)
                        .font(.subheadline)
                }
            }

            if isLoading && env.cabinService.allBookings.isEmpty {
                ForEach(0..<4, id: \.self) { _ in bookingSkeleton }
            } else if !isLoading && env.cabinService.allBookings.isEmpty {
                emptyState
            } else {
                ForEach(grouped, id: \.status.rawValue) { group in
                    Section {
                        ForEach(group.items) { booking in
                            BookingRow(
                                booking: booking,
                                onApprove: { note, notify in Task { await approve(booking, note: note, notify: notify) } },
                                onDeny:    { note, notify in Task { await deny(booking, note: note, notify: notify) } },
                                onCancel:  { Task { await cancel(booking) } },
                                onEdit:    { editingBooking = booking }
                            )
                        }
                    } header: { statusHeader(group.status) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Cabin Bookings")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await load() }
        .task {
            await load()
            subscribeRealtime()
        }
        .sheet(item: $editingBooking) { booking in
            NavigationStack {
                EditCabinBookingSheet(booking: booking) {
                    Task { await load() }
                }
            }
        }
    }

    // MARK: - Section header

    private func statusHeader(_ status: BookingStatus) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 7, height: 7)
            Text(status.label)
                .font(.mlrScaled(12, weight: .semibold))
                .foregroundStyle(statusColor(status))
                .textCase(nil)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        Section {
            VStack(spacing: 16) {
                Image(systemName: "house.lodge")
                    .font(.mlrScaled(44, weight: .light))
                    .foregroundStyle(Color.mlrTextSubtle)
                Text("No booking requests")
                    .font(.headline)
                    .foregroundStyle(Color.mlrTextMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Skeleton

    private var bookingSkeleton: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 4).fill(Color.mlrCard).frame(height: 14).frame(maxWidth: 160)
            RoundedRectangle(cornerRadius: 4).fill(Color.mlrCard).frame(height: 12).frame(maxWidth: 220)
            RoundedRectangle(cornerRadius: 4).fill(Color.mlrCard).frame(height: 12).frame(maxWidth: 140)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Data

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        await env.cabinService.fetchAllBookings()
    }

    @MainActor
    private func approve(_ booking: CabinBooking, note: String, notify: Bool) async {
        actionError = nil
        do {
            try await env.cabinService.approveBooking(bookingId: booking.id, adminNote: note.isEmpty ? nil : note, notify: notify)
        } catch {
            actionError = "Couldn't approve booking."
        }
    }

    @MainActor
    private func deny(_ booking: CabinBooking, note: String, notify: Bool) async {
        actionError = nil
        do {
            try await env.cabinService.denyBooking(bookingId: booking.id, adminNote: note.isEmpty ? nil : note, notify: notify)
        } catch {
            actionError = "Couldn't deny booking."
        }
    }

    @MainActor
    private func cancel(_ booking: CabinBooking) async {
        actionError = nil
        do {
            try await env.cabinService.cancelBooking(bookingId: booking.id)
            await load()
        } catch {
            actionError = "Couldn't cancel booking."
        }
    }

    private func subscribeRealtime() {
        Task {
            let channel = supabase.channel("admin-cabin-bookings")
            channel.onPostgresChange(AnyAction.self, schema: "public", table: "cabin_bookings") { _ in
                Task { @MainActor in await self.load() }
            }
            await channel.subscribe()
        }
    }

    private func statusColor(_ status: BookingStatus) -> Color {
        switch status {
        case .pending:   return Color.mlrWarning
        case .approved:  return Color.mlrSuccess
        case .denied:    return Color.mlrDanger
        case .cancelled: return Color.mlrTextSubtle
        }
    }
}

// MARK: - BookingRow

private struct BookingRow: View {
    let booking: CabinBooking
    let onApprove: (String, Bool) -> Void
    let onDeny:    (String, Bool) -> Void
    let onCancel:  () -> Void
    let onEdit:    () -> Void

    @State private var adminNote: String = ""
    @State private var showReviewForm = false
    @State private var emailConfirm = true   // "Email them a confirmation" (migration 0104)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(booking.requesterName ?? "Member")
                        .font(.mlrScaled(15, weight: .semibold))
                    if let bookedBy = booking.bookedByName {
                        Text("Booked by \(bookedBy)")
                            .font(.caption)
                            .foregroundStyle(Color.mlrInfo)
                    }
                    if let cabin = booking.cabin {
                        Text(cabin.name)
                            .font(.mlrScaled(13))
                            .foregroundStyle(Color.mlrTextMuted)
                    }
                    Text(dateRange)
                        .font(.caption)
                        .foregroundStyle(Color.mlrTextMuted)
                    Text("\(booking.guests) guest\(booking.guests == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(Color.mlrTextSubtle)
                }
                Spacer()
                Text(MLRFormat.relativeTime(booking.createdAt))
                    .font(.caption2)
                    .foregroundStyle(Color.mlrTextSubtle)
            }

            // Requester's note
            if let note = booking.note, !note.isEmpty {
                Text("\u{201C}\(note)\u{201D}")
                    .font(.caption)
                    .foregroundStyle(Color.mlrTextMuted)
                    .italic()
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.mlrCard)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Existing admin note
            if let note = booking.adminNote, !note.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "person.fill.checkmark").font(.caption2)
                    Text("Admin: \(note)").font(.caption)
                }
                .foregroundStyle(Color.mlrTextMuted)
            }

            // Action controls by status
            switch booking.status {
            case .pending:  pendingActions
            case .approved: approvedActions
            default:        EmptyView()
            }
        }
        .padding(.vertical, 8)
        .onAppear { adminNote = booking.adminNote ?? "" }
    }

    @ViewBuilder
    private var pendingActions: some View {
        if showReviewForm {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Admin note (optional)", text: $adminNote)
                    .font(.mlrScaled(13))
                    .padding(8)
                    .background(Color.mlrCard)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Toggle("Email them a confirmation", isOn: $emailConfirm)
                    .font(.mlrScaled(13))
                    .tint(Color.mlrPrimary)

                HStack(spacing: 10) {
                    filledButton("Approve", icon: "checkmark.circle.fill", color: Color.mlrSuccess) {
                        onApprove(adminNote, emailConfirm); showReviewForm = false
                    }
                    filledButton("Deny", icon: "xmark.circle.fill", color: Color.mlrDanger) {
                        onDeny(adminNote, emailConfirm); showReviewForm = false
                    }
                }

                HStack(spacing: 16) {
                    Button("Edit") { onEdit() }
                        .font(.mlrScaled(12, weight: .medium))
                        .foregroundStyle(Color.mlrPrimary)
                    Button("Cancel booking") { onCancel(); showReviewForm = false }
                        .font(.mlrScaled(12, weight: .medium))
                        .foregroundStyle(Color.mlrDanger)
                    Spacer()
                    Button("Close") { showReviewForm = false }
                        .font(.caption)
                        .foregroundStyle(Color.mlrTextMuted)
                }
            }
        } else {
            Button { showReviewForm = true } label: {
                Text("Review request")
                    .font(.mlrScaled(13, weight: .semibold))
                    .foregroundStyle(Color.mlrPrimary)
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.mlrPrimary.opacity(0.4), lineWidth: 1))
            }
        }
    }

    @ViewBuilder
    private var approvedActions: some View {
        HStack(spacing: 10) {
            outlineButton("Edit", icon: "pencil", color: Color.mlrPrimary, action: onEdit)
            outlineButton("Cancel booking", icon: "xmark.circle", color: Color.mlrDanger, action: onCancel)
        }
    }

    private func filledButton(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.mlrScaled(13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(color)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func outlineButton(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.mlrScaled(13, weight: .semibold))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, minHeight: 32)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var dateRange: String {
        "\(MLRFormat.shortDateISO(booking.checkIn)) – \(MLRFormat.shortDateISO(booking.checkOut)) · \(booking.nightCount) night\(booking.nightCount == 1 ? "" : "s")"
    }
}

#Preview {
    NavigationStack { AdminCabinBookings() }
        .environment(AppEnvironment())
}
