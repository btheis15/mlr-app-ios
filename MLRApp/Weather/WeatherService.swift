import Foundation
import WeatherKit
import CoreLocation
import os

// MARK: - Shared weather plumbing (Home card + event forecasts)

/// One logger for every weather path, so a real phone's Console shows which
/// source won and why: subsystem com.muskellungelakeresort.mlr, category weather.
let weatherLog = Logger(subsystem: "com.muskellungelakeresort.mlr", category: "weather")

struct WeatherTimeoutError: Error, CustomStringConvertible {
    let seconds: Double
    var description: String { "timed out after \(Int(seconds))s" }
}

private final class WeatherOnceGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    @discardableResult
    func finish(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        guard let c = continuation else { lock.unlock(); return false }
        continuation = nil
        lock.unlock()
        c.resume(with: result)
        return true
    }
}

/// Runs `operation` with a hard deadline. WeatherKit can neither return nor throw,
/// and a non-cooperative call ignores cancellation, so a task group (which waits
/// for every child) would hang with it. Instead the operation and the timer are
/// unstructured tasks racing to resume one continuation; the caller never awaits
/// the hung call itself, and the loser is cancelled best-effort.
func withWeatherTimeout<T: Sendable>(seconds: Double,
                                     _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        let gate = WeatherOnceGate<T>(cont)
        let work = Task {
            do { gate.finish(.success(try await operation())) }
            catch { gate.finish(.failure(error)) }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if gate.finish(.failure(WeatherTimeoutError(seconds: seconds))) { work.cancel() }
        }
    }
}

/// Open-Meteo: the keyless feed the web app's WeatherCard uses. Same endpoint and
/// parameters everywhere in the app.
struct OpenMeteoForecast: Decodable, Sendable {
    struct Current: Decodable, Sendable { let temperature_2m: Double; let weather_code: Int }
    struct Daily: Decodable, Sendable {
        let time: [String]
        let temperature_2m_max: [Double]
        let temperature_2m_min: [Double]
        let weather_code: [Int]
        let precipitation_probability_max: [Double?]
    }
    let current: Current
    let daily: Daily
}

enum OpenMeteoClient {
    static func fetch(forecastDays: Int = 6) async throws -> OpenMeteoForecast {
        let urlStr = "https://api.open-meteo.com/v1/forecast?latitude=45.53492&longitude=-89.69830"
            + "&current=temperature_2m,weather_code"
            + "&daily=temperature_2m_max,temperature_2m_min,weather_code,precipitation_probability_max"
            + "&temperature_unit=fahrenheit&timezone=America%2FChicago&forecast_days=\(forecastDays)"
        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(OpenMeteoForecast.self, from: data)
    }

    /// WMO weather code → SF Symbol (same buckets as the web's weatherEmoji).
    static func symbol(forWMO code: Int) -> String {
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

    /// Plain-language condition for accessibility labels and event badges.
    static func condition(forWMO code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1, 2: return "Partly Cloudy"
        case 3: return "Cloudy"
        case 45, 48: return "Foggy"
        case 51...67, 80...82: return "Rain"
        case 71...77, 85, 86: return "Snow"
        case 95...: return "Thunderstorms"
        default: return "Cloudy"
        }
    }
}

/// One forecast day, source-neutral (keyed by Central-time ISO date).
struct WeatherDay: Sendable {
    let iso: String
    let highC: Double
    let lowC: Double
    let symbolName: String
    let condition: String
    let precipitationChance: Double
    let fromWeatherKit: Bool

    var eventForecast: EventForecast {
        EventForecast(isoDate: iso, highC: highC, lowC: lowC,
                      highF: highC * 9 / 5 + 32, lowF: lowC * 9 / 5 + 32,
                      symbolName: symbolName, condition: condition,
                      precipitationChance: precipitationChance,
                      fromWeatherKit: fromWeatherKit)
    }
}

// MARK: - Weather Service (WeatherKit, Open-Meteo fallback)
//
// Fetches the forecast for resort events. The daily forecast reaches ~10 days
// out, so near-term events get a forecast and far-out ones simply don't — the
// UI hides the badge when `forecast(for:)` returns nil.
//
// WeatherKit is tried with a hard timeout (it has been observed to hang without
// ever returning or throwing) while Open-Meteo runs alongside as the fallback.
// Apple attribution is only shown for WeatherKit data (`hasWeatherKitData`).
//
// All resort events happen at the resort, so we anchor every forecast to the
// resort's coordinate rather than the device location.

