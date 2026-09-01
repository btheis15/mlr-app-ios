import Foundation

// MARK: - Family Fest Config
// Lives here (not SeedData) so it's lightweight to share with the widget/Live
// Activity target without dragging in the whole model layer.
//
// ⚠️ The window is RESOLVED FROM `fest_config`, not compiled in. The static
// values below are an offline fallback for a cold launch that has never reached
// the network. They were once the source of truth and they went stale — they
// said 2026-07-27 → 07-31 while the database said 2026-07-26 → 08-01, so during
// the actual fest week the app said "Day n of 5" instead of "of 7", and on
// Aug 1 — the real final day — it had already flipped to "wrap".
//
// `FestContentService` publishes the resolved window into the App Group on every
// load; everything here reads that first.

struct FamilyFestConfig {
    /// Offline fallback only — see the warning above. Never treat as truth.
    static let fallbackStartDate = "2026-07-26"
    static let fallbackEndDate   = "2026-08-01"
    static let fallbackYear      = 2026

    /// The window the app last resolved from `fest_config`, if any.
    static var resolved: FestWindowSnapshot? { SharedStore.shared.festWindow }

    static var startDate: String { resolved?.startDate ?? fallbackStartDate }
    static var endDate:   String { resolved?.endDate   ?? fallbackEndDate }
    static var year:      Int    { resolved?.year      ?? fallbackYear }

    /// The synthesized calendar event id for the current fest year.
    /// ⚠️ Derived from `year`, not a literal — a hardcoded "family-fest-2026"
    /// would keep pointing at last year's event once a new year is seeded.
    static var id: String { "family-fest-\(year)" }

    static var theme: String? { resolved?.theme }
    static var coverUrl: String? { resolved?.coverUrl }

    // "July 26 – August 1" — auto-derived so the poster card never gets stale.
    static var dateRangeLabel: String {
        Self.rangeLabel(start: startDate, end: endDate)
    }

    /// Shared so the Past Years archive can label a year that isn't the current one.
    static func rangeLabel(start: String, end: String) -> String {
        guard let s = festISOFormatter.date(from: start),
              let e = festISOFormatter.date(from: end) else { return "\(start) – \(end)" }
        let monthFmt = DateFormatter()
        monthFmt.dateFormat = "MMMM"
        monthFmt.locale = Locale(identifier: "en_US_POSIX")
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "d"
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        let sMonth = monthFmt.string(from: s)
        let eMonth = monthFmt.string(from: e)
        // A window that crosses a month boundary needs both month names, or
        // "July 26 – 1" reads as a range that runs backwards. The 2026 fest is
        // exactly such a week (Jul 26 – Aug 1).
        if sMonth == eMonth {
            return "\(sMonth) \(dayFmt.string(from: s)) – \(dayFmt.string(from: e))"
        }
        return "\(sMonth) \(dayFmt.string(from: s)) – \(eMonth) \(dayFmt.string(from: e))"
    }
}

// MARK: - Fest Season
// Port of lib/festSeason.ts — keep in sync with the web app's version.

enum FestPhase: String, Equatable {
    case offSeason   = "off-season"
    case planning
    case live
    case wrap
    /// This year's fest is history: the window is behind us and the 14-day
    /// photo-posting tail has closed.
    ///
    /// ⚠️ `offSeason` and `concluded` are both quiet but they are NOT the same
    /// thing and must never be collapsed back together. `offSeason` means the
    /// window is still AHEAD. Sharing one phase is the original bug — a finished
    /// fest rendered as a countdown, which clamps to zero and reads as "starting
    /// today", so it advertised itself as live indefinitely.
    case concluded
}

struct FestSeason: Equatable {
    let phase: FestPhase
    let isLive: Bool
    let isPlanning: Bool
    let isWrap: Bool
    let isConcluded: Bool
    let isTakeover: Bool
    let daysUntilStart: Int
    let isSoon: Bool
    let dayNumber: Int?
    let totalDays: Int
    let daysSinceEnd: Int
    let wrapDaysLeft: Int

