import Foundation
import Observation

// MARK: - Models

struct OuraDailySleep: Sendable {
    let day: String
    let score: Int?
    // From /daily_sleep
    let efficiency: Int?
    // From /sleep sessions (aggregated)
    let totalSleepDuration: Int?   // seconds
    let remSleepDuration: Int?     // seconds
    let deepSleepDuration: Int?    // seconds
    let lightSleepDuration: Int?   // seconds
    let lowestHeartRate: Int?
    let averageHrv: Int?
}

struct OuraDailyReadiness: Sendable {
    let day: String
    let score: Int?
    let temperatureDeviation: Double?
    let activityBalance: Int?
    let bodyBalance: Int?
    let recoveryIndex: Int?
    let restingHeartRate: Int?
    let hrvBalance: Int?
    let previousNightScore: Int?
    let sleepBalance: Int?
}

struct OuraDailyActivity: Sendable {
    let day: String
    let score: Int?
    let activeCalories: Int?
    let steps: Int?
    let equivalentWalkingDistance: Int?
    let highActivityTime: Int?
    let mediumActivityTime: Int?
    let lowActivityTime: Int?
    let restTime: Int?
    let sedentaryTime: Int?
}

struct OuraSleepTime: Sendable {
    let day: String
    /// Seconds offset from midnight (negative = before midnight, e.g. -3600 = 11 PM)
    let startOffset: Int?
    /// "improve_efficiency" | "earlier_bedtime" | "later_bedtime" | "maintain_routine"
    let recommendation: String?
    /// True when this came from Oura's API; false = user default fallback (10:30 PM)
    let isOuraRecommended: Bool

    /// The recommended bedtime as a Date, or nil if unavailable
    var bedtimeDate: Date? {
        guard let offset = startOffset else { return nil }
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 0; comps.minute = 0; comps.second = 0
        guard let midnight = cal.date(from: comps) else { return nil }
        return midnight.addingTimeInterval(TimeInterval(offset))
    }

    var recommendationLabel: String {
        switch recommendation {
        case "earlier_bedtime":  return "earlier than usual"
        case "later_bedtime":    return "later than usual"
        case "maintain_routine": return "maintain routine"
        default:                 return ""
        }
    }

    /// Default 10:30 PM target when Oura has no recommendation
    static func userDefault() -> OuraSleepTime {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 22; comps.minute = 30; comps.second = 0
        let date = Calendar.current.date(from: comps) ?? Date()
        let offset = Int(date.timeIntervalSince(
            Calendar.current.startOfDay(for: date).addingTimeInterval(0)
        ))
        // offset from midnight: 22.5h * 3600 = 81000s
        return OuraSleepTime(day: "", startOffset: 81000, recommendation: nil, isOuraRecommended: false)
    }
}

// MARK: - OuraService

@Observable
final class OuraService {

    static let shared = OuraService()
    private init() {}

    var sleep: OuraDailySleep?
    var readiness: OuraDailyReadiness?
    var activity: OuraDailyActivity?
    var sleepTime: OuraSleepTime?
    var isLoading = false
    var lastError: String?
    var lastFetchedDay: String?

    // MARK: - Fetch today