@Observable
final class WeatherService {
    static let shared = WeatherService()

    /// Muskellunge Lake Resort, Tomahawk, WI.
    static let resortCoordinate = CLLocationCoordinate2D(latitude: 45.53492, longitude: -89.69830)

    private let maxForecastDays = 10
    private static let weatherKitTimeout: Double = 6

    /// Cache keyed by ISO date string so we don't refetch per card. Only
    /// successful results are ever stored.
    private var cache: [String: EventForecast] = [:]
    /// The single running fetch, shared by concurrent callers; cleared the moment
    /// it finishes (success, failure or timeout) so it can never wedge later calls.
    @ObservationIgnored private var dailyTask: Task<[WeatherDay]?, Never>?

    private init() {}

    /// True when any forecast currently cached came from WeatherKit.
    var hasWeatherKitData: Bool { cache.values.contains { $0.fromWeatherKit } }

    /// Returns a forecast for an event's start date if one exists
    /// (i.e. the date is within the daily-forecast horizon), otherwise nil.
    @MainActor
    func forecast(forISODate iso: String,
                  coordinate: CLLocationCoordinate2D = WeatherService.resortCoordinate) async -> EventForecast? {
        if let cached = cache[iso] { return cached }
        guard let targetDate = Self.isoFormatter.date(from: iso) else { return nil }
        let cal = Calendar.current
        let daysOut = cal.dateComponents([.day],
                                         from: cal.startOfDay(for: .now),
                                         to: cal.startOfDay(for: targetDate)).day ?? 999
        // Past events and events beyond the forecast horizon get nothing.
        guard daysOut >= 0, daysOut <= maxForecastDays else { return nil }
        await refreshDaily(coordinate: coordinate)
        return cache[iso]
    }

    /// Forecasts for every day in `[startISO, endISO]` (inclusive) that we
    /// can cover — used by multi-day events to show a per-day strip. Days beyond
    /// the ~10-day horizon are simply omitted. Returns [] when none are available.
    @MainActor
    func forecasts(fromISO startISO: String,
                   toISO endISO: String?,
                   coordinate: CLLocationCoordinate2D = WeatherService.resortCoordinate) async -> [EventForecast] {
        let isoDates = Self.dateRange(startISO: startISO, endISO: endISO)
        guard !isoDates.isEmpty else { return [] }

        // Everything already cached → return without a network call.
        let cached = isoDates.compactMap { cache[$0] }
        if cached.count == isoDates.count { return cached }

        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let anyInHorizon = isoDates.contains { iso in
            guard let d = Self.isoFormatter.date(from: iso) else { return false }
            let out = cal.dateComponents([.day], from: today, to: cal.startOfDay(for: d)).day ?? 999
            return out >= 0 && out <= maxForecastDays
        }
        guard anyInHorizon else { return cached }

        await refreshDaily(coordinate: coordinate)
        return isoDates.compactMap { cache[$0] }
    }

    // MARK: Fetch

    @MainActor
    private func refreshDaily(coordinate: CLLocationCoordinate2D) async {
        if let running = dailyTask {
            _ = await running.value   // the owner stores the result in the cache
            return
        }
        let task = Task { await Self.fetchDaily(coordinate: coordinate) }
        dailyTask = task
        let days = await task.value
        dailyTask = nil
        guard let days else { return }
        for d in days { cache[d.iso] = d.eventForecast }
    }

