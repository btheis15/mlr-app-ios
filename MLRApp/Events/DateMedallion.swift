import SwiftUI

// MARK: - DateMedallion (UI/UX overhaul Phase 5)
//
// A bold day/month medallion in a kind-tinted gradient square — the calendar
// "date block" anchor on event cards and the event hero.

struct DateMedallion: View {
    /// ISO yyyy-MM-dd (the event's start date).
    let isoDate: String
    var tint: Color = .mlrPrimary
    var size: CGFloat = 52

    private var parts: (day: String, month: String)? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "America/Chicago")
        guard let date = f.date(from: isoDate) else { return nil }
        let dayF = DateFormatter(); dayF.dateFormat = "d"
        let monF = DateFormatter(); monF.dateFormat = "MMM"
        return (dayF.string(from: date), monF.string(from: date).uppercased())
    }

    var body: some View {
        if let parts {
            VStack(spacing: 0) {
                Text(parts.month)
                    .font(.system(size: size * 0.22, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.9))
                Text(parts.day)
                    .font(.system(size: size * 0.44, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [tint, tint.opacity(0.75)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24))
            .shadow(.low)
            .accessibilityHidden(true)   // date is always shown as text alongside
        }
    }
}
