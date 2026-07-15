import SwiftUI
import WeatherKit
import CoreLocation

// MARK: - HomeWeatherCard
// Compact "what's it like Up North" strip — current temp + today's hi/lo for
// Tomahawk, WI, via WeatherKit (native iOS; no API key needed). Collapsed to
// one row by default; tapping it reveals a 5-day forecast strip with rain %.
// Attribution link shown as required by Apple's WeatherKit license.

private let tomahawkLocation = CLLocation(latitude: 45.53492, longitude: -89.69830)

struct HomeWeatherCard: View {
    @State private var current: CurrentWeather? = nil
    @State private var daily: [DayWeather] = []
    @State private var attributionURL: URL? = nil
    @State private var isExpanded = false
    var body: some View {
        Group {
            if let current {
                card(current: current)
            }
        }
        .task { await load() }
    }

    // MARK: - Card layout

    private func card(current: CurrentWeather) -> some View {
        VStack(spacing: 0) {
            // Collapsed row — always visible
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: current.symbolName)
                        .font(.mlrScaled(26, weight: .medium))
                        .foregroundStyle(Color.mlrPrimary)
                        .symbolRenderingMode(.multicolor)
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(tempF(current.temperature))° Up North")
                            .font(.mlrScaled(14, weight: .semibold))
                            .foregroundStyle(Color.mlrText)
                        if let today = daily.first {
                            Text("H \(tempF(today.highTemperature))°  ·  L \(tempF(today.lowTemperature))°")
                                .font(.mlrScaled(11))
                                .foregroundStyle(Color.mlrTextMuted)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Tomahawk, WI")
                            .font(.mlrScaled(11))
                            .foregroundStyle(Color.mlrTextSubtle)
                            .italic()
                        if let url = attributionURL {
                            Link("Apple Weather", destination: url)
                                .font(.system(size: 9))
                                .foregroundStyle(Color.mlrTextSubtle)
                        }
                    }

                    if daily.count > 1 {
                        Image(systemName: "chevron.right")
                            .font(.mlrScaled(12, weight: .semibold))
                            .foregroundStyle(Color.mlrTextSubtle)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .padding(14)
            }
            .buttonStyle(.plain)
            .disabled(daily.count <= 1)

            // 5-day strip — revealed on tap
            if isExpanded && daily.count > 1 {
                Divider().padding(.horizontal, 14)
                HStack(spacing: 0) {
                    ForEach(Array(daily.dropFirst().prefix(5).enumerated()), id: \.offset) { _, day in
                        VStack(spacing: 3) {
                            Text(dayName(from: day.date))
                                .font(.mlrScaled(11))
                                .foregroundStyle(Color.mlrTextMuted)
                            Image(systemName: day.symbolName)
                                .font(.mlrScaled(14))
                                .foregroundStyle(Color.mlrPrimary)
                                .symbolRenderingMode(.multicolor)
                                .frame(height: 18)
                            Text("\(tempF(day.highTemperature))°")
                                .font(.mlrScaled(11, weight: .semibold))
                                .foregroundStyle(Color.mlrText)
                            Text("\(tempF(day.lowTemperature))°")
                                .font(.mlrScaled(11))
                                .foregroundStyle(Color.mlrTextSubtle)
                            let pct = Int((day.precipitationChance * 100).rounded())
                            if pct >= 20 {
                                Text("💧\(pct)%")
                                    .font(.mlrScaled(10))
                                    .foregroundStyle(Color.mlrInfo)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .cardStyle()
    }

    // MARK: - Fetch

    private func load() async {
        guard current == nil else { return }
        do {
            let (cur, dailyForecast) = try await WeatherKit.WeatherService.shared.weather(
                for: tomahawkLocation, including: .current, .daily)
            current = cur
            daily = Array(dailyForecast)
            if let attr = try? await WeatherKit.WeatherService.shared.attribution {
                attributionURL = attr.legalPageURL
            }
        } catch {
            // WeatherKit unavailable (offline or iOS beta) — card stays hidden
        }
    }

    // MARK: - Helpers

    private func tempF(_ m: Measurement<UnitTemperature>) -> Int {
        Int(m.converted(to: .fahrenheit).value.rounded())
    }

    private func dayName(from date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }
}