    /// WeatherKit under a hard timeout, with Open-Meteo already running alongside
    /// so a hung or failed WeatherKit costs nothing extra.
    private static func fetchDaily(coordinate: CLLocationCoordinate2D) async -> [WeatherDay]? {
        let t0 = Date()
        let openMeteo = Task { () -> [WeatherDay]? in
            do {
                let r = try await OpenMeteoClient.fetch(forecastDays: 10)
                return Self.days(from: r)
            } catch {
                weatherLog.error("Event forecast: Open-Meteo failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        let lat = coordinate.latitude, lon = coordinate.longitude
        do {
            let days = try await withWeatherTimeout(seconds: weatherKitTimeout) { () -> [WeatherDay] in
                let daily = try await WeatherKit.WeatherService.shared.weather(
                    for: CLLocation(latitude: lat, longitude: lon), including: .daily)
                let fmt = Self.makeISOFormatter()
                return daily.forecast.map {
                    WeatherDay(iso: fmt.string(from: $0.date),
                               highC: $0.highTemperature.converted(to: .celsius).value,
                               lowC: $0.lowTemperature.converted(to: .celsius).value,
                               symbolName: $0.symbolName,
                               condition: $0.condition.description,
                               precipitationChance: $0.precipitationChance,
                               fromWeatherKit: true)
                }
            }
            openMeteo.cancel()
            weatherLog.info("Event forecast: WeatherKit won in \(Date().timeIntervalSince(t0), format: .fixed(precision: 2))s")
            return days
        } catch let e as WeatherTimeoutError {
            weatherLog.error("Event forecast: WeatherKit timed out after \(Int(e.seconds))s, using Open-Meteo")
        } catch {
            weatherLog.error("Event forecast: WeatherKit error: \(String(describing: error), privacy: .public); using Open-Meteo")
        }
        let days = await openMeteo.value
        weatherLog.info("Event forecast: Open-Meteo \(days == nil ? "failed" : "won") after \(Date().timeIntervalSince(t0), format: .fixed(precision: 2))s")
        return days
    }

    private static func days(from r: OpenMeteoForecast) -> [WeatherDay] {
        let d = r.daily
        var out: [WeatherDay] = []
        for i in 0..<d.time.count {
            guard i < d.temperature_2m_max.count, i < d.temperature_2m_min.count,
                  i < d.weather_code.count else { continue }
            let p = i < d.precipitation_probability_max.count ? (d.precipitation_probability_max[i] ?? 0) : 0
            out.append(WeatherDay(iso: d.time[i],
                                  highC: (d.temperature_2m_max[i] - 32) * 5 / 9,
                                  lowC: (d.temperature_2m_min[i] - 32) * 5 / 9,
                                  symbolName: OpenMeteoClient.symbol(forWMO: d.weather_code[i]),
                                  condition: OpenMeteoClient.condition(forWMO: d.weather_code[i]),
                                  precipitationChance: p / 100,
                                  fromWeatherKit: false))
        }
        return out
    }

    private static func makeISOFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "America/Chicago")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    /// The inclusive list of ISO day strings from start to end (end defaults to start).
    static func dateRange(startISO: String, endISO: String?) -> [String] {
        guard let start = isoFormatter.date(from: startISO) else { return [] }
        let end = endISO.flatMap { isoFormatter.date(from: $0) } ?? start
        let cal = Calendar.current
        var out: [String] = []
        var day = cal.startOfDay(for: start)
        let last = cal.startOfDay(for: end)
        while day <= last && out.count < 14 {   // 14-day cap as a safety valve
            out.append(isoFormatter.string(from: day))
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out
    }

    static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "America/Chicago")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

// MARK: - Forecast model

struct EventForecast: Identifiable, Equatable {
    var id: String { isoDate }
    let isoDate: String
    let highC: Double
    let lowC: Double
    let highF: Double
    let lowF: Double
    let symbolName: String   // SF Symbol from WeatherKit (e.g. "cloud.sun.fill")
    let condition: String    // e.g. "Partly Cloudy"
    let precipitationChance: Double // 0...1
    /// True when the numbers came from Apple WeatherKit (attribution required);
    /// false for the Open-Meteo fallback (nothing Apple-branded may be shown).
    var fromWeatherKit: Bool = true

    func highLabel(fahrenheit: Bool = true) -> String {
        fahrenheit ? "\(Int(highF.rounded()))°" : "\(Int(highC.rounded()))°"
    }
    func lowLabel(fahrenheit: Bool = true) -> String {
        fahrenheit ? "\(Int(lowF.rounded()))°" : "\(Int(lowC.rounded()))°"
    }
    var precipPercent: Int { Int((precipitationChance * 100).rounded()) }

    private var date: Date? { WeatherService.isoFormatter.date(from: isoDate) }

    /// Short weekday, e.g. "Fri".
    var weekdayLabel: String {
        guard let date else { return isoDate }
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "America/Chicago")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE"
        return f.string(from: date)
    }

    /// Month + day, e.g. "Jul 4".
    var shortDateLabel: String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "America/Chicago")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}
