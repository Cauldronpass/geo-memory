import Foundation
import Observation

// MARK: - Models

struct ThingsTask: Identifiable, Codable {
    let id: String                     // mapped from "uuid"
    let title: String
    let list: String?                  // mapped from "project_title" (area/project name)
    let scheduledDateString: String?   // mapped from "scheduled_date" ("yyyy-MM-dd" or "")
    /// Freeform notes text. Added 2026-07-20 alongside DayflowTaskEditSheet's
    /// notes field/quick-add's notes field — the Mini bridge now sends this on
    /// all four GET endpoints (always a real string, "" for a to-do with no
    /// notes, never missing/null). Optional here anyway so decoding an old
    /// cached response from before this change (UserDefaults cache, see
    /// saveCache()/loadCache() below) doesn't fail — a missing key just
    /// decodes to nil rather than throwing.
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case id = "uuid"
        case title
        case list = "project_title"
        case scheduledDateString = "scheduled_date"
        case notes
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Real scheduled date, parsed from the Mini bridge's `scheduled_date` field.
    /// Added 2026-07-20 alongside the `/anytime` and `/upcoming` endpoints — needed
    /// so an edit (DayflowTaskEditSheet) always knows a task's true current date
    /// rather than risking a silent, destructive clear. Nil for undated tasks; the
    /// bridge sends `""` rather than omitting the key, so both are checked.
    var date: Date? {
        guard let s = scheduledDateString, !s.isEmpty else { return nil }
        return Self.dateFormatter.date(from: s)
    }
}

private struct ThingsResponse: Decodable {
    let today: [ThingsTask]
    let inboxCount: Int

    enum CodingKeys: String, CodingKey {
        case today
        case inboxCount = "inbox_count"
    }
}

private struct AnytimeResponse: Decodable {
    let anytime: [ThingsTask]
}

private struct UpcomingResponse: Decodable {
    let upcoming: [ThingsTask]
}

private struct InboxResponse: Decodable {
    let inbox: [ThingsTask]
}

private struct UpdateResponse: Decodable {
    let success: Bool
}

// MARK: - Service

/// Fetches today's tasks from the things-api REST wrapper running on Mac Mini (over Tailscale).
/// Falls back to a UserDefaults cache for up to 6 hours if the Mini is unreachable.
/// Section is hidden entirely if no URL is configured or cache is > 6 hours old.
///
/// **Extended 2026-07-20** with real Anytime and Upcoming list sources
/// (`/anytime`, `/upcoming` on the Mini bridge) and an `update(...)` call
/// (`/update`) so a task's title/date/list can be edited from Dayflow directly —
/// see DayflowTaskEditSheet.swift. Previously Dayflow's Anytime/Upcoming browse
/// views had no real per-task data source at all; see DayflowAnytimeView.swift
/// and DayflowUpcomingView.swift header comments for the before/after.
///
/// **Extended again 2026-07-20 (step 5b)** with a real Inbox list source
/// (`/inbox` on the Mini bridge) for Dayflow's fourth Browse destination — see
/// DayflowInboxView.swift.
@Observable
final class ThingsService {
    static let shared = ThingsService()
    private init() { loadCache() }

    var tasks: [ThingsTask] = []
    var totalCount: Int = 0
    var inboxCount: Int = 0
    var isLoading = false
    private(set) var lastFetched: Date?
    private(set) var lastError: String?

    /// Real Things Anytime list — every no-date task across all areas/projects.
    /// Replaces the old stand-in of reusing `tasks` (today's list only).
    var anytimeTasks: [ThingsTask] = []
    var isLoadingAnytime = false

    /// Real Things Upcoming list — every future-dated task across all lists.
    var upcomingTasks: [ThingsTask] = []
    var isLoadingUpcoming = false

    /// Real Things Inbox list — every unfiled, undated capture. Added 2026-07-20
    /// (step 5b) for DayflowInboxView.
    var inboxTasks: [ThingsTask] = []
    var isLoadingInbox = false

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

    /// True when a Things API URL is configured (regardless of whether fetch succeeded).
    var isConfigured: Bool {
        guard let url = UserDefaults.standard.string(forKey: "things_api_url"), !url.isEmpty else { return false }
        return true
    }

    private func baseURL() -> URL? {
        guard let rawURL = UserDefaults.standard.string(forKey: "things_api_url"), !rawURL.isEmpty else { return nil }
        let base = rawURL.hasSuffix("/") ? rawURL : rawURL + "/"
        return URL(string: base)
    }