    static let planningLeadDays = 60
    static let wrapTailDays     = 14
    static let soonThresholdDays = 7

    static func compute(startISO: String, endISO: String, now: Date = .now) -> FestSeason {
        // Empty/malformed dates degrade to the quiet, claim-nothing off-season.
        // Callers render before their dates resolve, and now that the final
        // branch means something specific ("concluded"), falling through to it
        // would report a fest with no dates at all as finished.
        guard
            let start = festISOFormatter.date(from: startISO),
            let end   = festISOFormatter.date(from: endISO)
        else {
            return offSeason()
        }

        let cal = Calendar.current
        let today = cal.startOfDay(for: now)

        let daysToStart  = cal.dateComponents([.day], from: today, to: cal.startOfDay(for: start)).day ?? 0
        let daysAfterEnd = cal.dateComponents([.day], from: cal.startOfDay(for: end), to: today).day ?? 0
        let totalDays    = (cal.dateComponents([.day], from: cal.startOfDay(for: start),
                                               to: cal.startOfDay(for: end)).day ?? 0) + 1

        let phase: FestPhase
        if daysToStart > 0 {
            phase = daysToStart <= planningLeadDays ? .planning : .offSeason
        } else if daysAfterEnd <= 0 {
            phase = .live
        } else {
            phase = daysAfterEnd <= wrapTailDays ? .wrap : .concluded
        }

        let isLive      = phase == .live
        let isPlanning  = phase == .planning
        let isWrap      = phase == .wrap
        let isConcluded = phase == .concluded

        let dayNumber: Int? = isLive ? max(0, -daysToStart) + 1 : nil
        let daysUntilStart = max(0, daysToStart)

        return FestSeason(
            phase: phase,
            isLive: isLive,
            isPlanning: isPlanning,
            isWrap: isWrap,
            isConcluded: isConcluded,
            // Spelled out as the three loud phases rather than `phase != .offSeason`:
            // that negation would start counting a finished fest as a takeover.
            isTakeover: isPlanning || isLive || isWrap,
            daysUntilStart: daysUntilStart,
            isSoon: isPlanning && daysUntilStart <= soonThresholdDays,
            dayNumber: dayNumber,
            totalDays: totalDays,
            daysSinceEnd: max(0, daysAfterEnd),
            wrapDaysLeft: isWrap ? max(0, wrapTailDays - daysAfterEnd) : 0
        )
    }

    private static func offSeason() -> FestSeason {
        FestSeason(
            phase: .offSeason,
            isLive: false, isPlanning: false, isWrap: false, isConcluded: false,
            isTakeover: false,
            daysUntilStart: 0, isSoon: false, dayNumber: nil,
            totalDays: 0, daysSinceEnd: 0, wrapDaysLeft: 0
        )
    }

    /// True when a fest year whose window has ended is old enough to belong in
    /// the archive. Same threshold as `.concluded`, so the hub saying "that's a
    /// wrap" and the year appearing in Past Years flip on the same day.
    static func isPast(endISO: String, now: Date = .now) -> Bool {
        guard let end = festISOFormatter.date(from: endISO) else { return false }
        let cal = Calendar.current
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: end),
                                      to: cal.startOfDay(for: now)).day ?? 0
        return days > wrapTailDays
    }
}

// MARK: - Convenience for the app's resolved fest dates

extension FestSeason {
    static func current(now: Date = .now) -> FestSeason {
        compute(
            startISO: FamilyFestConfig.startDate,
            endISO:   FamilyFestConfig.endDate,
            now: now
        )
    }
}

// MARK: - ISO date formatter

/// Shared, not private: the archive and the "start next year" editor parse the
/// same `yyyy-MM-dd` strings in the same resort timezone.
let festISOFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone(identifier: "America/Chicago")
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()
