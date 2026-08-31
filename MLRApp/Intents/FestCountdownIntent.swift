import AppIntents
import SwiftUI

// MARK: - Family Fest Countdown Intent
//
// "Hey Siri, how many days until Family Fest?" — computes the phase locally from
// the fest window the app cached in the App Group, no network needed.

struct FestCountdownIntent: AppIntent {
    static var title: LocalizedStringResource = "Family Fest Countdown"
    static var description = IntentDescription("Tells you how long until Family Fest.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let season = FestSeason.current()
        let spoken: String
        let headline: String

        switch season.phase {
        case .live:
            let day = season.dayNumber ?? 1
            spoken = "Family Fest is happening now — it's day \(day) of \(season.totalDays)."
            headline = "Day \(day) of \(season.totalDays)"
        case .wrap:
            spoken = "Family Fest just wrapped. Don't forget to post your photos!"
            headline = "Just wrapped 📸"
        case .concluded:
            // ⚠️ This branch must come BEFORE anything that reads
            // `daysUntilStart`. That value clamps to zero, and the countdown
            // branch below reads zero as "it's starting today" — so for three
            // weeks after the fest ended, Siri cheerfully answered "Family Fest
            // starts today!". A finished fest has to say it finished.
            spoken = "Family Fest \(FamilyFestConfig.year) is over. Thanks for a great one — see you next year!"
            headline = "See you next year"
        case .planning, .offSeason:
            let days = season.daysUntilStart
            if days == 1 {
                spoken = "Family Fest starts tomorrow!"
                headline = "Tomorrow"
            } else {
                spoken = "Family Fest is \(days) days away."
                headline = "\(days) days"
            }
        }

        return .result(
            dialog: IntentDialog(stringLiteral: spoken),
            view: IntentEventSnippet(title: "Family Fest \(String(FamilyFestConfig.year))",
                                     dateLabel: headline, emoji: "🌲")
        )
    }
}