    @MainActor
    func fetchToday() async {
        let token = UserDefaults.standard.string(forKey: "oura_token") ?? ""
        guard !token.isEmpty else {
            lastError = "No Oura token configured. Add it in Settings."
            return
        }

        isLoading = true
        lastError = nil

        let today     = dateString(for: Date())
        // Sleep sessions are tagged by START date — last night's sleep started yesterday
        let yesterday = dateString(for: Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())

        async let sleepResult         = fetchSleep(token: token, date: today)
        async let sleepSessionsResult = fetchSleepSessions(token: token, startDate: yesterday, endDate: today)
        async let readyResult         = fetchReadiness(token: token, date: today)
        async let activityResult      = fetchRecentActivity(token: token)
        async let sleepTimeResult     = fetchSleepTime(token: token, date: today)

        let (sleepBase, sessions, r, a, st) = await (
            sleepResult, sleepSessionsResult, readyResult, activityResult, sleepTimeResult
        )

        // Merge daily_sleep score with session-level detail
        if let base = sleepBase {
            sleep = OuraDailySleep(
                day:                base.day,
                score:              base.score,
                efficiency:         base.efficiency,
                totalSleepDuration: sessions?.totalSleepDuration ?? base.totalSleepDuration,
                remSleepDuration:   sessions?.remSleepDuration   ?? base.remSleepDuration,
                deepSleepDuration:  sessions?.deepSleepDuration  ?? base.deepSleepDuration,
                lightSleepDuration: sessions?.lightSleepDuration ?? base.lightSleepDuration,
                lowestHeartRate:    sessions?.lowestHeartRate    ?? base.lowestHeartRate,
                averageHrv:         sessions?.averageHrv         ?? base.averageHrv
            )
        } else {
            sleep = sessions
        }

        readiness      = r
        activity       = a
        sleepTime      = st
        lastFetchedDay = today
        isLoading      = false
    }

    // MARK: - Private fetch helpers

