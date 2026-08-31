// TraceMacQuickPanel.swift
// Search as a floating panel over whatever you were doing, not as a window in
// an app you have to bring forward. Mac-only.
//
// ── Why this exists, and why it did not two hours ago ────────────────────
//
// D99 refused a separate panel and said why: two surfaces over one search
// engine is two things to keep in step, and *"it is refused until there is a
// difference it would make that this does not."*
//
// David supplied the difference on first real use: *"When i was in another app
// and hit the hotkey to ask a question i think the search was hidden by other
// apps which is not good. Second, i wonder if the hotkey could surface just the
// search window without having to load the full app window."*
//
// Both halves are the same root cause. The overlay was drawn inside TraceMac's
// main window, so reaching it meant summoning a 1200×750 window — heavy for
// *"what is Megan's number"*, and subject to ordinary window ordering, which is
// how it ended up behind something.
//
// **And D99's rule is kept rather than broken.** This does not become a second
// surface: the in-window overlay is gone, and the same `TraceMacSearchPanel`
// view is now hosted here instead. One panel, one engine, reachable from
// everywhere. That was D99's actual requirement — the surface count, not the
// window type.
//
// ── The three AppKit facts that make it work ────────────────────────────
//
//   * `.nonactivatingPanel` + `canBecomeKey` — a panel that takes the keyboard
//     without the app taking over the screen.
//   * `.floating` level — above other applications' windows, which is the
//     literal fix for "hidden by other apps".
//   * `orderFrontRegardless()` — the documented way to show a window from an
//     application that is not frontmost. `makeKeyAndOrderFront` alone respects
//     activation and is exactly what would leave it buried.

import AppKit
import SwiftUI

/// A panel that can take keystrokes without its app becoming frontmost.
///
/// Both overrides are required and neither is optional-in-practice: an `NSPanel`
/// that cannot become key hands every keystroke to the app underneath, and one
/// that can become *main* starts behaving like a document window — it would take
/// the menu bar and the window title, which is the full-app takeover being
/// avoided here.
final class MacQuickPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the one search panel and the references it needs to draw.
///
/// A singleton because there is one of it, and because the hot key fires from a
/// C callback that has no view hierarchy to reach into. `configure` is called
/// once from `TraceMacContentView`, which is where the two stores actually live
/// — `TraceMacApp` builds its own `NotionService` rather than using
/// `NotionService.shared`, so reaching for the shared one here would quietly
/// search a second, empty copy.
@MainActor
final class MacQuickPanelController: NSObject, NSWindowDelegate {

    static let shared = MacQuickPanelController()
    private override init() { super.init() }

    private var panel: MacQuickPanelWindow?
    private var noteStore: NoteStore?
    private var notionService: NotionService?

    var isConfigured: Bool { noteStore != nil && notionService != nil }
    var isVisible: Bool { panel?.isVisible ?? false }

    func configure(noteStore: NoteStore, notionService: NotionService) {
        self.noteStore = noteStore
        self.notionService = notionService
    }

    // MARK: Show and hide

    /// **Debounced, because two keys can now reach this.**
    ///
    /// ⌘K is a menu shortcut and the global combination is a Carbon hot key,
    /// and nothing stops David setting the global one TO ⌘K in Settings — at
    /// which point both fire on one press, `show()` then `toggle()`, and the
    /// panel opens and immediately closes. That reads as "the shortcut is
    /// broken", which is the hardest kind of bug to attribute.
    ///
    /// A time guard rather than a rule against colliding combinations: the rule
    /// would have to be enforced in the recorder, explained to the user, and
    /// re-explained every time a menu item is added. 200ms costs nothing and
    /// closes the whole class.
    private var lastRequest = Date.distantPast

    private func debounced() -> Bool {
        let now = Date()
        defer { lastRequest = now }
        return now.timeIntervalSince(lastRequest) < 0.2
    }

    func toggle() {
        guard !debounced() else { return }
        isVisible ? hide() : present()
    }

    func show() {
        guard !debounced() else { return }
        present()
    }

