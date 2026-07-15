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

    init(booking: CabinBooking, onSaved: @escaping () -> Void) {
        self.booking = booking
        self.onSaved = onSaved
        _checkIn  = State(initialValue: Self.parseDate(booking.checkIn)  ?? .now)
        _checkOut = State(initialValue: Self.parseDate(booking.checkOut) ?? Calendar.current.date(byAdding: .day, value: 1, to: .now)!)
        _guests   = State(initialValue: booking.guests)
        _notes    = State(initialValue: booking.note ?? "")
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
                notes: notesVal.isEmpty ? nil : notesVal
            )
            onSaved()
            dismiss()
        } catch {
            saveError = "Save failed. Check your connection and try again."
        }
    }
}
