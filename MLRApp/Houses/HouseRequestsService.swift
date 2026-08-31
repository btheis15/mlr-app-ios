import Foundation
import Supabase

// MARK: - House requests service (migrations 0194–0208)
//
// Every write goes through an RPC — the table's RLS deliberately allows almost
// nothing directly, because the authority rules ("only THIS house's House
// Admins", "only the requester may convert to a reimbursement") are the point of
// the feature and belong in one place on the server.
//
// ⚠️ Supabase keys RPC arguments BY NAME. A wrong `p_` key fails at runtime with
// an unhelpful error, not a compile error. Every param struct below matches the
// migration exactly. Note `set_house_admin` is the one that is NOT `p_`-prefixed.

@Observable
@MainActor
final class HouseRequestsService {

    /// Requests for the house currently on screen. Newest first.
    var requests: [HouseRequest] = []
    /// Removed-but-restorable rows (0208's 7-day tombstone), reviewers only.
    var tombstones: [HouseRequest] = []
    /// True when the signed-in member may decide requests for the loaded house.
    var canReview = false
    /// The House Admins who would actually be notified, by display name.
    ///
    /// ⚠️ Shown BEFORE anything sends. A house with no House Admin notifies
    /// NOBODY, and that has to be said loudly rather than discovered later.
    var approverNames: [String] = []
    var loading = false
    var loadError: String?

    private var loadedHouseId: UUID?

    // MARK: - Reading

    /// ⚠️ Uses a COLUMN-GROUP LADDER. An unknown column fails the whole select
    /// with `42703` and renders an empty board — which then reads as "the
    /// migration is missing" when actually only one late column is. Falling back
    /// to the older column set keeps the board working on a partly-migrated DB.
    private static let baseColumns = """
        id, house_id, created_by, kind, title, reason, links, est_cost, quantity, status,
        reviewed_by, reviewed_at, review_note, actual_cost, order_note, ordered_at,
        received_at, change_note, created_at,
        author:created_by(display_name),
        reviewer:reviewed_by(display_name),
        house_request_media(id, storage_path, thumbnail_url, media_type, status, uploaded_by, position)
        """

    /// …plus the columns added after 0195: test rows (0200), the buy-it-myself
    /// conversion (0207) and the soft-delete tombstone (0208).
    private static let fullColumns = baseColumns + ", test_only, converted_from_kind, deleted_at"

    func load(houseId: UUID?, force: Bool = false) async {
        if !force, loadedHouseId == houseId, !requests.isEmpty { return }
        loading = true
        defer { loading = false }
        loadedHouseId = houseId

        var rows = await fetchRows(houseId: houseId, columns: Self.fullColumns)
        if rows == nil {
            rows = await fetchRows(houseId: houseId, columns: Self.baseColumns)
        }
        guard let rows else {
            // ⚠️ A read that failed must not look like "nothing here yet".
            loadError = "Couldn't load the requests board."
            return
        }
        loadError = nil

        let all = rows.map(\.toRequest)
        requests = all.filter { !$0.isDeleted }
        tombstones = all.filter(\.isDeleted)

        await loadApprovers(houseId: houseId)
    }

    private func fetchRows(houseId: UUID?, columns: String) async -> [RequestRow]? {
        do {
            var query = supabase.from("house_requests").select(columns)
            if let houseId {
                query = query.eq("house_id", value: houseId.uuidString)
            } else {
                query = query.is("house_id", value: nil)
            }
            return try await query.order("created_at", ascending: false).execute().value
        } catch {
            print("[HouseRequestsService] fetch error: \(error)")
            return nil
        }
    }

