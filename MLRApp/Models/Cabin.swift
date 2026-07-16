import Foundation

// MARK: - Cabin

struct Cabin: Codable, Identifiable, Equatable {
    let id: UUID
    var slug: String
    var name: String
    var description: String?  // not in DB yet; always nil
    var roomCount: Int
    var maxGuests: Int?       // not in DB yet; views fall back to ?? 12
    var imageUrl: String?     // not in DB yet; always nil
    var sortOrder: Int
    var bedCount: Int? = nil     // migration 0089
    var notes: String? = nil     // member-facing notes (migration 0089)
    var active: Bool = true      // archived cabins hidden from members (migration 0089)

    enum CodingKeys: String, CodingKey {
        case id, slug, name, description
        case roomCount = "room_count"
        case maxGuests = "max_guests"
        case imageUrl = "image_url"
        case sortOrder = "sort_order"
        case bedCount = "bed_count"
        case notes, active
    }

    // Custom decode so the extra columns degrade gracefully when a query only
    // selects the base fields (e.g. the admin booking join builds a Cabin from a
    // narrower projection). Present in `select("*")` reads; absent elsewhere.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        slug = try c.decode(String.self, forKey: .slug)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        roomCount = try c.decode(Int.self, forKey: .roomCount)
        maxGuests = try c.decodeIfPresent(Int.self, forKey: .maxGuests)
        imageUrl = try c.decodeIfPresent(String.self, forKey: .imageUrl)
        sortOrder = try c.decode(Int.self, forKey: .sortOrder)
        bedCount = try c.decodeIfPresent(Int.self, forKey: .bedCount)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? true
    }

    // Memberwise init retained (custom `init(from:)` suppresses synthesis).
    init(id: UUID, slug: String, name: String, description: String? = nil,
         roomCount: Int, maxGuests: Int? = nil, imageUrl: String? = nil,
         sortOrder: Int, bedCount: Int? = nil, notes: String? = nil, active: Bool = true) {
        self.id = id; self.slug = slug; self.name = name; self.description = description
        self.roomCount = roomCount; self.maxGuests = maxGuests; self.imageUrl = imageUrl
        self.sortOrder = sortOrder; self.bedCount = bedCount; self.notes = notes; self.active = active
    }
}

// MARK: - Cabin Availability (cabin_availability RPC, migration 0032)

struct CabinAvailability: Codable, Identifiable, Equatable {
    let cabinId: UUID
    let slug: String
    let name: String
    let roomCount: Int
    let available: Int

    var id: UUID { cabinId }

    enum CodingKeys: String, CodingKey {
        case cabinId = "cabin_id"
        case slug, name
        case roomCount = "room_count"
        case available
    }
}

// MARK: - Cabin Booking

struct CabinBooking: Codable, Identifiable, Equatable {
    let id: UUID
    let cabinId: UUID
    let userId: UUID
    var requesterName: String?   // from profiles join in admin RPC; nil on direct queries
    var checkIn: String
    var checkOut: String
    var guests: Int
    var note: String?
    var status: BookingStatus
    var adminNote: String?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case cabinId = "cabin_id"
        case userId = "user_id"
        case requesterName = "requester_name"
        case checkIn = "check_in"
        case checkOut = "check_out"
        case guests
        case note = "notes"
        case status
        case adminNote = "review_note"
        case createdAt = "created_at"
    }

    // Optionally hydrated from joined rows; excluded from CodingKeys above so
    // they aren't required when decoding a bare booking row.
    var cabin: Cabin? = nil
    var bookedByName: String? = nil  // profiles!booked_by join (migration 0087)

    var checkInDate: Date? {
        isoFormatter.date(from: checkIn)
    }

    var checkOutDate: Date? {
        isoFormatter.date(from: checkOut)
    }

    var nightCount: Int {
        guard let i = checkInDate, let o = checkOutDate else { return 0 }
        return Calendar.current.dateComponents([.day], from: i, to: o).day ?? 0
    }
}

enum BookingStatus: String, Codable {
    case pending
    case approved
    case denied
    case cancelled

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .approved: return "Approved"
        case .denied: return "Denied"
        case .cancelled: return "Cancelled"
        }
    }

    var color: String {
        switch self {
        case .pending: return "amber"
        case .approved: return "green"
        case .denied: return "red"
        case .cancelled: return "gray"
        }
    }
}

private let isoFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

// MARK: - Booked room link (cabin_booking_rooms join)

/// A room a booking currently reserves (id + display name), from the
/// cabin_booking_rooms join. Used to show/edit assigned rooms.
struct BookedRoom: Identifiable, Equatable {
    let id: UUID
    let name: String
}

// MARK: - Cabin Room (migration 0092)

struct CabinRoom: Codable, Identifiable, Equatable {
    let id: UUID
    let cabinId: UUID
    var name: String
    var beds: Int
    var active: Bool
    var sortOrder: Int
    var description: String?   // migration 0094

    enum CodingKeys: String, CodingKey {
        case id
        case cabinId    = "cabin_id"
        case name, beds, active, description
        case sortOrder  = "sort_order"
    }
}

// MARK: - Cabin Room Availability (from cabin_room_availability RPC)

struct CabinRoomAvailability: Codable, Identifiable, Equatable {
    let roomId: UUID
    let name: String
    let beds: Int
    let active: Bool
    let available: Bool

    var id: UUID { roomId }

    enum CodingKeys: String, CodingKey {
        case roomId   = "room_id"
        case name, beds, active, available
    }
}