    /// The actual presentation, with no guard on it.
    ///
    /// **Splitting this out is the fix for a bug I shipped one turn earlier.**
    /// The debounce went on both `toggle()` and `show()`, and `toggle()` calls
    /// `show()` — so the hot key consumed its own guard: `toggle()` stamped
    /// `lastRequest`, then `show()` saw a request microseconds old and returned
    /// immediately. The panel never opened. ⌘K still worked because it enters
    /// through `show()` alone, which is exactly why David reported the global
    /// shortcut broken and not the menu.
    ///
    /// The rule the first version broke: **a debounce belongs at the entry
    /// points only, never on a path another entry point calls through.** One
    /// public method calling another with the same guard on both is a guard
    /// that fires against itself.
    private func present() {
        guard let noteStore, let notionService else { return }

        let panel = self.panel ?? makePanel(noteStore: noteStore, notionService: notionService)
        self.panel = panel

        position(panel)

        // **`orderFrontRegardless`, not `makeKeyAndOrderFront`.** The latter
        // respects activation, so from a background app it puts the window in
        // the app's own layer and leaves it under whatever is in front — which
        // was the original burial.
        //
        // **And no `NSApp.activate()`.** The first version called it "to own the
        // keyboard", which was reasoning from a guess: activating an app brings
        // its windows forward, so David got the panel *and* the 1200×750 main
        // window, which is the exact thing this was built to avoid. He said so
        // on sight: *"both the floating window and the app both appear."*
        //
        // A `.nonactivatingPanel` whose `canBecomeKey` is true takes the
        // keyboard **without** its application becoming active. That is what the
        // style mask is for and it is how Spotlight and Things behave. The two
        // overrides on `MacQuickPanelWindow` are load-bearing precisely here.
        panel.orderFrontRegardless()
        panel.makeKey()

        // **One runloop turn later, not immediately, and not after a tuned
        // delay.** The panel is reused between presses, so `onAppear` fires
        // exactly once in its life and cannot be what puts the caret back in the
        // field. A counter the view watches can — but only after AppKit has
        // finished handing over key status, or SwiftUI claims focus in a window
        // that is not yet key and quietly loses it.
        //
        // `DispatchQueue.main.async` rather than a sleep: one turn is a fact
        // about the runloop, where "0.1 seconds" would be a guess. This project
        // deleted four tuned delays in Session 63 and should not add a fifth.
        DispatchQueue.main.async { MacQuickPanelSession.shared.opens += 1 }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// The user clicked something else.
    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in self.hide() }
    }

    /// Close the panel and bring the app properly forward. Called when a result
    /// or a citation is opened, which is the one moment the full window is
    /// actually wanted.
    func hideAndSurfaceApp() {

        // ── What is actually wrong here, established rather than assumed ──
        //
        // David ran the splitting test: press Return, then open the app by hand
        // from the Dock. **It was showing the right record.** So `onOpen` fires,
        // `MacSearchRoute` delivers, and `openSearchResult` runs. The routing
        // half is fine and always was. The only thing failing is bringing the
        // app to the front.
        //
        // **Why macOS refuses.** Since macOS 14 an application may not simply
        // activate itself; it activates when the user gives it an event, or when
        // the frontmost app yields. This panel is `.nonactivatingPanel` — its
        // entire purpose is that typing in it does *not* count as giving this
        // app the front. So the process asks to come forward with none of the
        // credit that would let it, and `NSApp.activate()` and
        // `NSRunningApplication.activate` both honour that refusal. They were
        // never going to work, which is why two attempts at rearranging them
        // changed nothing.
        //
        // `activate(ignoringOtherApps: true)` is the call that overrides it. It
        // is deprecated and not removed, and the deprecation is about
        // politeness, not capability — "ignoring other apps" is the exact
        // behaviour needed and the exact behaviour the replacement dropped.

        surfaceApp()

        // Hidden (⌘H) is a separate state; activation does not unhide.
        if NSApp.isHidden { NSApp.unhide(nil) }

        if let window = mainWindow() {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            // Closed outright. AppKit's Dock-click call rebuilds the
            // `WindowGroup` window, but not synchronously.
            _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
        }

        // **Checked, not assumed.** One runloop turn later either this app is
        // frontmost or it is not, and `NSApp.isActive` says which — so the
        // fallback fires on a measurement rather than on another theory.
        // `NSWorkspace.openApplication` on our own bundle goes through Launch
        // Services, which activates a running app without needing the
        // yield credit at all.
        //
        // The panel is ordered out **last**, on that same turn. Hiding it first
        // meant this process's only key window was gone before the activation
        // was requested, which is a poor position from which to ask for the
        // front.
        DispatchQueue.main.async { [weak self] in
            if !NSApp.isActive {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                                   configuration: configuration,
                                                   completionHandler: nil)
            }
            if let window = self?.mainWindow() {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            }
            self?.hide()
        }
    }

    private func surfaceApp() {
        // Deprecated since macOS 14, present and functional. See the note in
        // `hideAndSurfaceApp` for why the replacement cannot do this job.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The app's real window, as opposed to this panel, the `MenuBarExtra`'s
    /// host, or Settings — all of which are panels or cannot become main.
    private func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.canBecomeMain && !($0 is NSPanel) }
    }

    // MARK: Building

    private func makePanel(noteStore: NoteStore, notionService: NotionService) -> MacQuickPanelWindow {
        // **Borderless, and that is the fix for the lines David saw.**
        //
        // The first version was `.titled` + `.fullSizeContentView` with a clear
        // background, while the SwiftUI content drew its own rounded card, its
        // own 1px border and its own shadow. So AppKit drew a square titled
        // frame and a square shadow around a round card, and the two outlines
        // did not agree at the corners. *"the floating window has some weird
        // lines around it which doesn't seem right"* — two window frames, one
        // square and one round, drawn on top of each other.
        //
        // Now there is exactly one source of chrome: the SwiftUI card. The
        // window is borderless, transparent, and draws no shadow of its own; the
        // view adds padding so its own shadow has room to fall.
        let panel = MacQuickPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 768, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Survives a Space switch and shows over a full-screen app, which is
        // most of what "from anywhere" means on this machine.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Closing must not deallocate it — the panel is reopened on every hot
        // key press and a released one would crash the second time.
        panel.isReleasedWhenClosed = false
        // **Dismiss on losing key, not on `hidesOnDeactivate`.** That property
        // fires when the *application* deactivates, and this app is usually not
        // active when the panel is up — so clicking another app would produce no
        // deactivation event and the panel would sit there at floating level
        // over everything. Losing key status is the event that actually
        // corresponds to "the user went somewhere else".
        panel.delegate = self

        let root = TraceMacSearchPanel(
            isPresented: Binding(get: { [weak self] in self?.isVisible ?? false },
                                 set: { [weak self] shown in if !shown { self?.hide() } }),
            // `onOpen` before `onGoTo`, matching the order the properties are
            // declared in `TraceMacSearchPanel`. A memberwise initialiser takes
            // its arguments in declaration order, not in whatever order reads
            // best here — the same rule that bit `MacTaskRow(isToday:)` earlier
            // this session.
            onOpen: { destination, query in
                // **The request is posted before the app is surfaced**, not
                // after. Surfacing can restore a closed `WindowGroup` window,
                // and a request that arrives after that window has already run
                // its `.task(id:)` relies on a second firing to be picked up.
                // Setting it first means the value is simply there, whether the
                // window is old or brand new.
                MacSearchRoute.shared.pending = MacSearchRoute.Request(destination: destination,
                                                                      query: query)
                MacQuickPanelController.shared.hideAndSurfaceApp()
            },
            onGoTo: { section, list in
                // Same order-of-operations as `onOpen` above, and for the same
                // reason: set the request, then surface the window.
                MacSearchRoute.shared.pendingGoTo = MacSearchRoute.GoTo(section: section,
                                                                       list: list)
                MacQuickPanelController.shared.hideAndSurfaceApp()
            })
            .environment(noteStore)
            .environment(notionService)

        let hosting = NSHostingController(rootView: root)
        panel.contentViewController = hosting
        return panel
    }

    /// Centred horizontally on the screen the pointer is on, a third of the way
    /// down. Not the middle: a panel that grows downward as results arrive
    /// should not walk off the bottom of the display, and the eye is already
    /// nearer the top.
    private func position(_ panel: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - frame.height / 3 - size.height / 2))
    }
}

