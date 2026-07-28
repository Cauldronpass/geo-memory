import SwiftUI

// MARK: - SatchelApp
//
// Entry point for Satchel — the standalone Documents app for the Trace family,
// scoped and named in Session 49 (2026-07-27). Follows the same split pattern
// Jot used: its own target and bundle ID (com.david.Satchel), its own URL
// scheme (satchel://), but the SAME iCloud container as Trace, Dayflow and Jot
// (iCloud.com.david.Trace) so it reads and writes the identical `Documents/`
// folder those apps already share. See `DayflowJotApp.swift` for the precedent
// and Session 44's addendum for why the target itself is created by hand in
// Xcode rather than through the file bridge.
//
// Authoritative spec: `Documents-App-Scope.md` in the vault mirror. Approved
// visual reference: `satchel-mockup-v4.html` (8 frames). Both are locked —
// read them before changing behaviour here.
//
// Deliberately minimal, same as DayflowJotApp: no environment objects, no
// appearance override, no launch-time fetches. Satchel never talks to Notion
// at launch; the only Notion call it will ever make is populating the Endeavor
// picker (stubbed to an empty list until that database exists), and even the
// Endeavor's display name is cached in each document's sidecar so the library
// renders instantly offline. `SatchelLibraryView` owns its own `NoteStore`,
// `iOSDocumentStore` and `SatchelEndeavorStore` and loads once the iCloud
// container resolves.
//
// Session 50: `SatchelPlaceholderView` deleted, as build step 6 planned — the
// Library screen replaces it. Xcode's generated `ContentView.swift` was
// deleted on purpose back in Session 49; the vault mirror is a flat folder, so
// a second file by that name would collide with Trace's own.

@main
struct SatchelApp: App {

    /// Owned here rather than by the Library so a `satchel://` URL that arrives
    /// while the app is cold still has somewhere to land — SwiftUI delivers the
    /// URL to the scene, and the Library reads it once it appears.
    @State private var router = SatchelRouter()

    var body: some Scene {
        WindowGroup {
            SatchelLibraryView(router: router)
                .onOpenURL { router.handle($0) }
        }
    }
}
