// TraceMergeShims.swift
// Dayflow — the host target of the one app (D452).
//
// D469, Session 109. The old app's shell, answered so its screens compile
// without being edited.
//
// ── What this is for ────────────────────────────────────────────────────────
//
// Merge pass (a) adds twenty-nine of Trace's screen files to this target
// (D457 step 4). Those files were written inside Trace's shell and reach out
// to three things that live in `Trace/ContentView.swift` and
// `Trace/TraceApp.swift` — the old app's root and its `@main`. **Neither file
// can ever join this target**: each declares a type this target already has
// (`struct ContentView`, and an `App`), so the second one in is a
// redeclaration error, exactly the wall `Trace/TraceSkin.swift` hits and for
// the same reason (see `TraceSkinBridge.swift`).
//
// There were two ways to deal with that. Edit the call sites in seven of the
// incoming files and delete the references; or answer the three names here,
// with the meaning they have in THIS app, and leave the incoming files byte
// for byte as the old app has them. This file is the second.
//
// **Why the second.** Both apps are installed on the phone until pass (c)
// deletes the old one, and until then every one of these files is live in two
// targets at once. A file that is identical in both can be read, fixed and
// mirrored once. A file that has been edited on one side has to be diffed
// every time anyone touches it, and the edits here would be seven scattered
// deletions whose only record is this comment. The same argument D467 makes
// about the skin: one table, in one place, rather than an edit in every view.
//
// **These are not stubs waiting to be filled in.** Each one is the correct
// answer for this app, stated below. They retire in pass (c) along with the
// files that ask for them, not before.

import SwiftUI

// MARK: - The drawer that no longer exists

// Trace's shell is a left drawer opened from a toolbar button, plus a pair of
// floating buttons over the map screens. This app has the Editorial tab bar
// (`DayflowRootView`), and D454 retired the drawer with Home: there is nothing
// for either control to open, and drawing a button that opens nothing is worse
// than drawing none — it is a control that makes a promise the screen cannot
// keep.
//
// So both answer as nothing, here, once. Seven incoming files call
// `.drawerToolbar()` (`PeopleView`, `PlacesView`, `VisitsView`, `FitnessView`,
// `BilliardsView` twice) and two call `DrawerButtons()` (`DiscoverView`,
// `MapView`); none of them is edited.

extension View {
    /// Trace's toolbar drawer button. Nothing in this app, deliberately: the
    /// tab bar is how you get around here.
    func drawerToolbar() -> some View { self }
}

/// Trace's floating drawer / FAB pair, over Discover and the map. Nothing in
/// this app: the compose button on Today is what replaced it (D454).
struct DrawerButtons: View {
    var body: some View { EmptyView() }
}

// MARK: - A notification with no sender

/// Posted by `Trace/ContentView.swift`'s "Go to Visits" button, observed by
/// `PlacesView`. In this app nothing posts it, because the thing that did is
/// the old app's root. The name is declared so `PlacesView` compiles; the
/// observer simply never fires.
///
/// **Not wired to an equivalent on purpose.** There is no "Go to Visits"
/// control in this app's Places scope yet. Pointing this at something that
/// merely looks similar would make the screen respond to an event no one sent,
/// which is the kind of thing that is very hard to find later.
extension Notification.Name {
    static let tracePlacesShowVisits = Notification.Name("TracePlacesShowVisits")
}