    /// Who a notification would actually reach.
    ///
    /// ⚠️ Reads `profiles.house_admin` for that house — the SAME predicate the
    /// server's fan-out uses, so the list shown can't disagree with the list
    /// mailed. Resort-wide requests fall to app admins, matching
    /// `can_review_house_request(null)`.
    private func loadApprovers(houseId: UUID?) async {
        struct Row: Decodable { let id: UUID; let displayName: String?
            enum CodingKeys: String, CodingKey { case id; case displayName = "display_name" } }
        do {
            var query = supabase.from("profiles").select("id, display_name")
            if let houseId {
                query = query.eq("house_id", value: houseId.uuidString).eq("house_admin", value: true)
            } else {
                query = query.eq("is_admin", value: true)
            }
            let rows: [Row] = try await query.execute().value
            approverNames = rows.compactMap { $0.displayName }.sorted()
            let me = supabase.auth.currentUser?.id
            canReview = me.map { uid in rows.contains { $0.id == uid } } ?? false
        } catch {
            // `house_admin` may not exist on a partly-migrated DB. Treat as "no
            // approvers known" rather than failing the whole board.
            approverNames = []
            canReview = false
        }
    }

    // MARK: - Writing

    @discardableResult
    func create(houseId: UUID?, kind: HouseRequestKind, title: String,
                reason: String = "", links: [CalloutLink] = [],
                estCost: Double? = nil, quantity: Int? = nil,
                testOnly: Bool = false) async throws -> UUID {
        struct P: Encodable {
            let p_house_id: String?
            let p_kind: String
            let p_title: String
            let p_reason: String
            let p_links: [LinkPayload]
            let p_est_cost: Double?
            let p_quantity: Int?
            let p_test_only: Bool
        }
        let id: UUID = try await supabase.rpc("create_house_request", params: P(
            p_house_id: houseId?.uuidString,
            p_kind: kind.rawValue,
            p_title: title,
            p_reason: reason,
            p_links: links.map { LinkPayload(href: $0.href, label: $0.label) },
            // ⚠️ An idea never carries a cost — see HouseRequestKind.hasMoney.
            p_est_cost: kind.hasMoney ? estCost : nil,
            p_quantity: kind.hasMoney ? quantity : nil,
            p_test_only: testOnly
        )).execute().value
        return id
    }

    func review(id: UUID, approve: Bool, note: String? = nil, notify: Bool = true) async throws {
        struct P: Encodable { let p_id: String; let p_approve: Bool; let p_note: String?; let p_notify: Bool }
        try await supabase.rpc("review_house_request",
                               params: P(p_id: id.uuidString, p_approve: approve,
                                         p_note: note, p_notify: notify)).execute()
    }

    func update(id: UUID, title: String? = nil, reason: String? = nil,
                links: [CalloutLink]? = nil, estCost: Double? = nil, quantity: Int? = nil,
                clearCost: Bool = false, clearQuantity: Bool = false,
                note: String? = nil, notify: Bool = true) async throws {
        struct P: Encodable {
            let p_id: String
            let p_title: String?
            let p_reason: String?
            let p_links: [LinkPayload]?
            let p_est_cost: Double?
            let p_quantity: Int?
            let p_clear_cost: Bool
            let p_clear_quantity: Bool
            let p_note: String?
            let p_notify: Bool
        }
        try await supabase.rpc("update_house_request", params: P(
            p_id: id.uuidString, p_title: title, p_reason: reason,
            p_links: links?.map { LinkPayload(href: $0.href, label: $0.label) },
            p_est_cost: estCost, p_quantity: quantity,
            p_clear_cost: clearCost, p_clear_quantity: clearQuantity,
            p_note: note, p_notify: notify
        )).execute()
    }

    /// Move a request along the ladder — `ordered` for a purchase, `received`
    /// ("Paid") for a reimbursement.
    func setProgress(id: UUID, status: HouseRequestStatus,
                     actualCost: Double? = nil, orderNote: String? = nil) async throws {
        struct P: Encodable {
            let p_id: String; let p_status: String
            let p_actual_cost: Double?; let p_order_note: String?
        }
        try await supabase.rpc("set_house_request_progress", params: P(
            p_id: id.uuidString, p_status: status.rawValue,
            p_actual_cost: actualCost, p_order_note: orderNote
        )).execute()
    }

