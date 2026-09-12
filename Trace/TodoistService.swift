//  TodoistService.swift
//  Trace / TraceMac / Dayflow
//
//  Creating a task in Todoist. Work is tracked there; these apps are personal,
//  and this is the one road between them.
//
//  **Moved out of `TraceMac/DocumentScanService.swift` (D368).** It was written
//  for the Mac's hand-off (D348, D349) and lived inside a Mac-only file, so the
//  phone could not reach it. Dayflow's task card sends straight to Todoist when
//  the Work list is chosen, and the alternative to moving this was a second copy
//  of an endpoint, an auth header and an error table — the kind of duplication
//  that stays correct exactly until one of the two is fixed.
//
//  Nothing in here is platform-specific: URLSession and JSON. The move is a
//  target membership change and nothing else; not one line of its behaviour
//  changed with it.
//
//  `TodoistKeyStore` (NoteStore.swift) supplies the token and is already
//  per-device: the Mac's keychain, the phone's App Group defaults. A Mac with a
//  working token is what makes a phone with none look broken rather than
//  unconfigured, which is why both Settings screens say so.

import Foundation

enum TodoistService {

    enum SendError: LocalizedError {
        case noToken
        case http(Int, String)
        case noResponse
        /// A named project that Todoist does not have. Its own case rather
        /// than an `http` because it is not a failure of the call - the call
        /// succeeded and the answer was "no such project".
        case noProject(String)

        var errorDescription: String? {
            switch self {
            case .noToken:
                return "No Todoist token on this Mac. Add one in Settings (⌘,). "
                     + "Tokens are stored per-device, so the one on your phone does not carry over."
            case .http(let code, let body):
                // 401 is the one worth naming: it is the only failure here that
                // has an action attached to it.
                if code == 401 {
                    return "Todoist refused the token. Check it in Settings (⌘,)."
                }
                return "Todoist error \(code): \(body.prefix(160))"
            case .noResponse:
                return "No response from Todoist."
            case .noProject(let name):
                // **Named, and NOT sent to the Inbox instead.** A silent
                // fallback would tick the task off here and write the day-note
                // line saying it went to GBU while it sat in the Inbox: a
                // record making a statement that is not true, which is the one
                // failure this vault keeps having to correct.
                return "No Todoist project called \(name). Create it in Todoist, or send it to the Inbox."
            }
        }
    }

    /// The unified v1 API. `rest/v2` answered 410 Gone, and its own body said so
    /// more accurately than the published docs did: the docs still described v2
    /// as current while the endpoint had already been retired. The wire format
    /// is unchanged from v2 (JSON body, Bearer auth, `content` / `description` /
    /// `due_date` as yyyy-MM-dd, string `id` back), so only the URL moved.
    private static let endpoint = URL(string: "https://api.todoist.com/api/v1/tasks")!
    private static let projectsEndpoint = URL(string: "https://api.todoist.com/api/v1/projects")!

    /// Creates the task in Todoist's Inbox and returns its id.
    ///
    /// **Inbox, not a chosen project**, and deliberately for now: he triages at
    /// work, and a default project picked here would be one more thing to keep
    /// right in two places. A project picker is a Settings line and one extra
    /// call whenever that stops being true.
    ///
    /// The due date is sent as a plain `YYYY-MM-DD` in `due_date`, which Todoist
    /// reads in the account's own timezone. Sending a timestamp instead would
    /// make a 9am task land at 4am for anyone whose Todoist timezone is not
    /// this Mac's, and the date is the only part that matters here.
    ///
    /// `project` names a Todoist project to file it under; nil keeps the Inbox
    /// behaviour above. The name is resolved against David's real project list
    /// rather than a table of ids pasted into Settings, because a pasted id is
    /// a second place to keep right and goes stale silently when a project is
    /// renamed or rebuilt. A name Todoist does not have throws rather than
    /// falling back - see `noProject`.
    static func send(title: String, notes: String?, due: Date?,
                     project: String? = nil) async throws -> String {
        let token = TodoistKeyStore.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw SendError.noToken }

        var payload: [String: Any] = ["content": title]
        if let project {
            payload["project_id"] = try await projectID(named: project, token: token)
        }
        if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["description"] = notes
        }
        if let due {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = .current
            fmt.dateFormat = "yyyy-MM-dd"
            payload["due_date"] = fmt.string(from: due)
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // **A request id, so a retry cannot double-post.** Todoist treats a
        // repeated X-Request-Id as the same create and returns the original
        // task. Nothing retries today; the header costs one line and means a
        // future retry is safe by construction rather than by nobody having
        // written one yet.
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-Id")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw SendError.noResponse }
        guard (200...299).contains(http.statusCode) else {
            throw SendError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        // The id is not used today — nothing here reads Todoist back — so a
        // response this cannot parse is not a failure, it is a task that was
        // created and whose id nobody wanted. Returning "" says exactly that.
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String else { return "" }
        return id
    }

    /// Lowercased project name to id, filled on first use and kept for the life
    /// of the app run.
    ///
    /// **Cached, because the six names are fixed and his projects are not
    /// renamed mid-afternoon.** Fetching per send would put a second network
    /// call in front of every hand-off to buy freshness nothing here needs. The
    /// cost is that a project created in Todoist after this app launched is not
    /// found until relaunch, which `noProject` says plainly enough to act on.
    private static var projectIDs: [String: String] = [:]

    /// Resolves a project name against Todoist's own list.
    ///
    /// Matching is forgiving in ONE direction only: exact (case-insensitive)
    /// first, then a comparison with everything that is not a letter or digit
    /// removed, so the menu's `FP&A` finds a project called `FP & A` or `FPA`.
    /// It never matches a prefix or a substring - `Travel` must not silently
    /// land in `Travel Ops`.
    private static func projectID(named name: String, token: String) async throws -> String {
        let key = normalise(name)
        if let hit = projectIDs[key] { return hit }

        var fetched: [String: String] = [:]
        var cursor: String? = nil
        // Todoist v1 pages its lists. A dozen projects fit in one page, but a
        // loop stopping at the first page would go wrong quietly, and only for
        // the projects at the bottom of it.
        repeat {
            var comps = URLComponents(url: projectsEndpoint, resolvingAgainstBaseURL: false)!
            var items = [URLQueryItem(name: "limit", value: "200")]
            if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
            comps.queryItems = items
            var req = URLRequest(url: comps.url!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw SendError.noResponse }
            guard (200...299).contains(http.statusCode) else {
                throw SendError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            let root = try? JSONSerialization.jsonObject(with: data)
            // v1 answers `{"results": [...], "next_cursor": ...}`; v2 answered a
            // bare array. Both are read, so the shape moving in either direction
            // is not a silently empty list.
            let rows: [[String: Any]]
            if let obj = root as? [String: Any] {
                rows = obj["results"] as? [[String: Any]] ?? []
                cursor = obj["next_cursor"] as? String
            } else {
                rows = root as? [[String: Any]] ?? []
                cursor = nil
            }
            for row in rows {
                guard let n = row["name"] as? String else { continue }
                let id = (row["id"] as? String) ?? (row["id"] as? Int).map(String.init)
                guard let id else { continue }
                fetched[normalise(n)] = id
                fetched[n.lowercased()] = id
            }
        } while cursor != nil

        projectIDs = fetched
        guard let hit = fetched[key] ?? fetched[name.lowercased()] else {
            throw SendError.noProject(name)
        }
        return hit
    }

    private static func normalise(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
