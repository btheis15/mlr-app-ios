import Foundation
import Supabase

// MARK: - CabinService

@Observable
@MainActor
final class CabinService {
    var cabins: [Cabin] = []
    var myBookings: [CabinBooking] = []
    var allBookings: [CabinBooking] = []   // admin only
    var roomAvailability: [CabinRoomAvailability] = []  // per-room for selected cabin + dates
    var isLoading: Bool = false
    var error: String? = nil

    private var myBookingsChannel: RealtimeChannelV2? = nil

    // MARK: - Cabins

    func fetchCabins() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let rows: [Cabin] = try await supabase
                .from("cabins")
                .select("*")
                .eq("active", value: true)   // hide archived cabins (matches web)
                .order("sort_order", ascending: true)
                .execute()
                .value
            cabins = rows
        } catch {
            self.error = "Couldn't load cabins."
            print("[CabinService] fetchCabins error: \(error)")
        }
    }

    /// How many rooms are free in each cabin over a date range (migration 0032).
    func fetchAvailability(checkIn: String, checkOut: String) async -> [CabinAvailability] {
        struct AvailParams: Encodable {
            let p_check_in: String
            let p_check_out: String
        }
        do {
            let rows: [CabinAvailability] = try await supabase
                .rpc("cabin_availability", params: AvailParams(p_check_in: checkIn, p_check_out: checkOut))
                .execute()
                .value
            return rows
        } catch {
            print("[CabinService] fetchAvailability error: \(error)")
            return []
        }
    }

    // MARK: - Bookings

    func fetchRoomAvailability(cabinId: UUID, checkIn: String, checkOut: String) async {
        struct RoomAvailParams: Encodable {
            let p_cabin_id: String
            let p_check_in: String
            let p_check_out: String
        }
        do {
            let rows: [CabinRoomAvailability] = try await supabase
                .rpc("cabin_room_availability", params: RoomAvailParams(
                    p_cabin_id: cabinId.uuidString,
                    p_check_in: checkIn,
                    p_check_out: checkOut
                ))
                .execute()
                .value
            roomAvailability = rows
        } catch {
            roomAvailability = []
            print("[CabinService] fetchRoomAvailability error: \(error)")
        }
    }

    func requestStay(
        cabinId: UUID,
        checkIn: String,
        checkOut: String,
        guests: Int,
        note: String?,
        roomIds: [UUID]? = nil
    ) async throws {
        struct StayParams: Encodable {
            let p_cabin: String
            let p_check_in: String
            let p_check_out: String
            let p_guests: Int
            let p_notes: String?
            let p_room_ids: [String]?
        }
        try await supabase
            .rpc("request_cabin_stay", params: StayParams(
                p_cabin: cabinId.uuidString,
                p_check_in: checkIn,
                p_check_out: checkOut,
                p_guests: guests,
                p_notes: note,
                p_room_ids: roomIds?.map { $0.uuidString }
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
                    profiles!user_id(display_name),
                    booked_by_profile:profiles!booked_by(display_name)
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

    func editBooking(
        bookingId: UUID,
        checkIn: String,
        checkOut: String,
        guests: Int,
        notes: String?
    ) async throws {
        struct EditParams: Encodable {
            let p_booking: String
            let p_check_in: String
            let p_check_out: String
            let p_guests: Int
            let p_notes: String?
        }
        try await supabase
            .rpc("admin_update_cabin_booking", params: EditParams(
                p_booking: bookingId.uuidString,
                p_check_in: checkIn,
                p_check_out: checkOut,
                p_guests: guests,
                p_notes: notes
            ))
            .execute()
        func applyEdit(_ b: inout CabinBooking) {
            b.checkIn = checkIn; b.checkOut = checkOut
            b.guests = guests; b.note = notes
        }
        if let idx = allBookings.firstIndex(where: { $0.id == bookingId }) { applyEdit(&allBookings[idx]) }
        if let idx = myBookings.firstIndex(where: { $0.id == bookingId }) { applyEdit(&myBookings[idx]) }
    }

    // MARK: - Realtime

    /// Live-update the signed-in member's own bookings when an admin approves or
    /// denies them — matching the web app's `my-cabin-bookings` channel.
    func subscribeMyBookings(userId: UUID) {
        guard myBookingsChannel == nil else { return }
        let channel = supabase.channel("my-cabin-bookings-\(userId.uuidString)")
        myBookingsChannel = channel

        Task {
            channel.onPostgresChange(
                AnyAction.self,
                schema: "public",
                table: "cabin_bookings",
                filter: "user_id=eq.\(userId.uuidString)"
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in await self.fetchMyBookings(userId: userId) }
            }
            await channel.subscribe()
        }
    }

    func unsubscribeMyBookings() {
        Task {
            if let channel = myBookingsChannel {
                await supabase.removeChannel(channel)
                myBookingsChannel = nil
            }
        }
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
    let bookedByProfile: BookedByInfo?

    struct BookedByInfo: Decodable {
        let name: String?
        enum CodingKeys: String, CodingKey { case name = "display_name" }
    }

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
        case bookedByProfile = "booked_by_profile"
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
        booking.bookedByName = bookedByProfile?.name
        return booking
    }
}
