import SwiftUI

// MARK: - EventCard
// Compact calendar card for an event: title, kind badge, date range,
// going count, and the user's current attendance chip. Tap opens EventSheet.
// Family Fest is styled with the heraldic-wine accent.

struct EventCard: View {
    let event: ResortEvent
    var summary: AttendanceSummary?
    var myStatus: AttendanceStatus?
    let onTap: () -> Void

    private var accent: Color {
        EventKindStyle.color(for: event.kind)
    }

    private var symbol: String {
        switch event.kind {
        case .familyFest:  return "tent.fill"
        case .workWeekend: return "hammer.fill"
        case .holiday:     return "gift.fill"
        case .custom:      return "calendar"
        }
    }

    var body: some View {
        Button(action: onTap) {
            MLRCard(event.isFamilyFest ? .tinted(accent) : .plain, padding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 12) {
                        IconTile(symbol: symbol, accent: accent, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Eyebrow(EventKindStyle.label(for: event.kind), color: accent)
                            Text(event.title)
                                .font(event.isFamilyFest
                                      ? .system(size: UIFontMetrics(forTextStyle: .title3).scaledValue(for: 16), weight: .bold, design: .serif)
                                      : .mlrCardTitle)
                                .foregroundStyle(event.isFamilyFest ? Color.mlrFestReadable : Color.mlrText)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            HStack(spacing: 8) {
                                Text(MLRFormat.dateRange(start: event.startDate, end: event.endDate))
                                    .font(.mlrSecondary)
                                    .foregroundStyle(Color.mlrTextMuted)
                                if let start = event.startDateParsed {
                                    RelativeDue(start)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.mlrScaled(13, weight: .semibold))
                            .foregroundStyle(Color.mlrTextSubtle)
                    }

                    HStack(spacing: 14) {
                        if let location = event.location, !location.isEmpty {
                            Label(location, systemImage: "mappin.and.ellipse")
                                .font(.mlrSecondary)
                                .foregroundStyle(Color.mlrTextMuted)
                                .lineLimit(1)
                        }
                        EventWeatherBadge(isoDate: event.startDate)
                    }

                    HStack {
                        if let summary, summary.going > 0 {
                            HStack(spacing: 5) {
                                Image(systemName: "person.2.fill")
                                    .font(.mlrScaled(12))
                                Text("\(summary.going) going")
                                    .font(.mlrScaled(14, weight: .medium))
                                    .numericTransition()
                            }
                            .foregroundStyle(accent)
                        }
                        Spacer()
                        if let myStatus {
                            Text("\(myStatus.emoji) \(myStatus.label)")
                                .font(.mlrScaled(13, weight: .semibold))
                                .foregroundStyle(accent)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(accent.mlrTint(0.12))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }
}

// MARK: - Kind Badge

struct KindBadge: View {
    let kind: EventKind

    var body: some View {
        Text(EventKindStyle.label(for: kind))
            .font(.mlrScaled(10, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(EventKindStyle.color(for: kind))
            .clipShape(Capsule())
    }
}

// MARK: - Kind styling

enum EventKindStyle {
    static func color(for kind: EventKind) -> Color {
        switch kind {
        case .familyFest:  return .mlrFestReadable
        case .workWeekend: return .mlrPrimary
        case .holiday:     return .mlrInfo
        case .custom:      return .mlrTextMuted
        }
    }

    static func label(for kind: EventKind) -> String {
        switch kind {
        case .familyFest:  return "FAMILY FEST"
        case .workWeekend: return "WORK WEEKEND"
        case .holiday:     return "HOLIDAY"
        case .custom:      return "EVENT"
        }
    }
}
