// TraceWidget.swift — paste into the Xcode-generated TraceWidget.swift (TraceWidget target)
// TraceWidgetBundle.swift — replace with the stub in TraceWidgetBundle.swift (vault)
// TraceWidgetControl.swift / TraceWidgetLiveActivity.swift — replace with single import line

import WidgetKit
import SwiftUI

// MARK: - Constants

private let kAppGroup      = "group.com.david.trace"
private let kWorkoutsDBID  = "b7dab8c1a46542ab83c442e1b76f002a"
private let kVisitsDBID    = "ecd8cdc617e74c78b090afc5092cbdee"
private let kNotionVersion = "2022-06-28"
private let kNotionBase    = "https://api.notion.com/v1"

// MARK: - Timeline Entry

struct TraceWidgetEntry: TimelineEntry {
    let date: Date
    let workoutsToday: Int
    let visitsToday: Int
    let tokenMissing: Bool
}

// MARK: - Timeline Provider

struct TraceProvider: TimelineProvider {

    func placeholder(in context: Context) -> TraceWidgetEntry {
        TraceWidgetEntry(date: .now, workoutsToday: 1, visitsToday: 3, tokenMissing: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (TraceWidgetEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TraceWidgetEntry>) -> Void) {
        Task {
            let entry = await fetchEntry()
            let refresh = Calendar.current.date(byAdding: .minute, value: 30, to: .now)!
            completion(Timeline(entries: [entry], policy: .after(refresh)))
        }
    }

    private func fetchEntry() async -> TraceWidgetEntry {
        guard let token = UserDefaults(suiteName: kAppGroup)?.string(forKey: "notion_token"),
              !token.isEmpty else {
            return TraceWidgetEntry(date: .now, workoutsToday: 0, visitsToday: 0,
                                    tokenMissing: true)
        }
        let today = isoToday()
        async let w = queryCount(dbID: kWorkoutsDBID, dateField: "Date", token: token, date: today)
        async let v = queryCount(dbID: kVisitsDBID,   dateField: "Date", token: token, date: today)
        let (workouts, visits) = await (w, v)
        return TraceWidgetEntry(date: .now, workoutsToday: workouts, visitsToday: visits,
                                tokenMissing: false)
    }

    private func isoToday() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        f.timeZone = .current
        return f.string(from: .now)
    }

    private func queryCount(dbID: String, dateField: String, token: String, date: String) async -> Int {
        guard let url = URL(string: "\(kNotionBase)/databases/\(dbID)/query") else { return 0 }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(kNotionVersion,    forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "filter": ["property": dateField, "date": ["equals": date]]
        ])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return 0 }
        return results.count
    }

}

// MARK: - Widget View

struct TraceWidgetView: View {
    let entry: TraceWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Trace")
                    .font(.caption.weight(.bold))
                Spacer()
                Text(entry.date, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                statCell(count: entry.workoutsToday, icon: "figure.run",         color: .orange, label: "workout")
                Divider().frame(height: 36)
                statCell(count: entry.visitsToday,   icon: "mappin.circle.fill", color: .teal,   label: "visit")
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            Spacer(minLength: 0)
            Link(destination: URL(string: "trace://quicknote")!) {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                    Text("Add Note")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.orange, in: Capsule())
            }
        }
        .padding(12)
        .containerBackground(.background, for: .widget)
    }

    private func statCell(count: Int, icon: String, color: Color, label: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(count > 0 ? color : Color(.tertiaryLabel))
            Text("\(count)")
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(count > 0 ? color : Color(.tertiaryLabel))
            Text(count == 1 ? label : label + "s")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

// MARK: - Widget Definition (referenced by TraceWidgetBundle)

struct TraceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TraceWidget", provider: TraceProvider()) { entry in
            TraceWidgetView(entry: entry)
        }
        .configurationDisplayName("Trace Today")
        .description("Workouts, visits, and notes for today.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
