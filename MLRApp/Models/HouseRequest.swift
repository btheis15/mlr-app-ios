import Foundation

// MARK: - House requests (migrations 0194–0208)
//
// Three kinds of ask a member of a house can put to their House Admins:
// 💡 an idea, 🛒 "the house should buy this", 🧾 "I already paid — pay me back".
//
// ⚠️ APP ADMINS HAVE NO AUTHORITY HERE. Only that house's House Admins
// (`profiles.house_admin`) may decide a request, and only the author plus that
// house's members may see the board. When checking membership yourself, compare
// `house_id` DIRECTLY — the `is_house_member()` helper grants app admins a
// blanket pass, which would re-open cross-house reads.

enum HouseRequestKind: String, Codable, CaseIterable, Identifiable {
    case idea, purchase, reimbursement
    var id: String { rawValue }

    /// The order the chooser offers them — cheapest ask first.
    static let chooserOrder: [HouseRequestKind] = [.idea, .purchase, .reimbursement]
}

enum HouseRequestStatus: String, Codable {
    case pending, approved, denied, ordered, received, withdrawn
}

// MARK: - What a kind IS
//
// ⚠️⚠️ THIS IS THE FIX FOR THE FEATURE'S ONE REAL USABILITY FAILURE. A
// "Purchase Request" was filed and the House Admins read it as "he's buying it
// himself" — so nobody ordered anything. Nothing on any screen contradicted
// them, because every label named the PAPERWORK ("Purchase Request", "Request
// Reimbursement") instead of the DEAL ("the House Trust pays and a House Admin
// places the order"). Three tiles differing only by a noun and an emoji cannot
// teach anyone the difference.
//
// So every kind carries the deal as a sentence, and EVERY SURFACE THAT SHOWS A
// KIND SHOWS THAT SENTENCE — the chooser, the composer, the board card, the
// detail sheet. If you add a surface, show `deal` on it.

struct HouseRequestKindMeta {
    let emoji: String
    /// A plain third-person NOUN — chips, history, detail header.
    ///
    /// ⚠️ Keep it a noun that survives a possessive. The punchy requester-voice
    /// phrase ("Pay me back") reads well on a card right up until a co-admin
    /// notice says "Lee paid Brian's pay me back". The first-person ask lives in
    /// `ask`; this one has to work inside someone else's sentence.
    let label: String
    /// The ask in the REQUESTER's own voice — chooser tile headline only.
    let ask: String
    /// ⚠️ The load-bearing sentence: whose money, and who places the order.
    /// Phrased NEUTRALLY (no "you"/"your") — it renders both to the person
    /// writing the request and to everyone reading it later.
    let deal: String
    /// Two or three words naming whose money this is. Card badge.
    ///
    /// ⚠️ Must read correctly to a THIRD PARTY — most views of a request are by
    /// somebody else, so "You're owed" is wrong on a House Admin's screen.
    let money: String
    /// What the requester is on the hook for after sending. Often "nothing".
    let youDo: String
    /// What a House Admin actually does once they approve it.
    let adminDoes: String
}

extension HouseRequestKind {
    var meta: HouseRequestKindMeta {
        switch self {
        case .idea:
            return HouseRequestKindMeta(
                emoji: "💡",
                label: "Idea",
                ask: "Just an idea",
                deal: "Nobody buys anything — just a thought for the house to kick around.",
                money: "No money",
                youDo: "Write it down — that's the whole job.",
                adminDoes: "Says whether the house likes it. If it becomes a real thing to buy, that's a separate purchase request."
            )
        case .purchase:
            return HouseRequestKindMeta(
                emoji: "🛒",
                label: "Purchase request",
                ask: "The house should buy this",
                // The sentence the whole incident turned on. Keep "not the
                // person asking" in it.
                deal: "House Trust money — a House Admin places the order, not the person asking.",
                money: "House Trust pays",
                youDo: "Nothing — sit tight. If you'd rather buy it yourself, send a \u{201C}Pay me back\u{201D} instead.",
                adminDoes: "Orders it with House Trust funds, then marks it ordered here."
            )
        case .reimbursement:
            return HouseRequestKindMeta(
                emoji: "🧾",
                label: "Reimbursement",
                ask: "I already paid — pay me back",
                deal: "Already paid for out of pocket — the House Trust pays it back.",
                money: "Owed back",
                youDo: "Attach the receipt so nobody has to come asking for it.",
                adminDoes: "Approves it and sends you the money."
            )
        }
    }

    /// ⚠️ Only a REIMBURSEMENT and a PURCHASE involve money. An idea
    /// deliberately has no cost field anywhere — a price box on a "wouldn't it
    /// be nice if" is exactly the friction that stops ideas being written down,
    /// and a number on one makes it look like a proposal somebody must decide.
    var hasMoney: Bool { self != .idea }

