import SwiftUI

// MARK: - FestPayView
// Family Fest dues + who to pay — driven by the editable DB content
// (FestContentService): a set of dues tiers (Adult / Kid / per-day / without
// food, etc., each amount TBD until set) and the list of payees with their
// handles. Edited in the Family Fest Planner; shown identically on web + iOS.

struct FestPayView: View {
    @Environment(AppEnvironment.self) private var env

    private var dues: [FestDuesTier] { env.festContentService.dues }
    private var payees: [Payee] { env.festContentService.payees }

    // Running total + note from the dues calculator, fed into each payee's Venmo
    // deep link so the amount and memo are pre-filled (#249).
    @State private var calcAmount = 0
    @State private var calcNote = "Family Fest"

    var body: some View {
        if !env.isSignedIn {
            FestSignInNotice(message: "Sign in to see dues and payment details.")
        } else {
            payContent
        }
    }

    private var payContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                duesCard
                if !payees.isEmpty {
                    payeesSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(Color.mlrFestParchment)
    }

    // MARK: - Dues

    private var duesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.mlrScaled(20))
                    .foregroundStyle(Color.mlrFest)
                Text("Household Dues")
                    .font(.festSerif(16, weight: .bold))
                    .foregroundStyle(Color.mlrFest)
            }

            if dues.isEmpty {
                Text("Dues amounts are still being set — check back soon.")
                    .font(.mlrScaled(13))
                    .foregroundStyle(Color.mlrFest.opacity(0.65))
            } else {
                FestDuesCalculator(dues: dues, totalAmount: $calcAmount, note: $calcNote)
            }

            Text("Dues cover shared meals, activities, and resort costs for the week. Note \u{201C}Family Fest 2026\u{201D} with your payment.")
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

    // MARK: - Payees

    private var payeesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Who to pay")
                .font(.festSerif(15, weight: .bold))
                .foregroundStyle(Color.mlrFest)
            ForEach(payees) { payee in
                PayeeCard(payee: payee, calcAmount: calcAmount, calcNote: calcNote)
            }
        }
    }
}

// MARK: - Payee Card

private struct PayeeCard: View {
    let payee: Payee
    // Total + note from the dues calculator — pre-fill the Venmo deep link when set.
    var calcAmount: Int = 0
    var calcNote: String = ""
    @State private var copied: String?

    /// Venmo deep link: a full pre-filled charge (amount + memo) once the
    /// calculator has a total, otherwise just open the payee's profile.
    private func venmoURL(handle: String) -> URL? {
        guard calcAmount > 0 else { return URL(string: "venmo://users/\(handle)") }
        var c = URLComponents()
        c.scheme = "venmo"
        c.host = "paycharge"
        c.queryItems = [
            URLQueryItem(name: "txn", value: "pay"),
            URLQueryItem(name: "recipients", value: handle),
            URLQueryItem(name: "amount", value: String(calcAmount)),
            URLQueryItem(name: "note", value: calcNote.isEmpty ? "Family Fest 2026" : calcNote),
        ]
        return c.url
    }
    // Apple Cash handoff: amount the payer chooses + the Messages composer.
    @State private var appleCashAmount = ""
    @State private var askAmount = false
    @State private var showComposer = false

    /// Apple Cash sends over iMessage, so it needs a phone or email recipient —
    /// a bare $cashtag can't be messaged. nil ⇒ hide the native pay button.
    private var appleCashHandle: String? {
        guard let cash = payee.appleCash?.trimmedNonEmpty else { return nil }
        let contactable = cash.contains("@") || cash.contains(where: { $0.isNumber })
        return contactable ? cash : nil
    }

    private var appleCashMessageBody: String {
        let amt = appleCashAmount.trimmingCharacters(in: .whitespaces)
        let amountPart = amt.isEmpty ? "" : " \(amt.hasPrefix("$") ? amt : "$\(amt)")"
        return "Family Fest 2026 — sending\(amountPart) via Apple Cash 🌲"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(payee.name)
                    .font(.mlrScaled(15, weight: .bold))
                    .foregroundStyle(Color.mlrFest)
                if let role = payee.role, !role.isEmpty {
                    Text(role)
                        .font(.mlrScaled(12))
                        .foregroundStyle(Color.mlrFest.opacity(0.6))
                }
                if let amount = payee.amount {
                    Text("$\(amount)")
                        .font(.festSerif(15, weight: .bold))
                        .foregroundStyle(Color.mlrFest)
                }
            }

            if let venmo = payee.venmo?.trimmedNonEmpty {
                let handle = venmo.replacingOccurrences(of: "@", with: "")
                handleRow(label: "Venmo", value: "@\(handle)", icon: "v.circle.fill",
                          openURL: venmoURL(handle: handle))
            }
            if let zelle = payee.zelle?.trimmedNonEmpty {
                handleRow(label: "Zelle", value: zelle, icon: "z.circle.fill", openURL: nil)
            }
            if let cash = payee.appleCash?.trimmedNonEmpty {
                handleRow(label: "Apple Cash", value: cash, icon: "applelogo", openURL: nil)
                if appleCashHandle != nil, MessageComposeView.canSend {
                    Button {
                        appleCashAmount = payee.amount.map(String.init) ?? ""
                        askAmount = true
                    } label: {
                        Label("Pay with Apple Cash", systemImage: "applelogo")
                            .font(.mlrScaled(14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            if let paypal = payee.paypal?.trimmedNonEmpty {
                handleRow(label: "PayPal", value: paypal, icon: "p.circle.fill",
                          openURL: URL(string: "https://www.paypal.com/paypalme/\(paypal.replacingOccurrences(of: "@", with: ""))"))
            }
            if let note = payee.note?.trimmedNonEmpty {
                Text(note)
                    .font(.mlrScaled(12))
                    .foregroundStyle(Color.mlrFest.opacity(0.6))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mlrFestParchment)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.mlrFest.opacity(0.2), lineWidth: 1))
        .alert("Pay \(payee.name)", isPresented: $askAmount) {
            TextField("Amount (optional)", text: $appleCashAmount)
                .keyboardType(.decimalPad)
            Button("Continue") { showComposer = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Apple Cash has no send-money API — the amount is attached in
            // Messages (tap ⊕ → Apple Cash); we pre-fill the note for them.
            Text("Opens Messages to \(payee.name). Tap the ⊕ in Messages, then Apple Cash, to send the amount.")
        }
        .sheet(isPresented: $showComposer) {
            if let handle = appleCashHandle {
                MessageComposeView(recipients: [handle], body: appleCashMessageBody)
                    .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder
    private func handleRow(label: String, value: String, icon: String, openURL: URL?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.mlrScaled(18))
                .foregroundStyle(Color.mlrFest)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.mlrScaled(11))
                    .foregroundStyle(Color.mlrFest.opacity(0.6))
                Text(value)
                    .font(.mlrScaled(14, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.mlrFest)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                UIPasteboard.general.string = value
                copied = label
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == label { copied = nil } }
            } label: {
                Image(systemName: copied == label ? "checkmark" : "doc.on.doc")
                    .font(.mlrScaled(13, weight: .semibold))
                    .foregroundStyle(copied == label ? Color.mlrSuccess : Color.mlrFest.opacity(0.7))
            }
            .buttonStyle(.plain)
            if let openURL {
                Link(destination: openURL) {
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

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
