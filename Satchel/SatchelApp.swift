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
                // SATCHEL IS A LIGHT-ONLY APP AND MUST SAY SO.
                //
                // Every surface colour is hardcoded from `satchel-mockup-v4.html`
                // — white cards on a near-white canvas — but anything using a
                // SYSTEM colour still flips in dark mode. On David's phone that
                // rendered the Title and Description fields as white text on a
                // white card: the values were there and perfectly saved, just
                // invisible. Tags read fine because their colour is hardcoded.
                //
                // It cost most of an evening. The symptom is "the AI returned no
                // title" — a data bug that is not a data bug — and it sent me
                // chasing the scan prompt, the sidecar parser and the store.
                //
                // Pinning the appearance is the honest fix for an app whose
                // palette was only ever designed in light. A real dark mode is a
                // design pass over the whole token set, not a colour-scheme
                // switch, and the Dayflow Design Plan already records dark mode
                // as deliberately out of scope for that skin work.
                //
                // DO NOT "fix" this by adding `.foregroundStyle` to the two text
                // fields. The same bug exists anywhere a system colour meets a
                // hardcoded background — the navigation title in that screenshot
                // was white too.
                .preferredColorScheme(.light)
        }
    }
}