// MARK: - Routing out of the panel

/// Counts panel openings, so the view can reset itself on each one.
///
/// The panel and its hosted SwiftUI view are built once and reused, which is
/// what keeps the corpus loaded between presses. The cost is that every
/// appear-once hook — `onAppear`, a plain `.task` — runs only on the first
/// press. Anything that must happen on *every* press needs a value that changes,
/// and this is it.
@MainActor
@Observable
final class MacQuickPanelSession {
    static let shared = MacQuickPanelSession()
    var opens = 0
    private init() {}
}

/// A destination chosen in the floating panel, waiting for the main window.
///
/// The panel lives outside the SwiftUI window's view hierarchy, so it cannot
/// write into `TraceMacContentView`'s pending-link `@State` directly. Same
/// consume-and-clear shape as `MacSearchTrigger`, and for the same reason: the
/// window may be reopening at the moment the request is made, and a notification
/// posted then lands before anything is listening.
@MainActor
@Observable
final class MacSearchRoute {
    struct Request: Equatable {
        let destination: MacSearchDestination
        let query: String
    }

    /// **A second request type, not a `MacSearchDestination`.** Going to a
    /// SCREEN is not the same act as opening a RECORD: there is nothing to
    /// find, nothing to fail to find, and no history entry worth keeping — the
    /// navigator records records. Squeezing "show me Anytime" into the
    /// destination enum would have meant a case that carries no identity, which
    /// is exactly the kind of not-quite-a-route that enum's doc comment warns
    /// against.
    struct GoTo: Equatable {
        let section: MacSection
        /// A context list to select on the Tasks screen. `nil` means the
        /// section's own default.
        let list: String?
    }

    static let shared = MacSearchRoute()
    var pending: Request?
    var pendingGoTo: GoTo?
    private init() {}
}
