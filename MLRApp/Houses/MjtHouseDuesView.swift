import SwiftUI
import Supabase

// MARK: - MjtHouseDuesCard
// Shown inside HouseHubView for MJT House members during the Family Fest takeover
// window (planning through TAIL_DAYS after Fest ends). Members can mark
// themselves paid (profiles.mjt_dues_paid_year, migration 0086) so the card
// stops prompting — it comes back next year since the stored year won't match.
// Mirrors web MjtHouseDuesCard.

private let MJT_DUES_TAIL_DAYS = 7

struct MjtHouseDuesCard: View {
    @Environment(AppEnvironment.self) private var env
    let house: House

    @State private var busy = false

    private var festYear: Int { FamilyFestConfig.year }
    private var isPaid: Bool { env.currentProfile?.mjtDuesPaidYear == festYear }

    private var shouldShow: Bool {
        guard house.slug == "mjt-house" else { return false }
        let season = FestSeason.current()
        return season.isTakeover && season.daysSinceEnd <= MJT_DUES_TAIL_DAYS
    }

    var body: some View {
        if shouldShow {
            if isPaid {
                paidBanner
            } else {
                duesCard
            }
        }
    }

    private var paidBanner: some View {
        HStack(spacing: 10) {
            Text("✅ MJT House dues — you're marked as paid for \(festYear).")
                .font(.mlrScaled(13))
                .foregroundStyle(Color.mlrTextMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Undo") { Task { await markPaid(nil) } }
                .font(.mlrScaled(12, weight: .medium))
                .foregroundStyle(Color.mlrTextSubtle)
                .disabled(busy)
        }
        .padding(14)
        .cardStyle()
    }

    private var duesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("🍽️ MJT House dues")
                    .font(.mlrScaled(14, weight: .bold))
                    .foregroundStyle(Color.mlrText)
                Text("We're collecting $10/day/person ($2/day for kids 6–10; kids under 5 are free) for food & household items — not pop or alcohol.")
                    .font(.mlrScaled(13))
                    .foregroundStyle(Color.mlrTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Please confirm and pay ASAP to Beth:")
                .font(.mlrScaled(13))
                .foregroundStyle(Color.mlrTextMuted)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(["How many from your family will be attending",
                         "What days you'll be there",
                         "Who, if anyone, will be tenting"], id: \.self) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").font(.mlrScaled(13)).foregroundStyle(Color.mlrTextMuted)
                        Text(item).font(.mlrScaled(13)).foregroundStyle(Color.mlrTextMuted)
                    }
                }
            }

            NavigationLink(destination: MjtHousePayView()) {
                Text("🧮 Calculate & pay")
                    .font(.mlrScaled(14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.mlrPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            Button { Task { await markPaid(festYear) } } label: {
                Text("✅ I've already paid")
                    .font(.mlrScaled(13, weight: .medium))
                    .foregroundStyle(Color.mlrPrimary)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(busy)

            Text("Or pay in cash the day you arrive.")
                .font(.mlrScaled(12))
                .foregroundStyle(Color.mlrTextSubtle)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(14)
        .cardStyle()
    }

    private func markPaid(_ year: Int?) async {
        guard let userId = await env.authService.userId else { return }
        busy = true
        defer { busy = false }
        let params: [String: AnyJSON] = [
            "mjt_dues_paid_year": year == nil ? .null : .integer(year!)
        ]
        do {
            try await supabase
                .from("profiles")
                .update(params)
                .eq("id", value: userId.uuidString)
                .execute()
            env.currentProfile?.mjtDuesPaidYear = year
        } catch {
            print("[MjtHouseDuesCard] markPaid error: \(error)")
        }
    }
}

// MARK: - MjtHousePayView
// Calculate & pay screen for MJT House dues. Uses the shared FestDuesCalculator
// with MJT-specific per-day tiers and Beth Birkholz's Venmo handle.
// Mirrors web MjtHouseDuesScreen.

struct MjtHousePayView: View {
    @State private var calcAmount = 0
    @State private var calcNote = "MJT House dues"

    private static let dues: [FestDuesTier] = [
        FestDuesTier(id: UUID(uuidString: "b0000001-0000-0000-0000-000000000001")!, label: "Adult", amount: 10, perDay: true),
        FestDuesTier(id: UUID(uuidString: "b0000001-0000-0000-0000-000000000002")!, label: "Kid (6–10)", amount: 2, perDay: true),
        FestDuesTier(id: UUID(uuidString: "b0000001-0000-0000-0000-000000000003")!, label: "Kid (under 6)", amount: nil, note: "free", perDay: true),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                duesCard
                bethSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(Color.mlrFestParchment)
        .navigationTitle("MJT House Dues")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var duesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.mlrScaled(20))
                    .foregroundStyle(Color.mlrFest)
                Text("MJT House dues")
                    .font(.festSerif(16, weight: .bold))
                    .foregroundStyle(Color.mlrFest)
            }

            FestDuesCalculator(
                dues: Self.dues,
                totalAmount: $calcAmount,
                note: $calcNote,
                noteLabel: "MJT House dues"
            )

            Text("Food & household items for the week — not pop or alcohol.")
                .font(.mlrScaled(13))
                .foregroundStyle(Color.mlrFest.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.mlrFest.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.mlrFest.opacity(0.2), lineWidth: 1.5))
        )
    }

    private var bethSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pay Beth")
                .font(.festSerif(15, weight: .bold))
                .foregroundStyle(Color.mlrFest)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Beth Birkholz")
                        .font(.mlrScaled(15, weight: .bold))
                        .foregroundStyle(Color.mlrFest)
                    Text("MJT House dues")
                        .font(.mlrScaled(12))
                        .foregroundStyle(Color.mlrFest.opacity(0.6))
                }

                venmoRow

                Text("Or pay in cash the day you arrive.")
                    .font(.mlrScaled(12))
                    .foregroundStyle(Color.mlrFest.opacity(0.6))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.mlrFestParchment)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.mlrFest.opacity(0.2), lineWidth: 1))
        }
    }

    @ViewBuilder
    private var venmoRow: some View {
        let handle = "Beth-Birkholz-1"
        let venmoURL: URL? = {
            guard calcAmount > 0 else { return URL(string: "venmo://users/\(handle)") }
            var c = URLComponents()
            c.scheme = "venmo"
            c.host = "paycharge"
            c.queryItems = [
                URLQueryItem(name: "txn", value: "pay"),
                URLQueryItem(name: "recipients", value: handle),
                URLQueryItem(name: "amount", value: String(calcAmount)),
                URLQueryItem(name: "note", value: calcNote.isEmpty ? "MJT House dues" : calcNote),
            ]
            return c.url
        }()

        HStack(spacing: 10) {
            Image(systemName: "v.circle.fill")
                .font(.mlrScaled(18))
                .foregroundStyle(Color.mlrFest)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("Venmo")
                    .font(.mlrScaled(11))
                    .foregroundStyle(Color.mlrFest.opacity(0.6))
                Text("@\(handle)")
                    .font(.mlrScaled(14, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.mlrFest)
            }
            Spacer()
            if let url = venmoURL {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.mlrScaled(15))
                        .foregroundStyle(Color.mlrFest)
                }
            }
        }
        .padding(10)
        .background(Color.mlrFest.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