    /// "I bought it myself — pay me back" (0207).
    ///
    /// ⚠️ REQUESTER-ONLY, enforced server-side. A reimbursement pays
    /// `created_by`, so anyone else converting would route the money to whoever
    /// ASKED rather than whoever PAID.
    ///
    /// Returns the resulting status so the caller can say what happened —
    /// a big enough jump in cost sends it back for re-approval.
    @discardableResult
    func convertToReimbursement(id: UUID, actualCost: Double,
                                note: String? = nil, title: String? = nil,
                                links: [CalloutLink]? = nil) async throws -> String {
        struct P: Encodable {
            let p_id: String; let p_actual_cost: Double
            let p_note: String?; let p_title: String?; let p_links: [LinkPayload]?
        }
        let status: String = try await supabase.rpc("convert_request_to_reimbursement", params: P(
            p_id: id.uuidString, p_actual_cost: actualCost, p_note: note, p_title: title,
            p_links: links?.map { LinkPayload(href: $0.href, label: $0.label) }
        )).execute().value
        return status
    }

    func withdraw(id: UUID) async throws {
        struct P: Encodable { let p_id: String }
        try await supabase.rpc("withdraw_house_request", params: P(p_id: id.uuidString)).execute()
    }

    /// Soft-delete — leaves a 7-day tombstone (0208) rather than vanishing.
    func delete(id: UUID) async throws {
        struct P: Encodable { let p_id: String }
        try await supabase.rpc("delete_house_request", params: P(p_id: id.uuidString)).execute()
    }

    func restore(id: UUID) async throws {
        struct P: Encodable { let p_id: String }
        try await supabase.rpc("restore_house_request", params: P(p_id: id.uuidString)).execute()
    }

    @discardableResult
    func addMedia(requestId: UUID, url: String, type: String = "image",
                  thumbnailUrl: String? = nil, position: Int = 0) async throws -> UUID {
        struct P: Encodable {
            let p_request: String; let p_url: String; let p_type: String
            let p_thumbnail_url: String?; let p_position: Int
        }
        let id: UUID = try await supabase.rpc("add_house_request_media", params: P(
            p_request: requestId.uuidString, p_url: url, p_type: type,
            p_thumbnail_url: thumbnailUrl, p_position: position
        )).execute().value
        return id
    }

    func removeMedia(mediaId: UUID) async throws {
        struct P: Encodable { let p_media: String }
        try await supabase.rpc("remove_house_request_media", params: P(p_media: mediaId.uuidString)).execute()
    }

    /// Promote/demote a House Admin (0194).
    ///
    /// ⚠️ The argument names are `target` and `value` — deliberately NOT
    /// `p_`-prefixed, unlike every other RPC here. Supabase keys arguments by
    /// name, so `p_target` fails at runtime with an unhelpful error.
    ///
    /// ⚠️ Only an app admin who is THEMSELVES IN THAT HOUSE may appoint one, and
    /// changing someone's house clears the flag. Both are enforced server-side.
    func setHouseAdmin(target: UUID, value: Bool) async throws {
        struct P: Encodable { let target: String; let value: Bool }
        try await supabase.rpc("set_house_admin", params: P(target: target.uuidString, value: value)).execute()
    }
}

// MARK: - Wire types

private struct LinkPayload: Encodable {
    let href: String
    let label: String?
}

/// ⚠️ `numeric` comes back from PostgREST as a STRING, not a number. Decoding it
/// as `Double` throws, and treating it as text makes every cost total string
/// concatenation. Accept both shapes.
private func decodeNumeric(_ c: KeyedDecodingContainer<RequestRow.CodingKeys>,
                           _ key: RequestRow.CodingKeys) -> Double? {
    if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return d }
    if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Double(s) }
    return nil
}

private struct RequestRow: Decodable {
    let id: UUID
    let houseId: UUID?
    let createdBy: UUID
    let kind: String
    let title: String
    let reason: String?
    let links: [LinkRow]?
    let estCost: Double?
    let quantity: Int?
    let status: String
    let reviewedBy: UUID?
    let reviewedAt: Date?
    let reviewNote: String?
    let actualCost: Double?
    let orderNote: String?
    let orderedAt: Date?
    let receivedAt: Date?
    let changeNote: String?
    let testOnly: Bool?
    let convertedFromKind: String?
    let deletedAt: Date?
    let createdAt: Date
    let author: NameRow?
    let reviewer: NameRow?
    let media: [MediaRow]?

