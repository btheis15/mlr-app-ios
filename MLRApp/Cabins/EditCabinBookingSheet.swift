import SwiftUI

// MARK: - EditCabinBookingSheet
// Admin-only sheet to change a booking's dates, guest count, and notes.
// Mirrors web EditBookingSheet — calls admin_update_cabin_booking RPC (migration 0095).

struct EditCabinBookingSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let booking: CabinBooking
    let onSaved: () -> Void

    @State private var checkIn: Date
    @State private var checkOut: Date
    @State private var guests: Int
    @State private var notes: String
    @State private var isSaving = false
    @State private var saveError: String? = nil

    // Room reassignment (migration 0092). `rooms` is per-room availability for the
    // booking's dates; already-held rooms are force-shown as available.
    @State private var rooms: [CabinRoomAvailability] = []
    @State private var heldRoomIds: Set<UUID> = []
    @State private var selectedRoomIds: Set<UUID> = []
    @State private var loadingRooms = true
    @State private var notify = false   // "Email them about this update" (off by default)

    init(booking: CabinBooking, onSaved: @escaping () -> Void) {
        self.booking = booking
        self.onSaved = onSaved
        _checkIn  = State(initialValue: Self.parseDate(booking.checkIn)  ?? .now)
        _checkOut = State(initialValue: Self.parseDate(booking.checkOut) ?? Calendar.current.date(byAdding: .day, value: 1, to: .now)!)
        _guests   = State(initialValue: booking.guests)
        _notes    = State(initialValue: booking.note ?? "")
    }

    /// Per-room rows with already-held rooms forced available (so the admin can
    /// keep them selected even though the availability RPC counts them as taken).
    private var effectiveRooms: [CabinRoomAvailability] {
        rooms.map { r in
            heldRoomIds.contains(r.id)
                ? CabinRoomAvailability(roomId: r.roomId, name: r.name, beds: r.beds,
                                        active: r.active, available: true)
                : r
        }
    }

    var body: some View {
        Form {
            Section("Dates") {
                DatePicker("Check-in", selection: $checkIn, displayedComponents: .date)
                    .onChange(of: checkIn) { _, new in
                        if checkOut <= new {
                            checkOut = Calendar.current.date(byAdding: .day, value: 1, to: new)!
                        }
                    }
                DatePicker(
                    "Check-out",
                    selection: $checkOut,
                    in: Calendar.current.date(byAdding: .day, value: 1, to: checkIn)!...,
                    displayedComponents: .date
                )
            }

            Section("Guests") {
                Stepper(guests == 1 ? "1 guest" : "\(guests) guests", value: $guests, in: 1...16)
            }

            Section("Notes") {
                TextField("Optional notes for the member", text: $notes, axis: .vertical)
                    .lineLimit(3...6)
            }

            // Room reassignment — only for cabins broken into named rooms.
            if loadingRooms {
                Section("Rooms") {
                    HStack { ProgressView(); Text("Loading rooms…").foregroundStyle(Color.mlrTextMuted) }
                }
            } else if !rooms.isEmpty {
                Section {
                    ForEach(effectiveRooms) { room in
                        RoomPickRow(
                            room: room,
                            isSelected: selectedRoomIds.contains(room.id),
                            onToggle: {
                                if selectedRoomIds.contains(room.id) {
                                    selectedRoomIds.remove(room.id)
                                } else if room.available {
                                    selectedRoomIds.insert(room.id)
                                }
                            }
                        )
                    }
                } header: {
                    Text("Rooms")
                } footer: {
                    Text("Reassign which room(s) this booking holds.")
                }
            }

            Section {
                Toggle("Email them about this update", isOn: $notify)
                    .tint(Color.mlrPrimary)
            } footer: {
                Text("Off by default — turn on to send the member a confirmation of these changes.")
            }

            if let saveError {
                Section {
                    Text(saveError)
                        .font(.mlrScaled(13))
                        .foregroundStyle(Color.mlrDanger)
                }
            }
        }
        .navigationTitle("Edit Booking")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadRooms() }
        .task(id: "\(Self.formatDate(checkIn))|\(Self.formatDate(checkOut))") { await loadRooms() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Save") { Task { await save() } }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private static let isoFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    private static func parseDate(_ s: String) -> Date? { isoFmt.date(from: s) }
    private static func formatDate(_ d: Date) -> String { isoFmt.string(from: d) }

    @State private var didLoadHeldRooms = false

    private func loadRooms() async {
        // Seed the currently-held rooms once (so date changes don't wipe them).
        if !didLoadHeldRooms {
            let held = await env.cabinService.fetchBookingRooms(bookingId: booking.id)
            heldRoomIds = Set(held.map(\.id))
            selectedRoomIds = heldRoomIds
            didLoadHeldRooms = true
        }
        // Per-room availability for the current date range.
        await env.cabinService.fetchRoomAvailability(
            cabinId: booking.cabinId,
            checkIn: Self.formatDate(checkIn),
            checkOut: Self.formatDate(checkOut)
        )
        rooms = env.cabinService.roomAvailability
        loadingRooms = false
    }

    private func save() async {
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        let notesVal = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await env.cabinService.editBooking(
                bookingId: booking.id,
                checkIn:  Self.formatDate(checkIn),
                checkOut: Self.formatDate(checkOut),
                guests: guests,
                notes: notesVal.isEmpty ? nil : notesVal,
                notify: notify
            )
            // Persist room reassignment when the cabin has named rooms and the
            // selection changed from what was held.
            if !rooms.isEmpty && selectedRoomIds != heldRoomIds {
                try await env.cabinService.setBookingRooms(
                    bookingId: booking.id,
                    roomIds: Array(selectedRoomIds)
                )
            }
            onSaved()
            dismiss()
        } catch {
            saveError = "Save failed. Check your connection and try again."
        }
    }
}
