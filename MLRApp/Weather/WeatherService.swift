import Foundation
import WeatherKit
import CoreLocation
import FoundationModels

// MARK: - Weather Service (WeatherKit)
//
// Fetches the forecast for resort events. WeatherKit's daily forecast reaches ~10
// days out, so near-term events get a forecast and far-out ones simply don't — the
// UI hides the badge when `forecast(for:)` returns nil.
//
// Requirements:
//   • Add the WeatherKit capability to the App ID (developer.apple.com) and the
//     Xcode target (Signing & Capabilities → + WeatherKit).
//   • Add NSLocationWhenInUseUsageDescription if you ever resolve "my location";
//     for events we use the fixed resort coordinate so no permission is needed.
//   • Apple requires attribution — see `WeatherAttribution` usage in the UI.
//
// All resort events happen at the resort, so we anchor every forecast to the
// resort's coordinate rather than the device location.

@Observable
final class WeatherService {
    static let shared = WeatherService()

    /// Muskellunge Lake Resort, Tomahawk, WI.
    static let resortCoordinate = CLLocationCoordinate2D(latitude: 45.53492, longitude: -89.69830)

    private let service = WeatherKit.WeatherService.shared
    private let maxForecastDays = 10

    /// Cache keyed by ISO date string so we don't refetch per card.
    private var cache: [String: EventForecast] = [:]
    private var inFlight: Set<String> = []

    private init() {}

    /// Returns a forecast for an event's start date if WeatherKit has one
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
        guard !inFlight.contains(iso) else { return nil }
        inFlight.insert(iso)
        defer { inFlight.remove(iso) }

        do {
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let daily = try await service.weather(for: location, including: .daily)
            guard let day = daily.first(where: {
                cal.isDate($0.date, inSameDayAs: targetDate)
            }) else { return nil }

            let forecast = EventForecast(
                isoDate: iso,
                highC: day.highTemperature.value,
                lowC: day.lowTemperature.value,
                highF: day.highTemperature.converted(to: .fahrenheit).value,
                lowF: day.lowTemperature.converted(to: .fahrenheit).value,
                symbolName: day.symbolName,
                condition: day.condition.description,
                precipitationChance: day.precipitationChance
            )
            cache[iso] = forecast
            return forecast
        } catch {
            print("[WeatherService] forecast error for \(iso): \(error)")
            return nil
        }
    }

    /// Forecasts for every day in `[startISO, endISO]` (inclusive) that WeatherKit
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

        do {
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let daily = try await service.weather(for: location, including: .daily)
            var results: [EventForecast] = []
            for iso in isoDates {
                if let hit = cache[iso] { results.append(hit); continue }
                guard let target = Self.isoFormatter.date(from: iso),
                      let day = daily.first(where: { cal.isDate($0.date, inSameDayAs: target) })
                else { continue }
                let forecast = EventForecast(
                    isoDate: iso,
                    highC: day.highTemperature.value,
                    lowC: day.lowTemperature.value,
                    highF: day.highTemperature.converted(to: .fahrenheit).value,
                    lowF: day.lowTemperature.converted(to: .fahrenheit).value,
                    symbolName: day.symbolName,
                    condition: day.condition.description,
                    precipitationChance: day.precipitationChance
                )
                cache[iso] = forecast
                results.append(forecast)
            }
            return results
        } catch {
            print("[WeatherService] forecasts error \(startISO)…\(endISO ?? startISO): \(error)")
            return cached
        }
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

// MARK: - Weather Summarizer (Apple Intelligence / FoundationModels)
//
// Turns a multi-day forecast into a short, friendly planning blurb using the
// on-device model. Availability depends on the device supporting Apple
// Intelligence and it being turned on; callers hide the summary when it returns
// nil, so nothing breaks on unsupported devices.

enum WeatherSummarizer {
    /// Whether the on-device model is ready to generate text right now.
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static func summarize(eventTitle: String, forecasts: [EventForecast]) async -> String? {
        guard isAvailable, !forecasts.isEmpty else { return nil }

        let lines = forecasts.map { f in
            "\(f.weekdayLabel) \(f.shortDateLabel): \(f.condition), high \(f.highLabel()), low \(f.lowLabel()), \(f.precipPercent)% chance of precipitation"
        }.joined(separator: "\n")

        let session = LanguageModelSession(instructions: """
            You write short, warm weather blurbs for a family lake-resort app in the \
            northwoods of Wisconsin. Given a multi-day forecast for an event, write ONE \
            to TWO sentences (under 45 words) that help a family plan: call out the \
            nicest day, any rain to watch for, and a practical tip (layers, sunscreen, \
            a rain backup). Be friendly and natural — do not just list each day.
            """)

        let prompt = """
            Event: \(eventTitle)
            Forecast:
            \(lines)

            Write the summary.
            """

        do {
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            print("[WeatherSummarizer] summarize error: \(error)")
            return nil
        }
    }
}
