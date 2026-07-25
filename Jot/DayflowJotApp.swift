import SwiftUI

// MARK: - DayflowJotApp
//
// Entry point for the standalone quick-capture companion app — backlog item
// 10, second pivot, 2026-07-24. David's ask, modeled explicitly on Drafts by
// Agile Tortoise: a separate, minimal app whose only job is capturing text
// straight into today's Daily Note, no navigation chrome, opens directly
// into an editable text field every time (see the first pivot's App
// Intent + Shortcuts-icon idea in Dayflow-HANDOFF.md Session 44 — David
// didn't want that Shortcuts-app dependency, this replaces it).
//
// Reuses `NoteStore.swift`'s existing `appendToDailyNote(_:date:)`
// (unchanged, written long before this app existed) via target membership —
// same iCloud container (iCloud.com.david.Trace) Dayflow and Trace already
// share; this app needs its own separate bundle ID, set when its Xcode
// target is created. See Dayflow-HANDOFF.md Session 44 addendum for the
// manual one-time Xcode setup this needed — creating a brand-new app target
// isn't something safe to do blind through the file-bridge workflow the
// rest of this project uses, so David set the target itself; this file (and
// CaptureView.swift alongside it) are what get added to that target.
//
// Deliberately as minimal as DayflowApp.swift's own entry point — no
// environment objects, no appearance override, no launch-time fetches. This
// app never reads any of Trace/Dayflow's other data, only ever writes
// through NoteStore.
@main
struct DayflowJotApp: App {
    var body: some Scene {
        WindowGroup {
            CaptureView()
        }
    }
}
