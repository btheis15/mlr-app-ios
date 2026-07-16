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

    /// Submit a request. Pass `forUserId` to book on behalf of another member —
    /// admin-only, enforced server-side; the booking lands under that member's id
    /// with `booked_by` stamped to the admin (migration 0087). Pass `roomIds` for
    /// a cabin broken into named rooms (migration 0092).
    @discardableResult
    func requestStay(
        cabinId: UUID,
        checkIn: String,
        checkOut: String,
        guests: Int,
        note: String?,
        roomIds: [UUID]? = nil,
        forUserId: UUID? = nil
    ) async throws -> UUID? {
        struct StayParams: Encodable {
            let p_cabin: String
            let p_check_in: String
            let p_check_out: String
            let p_guests: Int
            let p_notes: String?
            let p_for_user: String?
            let p_room_ids: [String]?
        }
        // Throws on a real RPC failure (so submit() still surfaces errors); the
        // RPC returns the new booking's id, decoded best-effort for the
        // book-on-behalf auto-approve that follows.
        let response = try await supabase
            .rpc("request_cabin_stay", params: StayParams(
                p_cabin: cabinId.uuidString,
                p_check_in: checkIn,
                p_check_out: checkOut,
                p_guests: guests,
                p_notes: note,
                p_for_user: forUserId?.uuidString,
                p_room_ids: (roomIds?.isEmpty == false) ? roomIds?.map { $0.uuidString } : nil
            ))
            .execute()
        return try? JSONDecoder().decode(UUID.self, from: response.data)
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

    /// Approve or deny. Pass `notify = false` to skip the requester's confirmation
    /// email (migration 0104) — e.g. booking on behalf of someone who doesn't use
    /// email/the app.
    private struct ReviewParams: Encodable {
        let p_booking: String
        let p_approve: Bool
        let p_note: String?
        let p_notify: Bool
    }

    func approveBooking(bookingId: UUID, adminNote: String?, notify: Bool = true) async throws {
        try await supabase
            .rpc("review_cabin_stay", params: ReviewParams(
                p_booking: bookingId.uuidString,
                p_approve: true,
                p_note: adminNote,
                p_notify: notify
            ))
            .execute()
        updateBookingStatus(id: bookingId, status: .approved, adminNote: adminNote, in: &myBookings)
        updateBookingStatus(id: bookingId, status: .approved, adminNote: adminNote, in: &allBookings)
    }

    func denyBooking(bookingId: UUID, adminNote: String?, notify: Bool = true) async throws {
        try await supabase
            .rpc("review_cabin_stay", params: ReviewParams(
                p_booking: bookingId.uuidString,
                p_approve: false,
                p_note: adminNote,
                p_notify: notify
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

    /// Admin-only: edit a request's dates/guests/notes (migration 0095). Pass
    /// `notify = true` to email the requester about the change (migration 0105) —
    /// off by default, since most edits are small corrections.
    func editBooking(
        bookingId: UUID,
        checkIn: String,
        checkOut: String,
        guests: Int,
        notes: String?,
        notify: Bool = false
    ) async throws {
        struct EditParams: Encodable {
            let p_booking: String
            let p_check_in: String
            let p_check_out: String
            let p_guests: Int
            let p_notes: String?
            let p_notify: Bool
        }
        try await supabase
            .rpc("admin_update_cabin_booking", params: EditParams(
                p_booking: bookingId.uuidString,
                p_check_in: checkIn,
                p_check_out: checkOut,
                p_guests: guests,
                p_notes: notes,
                p_notify: notify
            ))
            .execute()
        func applyEdit(_ b: inout CabinBooking) {
            b.checkIn = checkIn; b.checkOut = checkOut
            b.guests = guests; b.note = notes
        }
        if let idx = allBookings.firstIndex(where: { $0.id == bookingId }) { applyEdit(&allBookings[idx]) }
        if let idx = myBookings.firstIndex(where: { $0.id == bookingId }) { applyEdit(&myBookings[idx]) }
    }

    // MARK: - Room assignment (migration 0092) + cabin/room CRUD (migration 0089/0092)

    /// (Re)assign which room(s) an existing booking reserves. Empty array clears
    /// all assignments. Admin-gated server-side (also used by the self-service
    /// "Choose your room" flow, which migration 0106 permits for the requester).
    func setBookingRooms(bookingId: UUID, roomIds: [UUID]) async throws {
        struct Params: Encodable {
            let p_booking: String
            let p_room_ids: [String]
        }
        try await supabase
            .rpc("set_booking_rooms", params: Params(
                p_booking: bookingId.uuidString,
                p_room_ids: roomIds.map { $0.uuidString }
            ))
            .execute()
    }

    /// The specific room(s) a booking currently has attached (id + name).
    func fetchBookingRooms(bookingId: UUID) async -> [BookedRoom] {
        struct LinkRow: Decodable {
            let roomId: UUID
            let cabinRooms: RoomName?
            struct RoomName: Decodable { let name: String }
            enum CodingKeys: String, CodingKey {
                case roomId = "room_id"
                case cabinRooms = "cabin_rooms"
            }
        }
        do {
            let rows: [LinkRow] = try await supabase
                .from("cabin_booking_rooms")
                .select("room_id, cabin_rooms(name)")
                .eq("booking_id", value: bookingId.uuidString)
                .execute()
                .value
            return rows.map { BookedRoom(id: $0.roomId, name: $0.cabinRooms?.name ?? "Room") }
        } catch {
            print("[CabinService] fetchBookingRooms error: \(error)")
            return []
        }
    }

    /// Every cabin regardless of active state (admin editor only).
    func fetchCabinsAdmin() async -> [Cabin] {
        do {
            return try await supabase
                .from("cabins")
                .select("*")
                .order("sort_order", ascending: true)
                .execute()
                .value
        } catch {
            print("[CabinService] fetchCabinsAdmin error: \(error)")
            return []
        }
    }

    /// Edit a cabin's editable fields (admin-gated by RLS, migration 0089).
    func saveCabin(id: UUID, name: String, roomCount: Int, bedCount: Int?,
                   notes: String?, active: Bool) async throws {
        struct Row: Encodable {
            let name: String
            let room_count: Int
            let bed_count: Int?
            let notes: String?
            let active: Bool
        }
        try await supabase
            .from("cabins")
            .update(Row(name: name, room_count: roomCount, bed_count: bedCount, notes: notes, active: active))
            .eq("id", value: id.uuidString)
            .execute()
    }

    /// The named rooms within a cabin (migration 0092), ordered. Empty when the
    /// cabin hasn't been broken into rooms.
    func fetchCabinRooms(cabinId: UUID) async -> [CabinRoom] {
        do {
            return try await supabase
                .from("cabin_rooms")
                .select("id, cabin_id, name, beds, description, active, sort_order")
                .eq("cabin_id", value: cabinId.uuidString)
                .order("sort_order", ascending: true)
                .execute()
                .value
        } catch {
            print("[CabinService] fetchCabinRooms error: \(error)")
            return []
        }
    }

    /// Create (id nil) or update a room (admin-gated by RLS, migration 0092).
    func saveCabinRoom(id: UUID?, cabinId: UUID, name: String, beds: Int,
                       description: String?, active: Bool, sortOrder: Int?) async throws {
        struct Row: Encodable {
            let cabin_id: String
            let name: String
            let beds: Int
            let description: String?
            let active: Bool
            let sort_order: Int?
        }
        let row = Row(cabin_id: cabinId.uuidString, name: name, beds: beds,
                      description: description, active: active, sort_order: sortOrder)
        if let id {
            try await supabase.from("cabin_rooms").update(row).eq("id", value: id.uuidString).execute()
        } else {
            try await supabase.from("cabin_rooms").insert(row).execute()
        }
    }

    /// Delete a room (admin-gated by RLS). Past bookings cascade-lose the link.
    func deleteCabinRoom(id: UUID) async throws {
        try await supabase.from("cabin_rooms").delete().eq("id", value: id.uuidString).execute()
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