    private func fetchSleep(token: String, date: String) async -> OuraDailySleep? {
        guard let data = await get("/v2/usercollection/daily_sleep", token: token,
                                   start: date, end: date) else { return nil }
        guard let root  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]],
              let item  = items.first(where: { ($0["day"] as? String) == date }) else { return nil }

        let contributors = item["contributors"] as? [String: Any] ?? [:]

        return OuraDailySleep(
            day:                date,
            score:              item["score"] as? Int,
            efficiency:         contributors["efficiency"] as? Int,
            totalSleepDuration: nil,
            remSleepDuration:   nil,
            deepSleepDuration:  nil,
            lightSleepDuration: nil,
            lowestHeartRate:    nil,
            averageHrv:         nil
        )
    }

    /// Fetches sleep sessions for a date range and aggregates duration + HRV.
    /// Uses a range because sessions are tagged by START date (last night = yesterday).
    private func fetchSleepSessions(token: String, startDate: String, endDate: String) async -> OuraDailySleep? {
        guard let data = await get("/v2/usercollection/sleep", token: token,
                                   start: startDate, end: endDate) else { return nil }
        guard let root  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]] else { return nil }

        // Exclude naps (type == "rest" or duration < 3h) — take long sleep sessions only
        let sessions = items.filter {
            let type = $0["type"] as? String ?? ""
            return type != "rest"
        }
        guard !sessions.isEmpty else { return nil }

        // Aggregate: sum durations, average HRV and HR across sessions
        let totalDuration  = sessions.compactMap { $0["total_sleep_duration"] as? Int }.reduce(0, +)
        let remDuration    = sessions.compactMap { $0["rem_sleep_duration"]   as? Int }.reduce(0, +)
        let deepDuration   = sessions.compactMap { $0["deep_sleep_duration"]  as? Int }.reduce(0, +)
        let lightDuration  = sessions.compactMap { $0["light_sleep_duration"] as? Int }.reduce(0, +)
        let hrvValues      = sessions.compactMap { $0["average_hrv"]          as? Double }
        let hrValues       = sessions.compactMap { $0["lowest_heart_rate"]    as? Int }

        let avgHrv = hrvValues.isEmpty ? nil : Int(hrvValues.reduce(0, +) / Double(hrvValues.count))
        let minHR  = hrValues.isEmpty  ? nil : hrValues.min()

        return OuraDailySleep(
            day:                endDate,
            score:              nil,
            efficiency:         nil,
            totalSleepDuration: totalDuration > 0 ? totalDuration : nil,
            remSleepDuration:   remDuration   > 0 ? remDuration   : nil,
            deepSleepDuration:  deepDuration  > 0 ? deepDuration  : nil,
            lightSleepDuration: lightDuration > 0 ? lightDuration : nil,
            lowestHeartRate:    minHR,
            averageHrv:         avgHrv
        )
    }

    private func fetchReadiness(token: String, date: String) async -> OuraDailyReadiness? {
        guard let data = await get("/v2/usercollection/daily_readiness", token: token,
                                   start: date, end: date) else { return nil }
        guard let root  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]],
              let item  = items.first(where: { ($0["day"] as? String) == date }) else { return nil }

        let contributors = item["contributors"] as? [String: Any] ?? [:]

        return OuraDailyReadiness(
            day:                  date,
            score:                item["score"] as? Int,
            temperatureDeviation: item["temperature_deviation"] as? Double,
            activityBalance:      contributors["activity_balance"] as? Int,
            bodyBalance:          contributors["body_temperature"] as? Int,
            recoveryIndex:        contributors["recovery_index"]   as? Int,
            // Note: contributors["resting_heart_rate"] is a 0-100 score, NOT bpm.
            // Actual RHR bpm comes from sleep sessions (lowestHeartRate).
            restingHeartRate:     nil,
            hrvBalance:           contributors["hrv_balance"] as? Int,
            previousNightScore:   contributors["previous_night"] as? Int,
            sleepBalance:         contributors["sleep_balance"]  as? Int
        )
    }

    /// Fetches the 7 most recent days of activity and returns the latest entry.
    /// More robust than exact-date matching since Oura sometimes lags a day.
    private func fetchRecentActivity(token: String) async -> OuraDailyActivity? {
        let endDate   = dateString(for: Date())
        let startDate = dateString(for: Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date())
        guard let data = await get("/v2/usercollection/daily_activity", token: token,
                                   start: startDate, end: endDate) else { return nil }
        guard let root  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]] else { return nil }

        // Take the most recent day available
        let sorted = items.sorted { ($0["day"] as? String ?? "") > ($1["day"] as? String ?? "") }
        guard let item = sorted.first else { return nil }

        return OuraDailyActivity(
            day:                        item["day"] as? String ?? endDate,
            score:                      item["score"] as? Int,
            activeCalories:             item["active_calories"] as? Int,
            steps:                      item["steps"] as? Int,
            equivalentWalkingDistance:  item["equivalent_walking_distance"] as? Int,
            highActivityTime:           item["high_activity_time"] as? Int,
            mediumActivityTime:         item["medium_activity_time"] as? Int,
            lowActivityTime:            item["low_activity_time"]   as? Int,
            restTime:                   item["rest_time"]           as? Int,
            sedentaryTime:              item["sedentary_time"]      as? Int
        )
    }

    private func fetchSleepTime(token: String, date: String) async -> OuraSleepTime? {
        guard let data = await get("/v2/usercollection/sleep_time", token: token,
                                   start: date, end: date) else { return nil }
        guard let root  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]],
              let item  = items.first else { return nil }

        let optimal = item["optimal_bedtime"] as? [String: Any]
        return OuraSleepTime(
            day:                item["day"] as? String ?? date,
            startOffset:        optimal?["start_offset"] as? Int,
            recommendation:     item["recommendation"] as? String,
            isOuraRecommended:  true
        )
    }

    // MARK: - Networking

    private func get(_ path: String, token: String, start: String, end: String) async -> Data? {
        var components = URLComponents(string: "https://api.ouraring.com\(path)")
        components?.queryItems = [
            URLQueryItem(name: "start_date", value: start),
            URLQueryItem(name: "end_date",   value: end)
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 401 {
                await MainActor.run { lastError = "Oura token invalid or expired. Check Settings." }
                return nil
            }
            guard (200..<300).contains(http.statusCode) else { return nil }
            return data
        } catch {
            await MainActor.run { lastError = "Oura fetch failed: \(error.localizedDescription)" }
            return nil
        }
    }

    // MARK: - Helpers

    private func dateString(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = .current
        return fmt.string(from: date)
    }

    static func formatDuration(_ seconds: Int?) -> String? {
        guard let s = seconds, s > 0 else { return nil }
        let h = s / 3600
        let m = (s % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static func scoreColor(_ score: Int?) -> ScoreColor {
        guard let score else { return .unknown }
        if score >= 85 { return .good }
        if score >= 70 { return .fair }
        return .poor
    }

    enum ScoreColor { case good, fair, poor, unknown }
}
