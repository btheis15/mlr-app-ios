import SwiftUI
import WeatherKit
import CoreLocation

// MARK: - HomeWeatherCard
// Compact "what's it like Up North" strip — current temp + today's hi/lo for
// Tomahawk, WI. Collapsed to one row by default; tapping it reveals a 5-day
// forecast strip with rain %.
//
// Source: WeatherKit first (attribution link shown as Apple's license requires).
// If WeatherKit fails for any reason (beta OS, entitlement not yet live, no
// network to Apple) we fall back to Open-Meteo — the same keyless feed the web
// app's WeatherCard uses — so the card never silently vanishes. The last good
// snapshot is cached for 30 min so it paints instantly on a cold open.

private let tomahawkLocation = CLLocation(latitude: 45.53492, longitude: -89.69830)

struct HomeWeatherCard: View {
    @State private var snap: Snapshot? = Snapshot.cached()
    @State private var attributionURL: URL? = nil
    @State private var isExpanded = false
    var body: some View {
        Group {
            if let snap {
                card(snap: snap)
            }
        }
        .task { await load() }
    }

    // MARK: - Card layout

    private func card(snap: Snapshot) -> some View {
        VStack(spacing: 0) {
            // Collapsed row — always visible
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: snap.symbol)
                        .font(.mlrScaled(26, weight: .medium))
                        .foregroundStyle(Color.mlrPrimary)
                        .symbolRenderingMode(.multicolor)
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(snap.temp)° Up North")
                            .font(.mlrScaled(14, weight: .semibold))
                            .foregroundStyle(Color.mlrText)
                        Text("H \(snap.hi)°  ·  L \(snap.lo)°")
                            .font(.mlrScaled(11))
                            .foregroundStyle(Color.mlrTextMuted)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Tomahawk, WI")
                            .font(.mlrScaled(11))
                            .foregroundStyle(Color.mlrTextSubtle)
                            .italic()
                        if snap.fromWeatherKit, let url = attributionURL {
                            Link("Apple Weather", destination: url)
                                .font(.system(size: 9))
                                .foregroundStyle(Color.mlrTextSubtle)
                        }
                    }

                    if !snap.forecast.isEmpty {
                        Image(systemName: "chevron.right")
                            .font(.mlrScaled(12, weight: .semibold))
                            .foregroundStyle(Color.mlrTextSubtle)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .padding(14)
            }
            .buttonStyle(.pressable)
            .disabled(snap.forecast.isEmpty)

