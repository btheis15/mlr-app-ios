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

    enum CodingKeys: String, CodingKey {
        case id, slug, name, description
        case roomCount = "room_count"
        case maxGuests = "max_guests"
        case imageUrl = "image_url"
        case sortOrder = "sort_order"
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

    // Optionally hydrated from a joined `cabins` row; excluded from CodingKeys
    // above so it isn't required when decoding a bare booking row.
    var cabin: Cabin? = nil

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