    /// The approve/deny verbs. "Approve" is right for money and wrong for a
    /// thought — you don't *approve* an idea. Naming the follow-through in the
    /// approve verb is also the last place to tell a House Admin the ball is
    /// theirs.
    var decideLabels: (approve: String, deny: String) {
        switch self {
        case .idea:          return ("Yes — the house likes it", "Not now")
        case .purchase:      return ("Approve — I'll order it", "Turn it down")
        case .reimbursement: return ("Approve — pay them back", "Turn it down")
        }
    }
}

// MARK: - The request

struct HouseRequest: Identifiable, Equatable {
    let id: UUID
    var houseId: UUID?          // nil = resort-wide
    var createdBy: UUID
    var createdByName: String?
    var kind: HouseRequestKind
    var title: String
    var reason: String
    var links: [CalloutLink]
    var estCost: Double?
    var quantity: Int?
    var status: HouseRequestStatus
    var reviewedBy: UUID?
    var reviewedByName: String?
    var reviewedAt: Date?
    var reviewNote: String?
    var actualCost: Double?
    var orderNote: String?
    var orderedAt: Date?
    var receivedAt: Date?
    var changeNote: String?
    /// 0200 — "just test it, only notify me". Visible to its author alone.
    var testOnly: Bool
    /// 0207 — set when a purchase was converted into a reimbursement.
    var convertedFromKind: String?
    /// 0208 — a removed request leaves a 7-day tombstone before it's really gone.
    var deletedAt: Date?
    var createdAt: Date
    var media: [HouseRequestMedia]

    var isDeleted: Bool { deletedAt != nil }

    /// "So what happens next, and who does it?" — nil once nothing is owed by
    /// anyone. Deliberately names the ACTOR every time: the failure this feature
    /// exists to prevent is everyone assuming somebody else has it.
    var nextStep: String? {
        switch status {
        case .pending:
            switch kind {
            case .idea:          return "A House Admin says yes or no"
            case .purchase:      return "A House Admin decides, then orders it"
            case .reimbursement: return "A House Admin decides, then pays you back"
            }
        case .approved:
            switch kind {
            // An agreed idea is FINISHED — there's nothing to order.
            case .idea:          return nil
            case .purchase:      return "A House Admin still has to order it"
            case .reimbursement: return "Nobody has sent the money yet"
            }
        default:
            return nil
        }
    }

    /// The status label a human should read, which depends on the KIND: nothing
    /// gets "ordered" for a reimbursement (0195 rejects it outright) and its
    /// terminal state reads "Paid", not "Got it".
    var statusLabel: String {
        switch status {
        case .pending:
            return "Waiting on a House Admin"
        case .approved:
            // ⚠️ Per kind, because "approved" means three different things. An
            // IDEA is FINISHED here — the house said yes and there is nothing to
            // buy, so labelling it "not ordered yet" invents a chore nobody owes
            // and parks a permanent nag on the board.
            if kind == .idea { return "The house is up for it" }
            return kind == .reimbursement
                ? "Approved — not paid yet"
                : "Approved — nobody's ordered it yet"
        case .ordered:
            // Terminal for a purchase — there's deliberately no "it arrived" step.
            return "Ordered"
        case .received:
            // Only reachable for a reimbursement now; the other wording is kept
            // so any pre-existing row still reads sensibly.
            return kind == .reimbursement ? "Paid" : "Got it"
        case .denied:
            return "Not approved"
        case .withdrawn:
            return "Withdrawn"
        }
    }

    /// What the request actually cost, best-known: the real amount if there is
    /// one, otherwise the estimate.
    var cost: Double? { actualCost ?? estCost }

    /// ⚠️ The status ladder: `pending → approved → ordered` for a purchase;
    /// `→ received` ("Paid") for a reimbursement, which SKIPS `ordered`; and an
    /// idea ENDS at `approved`. `approved` is NOT terminal for a purchase —
    /// "approved but nobody bought it" is the exact failure this feature exists
    /// to make visible.
    var group: Group {
        if status == .pending { return .waiting }
        if status == .approved { return kind == .idea ? .done : .toDo }
        if status == .ordered { return .moving }
        return .done
    }

    enum Group: String, CaseIterable {
        case waiting, toDo, moving, done

        var title: String {
            switch self {
            case .waiting: return "Waiting on a decision"
            case .toDo:    return "Approved — still to do"
            case .moving:  return "On its way"
            case .done:    return "Finished"
            }
        }
    }

    /// A removed request is restorable for 7 days (0208).
    func tombstoneDaysLeft(now: Date = .now) -> Int {
        guard let deletedAt else { return 0 }
        let elapsed = Calendar.current.dateComponents([.day], from: deletedAt, to: now).day ?? 0
        return max(0, 7 - elapsed)
    }
}

struct HouseRequestMedia: Identifiable, Equatable {
    let id: UUID
    var storagePath: String
    var thumbnailUrl: String?
    var mediaType: String       // "image" | "video"
    var status: String          // "visible" | "pending" | "hidden"
    var uploadedBy: UUID

    var isHeld: Bool { status == "pending" }
}
