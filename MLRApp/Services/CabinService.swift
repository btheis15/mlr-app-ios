import Foundation
import Supabase

// MARK: - CabinService

@Observable
@MainActor
final class CabinService {
    var cabins: [Cabin] = []
    var myBookings: [CabinBooking] = []
    var allBookings: [CabinBooking] = []   // admin only
    var isLoading: Bool = false
    var error: String? = nil

    // MARK: - Cabins

    func fetchCabins() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let rows: [Cabin] = try await supabase
                .from("cabins")
                .select("*")
                .order("sort_order", ascending: true)
                .execute()
                .value
            cabins = rows
        } catch {
            self.error = "Couldn't load cabins."
            print("[CabinService] fetchCabins error: \(error)")
        }
    }

    // MARK: - Bookings

    func requestStay(
        cabinId: UUID,
        checkIn: String,
        checkOut: String,
        guests: Int,
        note: String?
    ) async throws {
        struct StayParams: Encodable {
            let p_cabin: String
            let p_check_in: String
            let p_check_out: String
            let p_guests: Int
            let p_notes: String?
        }
        try await supabase
            .rpc("request_cabin_stay", params: StayParams(
                p_cabin: cabinId.uuidString,
                p_check_in: checkIn,
                p_check_out: checkOut,
                p_guests: guests,
                p_notes: note
            ))
            .execute()
    }

    func fetchMyBookings(userId: UUID) async {
        do {
            let rows: [CabinBooking] = try await supabase
                .from("cabin_bookings")
                .select("""
                    *,
                    cabins!cabin_id(id, slug, name, room_count, sort_order)
                """)
                .eq("user_id", value: userId.uuidString)
                .order("check_in", ascending: true)
                .execute()
                .value
            myBookings = rows
        } catch {
            print("[CabinService] fetchMyBookings error: \(error)")
        }
    }

    /// Admin only — queries the table directly (RLS permits admins to see all rows).
    func fetchAllBookings() async {
        do {
            let rows: [CabinBookingAdminRow] = try await supabase
                .from("cabin_bookings")
                .select("""
                    *,
                    cabins!cabin_id(id, slug, name, room_count, sort_order),
                    profiles!user_id(display_name)
                """)
                .order("check_in", ascending: true)
                .execute()
                .value
            allBookings = rows.map(\.toCabinBooking)
        } catch {
            print("[CabinService] fetchAllBookings error: \(error)")
        }
    }

    func approveBooking(bookingId: UUID, adminNote: String?) async throws {
        struct ReviewParams: Encodable {
            let p_booking: String
            let p_approve: Bool
            let p_note: String?
        }
        try await supabase
            .rpc("review_cabin_stay", params: ReviewParams(
                p_booking: bookingId.uuidString,
                p_approve: true,
                p_note: adminNote
            ))
            .execute()
        updateBookingStatus(id: bookingId, status: .approved, adminNote: adminNote, in: &myBookings)
        updateBookingStatus(id: bookingId, status: .approved, adminNote: adminNote, in: &allBookings)
    }

    func denyBooking(bookingId: UUID, adminNote: String?) async throws {
        struct ReviewParams: Encodable {
            let p_booking: String
            let p_approve: Bool
            let p_note: String?
        }
        try await supabase
            .rpc("review_cabin_stay", params: ReviewParams(
                p_booking: bookingId.uuidString,
                p_approve: false,
                p_note: adminNote
            ))
            .execute()
        updateBookingStatus(id: bookingId, status: .denied, adminNote: adminNote, in: &myBookings)
        updateBookingStatus(id: bookingId, status: .denied, adminNote: adminNote, in: &allBookings)
    }

    func cancelBooking(bookingId: UUID) async throws {
        struct CancelParams: Encodable { let p_booking: String }
        try await supabase
            .rpc("cancel_cabin_stay", params: CancelParams(p_booking: bookingId.uuidString))
            .execute()
        myBookings.removeAll { $0.id == bookingId }
        allBookings.removeAll { $0.id == bookingId }
    }

    // MARK: - Private

    private func updateBookingStatus(
        id: UUID,
        status: BookingStatus,
        adminNote: String?,
        in list: inout [CabinBooking]
    ) {
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
        list[idx].status = status
        if let note = adminNote { list[idx].adminNote = note }
    }
}

// MARK: - Private row type for fetchAllBookings (includes profiles join for requester name)

private struct CabinBookingAdminRow: Decodable {
    let id: UUID
    let cabinId: UUID
    let userId: UUID
    let checkIn: String
    let checkOut: String
    let guests: Int
    let note: String?
    let status: BookingStatus
    let adminNote: String?
    let createdAt: Date
    let cabins: CabinInfo?
    let profiles: RequesterInfo?

    enum CodingKeys: String, CodingKey {
        case id
        case cabinId = "cabin_id"
        case userId = "user_id"
        case checkIn = "check_in"
        case checkOut = "check_out"
        case guests
        case note = "notes"
        case status
        case adminNote = "review_note"
        case createdAt = "created_at"
        case cabins, profiles
    }

    struct CabinInfo: Decodable {
        let id: UUID; let slug: String; let name: String
        let roomCount: Int; let sortOrder: Int
        enum CodingKeys: String, CodingKey {
            case id, slug, name
            case roomCount = "room_count"; case sortOrder = "sort_order"
        }
    }

    struct RequesterInfo: Decodable {
        let name: String?
        enum CodingKeys: String, CodingKey { case name = "display_name" }
    }

    var toCabinBooking: CabinBooking {
        var booking = CabinBooking(
            id: id, cabinId: cabinId, userId: userId,
            requesterName: profiles?.name,
            checkIn: checkIn, checkOut: checkOut, guests: guests,
            note: note, status: status, adminNote: adminNote, createdAt: createdAt
        )
        if let c = cabins {
            booking.cabin = Cabin(
                id: c.id, slug: c.slug, name: c.name,
                description: nil, roomCount: c.roomCount,
                maxGuests: nil, imageUrl: nil, sortOrder: c.sortOrder
            )
        }
        return booking
    }
}