    private func authorize(_ request: inout URLRequest) {
        if let token = UserDefaults.standard.string(forKey: "things_api_token"), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Logs a fetch failure to the Xcode console with real detail — added
    /// 2026-07-20 after every fetch's catch block turned out to be completely
    /// silent (no print, no visible UI signal beyond an array staying empty),
    /// which made a real regression (Agenda/Upcoming losing all Things data
    /// after this session's changes) undiagnosable from outside Xcode. Prints
    /// the specific `DecodingError` case (missing key, type mismatch, etc.)
    /// when that's what happened, since "decode failed" alone doesn't say
    /// which field or why.
    private func logFetchError(_ endpoint: String, _ error: Error) {
        if let decodingError = error as? DecodingError {
            print("[ThingsService] \(endpoint) decode failed: \(decodingError)")
        } else {
            print("[ThingsService] \(endpoint) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Fetch (Today)

    func fetch() async {
        guard let base = baseURL(), let url = URL(string: "today", relativeTo: base) else {
            print("[ThingsService] /today skipped — no things_api_url configured")
            return
        }

        await MainActor.run { isLoading = true }

        do {
            // 4-second timeout — short enough to fail fast in simulator if Mini is unreachable.
            var request = URLRequest(url: url, timeoutInterval: 4)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            authorize(&request)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let decoded = try JSONDecoder().decode(ThingsResponse.self, from: data)
            await MainActor.run {
                tasks = decoded.today
                totalCount = decoded.today.count
                inboxCount = decoded.inboxCount
                lastFetched = Date()
                isLoading = false
            }
            saveCache()
        } catch {
            // Cached data stays visible if within maxCacheAge — but now at
            // least logged, see logFetchError()'s header comment.
            logFetchError("/today", error)
            await MainActor.run {
                lastError = error.localizedDescription
                isLoading = false
            }
        }
    }

    // MARK: - Fetch (Anytime)

    /// Pulls the real Things Anytime list from the Mini bridge's `/anytime`
    /// endpoint. Silent fail, no caching (unlike `fetch()`) — this is a browse
    /// view data source, not something shown on the always-visible main screen.
    ///
    /// **Timeout bumped 6s → 20s, 2026-07-20.** `/upcoming` (same risk profile —
    /// see that function) was measured timing out at 6.37s after the notes
    /// feature added a `task.notes()` JXA/AppleScript-bridge call per task on
    /// every GET endpoint; each bridge call carries real per-call overhead, so
    /// larger lists like Anytime/Upcoming are the ones at risk, not `/today`
    /// (small list, still fine at 4s). Bumped preventively here even though
    /// only `/upcoming` was confirmed timing out, since the same per-item cost
    /// applies equally to this endpoint.
    func fetchAnytime() async {
        guard let base = baseURL(), let url = URL(string: "anytime", relativeTo: base) else {
            print("[ThingsService] /anytime skipped — no things_api_url configured")
            return
        }

        await MainActor.run { isLoadingAnytime = true }
        do {
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            authorize(&request)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let decoded = try JSONDecoder().decode(AnytimeResponse.self, from: data)
            await MainActor.run {
                anytimeTasks = decoded.anytime
                isLoadingAnytime = false
            }
        } catch {
            logFetchError("/anytime", error)
            await MainActor.run { isLoadingAnytime = false }
        }
    }

    // MARK: - Fetch (Upcoming)

    /// Pulls the real Things Upcoming list from the Mini bridge's `/upcoming`
    /// endpoint. Same silent-fail, no-cache pattern as `fetchAnytime()`.
    ///
    /// **Timeout bumped 6s → 20s, 2026-07-20.** Root cause of a same-day
    /// "Agenda/Upcoming lost all data" report: confirmed via console log
    /// (`[ThingsService] /upcoming failed: The request timed out.`) plus a
    /// direct `curl -w "%{time_total}"` measurement on the Mini (6.37s) that
    /// this endpoint was landing just past the old 6s timeout. The notes
    /// feature added a `task.notes()` JXA/AppleScript-bridge call per task on
    /// every GET endpoint; each bridge call has real overhead, and `/upcoming`
    /// (a larger list than `/today`) pushed the accumulated cost over the old
    /// timeout. No backend change needed — this was purely a client-side
    /// timeout sized for pre-notes response times.
    func fetchUpcoming() async {
        guard let base = baseURL(), let url = URL(string: "upcoming", relativeTo: base) else {
            print("[ThingsService] /upcoming skipped — no things_api_url configured")
            return
        }

        await MainActor.run { isLoadingUpcoming = true }
        do {
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            authorize(&request)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let decoded = try JSONDecoder().decode(UpcomingResponse.self, from: data)
            await MainActor.run {
                upcomingTasks = decoded.upcoming
                isLoadingUpcoming = false
            }
        } catch {
            logFetchError("/upcoming", error)
            await MainActor.run { isLoadingUpcoming = false }
        }
    }

    // MARK: - Fetch (Inbox)

    /// Pulls the real Things Inbox list from the Mini bridge's `/inbox`
    /// endpoint. Same silent-fail, no-cache pattern as `fetchAnytime()` /
    /// `fetchUpcoming()`. Distinct from `inboxCount` (an `Int` sourced from
    /// `/today`'s `inbox_count` field) — that's a count only, this is the real
    /// task list, needed once Dayflow has an actual Inbox browse view to render.
    ///
    /// **Timeout bumped 6s → 20s, 2026-07-20.** Same preventive reasoning as
    /// `fetchAnytime()` — see `fetchUpcoming()`'s header comment for the
    /// confirmed root cause this matches.
    func fetchInbox() async {
        guard let base = baseURL(), let url = URL(string: "inbox", relativeTo: base) else {
            print("[ThingsService] /inbox skipped — no things_api_url configured")
            return
        }

        await MainActor.run { isLoadingInbox = true }
        do {
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            authorize(&request)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let decoded = try JSONDecoder().decode(InboxResponse.self, from: data)
            await MainActor.run {
                inboxTasks = decoded.inbox
                isLoadingInbox = false
            }
        } catch {
            logFetchError("/inbox", error)
            await MainActor.run { isLoadingInbox = false }
        }
    }

    // MARK: - Refresh all

    /// Re-runs all four GET fetches. Added 2026-07-20 — David hit a real gap
    /// where a note edited directly in Things (outside Dayflow) didn't show up
    /// when reopening that task in Dayflow, since nothing here re-fetches on
    /// its own once a view has already loaded once. Used by
    /// `DayflowContentView.swift`'s foreground-return auto-refresh and
    /// available for any view's own pull-to-refresh to call instead of a
    /// single endpoint, where "just get everything current" is simpler than
    /// reasoning about which one list actually needs it.
    ///
    /// **Sequential, not concurrent — found the hard way, same day.** The
    /// first version fired all four with `async let`. `things-jxa-server.py`
    /// runs a plain `http.server.HTTPServer` (confirmed via its own source —
    /// no `ThreadingMixIn`/`ThreadingHTTPServer`), which only ever processes
    /// one request at a time; four simultaneous requests just queue at the
    /// socket level rather than actually running in parallel. Once the notes
    /// feature made `/anytime`/`/upcoming`/`/inbox` each take several seconds
    /// (see `fetchUpcoming()`'s own header comment), whichever request landed
    /// last in that queue could sit waiting long enough to blow even
    /// `/today`'s comparatively generous 4s timeout — confirmed via console:
    /// `[ThingsService] /today failed: The request timed out.`, immediately
    /// after this function started being called from the new foreground
    /// auto-refresh. Sequential awaits take longer wall-clock overall (sum of
    /// four instead of the slowest one), but that's the honest cost of a
    /// server that can't actually do more than one thing at a time — and it's
    /// a background refresh, not something blocking the UI.
    func refreshAll() async {
        await fetch()
        await fetchAnytime()
        await fetchUpcoming()
        await fetchInbox()
    }

    // MARK: - Complete

    /// Marks a task done on the Mini, removes it from every local list immediately
    /// (a task can be completed from Today's Agenda, Anytime, Upcoming, or Inbox —
    /// all four local arrays are optimistically pruned so it disappears everywhere).
    func complete(taskID: String) async {
        await MainActor.run {
            tasks.removeAll { $0.id == taskID }
            anytimeTasks.removeAll { $0.id == taskID }
            upcomingTasks.removeAll { $0.id == taskID }
            inboxTasks.removeAll { $0.id == taskID }
            totalCount = max(0, totalCount - 1)
        }

        guard let base = baseURL(), let url = URL(string: "complete", relativeTo: base) else { return }

        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["uuid": taskID])
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Add

    /// Adds a new task to Things via the Mini server.
    ///
    /// - Parameters:
    ///   - title: Task title.
    ///   - toToday: If true and `date` is nil, schedules for today; if false and `date`
    ///     is nil, sends to Inbox undated. Kept for source compatibility with existing
    ///     call sites — prefer passing `date` explicitly for anything other than "today".
    ///   - date: Optional explicit date to schedule the task on (any day, not just
    ///     today). Takes priority over `toToday` when both are provided.
    ///   - list: Optional area or project name to file the task under. Must match an
    ///     existing Things area/project exactly (same exact-match-or-Inbox rule
    ///     `things-adapter.sh` already uses) — a non-matching or empty value leaves
    ///     the task in the Inbox.
    ///   - notes: Optional freeform note/description text, passed straight through to
    ///     Things. **Removed the old hardcoded `"From Trace"` default 2026-07-20** —
    ///     David found it added no value and just cluttered every task. Wired up to
    ///     a real Notes field in the quick-add sheet's Details section same day
    ///     (second pass) — empty/nil is skipped entirely (nothing to "clear" on a
    ///     brand-new task, unlike `update()` below, which does need to distinguish
    ///     "leave unchanged" from "clear to blank" on an existing task's notes).
    func addTask(title: String, toToday: Bool = false, date: Date? = nil, list: String? = nil, notes: String? = nil) async {
        guard let base = baseURL(), let url = URL(string: "add", relativeTo: base) else { return }

        var body: [String: String] = ["title": title]
        if let notes, !notes.isEmpty {
            body["notes"] = notes
        }

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        if let date {
            body["date"] = f.string(from: date)
        } else if toToday {
            body["date"] = f.string(from: Date())
        }

        if let list, !list.isEmpty {
            body["list"] = list
        }

        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)

        // Refresh so the new task appears if it landed in Today
        if toToday || date != nil { await fetch() }
    }

    // MARK: - Update

    /// Edits an existing task's title, date, and/or list via the Mini bridge's
    /// `/update` endpoint. Added 2026-07-20 for DayflowTaskEditSheet — tap a task's
    /// title anywhere in Dayflow (Agenda, Anytime, Upcoming) to edit it in place.
    ///
    /// - Parameters:
    ///   - taskID: The Things uuid to update.
    ///   - title: New title (Things requires a non-empty title; caller validates).
    ///   - date: New scheduled date. Ignored if `clearDate` is true.
    ///   - clearDate: Removes the task's scheduled date entirely (Things "Anytime").
    ///   - list: New area/project name, exact match. Pass nil/empty to leave the
    ///     task's current list unchanged (the bridge only reassigns list when a
    ///     non-empty value is sent).
    ///   - notes: New notes text. Added 2026-07-20 for DayflowTaskEditSheet's notes
    ///     field. **Different convention from `list`/`title` above:** pass `nil` to
    ///     leave notes unchanged, but pass `""` (empty string) to deliberately clear
    ///     them — the bridge distinguishes "key absent" from "key present but empty"
    ///     (see `things-jxa-server.py`'s `update_task()` docstring), so this method
    ///     always includes the `"notes"` key in the request body whenever `notes` is
    ///     non-nil, even if it's an empty string. DayflowTaskEditSheet always passes
    ///     its notes text field's current value (never nil) since the field always
    ///     reflects the task's true current notes, including "the user cleared it."
    /// - Returns: true if the Mini reported success. On success, `fetch()`,
    ///   `fetchAnytime()`, `fetchUpcoming()`, and `fetchInbox()` all re-run
    ///   concurrently — an edit can move a task between the Today/Anytime/
    ///   Upcoming/Inbox buckets (e.g. scheduling a date on an Inbox task moves
    ///   it into Today or Upcoming), so a full refresh is simpler and safer
    ///   than hand-patching four local arrays.
    @discardableResult
    func update(taskID: String, title: String, date: Date?, clearDate: Bool, list: String?, notes: String? = nil) async -> Bool {
        guard let base = baseURL(), let url = URL(string: "update", relativeTo: base) else { return false }

        var body: [String: Any] = ["uuid": taskID, "title": title]
        if clearDate {
            body["clearDate"] = true
        } else if let date {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            body["date"] = f.string(from: date)
        }
        if let list, !list.isEmpty {
            body["list"] = list
        }
        if let notes {
            body["notes"] = notes
        }

        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            let decoded = try? JSONDecoder().decode(UpdateResponse.self, from: data)
            let success = decoded?.success ?? false
            if success {
                // Sequential, not concurrent — same reasoning as refreshAll()
                // above (its header comment has the full story): the Mini's
                // server only handles one request at a time, so firing these
                // four together just queues them and risks the same
                // self-inflicted timeout. This call site had the identical
                // bug from Session 6 round 1 onward, just never exposed until
                // the notes feature made the GET endpoints slow enough for it
                // to matter — fixed here for consistency, same day.
                await refreshAll()
            }
            return success
        } catch {
            return false
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
