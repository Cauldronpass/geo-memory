// JotWidget.swift — paste over the Xcode-generated widget file in the new
// JotWidget extension target.
//
// Medium-size Home Screen widget for Jot. Content design locked with David
// 2026-07-24 (Dayflow-HANDOFF.md Session 44 addendum 4), built same day in
// addendum 6:
//   - Shows the START of today's note — first lines from the top, not a
//     live summary or the last lines. Matches the Drafts widget on David's
//     own Home Screen, the reference he pointed to.
//   - Hard-truncated wherever it runs off the visible frame — no ellipsis,
//     no scrolling. WidgetKit tiles can't scroll or be measured past their
//     fixed tile size, so this Text is deliberately given no `lineLimit` —
//     whatever doesn't fit inside the tile is clipped by the OS's own
//     rendering bounds, not by any truncation logic here. That's what
//     produces the "just cuts off" look instead of a "…" fade.
//   - Tapping anywhere on the card opens Jot directly via `widgetURL()`.
//     Jot is a single screen (CaptureView, always the capture field), so
//     there's nothing to route to once it opens — no onOpenURL handling
//     needed inside Jot, just a `jot://` URL scheme registered on the Jot
//     app target (Xcode: Jot target → Info tab → URL Types → add scheme
//     "jot") so iOS knows which app owns the tap.
//
// Reads through NoteStore.swift's existing `readDailyNote(date:)` —
// NoteStore.swift needs to be added to this extension's target membership,
// same as it was added to Jot's own app target.
//
// NoteStore's iCloud container URL resolves asynchronously in `init()`. A
// widget extension is a fresh process every time WidgetKit runs it, so
// this timeline provider hits the exact same "not ready yet" race Jot's
// own commit() button hit on-device (fixed in addendum 5) — same fix here:
// poll `hasAccess` briefly before reading instead of assuming it's ready.

import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct JotWidgetEntry: TimelineEntry {
    let date: Date
    let noteText: String       // today's note, date-header line already stripped
    let iCloudUnavailable: Bool
}

// MARK: - Timeline Provider

struct JotProvider: TimelineProvider {

    func placeholder(in context: Context) -> JotWidgetEntry {
        JotWidgetEntry(date: .now, noteText: "Tap to jot something down…", iCloudUnavailable: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (JotWidgetEntry) -> Void) {
        Task { completion(await fetchEntry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<JotWidgetEntry>) -> Void) {
        Task {
            let entry = await fetchEntry()
            // Jot's own commit() calls WidgetCenter.shared.reloadTimelines(ofKind:)
            // right after a successful save, so this scheduled refresh is just a
            // safety net for whatever WidgetKit's background budget allows on its
            // own — not the primary way the widget picks up a new note.
            let refresh = Calendar.current.date(byAdding: .minute, value: 30, to: .now)!
            completion(Timeline(entries: [entry], policy: .after(refresh)))
        }
    }

    @MainActor
    private func fetchEntry() async -> JotWidgetEntry {
        if !NoteStore.shared.hasAccess {
            for _ in 0..<20 {
                if NoteStore.shared.hasAccess { break }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        guard NoteStore.shared.hasAccess else {
            return JotWidgetEntry(date: .now, noteText: "", iCloudUnavailable: true)
        }
        let raw = (try? NoteStore.shared.readDailyNote()) ?? ""
        return JotWidgetEntry(date: .now, noteText: Self.stripHeader(raw), iCloudUnavailable: false)
    }

    /// Drops the auto-generated "# YYYY-MM-DD" header line (and any blank
    /// lines right after it) so the widget shows actual note content from
    /// the top, not the date header `appendToDailyNote` writes into every
    /// new file — same header-stripping NoteStore's own `moveDailyNote`
    /// already does, for the same reason.
    private static func stripHeader(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if let first = lines.first,
           first.hasPrefix("# "),
           first.dropFirst(2).range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            lines.removeFirst()
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                lines.removeFirst()
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Widget View

struct JotWidgetView: View {
    let entry: JotWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Jot")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(entry.date, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Group {
                if entry.iCloudUnavailable {
                    Text("iCloud unavailable")
                        .foregroundStyle(.secondary)
                } else if entry.noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No note yet today — tap to start")
                        .foregroundStyle(.secondary)
                } else {
                    // No .lineLimit() on purpose — see file header. The tile's
                    // own fixed bounds are what cut this off, not this view.
                    Text(entry.noteText)
                        .foregroundStyle(.primary)
                }
            }
            .font(.system(size: 14))
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.background, for: .widget)
        .widgetURL(URL(string: "jot://open"))
    }
}

// MARK: - Widget Definition (referenced by JotWidgetBundle)

struct JotWidget: Widget {
    let kind: String = "JotWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: JotProvider()) { entry in
            JotWidgetView(entry: entry)
        }
        .configurationDisplayName("Jot")
        .description("Shows the start of today's note. Tap to open Jot.")
        .supportedFamilies([.systemMedium])
    }
}