            // 5-day strip — revealed on tap
            if isExpanded && !snap.forecast.isEmpty {
                Divider().padding(.horizontal, 14)
                HStack(spacing: 0) {
                    ForEach(Array(snap.forecast.enumerated()), id: \.offset) { _, day in
                        VStack(spacing: 3) {
                            Text(day.day)
                                .font(.mlrScaled(11))
                                .foregroundStyle(Color.mlrTextMuted)
                            Image(systemName: day.symbol)
                                .font(.mlrScaled(14))
                                .foregroundStyle(Color.mlrPrimary)
                                .symbolRenderingMode(.multicolor)
                                .frame(height: 18)
                            Text("\(day.hi)°")
                                .font(.mlrScaled(11, weight: .semibold))
                                .foregroundStyle(Color.mlrText)
                            Text("\(day.lo)°")
                                .font(.mlrScaled(11))
                                .foregroundStyle(Color.mlrTextSubtle)
                            if let pct = day.precipPct, pct >= 20 {
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
        if let cached = Snapshot.cached(), cached.isFresh {
            snap = cached
            if cached.fromWeatherKit { await loadAttribution() }
            return
        }
        var result = await fetchWeatherKit()
        if result == nil { result = await fetchOpenMeteo() }
        if let fresh = result {
            snap = fresh
            fresh.save()
            if fresh.fromWeatherKit { await loadAttribution() }
        }
        // Both sources failed: keep whatever stale cache `snap` already holds (or nothing).
    }

    private func loadAttribution() async {
        if let attr = try? await WeatherKit.WeatherService.shared.attribution {
            attributionURL = attr.legalPageURL
        }
    }

    private func fetchWeatherKit() async -> Snapshot? {
        do {
            let (cur, daily) = try await WeatherKit.WeatherService.shared.weather(
                for: tomahawkLocation, including: .current, .daily)
            guard let today = daily.forecast.first else { return nil }
            let days = Array(daily.forecast.dropFirst().prefix(5)).map {
                Snapshot.Day(day: Self.dayName(from: $0.date),
                             symbol: $0.symbolName,
                             hi: Self.tempF($0.highTemperature),
                             lo: Self.tempF($0.lowTemperature),
                             precipPct: Int(($0.precipitationChance * 100).rounded()))
            }
            return Snapshot(ts: Date(), fromWeatherKit: true,
                            temp: Self.tempF(cur.temperature),
                            hi: Self.tempF(today.highTemperature),
                            lo: Self.tempF(today.lowTemperature),
                            symbol: cur.symbolName, forecast: days)
        } catch {
            print("[HomeWeatherCard] WeatherKit failed, falling back to Open-Meteo: \(error)")
            return nil
        }
    }

    /// Same endpoint + params as the web app's WeatherCard.
    private func fetchOpenMeteo() async -> Snapshot? {
        let urlStr = "https://api.open-meteo.com/v1/forecast?latitude=45.53492&longitude=-89.69830"
            + "&current=temperature_2m,weather_code"
            + "&daily=temperature_2m_max,temperature_2m_min,weather_code,precipitation_probability_max"
            + "&temperature_unit=fahrenheit&timezone=America%2FChicago&forecast_days=6"
        guard let url = URL(string: urlStr) else { return nil }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let r = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
            guard let hi = r.daily.temperature_2m_max.first, let lo = r.daily.temperature_2m_min.first else { return nil }
            var days: [Snapshot.Day] = []
            let parser = DateFormatter()
            parser.dateFormat = "yyyy-MM-dd"
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.timeZone = TimeZone(identifier: "America/Chicago")
            for i in 1..<max(1, r.daily.time.count) where days.count < 5 {
                guard i < r.daily.temperature_2m_max.count, i < r.daily.temperature_2m_min.count,
                      i < r.daily.weather_code.count, let d = parser.date(from: r.daily.time[i]) else { continue }
                let p = i < r.daily.precipitation_probability_max.count ? r.daily.precipitation_probability_max[i] : nil
                days.append(.init(day: Self.dayName(from: d),
                                  symbol: Self.symbol(forWMO: r.daily.weather_code[i]),
                                  hi: Int(r.daily.temperature_2m_max[i].rounded()),
                                  lo: Int(r.daily.temperature_2m_min[i].rounded()),
                                  precipPct: p.map { Int($0.rounded()) }))
            }
            return Snapshot(ts: Date(), fromWeatherKit: false,
                            temp: Int(r.current.temperature_2m.rounded()),
                            hi: Int(hi.rounded()), lo: Int(lo.rounded()),
                            symbol: Self.symbol(forWMO: r.current.weather_code), forecast: days)
        } catch {
            print("[HomeWeatherCard] Open-Meteo failed: \(error)")
            return nil
        }
    }

    // MARK: - Model

    struct Snapshot: Codable {
        struct Day: Codable {
            let day: String
            let symbol: String
            let hi: Int
            let lo: Int
            let precipPct: Int?
        }
        let ts: Date
        let fromWeatherKit: Bool
        let temp: Int
        let hi: Int
        let lo: Int
        let symbol: String
        let forecast: [Day]

        static let cacheKey = "mlr.homeWeather.v1"
        var isFresh: Bool { Date().timeIntervalSince(ts) < 30 * 60 }

        static func cached() -> Snapshot? {
            guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
            return try? JSONDecoder().decode(Snapshot.self, from: data)
        }
        func save() {
            if let data = try? JSONEncoder().encode(self) {
                UserDefaults.standard.set(data, forKey: Self.cacheKey)
            }
        }
    }

    private struct OpenMeteoResponse: Decodable {
        struct Current: Decodable { let temperature_2m: Double; let weather_code: Int }
        struct Daily: Decodable {
            let time: [String]
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
            let weather_code: [Int]
            let precipitation_probability_max: [Double?]
        }
        let current: Current
        let daily: Daily
    }

    // MARK: - Helpers

    /// WMO weather code → SF Symbol (same buckets as the web's weatherEmoji).
    private static func symbol(forWMO code: Int) -> String {
        switch code {
        case 0: return "sun.max.fill"
        case 1, 2: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "snowflake"
        case 95...: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    private static func tempF(_ m: Measurement<UnitTemperature>) -> Int {
        Int(m.converted(to: .fahrenheit).value.rounded())
    }

    private static func dayName(from date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "America/Chicago")
        return fmt.string(from: date)
    }
}
