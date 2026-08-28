//
//  DayflowHomeWeather.swift
//  Dayflow
//
//  The masthead kicker's weather (Session 77 Editorial skin — the locked
//  frame reads "AUGUST · 78° AND CLEAR"). The widget already fetches
//  Open-Meteo (DayflowWidget.swift, switched off WeatherKit 2026-07-26),
//  but that code lives in the widget target and caches for the widget's
//  needs, so the app screen gets its own minimal current-conditions fetch:
//  same host, current temperature + weather code only, 30-minute in-memory
//  cache. Location is the system's cached fix — DayflowLocationPrimer
//  already asks for when-in-use on first launch, and the Simulator usually
//  has no fix at all, which is why the Simulator shows the month alone:
//  every failure path here just leaves `kicker` nil and the masthead
//  degrades to "AUGUST".
//

import Foundation
import CoreLocation
import Observation

@MainActor
@Observable
final class DayflowHomeWeather {
    static let shared = DayflowHomeWeather()

    /// e.g. "78° AND CLEAR" — nil until a fetch lands.
    private(set) var kicker: String? = nil
    private var fetchedAt: Date? = nil

    private init() {}

    func refresh() async {
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < 1800, kicker != nil { return }
        guard let location = CLLocationManager().location else { return }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(location.coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(location.coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "temperature_unit", value: "celsius"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1"),
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(Response.self, from: data)
        else { return }
        let unit = UnitTemperature(forLocale: .current)
        let temp = Int(Measurement(value: decoded.current.temperature_2m,
                                   unit: UnitTemperature.celsius)
            .converted(to: unit).value.rounded())
        kicker = "\(temp)\u{00B0} AND \(Self.word(forWeatherCode: decoded.current.weather_code))"
        fetchedAt = Date()
    }

    private struct Response: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let weather_code: Int
        }
        let current: Current
    }

    /// WMO weather codes → one calm word, uppercased for the kicker's
    /// small-caps line. Deliberately coarse — the kicker is furniture, not a
    /// forecast; the widget carries the detailed version.
    private static func word(forWeatherCode code: Int) -> String {
        switch code {
        case 0, 1:            return "CLEAR"
        case 2, 3:            return "CLOUDS"
        case 45, 48:          return "FOG"
        case 51...57:         return "DRIZZLE"
        case 61...67:         return "RAIN"
        case 71...77, 85, 86: return "SNOW"
        case 80...82:         return "SHOWERS"
        case 95...99:         return "STORMS"
        default:              return "CLOUDS"
        }
    }
}
