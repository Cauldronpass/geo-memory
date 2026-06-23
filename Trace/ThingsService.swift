import Foundation
import Observation

// MARK: - Models

struct ThingsTask: Identifiable, Codable {
    let id: String
    let title: String
    let list: String?   // Things project or area name ("Work", "Personal", etc.)
}

private struct ThingsTodayResponse: Codable {
    let count: Int
    let tasks: [ThingsTask]
    let inbox_count: Int?
}

// MARK: - Service

/// Fetches today's tasks from the things-api REST wrapper running on Mac Mini (over Tailscale).
/// Falls back to a UserDefaults cache for up to 6 hours if the Mini is unreachable.
/// Section is hidden entirely if no URL is configured or cache is > 6 hours old.
@Observable
final class ThingsService {
    static let shared = ThingsService()
    private init() { loadCache() }

    var tasks: [ThingsTask] = []
    var totalCount: Int = 0
    var inboxCount: Int = 0
    var isLoading = false
    private(set) var lastFetched: Date?

    private let cacheTasksKey    = "things_cache_tasks"
    private let cacheCountKey    = "things_cache_count"
    private let cacheInboxKey    = "things_cache_inbox"
    private let cacheDateKey     = "things_cache_date"
    private let maxCacheAge: TimeInterval = 6 * 3600   // 6 hours

    /// True when the section should be rendered (URL configured + data not stale).
    var shouldShow: Bool {
        guard let url = UserDefaults.standard.string(forKey: "things_api_url"), !url.isEmpty else { return false }
        guard let fetched = lastFetched else { return false }
        return Date().timeIntervalSince(fetched) < maxCacheAge
    }

    // MARK: - Fetch

    func fetch() async {
        guard let rawURL = UserDefaults.standard.string(forKey: "things_api_url"),
              !rawURL.isEmpty else { return }

        let base = rawURL.hasSuffix("/") ? rawURL : rawURL + "/"
        guard let url = URL(string: base + "today") else { return }

        await MainActor.run { isLoading = true }

        do {
            var request = URLRequest(url: url, timeoutInterval: 8)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let decoded = try JSONDecoder().decode(ThingsTodayResponse.self, from: data)
            await MainActor.run {
                tasks = decoded.tasks
                totalCount = decoded.count
                inboxCount = decoded.inbox_count ?? 0
                lastFetched = Date()
                isLoading = false
            }
            saveCache()
        } catch {
            // Silent fail — cached data stays visible if within maxCacheAge
            await MainActor.run { isLoading = false }
        }
    }

    // MARK: - Cache

    private func saveCache() {
        if let data = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(data, forKey: cacheTasksKey)
        }
        UserDefaults.standard.set(totalCount, forKey: cacheCountKey)
        UserDefaults.standard.set(inboxCount, forKey: cacheInboxKey)
        UserDefaults.standard.set(lastFetched, forKey: cacheDateKey)
    }

    private func loadCache() {
        lastFetched = UserDefaults.standard.object(forKey: cacheDateKey) as? Date
        totalCount  = UserDefaults.standard.integer(forKey: cacheCountKey)
        inboxCount  = UserDefaults.standard.integer(forKey: cacheInboxKey)
        if let data = UserDefaults.standard.data(forKey: cacheTasksKey),
           let decoded = try? JSONDecoder().decode([ThingsTask].self, from: data) {
            tasks = decoded
        }
    }
}
