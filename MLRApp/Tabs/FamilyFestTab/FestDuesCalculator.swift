import SwiftUI

// MARK: - FestDuesCalculator
//
// Interactive Family Fest dues table (port of web's FestDuesCalculator, #249): a
// +/- stepper per tier instead of a static price list, so paying for e.g. "2
// adults" doesn't need mental math. Every change recomputes the total and hands
// it up (dollars + a plain-English note) so the Pay screen's Venmo deep link
// stays in sync. Flat tiers just need a headcount; per-day tiers (migration
// 0078, `FestDuesTier.perDay`) also multiply by a shared "how many days" count —
// the assumption being everyone in one payment is here for the same span.

struct FestDuesCalculator: View {
    let dues: [FestDuesTier]
    @Binding var totalAmount: Int
    @Binding var note: String

    @State private var counts: [UUID: Int] = [:]
    @State private var days: Int = 1

    private var flatTiers: [FestDuesTier] { dues.filter { !$0.perDay } }
    private var dailyTiers: [FestDuesTier] { dues.filter { $0.perDay } }
    private var maxDays: Int { max(1, FestSeason.current().totalDays) }
    private var dailyHasPricing: Bool { dailyTiers.contains { $0.amount != nil } }
    private var anySelected: Bool { counts.values.contains { $0 > 0 } }

    private var total: Int {
        let flat = flatTiers.reduce(0) { $0 + (counts[$1.id] ?? 0) * ($1.amount ?? 0) }
        let daily = dailyTiers.reduce(0) { $0 + (counts[$1.id] ?? 0) * ($1.amount ?? 0) * days }
        return flat + daily
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Use +/- for how many you're paying for — the total fills in below.")
                .font(.mlrScaled(11))
                .foregroundStyle(Color.mlrFest.opacity(0.55))
                .padding(.bottom, 4)

            // Flat tiers
            ForEach(flatTiers) { tier in
                duesRow(tier)
                if tier.id != flatTiers.last?.id { divider }
            }

            // Per-day tiers, under a shared day-count stepper
            if dailyHasPricing {
                Divider().background(Color.mlrFest.opacity(0.12)).padding(.vertical, 6)
                Text("Paying by the day?")
                    .font(.mlrScaled(12, weight: .semibold))
                    .foregroundStyle(Color.mlrFest.opacity(0.7))
                Text("Only for someone not staying the whole week. Set the days once — it applies to everyone below.")
                    .font(.mlrScaled(11))
                    .foregroundStyle(Color.mlrFest.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
                HStack {
                    Text("Number of days").font(.mlrScaled(14, weight: .medium)).foregroundStyle(Color.mlrFest)
                    Spacer()
                    stepper(count: days, min: 1,
                            dec: { setDays(days - 1) }, inc: { setDays(days + 1) })
                }
                .padding(10)
                .background(Color.mlrFestParchment)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                ForEach(dailyTiers) { tier in
                    duesRow(tier, perDaySuffix: true)
                    if tier.id != dailyTiers.last?.id { divider }
                }
            }

            // Running total
            if anySelected || total > 0 {
                HStack {
                    Text("Your total").font(.mlrScaled(14, weight: .semibold)).foregroundStyle(Color.mlrFest.opacity(0.75))
                    Spacer()
                    Text("$\(total)").font(.festSerif(18, weight: .bold)).foregroundStyle(Color.mlrFest)
                }
                .padding(.horizontal, 10).padding(.vertical, 10)
                .background(Color.mlrFestParchment)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.top, 10)

                Button("Reset") { reset() }
                    .font(.mlrScaled(12, weight: .medium))
                    .foregroundStyle(Color.mlrFest.opacity(0.55))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
            }
        }
        .onChange(of: counts) { _, _ in recompute() }
        .onChange(of: days) { _, _ in recompute() }
    }

    private var divider: some View { Divider().background(Color.mlrFest.opacity(0.12)) }

    private func duesRow(_ tier: FestDuesTier, perDaySuffix: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(tier.label).font(.mlrScaled(14, weight: .semibold)).foregroundStyle(Color.mlrFest)
                if let note = tier.note, !note.isEmpty {
                    Text(note).font(.mlrScaled(11)).foregroundStyle(Color.mlrFest.opacity(0.55))
                }
                Text(tier.amount.map { "$\($0)\(perDaySuffix ? "/day" : "")" } ?? "TBD")
                    .font(.mlrScaled(12, weight: .bold))
                    .foregroundStyle(tier.amount == nil ? Color.mlrFest.opacity(0.5) : Color.mlrFest)
            }
            Spacer()
            if tier.amount != nil {
                stepper(count: counts[tier.id] ?? 0, min: 0,
                        dec: { setCount(tier, (counts[tier.id] ?? 0) - 1) },
                        inc: { setCount(tier, (counts[tier.id] ?? 0) + 1) })
            }
        }
        .padding(.vertical, 9)
    }

    private func stepper(count: Int, min: Int, dec: @escaping () -> Void, inc: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Button(action: dec) {
                Image(systemName: "minus")
                    .font(.mlrScaled(14, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(Color.mlrFestParchment)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.mlrFest.opacity(0.2)))
            }
            .buttonStyle(.plain)
            .disabled(count <= min)
            .opacity(count <= min ? 0.3 : 1)

            Text("\(count)").font(.mlrScaled(15, weight: .bold)).foregroundStyle(Color.mlrFest)
                .frame(minWidth: 16)

            Button(action: inc) {
                Image(systemName: "plus")
                    .font(.mlrScaled(14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.mlrFest)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Mutations

    private func setCount(_ tier: FestDuesTier, _ next: Int) {
        counts[tier.id] = max(0, min(99, next))
    }

    private func setDays(_ next: Int) {
        days = max(1, min(maxDays, next))
    }

    private func reset() {
        counts = [:]
        days = 1
    }

    private func recompute() {
        totalAmount = total
        let flatPicked = flatTiers.filter { (counts[$0.id] ?? 0) > 0 }
        let dailyPicked = dailyTiers.filter { (counts[$0.id] ?? 0) > 0 }
        var parts = flatPicked.map { "\(counts[$0.id] ?? 0) \($0.label)" }
        if !dailyPicked.isEmpty {
            let inner = dailyPicked.map { "\(counts[$0.id] ?? 0) \($0.label)" }.joined(separator: ", ")
            parts.append("\(days) day\(days == 1 ? "" : "s"): \(inner)")
        }
        note = parts.isEmpty ? "Family Fest" : "Family Fest — " + parts.joined(separator: "; ")
    }
}
