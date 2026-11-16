import SwiftUI
import WeatherKit
import CoreLocation
import os

// MARK: - HomeWeatherCard
// "What's it like Up North" — current temp + today's hi/lo for Tomahawk, WI.
// Collapsed to one row by default; tapping reveals a 5-day forecast strip with
// rain %. Two looks: `.card` (the original card) and `.compact` (a slim
// single-line strip meant for the very top of Home).
//
// Sources: WeatherKit and Open-Meteo start concurrently and the first usable
// result is shown. WeatherKit has been seen to neither return nor throw, so it
// runs under a hard timeout in unstructured tasks that report back through
// `HomeWeatherModel` — the UI never awaits it. If Open-Meteo wins and WeatherKit
// answers within the bound, the card upgrades to the WeatherKit snapshot.
// Apple's attribution link appears only while WeatherKit data is shown. The last
// good snapshot is cached for 30 min and painted instantly on a cold open.

private let tomahawkLocation = CLLocation(latitude: 45.53492, longitude: -89.69830)

struct HomeWeatherCard: View {
    enum Style { case card, compact }

    var style: Style = .card

    @State private var model = HomeWeatherModel()
    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let snap = model.snap {
                content(snap: snap)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: model.snap)
        .task { model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refresh() }
        }
    }

    @ViewBuilder
    private func content(snap: HomeWeatherSnapshot) -> some View {
        switch style {
        case .card: card(snap: snap)
        case .compact: compact(snap: snap)
        }
    }

    private func toggle(_ snap: HomeWeatherSnapshot) {
        guard !snap.forecast.isEmpty else { return }
        if !isExpanded { Haptics.tap() }
        withAnimation(reduceMotion ? nil : MLRMotion.spring) { isExpanded.toggle() }
    }

    private func a11yLabel(_ snap: HomeWeatherSnapshot) -> String {
        var parts = ["Weather up north", "\(snap.temp) degrees"]
        if let c = snap.condition { parts.append(c) }
        parts.append("high \(snap.hi), low \(snap.lo)")
        return parts.joined(separator: ", ")
    }

    private func symbolView(_ snap: HomeWeatherSnapshot, size: CGFloat, width: CGFloat) -> some View {
        Image(systemName: snap.symbol)
            .font(.mlrScaled(size, weight: .medium))
            .symbolRenderingMode(.palette)
            .foregroundStyle(WeatherSymbolTint.primary(snap.symbol), WeatherSymbolTint.secondary(snap.symbol))
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? "" : snap.symbol)
            .frame(width: width)
    }

    @ViewBuilder
    private var attributionLink: some View {
        if let url = model.attributionURL {
            Link("Apple Weather", destination: url)
                .font(.system(size: 9))
                .foregroundStyle(Color.mlrTextSubtle)
        }
    }

    // MARK: - Card layout

    private func card(snap: HomeWeatherSnapshot) -> some View {
        VStack(spacing: 0) {
            Button { toggle(snap) } label: {
                HStack(spacing: 12) {
                    symbolView(snap, size: 26, width: 32)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 0) {
                            Text("\(snap.temp)°")
                                .contentTransition(.numericText())
                                .monospacedDigit()
                            Text(" Up North")
                        }
                        .font(.mlrScaled(14, weight: .semibold))
                        .foregroundStyle(Color.mlrText)
                        Text("H \(snap.hi)°  ·  L \(snap.lo)°")
                            .font(.mlrScaled(11))
                            .foregroundStyle(Color.mlrTextMuted)
                            .contentTransition(.numericText())
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Tomahawk, WI")
                            .font(.mlrScaled(11))
                            .foregroundStyle(Color.mlrTextSubtle)
                            .italic()
                        if snap.fromWeatherKit { attributionLink }
                    }

                    if !snap.forecast.isEmpty { chevron }
                }
                .padding(14)
            }
            .buttonStyle(.pressable)
            .disabled(snap.forecast.isEmpty)
            .accessibilityLabel(a11yLabel(snap))
            .accessibilityHint(snap.forecast.isEmpty ? "" : (isExpanded ? "Collapses the five day forecast" : "Shows the five day forecast"))

            strip(snap)
        }
        .cardStyle()
    }

    // MARK: - Compact layout

    private func compact(snap: HomeWeatherSnapshot) -> some View {
        MLRCard(padding: 0) {
            VStack(spacing: 0) {
                Button { toggle(snap) } label: {
                    HStack(spacing: 12) {
                        symbolView(snap, size: 20, width: 28)
                        Text("\(snap.temp)°")
                            .font(.mlrScaled(22, weight: .semibold, design: .rounded, relativeTo: .title2))
                            .foregroundStyle(Color.mlrText)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Up North")
                                .font(.mlrScaled(14, weight: .semibold, relativeTo: .subheadline))
                                .foregroundStyle(Color.mlrText)
                            Text("H \(snap.hi)°  L \(snap.lo)°")
                                .font(.mlrScaled(12, relativeTo: .footnote))
                                .foregroundStyle(Color.mlrTextMuted)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                        Spacer(minLength: 4)
                        if snap.fromWeatherKit { attributionLink.lineLimit(1) }
                        if !snap.forecast.isEmpty { chevron }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .disabled(snap.forecast.isEmpty)
                .accessibilityLabel(a11yLabel(snap))
                .accessibilityHint(snap.forecast.isEmpty ? "" : (isExpanded ? "Collapses the five day forecast" : "Shows the five day forecast"))

                strip(snap)
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.mlrScaled(12, weight: .semibold))
            .foregroundStyle(Color.mlrTextSubtle)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
    }

    // MARK: - 5-day strip (shared)

    @ViewBuilder
    private func strip(_ snap: HomeWeatherSnapshot) -> some View {
        if isExpanded && !snap.forecast.isEmpty {
            VStack(spacing: 0) {
                Divider().padding(.horizontal, 14)
                HStack(spacing: 0) {
                    ForEach(snap.forecast) { day in
                        VStack(spacing: 3) {
                            Text(day.day)
                                .font(.mlrScaled(11))
                                .foregroundStyle(Color.mlrTextMuted)
                            Image(systemName: day.symbol)
                                .font(.mlrScaled(14))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(WeatherSymbolTint.primary(day.symbol), WeatherSymbolTint.secondary(day.symbol))
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
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(dayLabel(day))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
        }
    }

    private func dayLabel(_ day: HomeWeatherSnapshot.Day) -> String {
        var s = "\(day.day): high \(day.hi), low \(day.lo)"
        if let pct = day.precipPct, pct >= 20 { s += ", \(pct) percent chance of rain" }
        return s
    }
}

// MARK: - Snapshot

struct HomeWeatherSnapshot: Codable, Equatable, Sendable {
    struct Day: Codable, Equatable, Sendable, Identifiable {
        var id: String { day }
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
    /// Plain-language condition for accessibility; absent in older cached snapshots.
    var condition: String? = nil

    static let cacheKey = "mlr.homeWeather.v1"
    var age: TimeInterval { Date().timeIntervalSince(ts) }
    var isFresh: Bool { age < 30 * 60 }

    static func cached() -> HomeWeatherSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(HomeWeatherSnapshot.self, from: data)
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }
}

// MARK: - Model (owns the WeatherKit / Open-Meteo race)

@MainActor
@Observable
final class HomeWeatherModel {
    /// Apple's legal page; used until (or unless) WeatherKit hands us its own URL.
    private static let fallbackAttributionURL = URL(string: "https://weatherkit.apple.com/legal-attribution.html")

    private(set) var snap: HomeWeatherSnapshot? = HomeWeatherSnapshot.cached()
    /// Non-nil only while the shown snapshot is WeatherKit data.
    var attributionURL: URL? { (snap?.fromWeatherKit ?? false) ? (resolvedAttributionURL ?? Self.fallbackAttributionURL) : nil }
    private var resolvedAttributionURL: URL?

    private static let weatherKitTimeout: Double = 8
    private static let recentEnough: TimeInterval = 3 * 60

    @ObservationIgnored private var running = false
    @ObservationIgnored private var pending = 0
    @ObservationIgnored private var gotWeatherKit = false
    @ObservationIgnored private var t0 = Date()

    /// Paints nothing itself (the cached snapshot is already in `snap`); starts a
    /// background refresh unless the cache is only minutes old. Returns at once.
    func refresh() {
        if let s = snap, s.age < Self.recentEnough { return }
        guard !running else { return }
        running = true
        pending = 2
        gotWeatherKit = false
        t0 = Date()

        Task { [weak self] in
            let start = Date()
            do {
                let s = try await withWeatherTimeout(seconds: Self.weatherKitTimeout) {
                    try await HomeWeatherFetch.weatherKit()
                }
                weatherLog.info("Home: WeatherKit answered in \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s")
                self?.accept(s)
            } catch let e as WeatherTimeoutError {
                weatherLog.error("Home: WeatherKit timed out after \(Int(e.seconds))s")
            } catch {
                weatherLog.error("Home: WeatherKit failed after \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s: \(String(describing: error), privacy: .public)")
            }
            self?.finishOne()
        }
        Task { [weak self] in
            let start = Date()
            do {
                let s = try await HomeWeatherFetch.openMeteo()
                weatherLog.info("Home: Open-Meteo answered in \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s")
                self?.accept(s)
            } catch {
                weatherLog.error("Home: Open-Meteo failed after \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s: \(String(describing: error), privacy: .public)")
            }
            self?.finishOne()
        }
    }

    private func accept(_ s: HomeWeatherSnapshot) {
        if s.fromWeatherKit {
            gotWeatherKit = true
            show(s, reason: "WeatherKit")
            loadAttribution()
        } else {
            if gotWeatherKit {
                weatherLog.info("Home: Open-Meteo result ignored, WeatherKit already shown")
            } else if let cur = snap, cur.fromWeatherKit, cur.isFresh {
                // Keep a still-fresh WeatherKit cache rather than flicker the
                // attribution; a late WeatherKit answer will refresh it.
                weatherLog.info("Home: Open-Meteo result held back, fresh WeatherKit cache shown")
            } else {
                show(s, reason: "Open-Meteo")
            }
        }
    }

    private func show(_ s: HomeWeatherSnapshot, reason: String) {
        snap = s
        s.save()
        weatherLog.info("Home: showing \(reason, privacy: .public) after \(Date().timeIntervalSince(self.t0), format: .fixed(precision: 2))s")
    }

    private func finishOne() {
        pending -= 1
        if pending <= 0 {
            running = false
            if snap == nil { weatherLog.error("Home: no weather source produced a result") }
        }
    }

    private func loadAttribution() {
        guard resolvedAttributionURL == nil else { return }
        Task { [weak self] in
            if let attr = try? await withWeatherTimeout(seconds: 8, { try await WeatherKit.WeatherService.shared.attribution }) {
                self?.resolvedAttributionURL = attr.legalPageURL
            }
        }
    }
}

// MARK: - Fetch (nonisolated; safe to run off the main actor)

enum HomeWeatherFetch {
    static func weatherKit() async throws -> HomeWeatherSnapshot {
        let (cur, daily) = try await WeatherKit.WeatherService.shared.weather(
            for: tomahawkLocation, including: .current, .daily)
        guard let today = daily.forecast.first else { throw URLError(.cannotParseResponse) }
        let days = Array(daily.forecast.dropFirst().prefix(5)).map {
            HomeWeatherSnapshot.Day(day: dayName(from: $0.date),
                                    symbol: $0.symbolName,
                                    hi: tempF($0.highTemperature),
                                    lo: tempF($0.lowTemperature),
                                    precipPct: Int(($0.precipitationChance * 100).rounded()))
        }
        return HomeWeatherSnapshot(ts: Date(), fromWeatherKit: true,
                                   temp: tempF(cur.temperature),
                                   hi: tempF(today.highTemperature),
                                   lo: tempF(today.lowTemperature),
                                   symbol: cur.symbolName, forecast: days,
                                   condition: cur.condition.description)
    }

    /// Same endpoint + params as the web app's WeatherCard.
    static func openMeteo() async throws -> HomeWeatherSnapshot {
        let r = try await OpenMeteoClient.fetch(forecastDays: 6)
        guard let hi = r.daily.temperature_2m_max.first, let lo = r.daily.temperature_2m_min.first else {
            throw URLError(.cannotParseResponse)
        }
        var days: [HomeWeatherSnapshot.Day] = []
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "America/Chicago")
        for i in 1..<max(1, r.daily.time.count) where days.count < 5 {
            guard i < r.daily.temperature_2m_max.count, i < r.daily.temperature_2m_min.count,
                  i < r.daily.weather_code.count, let d = parser.date(from: r.daily.time[i]) else { continue }
            let p = i < r.daily.precipitation_probability_max.count ? r.daily.precipitation_probability_max[i] : nil
            days.append(.init(day: dayName(from: d),
                              symbol: OpenMeteoClient.symbol(forWMO: r.daily.weather_code[i]),
                              hi: Int(r.daily.temperature_2m_max[i].rounded()),
                              lo: Int(r.daily.temperature_2m_min[i].rounded()),
                              precipPct: p.map { Int($0.rounded()) }))
        }
        return HomeWeatherSnapshot(ts: Date(), fromWeatherKit: false,
                                   temp: Int(r.current.temperature_2m.rounded()),
                                   hi: Int(hi.rounded()), lo: Int(lo.rounded()),
                                   symbol: OpenMeteoClient.symbol(forWMO: r.current.weather_code),
                                   forecast: days,
                                   condition: OpenMeteoClient.condition(forWMO: r.current.weather_code))
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

// MARK: - Weather symbol colours
// Multicolor weather symbols draw their clouds white, which vanishes on the
// app's light cards. Palette rendering keeps the sun gold and the rain blue but
// gives clouds a visible slate.

enum WeatherSymbolTint {
    private static let cloud = Color(light: "#7C8794", dark: "#C3CAD3")
    private static let sun   = Color(light: "#E9A100", dark: "#FFC83D")
    private static let water = Color(light: "#2F7FD1", dark: "#6FB2F2")

    /// The symbol's main shape: the cloud when there is one, else the sun/moon/flake.
    static func primary(_ symbol: String) -> Color {
        if symbol.hasPrefix("cloud") || symbol.contains("fog") || symbol.contains("wind") { return cloud }
        if symbol.contains("snow") { return water }
        if symbol.contains("drop") || symbol.contains("rain") { return water }
        return sun
    }

    /// The accent layer: sun or moon behind a cloud, rain, snow or lightning under it.
    static func secondary(_ symbol: String) -> Color {
        if symbol.contains("sun") || symbol.contains("moon") || symbol.contains("bolt") { return sun }
        if symbol.contains("rain") || symbol.contains("drizzle") || symbol.contains("snow")
            || symbol.contains("sleet") || symbol.contains("hail") { return water }
        return primary(symbol)
    }
}
