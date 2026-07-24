import SwiftUI

// MARK: - TeeTimesView
//
// Tee Times — a clean hand-off to foreUP for Inshalla Country Club (mirrors the
// web TeeTimesView). We deliberately don't fetch foreUP's API or scrape its HTML
// (their terms prohibit it); instead quick-pick day chips deep-link straight
// into the Daily Golf class for that day, with call + Daily Deals alongside.

struct TeeTimesView: View {
    private static let courseId = 19715
    private static let scheduleId = 2251
    /// "Daily Golf" booking class — pre-selected so foreUP skips its chooser.
    private static let dailyGolfClassId = 2431
    private static let foreUpBase = "https://stage.foreupsoftware.com/index.php/booking/\(courseId)/\(scheduleId)"

    private static let phoneDisplay = "(715) 453-3130"
    private static let phoneTel = "+17154533130"

    /// Sagacity Golf's "Daily Deals" page for Inshalla (an explicit partner-embed
    /// product on web; opened as a page here).
    private static let dailyDealsUrl = "https://inshalla.dailydeals.golf/widget/layout/2/times?utm_source=mlr-app&utm_medium=tee-times&utm_campaign=daily-deals"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Quick book — today / tomorrow / day after.
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "Quick book")
                    HStack(spacing: 8) {
                        dayChip(offset: 0, label: "Today")
                        dayChip(offset: 1, label: "Tomorrow")
                        dayChip(offset: 2, label: weekdayName(offset: 2))
                    }
                    if let url = URL(string: Self.foreUpBase + "?booking_class_id=\(Self.dailyGolfClassId)&schedule_id=\(Self.scheduleId)#/teetimes") {
                        Link(destination: url) {
                            Label("View all available times", systemImage: "arrow.up.right.square")
                                .font(.mlrScaled(14, weight: .semibold))
                                .foregroundStyle(Color.mlrPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.mlrPrimary.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    if let url = URL(string: "tel:\(Self.phoneTel)") {
                        Link(destination: url) {
                            HStack {
                                Label("Call pro shop", systemImage: "phone.fill")
                                    .font(.mlrScaled(14, weight: .semibold))
                                Spacer()
                                Text(Self.phoneDisplay)
                                    .font(.mlrScaled(13))
                                    .foregroundStyle(Color.mlrTextMuted)
                            }
                            .foregroundStyle(Color.mlrPrimary)
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .background(Color.mlrCard)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }

                // Daily Deals (Sagacity)
                if let url = URL(string: Self.dailyDealsUrl) {
                    Link(destination: url) {
                        VStack(alignment: .leading, spacing: 3) {
                            Label("Daily Deals", systemImage: "tag.fill")
                                .font(.mlrScaled(15, weight: .semibold))
                            Text("Discounted Inshalla tee times via Sagacity Golf")
                                .font(.mlrScaled(12))
                                .foregroundStyle(Color.mlrTextMuted)
                        }
                        .foregroundStyle(Color.mlrPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color.mlrCard)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }

                Text("Tee times, pricing, and booking are managed by Inshalla Country Club via foreUP. Tapping a day opens foreUP's secure booking page pre-filtered to that day — your tee time, account, and payment all live there. Or call to book by phone.")
                    .font(.mlrScaled(12))
                    .foregroundStyle(Color.mlrTextSubtle)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Tee Times")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Helpers

    @ViewBuilder
    private func dayChip(offset: Int, label: String) -> some View {
        if let url = URL(string: foreUpUrl(offset: offset)) {
            Link(destination: url) {
                VStack(spacing: 2) {
                    Text(label).font(.mlrScaled(14, weight: .semibold))
                    Text(shortDate(offset: offset)).font(.mlrScaled(11)).foregroundStyle(Color.mlrTextMuted)
                }
                .foregroundStyle(Color.mlrPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.mlrCard)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    /// foreUP deep link for a given day — date format MM-DD-YYYY (their convention).
    private func foreUpUrl(offset: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        let f = DateFormatter()
        f.dateFormat = "MM-dd-yyyy"
        return Self.foreUpBase + "?booking_class_id=\(Self.dailyGolfClassId)&schedule_id=\(Self.scheduleId)&date=\(f.string(from: date))#/teetimes"
    }

    private func weekdayName(offset: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        let f = DateFormatter(); f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    private func shortDate(offset: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}
