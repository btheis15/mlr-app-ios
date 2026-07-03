import SwiftUI
import WeatherKit

// MARK: - Event Weather Badge
//
// Drop-in badge that shows the forecast for an event's date when WeatherKit has
// one, and renders nothing otherwise (far-out events → no badge). Use on
// EventCard, EventSheet, UpcomingEventCard, and the Family Fest day rows.
//
//   EventWeatherBadge(isoDate: event.startDate)
//
// Apple's attribution requirement is satisfied by `WeatherAttributionLink` in the
// event detail (EventSheet) — the small badge links there. Place at least one
// `WeatherAttributionLink` on any screen that displays WeatherKit data.

struct EventWeatherBadge: View {
    let isoDate: String
    var compact: Bool = true

    @State private var forecast: EventForecast?
    @State private var didLoad = false

    var body: some View {
        Group {
            if let f = forecast {
                if compact {
                    compactBadge(f)
                } else {
                    fullBadge(f)
                }
            } else {
                // A zero-size anchor (NOT EmptyView) so `.task` still attaches and
                // runs while the forecast loads — SwiftUI skips lifecycle modifiers
                // on views that resolve to empty content.
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .task(id: isoDate) {
            guard !didLoad else { return }
            didLoad = true
            forecast = await WeatherService.shared.forecast(forISODate: isoDate)
        }
    }

    @ViewBuilder
    private func compactBadge(_ f: EventForecast) -> some View {
        let badge = HStack(spacing: 4) {
            Image(systemName: f.symbolName)
                .symbolRenderingMode(.multicolor)
                .font(.caption)
            Text("\(f.highLabel())/\(f.lowLabel())")
                .font(.caption2.weight(.medium))
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        if #available(iOS 26, *) {
            badge
                .glassEffect(.clear, in: .capsule)
                .accessibilityLabel("Forecast \(f.condition), high \(f.highLabel()), low \(f.lowLabel())")
        } else {
            badge
                .background(.ultraThinMaterial, in: .capsule)
                .accessibilityLabel("Forecast \(f.condition), high \(f.highLabel()), low \(f.lowLabel())")
        }
    }

    @ViewBuilder
    private func fullBadge(_ f: EventForecast) -> some View {
        let card = HStack(spacing: 12) {
            Image(systemName: f.symbolName)
                .symbolRenderingMode(.multicolor)
                .font(.title)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.condition)
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    Label("\(f.highLabel()) / \(f.lowLabel())", systemImage: "thermometer.medium")
                        .font(.caption)
                    if f.precipPercent > 0 {
                        Label("\(f.precipPercent)%", systemImage: "drop.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        if #available(iOS 26, *) {
            card.glassCard(cornerRadius: 14)
        } else {
            card
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}

// MARK: - Event Weather Forecast Section
//
// For a multi-day event, shows a per-day forecast strip plus an on-device Apple
// Intelligence summary of the week's weather. For a single-day event it falls
// back to the existing full-size badge. Self-hides when WeatherKit has no data
// (event too far out / in the past).

struct EventWeatherForecastSection: View {
    let event: ResortEvent

    @State private var forecasts: [EventForecast] = []
    @State private var summary: String?
    @State private var summarizing = false
    @State private var didLoad = false

    private var isMultiDay: Bool {
        guard let end = event.endDate, end != event.startDate else { return false }
        return true
    }

    var body: some View {
        weatherContent
            .task(id: event.id) {
                guard isMultiDay, !didLoad else { return }
                didLoad = true
                forecasts = await WeatherService.shared.forecasts(fromISO: event.startDate, toISO: event.endDate)
                guard !forecasts.isEmpty, WeatherSummarizer.isAvailable else { return }
                summarizing = true
                summary = await WeatherSummarizer.summarize(eventTitle: event.title, forecasts: forecasts)
                summarizing = false
            }
    }

    @ViewBuilder
    private var weatherContent: some View {
        if isMultiDay {
            if forecasts.isEmpty {
                // Zero-size anchor so `.task` runs while the forecast loads —
                // SwiftUI skips `.task` on views that resolve to empty content.
                Color.clear.frame(width: 0, height: 0)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "Weather")
                    if summarizing {
                        summaryPlaceholder
                    } else if let summary {
                        summaryCard(summary)
                    }
                    dayStrip
                }
            }
        } else {
            // Single-day events keep the original badge.
            EventWeatherBadge(isoDate: event.startDate, compact: false)
        }
    }

    // MARK: Per-day strip

    private var dayStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(forecasts) { f in
                    dayCard(f)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func dayCard(_ f: EventForecast) -> some View {
        VStack(spacing: 5) {
            Text(f.weekdayLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.mlrTextMuted)
            Text(f.shortDateLabel)
                .font(.caption2)
                .foregroundStyle(Color.mlrTextSubtle)
            Image(systemName: f.symbolName)
                .symbolRenderingMode(.multicolor)
                .font(.title2)
                .padding(.vertical, 2)
            Text(f.highLabel())
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Color.mlrText)
            Text(f.lowLabel())
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Color.mlrTextMuted)
            if f.precipPercent > 0 {
                Label("\(f.precipPercent)%", systemImage: "drop.fill")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
        }
        .frame(width: 74)
        .padding(.vertical, 12)
        .background(Color.mlrCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(f.weekdayLabel) \(f.shortDateLabel): \(f.condition), high \(f.highLabel()), low \(f.lowLabel())")
    }

    // MARK: AI summary

    private func summaryCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.mlrScaled(15, weight: .semibold))
                .foregroundStyle(Color.mlrPrimary)
                .padding(.top, 1)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Color.mlrText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mlrPrimaryLight)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var summaryPlaceholder: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.mlrScaled(15, weight: .semibold))
                .foregroundStyle(Color.mlrPrimary)
            Text("Summarizing the forecast…")
                .font(.subheadline)
                .foregroundStyle(Color.mlrTextMuted)
            ProgressView().controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mlrPrimaryLight)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Attribution (required by Apple's WeatherKit terms)

struct WeatherAttributionView: View {
    @State private var attribution: WeatherAttribution?

    var body: some View {
        Group {
            if let attribution {
                HStack(spacing: 4) {
                    AsyncImage(url: attribution.combinedMarkLightURL) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Text("Weather")
                    }
                    .frame(height: 12)
                    Link("Data sources", destination: attribution.legalPageURL)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            attribution = try? await WeatherKit.WeatherService.shared.attribution
        }
    }
}
