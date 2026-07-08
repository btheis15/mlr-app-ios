import AppIntents

// MARK: - Siri donations
//
// Donate the most-asked resort questions so Apple Intelligence learns to surface
// them as Siri Suggestions and predicts routines (e.g. someone who checks the
// dinner every evening during Fest). Best-effort and cheap — a failed donation
// just means no suggestion. Called once per launch from MLRApp.

enum SiriDonations {
    static func donateCommon() async {
        _ = try? await IntentDonationManager.shared.donate(intent: NextEventIntent())
        _ = try? await IntentDonationManager.shared.donate(intent: DinnerForDayIntent())
        _ = try? await IntentDonationManager.shared.donate(intent: WeatherUpNorthIntent())
        _ = try? await IntentDonationManager.shared.donate(intent: ThingsToDoUpNorthIntent())
        _ = try? await IntentDonationManager.shared.donate(intent: NextVisitUpNorthIntent())
        _ = try? await IntentDonationManager.shared.donate(intent: WhatDidIMissIntent())
    }
}
