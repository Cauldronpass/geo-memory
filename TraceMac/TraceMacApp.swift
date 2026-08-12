// TraceMacApp.swift
// Entry point for the Trace Mac companion app.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI

@main
struct TraceMacApp: App {
    @State private var noteStore = NoteStore.shared
    @State private var notionService = NotionService()
    @State private var selectedSection: MacSection? = .notes
    /// ⌘K. Lives on the `App` for the same reason `selectedSection` does — the
    /// shortcut is declared in `.commands`, which is scene-level, and the panel
    /// it opens is a window-level overlay.
    ///
    /// **Still the in-window overlay, not a `MenuBarExtra` panel.** The
    /// system-wide shortcut arrived (Session 70, `TraceMacHotKey.swift`) and it
    /// brings the app forward and opens this, so one panel serves both cases —
    /// which is what David asked for: *"Id want in app to be the same as out of
    /// app."* A separate floating panel would be a second surface to keep in
    /// step with the first, for a difference nobody asked for.
    @State private var showSearch = false
    /// Held here only so the Go menu can print the current shortcut in its
    /// title. Registration happens in `TraceMacContentView`'s launch task; the
    /// Carbon hot key is app-wide and outlives the window, so closing the window
    /// does not stop the shortcut that reopens it.
    @State private var hotKeys = MacHotKeyCenter.shared
    // An `@NSApplicationDelegateAdaptor(TraceMacDropReceiver.self)` lived here
    // for one evening. Removed 2026-08-11 with the rest of the file-handoff
    // attempt: eight tries across Dock-icon drops and Finder Services, all
    // proved dead (Dayflow-HANDOFF addenda 9 and 10). Files come in through the
    // window drop or the Dropzone actions.

    var body: some Scene {
        WindowGroup {
            TraceMacContentView(selectedSection: $selectedSection,
                                showSearch: $showSearch)
                .environment(noteStore)
                .environment(notionService)
                .frame(minWidth: 900, minHeight: 600)
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
            CommandGroup(replacing: .newItem) { }
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
                Button("Search…  \(hotKeys.combo.label)") { showSearch = true }
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
