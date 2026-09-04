// TraceMacApp.swift
// Entry point for the Trace Mac companion app.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI

@main
struct TraceMacApp: App {

    /// Shared by key with the day note pane — see `MacNoteToolbarSetting`.
    @AppStorage(MacNoteToolbarSetting.key) private var showNoteToolbar = false
    @State private var noteStore = NoteStore.shared
    /// **`NotionService.shared`, the same instance both iOS apps use.**
    ///
    /// This was `NotionService()` — a fresh object, unique to this target — from
    /// the day the Mac app was written, and nobody ever recorded a reason.
    /// `TraceApp` and `DayflowApp` both take `.shared`, so the Mac was the odd
    /// one out, and the divergence had grown three separate workarounds:
    /// `TraceMacContentView` configuring the quick panel by hand,
    /// `MacQuickPanelController` explaining why it could not reach for the
    /// singleton, and `TraceMacDocumentsView` documenting a live bug where
    /// `.shared.people` was empty forever.
    ///
    /// **It was also a bug factory for shared code.** Files in `Trace/` are
    /// compiled into this target and reach for `NotionService.shared` because on
    /// iOS that IS the app's instance — `DayflowAgendaMatch` does, which is how
    /// D246's agenda shipped unable to match a single person on the Mac hours
    /// after D244 moved that matcher into the shared folder. Every future shared
    /// file would have walked into the same hole.
    ///
    /// One instance, reachable both ways. Session 82, D248.
    @State private var notionService = NotionService.shared
    @State private var selectedSection: MacSection? = .today
    /// Held here only so the Go menu can print the current shortcut in its
    /// title. Registration happens in `TraceMacContentView`'s launch task; the
    /// Carbon hot key is app-wide and outlives the window, so closing the window
    /// does not stop the shortcut that reopens it.
    /// Spotlight results arrive here on macOS, not through SwiftUI's
    /// `onContinueUserActivity`. See the delegate file's header.
    @NSApplicationDelegateAdaptor(TraceMacSpotlightDelegate.self) private var spotlightDelegate
    // An `@NSApplicationDelegateAdaptor(TraceMacDropReceiver.self)` lived here
    // for one evening. Removed 2026-08-11 with the rest of the file-handoff
    // attempt: eight tries across Dock-icon drops and Finder Services, all
    // proved dead (Dayflow-HANDOFF addenda 9 and 10). Files come in through the
    // window drop or the Dropzone actions.

    var body: some Scene {
        WindowGroup {
            TraceMacContentView(selectedSection: $selectedSection)
                .environment(noteStore)
                .environment(notionService)
                .frame(minWidth: 900, minHeight: 600)
                // D265 — the agenda matcher's owner name is a macOS-only
                // fallback, so the Mac has always had one and the phone never
                // did. Publishing it here means the phone inherits it without
                // anyone having to know the Settings field exists. Writes at
                // most once, and never over a value that has been set.
                .task { DayflowAgendaMatch.publishSeededOwnerNameIfNeeded() }
        }
        .defaultSize(width: 1200, height: 750)
        .windowResizability(.contentMinSize)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            // Suppresses SwiftUI's default File ▸ New Window. Trace Mac is
            // single-window on purpose: `selectedSection` lives on the App
            // struct, so a second window would share one selection with the
            // first and the two would fight.
            //
            // Session 63 (2026-08-01): this group used to hold
            // `Button("New Note") { }` — an empty body on ⌘N. It suppressed New
            // Window as intended, but did so by drawing a menu item that
            // advertised an action and performed none, which is worse than the
            // thing it was suppressing. The suppression is the actual intent, so
            // it is now stated as an empty group.
            //
            // A real ⌘N belongs to whichever section is on screen — the note
            // list already has its own New Note toolbar button — and wiring it
            // needs a focused-section concept the app does not have until the
            // NavigationSplitView work.
            // ⌘N is a real command now (Session 80). It was an empty group
            // suppressing the default New Item, because at the time nothing in
            // this app knew what "new" meant. The composer does — it is the one
            // thing you make here — and it is reachable from every screen, so
            // it has earned the standard key.
            CommandGroup(after: .toolbar) {
                Button(showNoteToolbar ? "Hide Formatting Bar" : "Show Formatting Bar") {
                    showNoteToolbar.toggle()
                }
                .keyboardShortcut("y", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .newItem) {
                Button("New Task") { MacComposeTrigger.shared.requests += 1 }
                    .keyboardShortcut("n", modifiers: .command)
            }
            // Session 63 (2026-08-02): reordered to follow the new sidebar, so
            // ⌘1–⌘7 read top to bottom rather than in the order they were added.
            // `Horizons` became `Weekly` (D3) and `Visits` took ⌘5 now that it
            // is a tab rather than a sheet buried inside Places.
            CommandMenu("Go") {
                // **No `.keyboardShortcut` here, and that is the point.**
                //
                // Search is on a system-wide Carbon hot key now (⌃⌥Space by
                // default, changeable in Settings), which fires whether or not
                // TraceMac is frontmost — including when it is. Declaring the
                // same combination as a menu shortcut as well would open the
                // panel twice on one press.
                //
                // ⌘K, which this had for one build, is gone. David: *"Id want
                // in app to be the same as out of app."* Two shortcuts for one
                // panel is two things to remember and one of them is wrong.
                //
                // The item stays so the feature is discoverable in a menu and
                // the current shortcut is written where someone would look.
                // **⌘K is back, and this reverses D-79's removal knowingly.**
                //
                // It came out because David said *"Id want in app to be the same
                // as out of app"* — two keys for one panel with nothing to tell
                // them apart. What changed is that the panel now has a visible
                // control in the sidebar rail, and ⌘K is that button's keyboard
                // equivalent, which is a different job from the global hot key's
                // "reach it from anywhere". The distinction is real: one is for
                // when TraceMac is in front of you, the other for when it is
                // not.
                //
                // The global combination moved OUT of this label. Showing both
                // here would read "Search…  ⌃⌥Space  ⌘K", which is the exact
                // confusion the original removal was avoiding. It is on the
                // rail button's tooltip and in Settings, where it is set.
                Button("Search…") {
                    MacQuickPanelController.shared.show()
                }
                .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("Notes")     { selectedSection = .notes }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Endeavors") { selectedSection = .endeavors }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Directory") { selectedSection = .directory }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Activity")  { selectedSection = .activity }
                    .keyboardShortcut("4", modifiers: .command)
                Button("Satchel")   { selectedSection = .documents }
                    .keyboardShortcut("5", modifiers: .command)
                Divider()
                Button("Inbox")     { selectedSection = .inbox }
                    .keyboardShortcut("6", modifiers: .command)
                // ⌘0 / Home removed Session 64 with the Home section (D21).
                // Nothing takes ⌘0: leaving a shortcut bound to the nearest
                // survivor is how a muscle-memory keystroke starts landing
                // somewhere it was never asked to go.
            }
        }

        MenuBarExtra("Trace", systemImage: "mappin.circle.fill") {
            TraceMacMenuBarView()
                .environment(noteStore)
                .environment(notionService)
        }
        .menuBarExtraStyle(.window)

        Settings {
            TraceMacSettingsView()
        }
    }
}