    struct NameRow: Decodable {
        let displayName: String?
        enum CodingKeys: String, CodingKey { case displayName = "display_name" }
    }
    struct LinkRow: Decodable { let href: String; let label: String? }
    struct MediaRow: Decodable {
        let id: UUID
        let storagePath: String
        let thumbnailUrl: String?
        let mediaType: String?
        let status: String?
        let uploadedBy: UUID
        enum CodingKeys: String, CodingKey {
            case id, status
            case storagePath = "storage_path"
            case thumbnailUrl = "thumbnail_url"
            case mediaType = "media_type"
            case uploadedBy = "uploaded_by"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, reason, links, quantity, status, author, reviewer
        case houseId = "house_id"
        case createdBy = "created_by"
        case estCost = "est_cost"
        case reviewedBy = "reviewed_by"
        case reviewedAt = "reviewed_at"
        case reviewNote = "review_note"
        case actualCost = "actual_cost"
        case orderNote = "order_note"
        case orderedAt = "ordered_at"
        case receivedAt = "received_at"
        case changeNote = "change_note"
        case testOnly = "test_only"
        case convertedFromKind = "converted_from_kind"
        case deletedAt = "deleted_at"
        case createdAt = "created_at"
        case media = "house_request_media"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        houseId = try c.decodeIfPresent(UUID.self, forKey: .houseId)
        createdBy = try c.decode(UUID.self, forKey: .createdBy)
        kind = try c.decode(String.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        links = try c.decodeIfPresent([LinkRow].self, forKey: .links)
        quantity = try c.decodeIfPresent(Int.self, forKey: .quantity)
        status = try c.decode(String.self, forKey: .status)
        reviewedBy = try c.decodeIfPresent(UUID.self, forKey: .reviewedBy)
        reviewedAt = try c.decodeIfPresent(Date.self, forKey: .reviewedAt)
        reviewNote = try c.decodeIfPresent(String.self, forKey: .reviewNote)
        orderNote = try c.decodeIfPresent(String.self, forKey: .orderNote)
        orderedAt = try c.decodeIfPresent(Date.self, forKey: .orderedAt)
        receivedAt = try c.decodeIfPresent(Date.self, forKey: .receivedAt)
        changeNote = try c.decodeIfPresent(String.self, forKey: .changeNote)
        testOnly = try c.decodeIfPresent(Bool.self, forKey: .testOnly)
        convertedFromKind = try c.decodeIfPresent(String.self, forKey: .convertedFromKind)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        author = try c.decodeIfPresent(NameRow.self, forKey: .author)
        reviewer = try c.decodeIfPresent(NameRow.self, forKey: .reviewer)
        media = try c.decodeIfPresent([MediaRow].self, forKey: .media)
        estCost = decodeNumeric(c, .estCost)
        actualCost = decodeNumeric(c, .actualCost)
    }

    var toRequest: HouseRequest {
        HouseRequest(
            id: id,
            houseId: houseId,
            createdBy: createdBy,
            createdByName: author?.displayName,
            // An unrecognised kind degrades to `idea` — the one that promises
            // nothing — rather than dropping the row off the board entirely.
            kind: HouseRequestKind(rawValue: kind) ?? .idea,
            title: title,
            reason: reason ?? "",
            links: (links ?? []).map { CalloutLink(href: $0.href, label: $0.label ?? $0.href) },
            estCost: estCost,
            quantity: quantity,
            status: HouseRequestStatus(rawValue: status) ?? .pending,
            reviewedBy: reviewedBy,
            reviewedByName: reviewer?.displayName,
            reviewedAt: reviewedAt,
            reviewNote: reviewNote,
            actualCost: actualCost,
            orderNote: orderNote,
            orderedAt: orderedAt,
            receivedAt: receivedAt,
            changeNote: changeNote,
            testOnly: testOnly ?? false,
            convertedFromKind: convertedFromKind,
            deletedAt: deletedAt,
            createdAt: createdAt,
            media: (media ?? []).map {
                HouseRequestMedia(
                    id: $0.id,
                    storagePath: $0.storagePath,
                    thumbnailUrl: $0.thumbnailUrl,
                    mediaType: $0.mediaType ?? "image",
                    status: $0.status ?? "visible",
                    uploadedBy: $0.uploadedBy
                )
            }
        )
    }
}
