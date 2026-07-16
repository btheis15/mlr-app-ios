import SwiftUI

// MARK: - PickMyRoomSheet
//
// Self-service "Choose your room" for a booking that has no room assigned yet,
// on a cabin broken into named rooms (migration 0106 lets the requester set
// their own rooms). Reuses RoomPickRow + set_booking_rooms. Mirrors the web
// PickMyRoomSheet.

struct PickMyRoomSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let booking: CabinBooking
    let onSaved: () -> Void

    @State private var rooms: [CabinRoomAvailability] = []
    @State private var selected: Set<UUID> = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading rooms…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if rooms.isEmpty {
                    ContentUnavailableView(
                        "No rooms to choose",
                        systemImage: "bed.double",
                        description: Text("This cabin isn't broken into named rooms.")
                    )
                } else {
                    form
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Choose your room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving { ProgressView() }
                    else {
                        Button("Save") { Task { await save() } }
                            .fontWeight(.semibold)
                            .disabled(selected.isEmpty)
                    }
                }
            }
            .task { await load() }
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(booking.cabin?.name ?? "Cabin") · \(MLRFormat.shortDateISO(booking.checkIn)) – \(MLRFormat.shortDateISO(booking.checkOut))")
                    .font(.mlrScaled(13))
                    .foregroundStyle(Color.mlrTextMuted)

                VStack(spacing: 0) {
                    ForEach(rooms) { room in
                        RoomPickRow(
                            room: room,
                            isSelected: selected.contains(room.id),
                            onToggle: {
                                if selected.contains(room.id) { selected.remove(room.id) }
                                else if room.available { selected.insert(room.id) }
                            }
                        )
                        if room.id != rooms.last?.id { Divider().padding(.leading, 16) }
                    }
                }
                .cardStyle()

                if let saveError {
                    Text(saveError).font(.mlrCaption).foregroundStyle(Color.mlrDanger)
                }
            }
            .padding(20)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        await env.cabinService.fetchRoomAvailability(
            cabinId: booking.cabinId, checkIn: booking.checkIn, checkOut: booking.checkOut)
        rooms = env.cabinService.roomAvailability
    }

    private func save() async {
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            try await env.cabinService.setBookingRooms(bookingId: booking.id, roomIds: Array(selected))
            Haptics.success()
            onSaved()
            dismiss()
        } catch {
            saveError = "Couldn't save your room choice. Try again."
        }
    }
}
