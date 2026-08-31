import SwiftUI

private extension String {
    var blankToNil: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - Past Years — the Family Fest archive
//
// Family Fest is one week a year the family spends a year planning, and until
// now the app kept exactly one of them: when a fest ended its schedule, dinners
// and crew assignments sat on the hub going stale, and the only way to start a
// new year would have been to overwrite them. This is where a finished fest
// goes instead — the whole week preserved, readable, and out of the way of next
// year's planning.
//
// A year lands here on its own, purely from its dates (`FestSeason.isPast`) —
// nothing has to be archived by hand, and nothing can be forgotten.
//
// ⚠️ READ-ONLY FOR EVERYONE, INCLUDING ADMINS. The fest editor writes to the
// CURRENT year, so wiring its sheets in here would silently edit the wrong fest.
// There are deliberately no edit affordances and no sign-up cards — there's
// nothing left to sign up for.

struct FestPastYearsView: View {
    @Environment(AppEnvironment.self) private var env

    private var past: [FestConfig] { env.festContentService.pastYears }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                if past.isEmpty {
                    Text("No past Family Fests yet. Once a week wraps up, it lands here — schedule, dinners and all.")
                        .font(.mlrScaled(13))
                        .foregroundStyle(Color.mlrFestInk.opacity(0.75))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                        .padding(16)
                        .festCardStyle(cornerRadius: 14)
                } else {
                    ForEach(past) { year in
                        NavigationLink(destination: FestPastYearDetailView(year: year)) {
                            PastYearRow(year: year)
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
            .padding(16)
        }
        .background(Color.mlrFestParchment.ignoresSafeArea())
        .navigationTitle("Past Years")
        .navigationBarTitleDisplayMode(.inline)
        .task { await env.festContentService.load() }
    }

    private var header: some View {
        Text("Every Family Fest we've had, kept whole — the week, the dinners, and who ran what.")
            .font(.mlrScaled(13))
            .foregroundStyle(Color.mlrFestInk.opacity(0.75))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PastYearRow: View {
    let year: FestConfig

    var body: some View {
        HStack(spacing: 12) {
            Text("🎪").font(.mlrScaled(24))

            VStack(alignment: .leading, spacing: 2) {
                Text(year.name)
                    .font(.mlrScaled(15, weight: .semibold))
                    .foregroundStyle(Color.mlrFestInk)
                    .lineLimit(1)
                Text(year.dateRangeLabel)
                    .font(.mlrScaled(12))
                    .foregroundStyle(Color.mlrFestInk.opacity(0.7))
                // The year's THEME identifies it better than its tagline —
                // "Ye Olde Family Feste" is what people remember 2026 by.
                // Falls back to the tagline for a year that had no theme.
                if let sub = year.theme?.blankToNil ?? year.tagline?.blankToNil {
                    Text(sub)
                        .font(.mlrScaled(11))
                        .foregroundStyle(Color.mlrFestInk.opacity(0.55))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.mlrScaled(12, weight: .semibold))
                .foregroundStyle(Color.mlrFestInk.opacity(0.35))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .festCardStyle(cornerRadius: 14)
        .contentShape(Rectangle())
    }
}

// MARK: - One archived year

struct FestPastYearDetailView: View {
    @Environment(AppEnvironment.self) private var env
    let year: FestConfig

    @State private var content: FestContentService.ArchivedYear?
    @State private var loading = true

    private let dayOrder = ["Sunday", "Monday", "Tuesday", "Wednesday",
                            "Thursday", "Friday", "Saturday"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                heading
                thankYou

                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
                } else if let content, !content.isEmpty {
                    week(content)
                } else {
                    // ⚠️ No seed fallback here. The live hub backfills an empty
                    // table with in-code seed data so it's never blank; an
                    // archive doing that would fabricate history.
                    Text("No schedule was saved for this one.")
                        .font(.mlrScaled(13))
                        .foregroundStyle(Color.mlrFestInk.opacity(0.75))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(16)
                        .festCardStyle(cornerRadius: 14)
                }
            }
            .padding(16)
        }
        .background(Color.mlrFestParchment.ignoresSafeArea())
        .navigationTitle(String(year.year))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            content = await env.festContentService.fetchArchivedYear(year.year)
            loading = false
        }
    }

    private var heading: some View {
        VStack(spacing: 4) {
            Text("⚜ In the archives ⚜")
                .font(.festSerif(11, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(Color.mlrFest)
            Text(year.name)
                .font(.festSerif(20, weight: .bold))
                .foregroundStyle(Color.mlrFest)
                .multilineTextAlignment(.center)
            if let theme = year.theme?.blankToNil {
                Text(theme)
                    .font(.festSerif(11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Color.mlrFest.opacity(0.8))
            }
            Text(year.dateRangeLabel)
                .font(.mlrScaled(13))
                .foregroundStyle(Color.mlrFestInk.opacity(0.75))
            if let tagline = year.tagline?.blankToNil {
                Text(tagline)
                    .font(.mlrScaled(11))
                    .foregroundStyle(Color.mlrFestInk.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var thankYou: some View {
        VStack(spacing: 6) {
            Text("Thank you for a great Family Fest 🎆")
                .font(.mlrScaled(14, weight: .bold))
                .foregroundStyle(Color.mlrFest)
            Text("See you next year!")
                .font(.mlrScaled(13))
                .foregroundStyle(Color.mlrFestInk.opacity(0.75))

            // The year is a live segment of a well-known Drop Box id, so an
            // unseeded year just degrades to "folder isn't available" —
            // linking one early is harmless.
            if let albumId = UUID(uuidString: FestContentService.albumId(for: year.year)) {
                NavigationLink(destination: DropBoxDetailView(boxId: albumId)) {
                    Text("📸 Photos & videos from \(String(year.year)) →")
                        .font(.mlrScaled(13, weight: .semibold))
                        .foregroundStyle(Color.mlrAccent)
                }
                .buttonStyle(.pressable)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.mlrFest.opacity(0.1)))
    }

    /// ⚠️ Deliberately KEEPS tournament brackets nowhere here but keeps the week
    /// itself — who ran what and what was on the menu is exactly the history
    /// worth archiving. Rows are plain text: no expand-to-edit, no sign-up card.
    @ViewBuilder
    private func week(_ content: FestContentService.ArchivedYear) -> some View {
        let anytime = content.schedule.filter { $0.day == "Anytime" }
        let byDay = dayOrder.compactMap { day -> (String, [ScheduleItem], FestDinner?)? in
            let items = content.schedule.filter { $0.day == day }
            let dinner = content.dinners.first { $0.day == day }
            return items.isEmpty && dinner == nil ? nil : (day, items, dinner)
        }

        ForEach(byDay, id: \.0) { day, items, dinner in
            VStack(alignment: .leading, spacing: 8) {
                Text(day.uppercased())
                    .font(.festSerif(12, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Color.mlrFest)

                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().background(Color.mlrFest.opacity(0.1)) }
                        ArchivedScheduleRow(item: item)
                    }
                    if let dinner {
                        if !items.isEmpty { Divider().background(Color.mlrFest.opacity(0.15)) }
                        ArchivedDinnerRow(dinner: dinner)
                    }
                }
                .festCardStyle(cornerRadius: 12)
            }
        }

        if !anytime.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("ALL WEEK — ANYTIME")
                    .font(.festSerif(12, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Color.mlrFest)
                VStack(spacing: 0) {
                    ForEach(Array(anytime.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().background(Color.mlrFest.opacity(0.1)) }
                        ArchivedScheduleRow(item: item)
                    }
                }
                .festCardStyle(cornerRadius: 12)
            }
        }
    }
}

// MARK: - Read-only rows
//
// Separate from ExpandableScheduleRow / ExpandableDinnerRow on purpose: those
// route into the fest EDIT sheets, which write to the current year. Reusing
// them here is how an archive quietly rewrites a different fest.

private struct ArchivedScheduleRow: View {
    let item: ScheduleItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.time)
                    .font(.mlrScaled(11, weight: .semibold))
                    .foregroundStyle(Color.mlrFest.opacity(0.8))
                    .frame(width: 74, alignment: .leading)
                Text(item.title)
                    .font(.mlrScaled(14, weight: .semibold))
                    .foregroundStyle(Color.mlrFestInk)
                Spacer(minLength: 0)
            }
            let place = item.location.flatMap { $0 == "TBD" ? nil : $0 }
            if place != nil || !item.leads.isEmpty {
                HStack(spacing: 6) {
                    Spacer().frame(width: 74)
                    if let place {
                        Text(place)
                            .font(.mlrScaled(11))
                            .foregroundStyle(Color.mlrFestInk.opacity(0.65))
                    }
                    if !item.leads.isEmpty {
                        Text("· \(item.leads.joined(separator: ", "))")
                            .font(.mlrScaled(11))
                            .foregroundStyle(Color.mlrFestInk.opacity(0.65))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ArchivedDinnerRow: View {
    let dinner: FestDinner

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("🍽")
                    .font(.mlrScaled(12))
                    .frame(width: 74, alignment: .leading)
                Text(dinner.title)
                    .font(.mlrScaled(14, weight: .semibold))
                    .foregroundStyle(Color.mlrFestInk)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Spacer().frame(width: 74)
                Text("\(dinner.menu) · \(dinner.chef)")
                    .font(.mlrScaled(11))
                    .foregroundStyle(Color.mlrFestInk.opacity(0.65))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
