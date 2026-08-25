// MacSatchelFilterShortcut.swift
// The user-settable, in-app shortcut for Satchel's filter pane, and the pane's
// two stored preferences.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.
//
// Session 73. David: *"can we add a setting that allows me to add a hotkey to
// open that side panel and also allow me to adjust the width of it?"*
//
// ── Local monitor, not Carbon, and not a menu key equivalent ──────────────
//
// Three ways to catch a key on macOS, and this is the third of them.
//
// **Carbon `RegisterEventHotKey`** is what `TraceMacHotKey.swift` uses for
// global search, and it is wrong here. It registers system-wide: pick ⌘⇧F for
// this pane and you take ⌘⇧F away from every other app on the Mac. A shortcut
// for a filter pane inside one tab has no business doing that.
//
// **`.keyboardShortcut` on a `Button`** is what Session 73 shipped first, and it
// is a *menu* key equivalent resolved through the active app's main menu. It
// also cannot be user-settable in any honest way — the modifier set is fixed at
// the call site, and `TraceMacSearchPanel` already documents it failing
// silently in a context where no menu was in play.
//
// **`NSEvent.addLocalMonitorForEvents`** needs no permission (it is local, not
// global — Accessibility is only required for the global variety), needs no
// menu, and reads its combination from a stored value at match time rather than
// from a literal at compile time. Making the shortcut settable and making it
// reliable turn out to be the same change.
//
// ── What it refuses, and why refusing is the point ────────────────────────
//
// A local monitor is called from `-[NSApplication sendEvent:]` before the main
// menu gets its look at the event, so **whatever is recorded here shadows the
// menu**. That is exactly what makes it work while focus is inside the PDF
// view, and it is also how someone binds ⌘Q to a filter pane and can no longer
// quit the app. So a short deny list is refused out loud, on screen, rather
// than accepted and regretted:
//
//   ⌘Q  quit          ⌘W  close window     ⌘,  settings
//   ⌘H  hide          ⌘M  minimise
//
// Everything else is allowed, including combinations this app uses elsewhere.
// Shadowing ⌘F is a defensible thing for David to choose on his own Mac; losing
// ⌘Q is not a choice anyone makes deliberately.
//
// A bare key with no modifier is refused for the ordinary reason: it would eat
// that letter everywhere in the app, including inside the search field.

import AppKit
import SwiftUI
import Carbon.HIToolbox

// MARK: - The pane's stored preferences

/// One home for the pane's defaults keys and its width bounds.
///
/// The bounds were written twice within an hour of each other — once in the
/// `MacColumnResizer` call and once in the Settings slider — which is how two
/// controls end up disagreeing about how narrow the pane may get. D18's rule
/// applies: a number that appears in two places is a decision that lives in
/// neither.
enum SatchelFilterPane {
    static let visibleKey = "tracemac.satchel.facets"
    static let widthKey   = "tracemac.column.satchelfacets"

    static let minWidth: Double = 180
    static let maxWidth: Double = 380
    static let defaultWidth: Double = 232

    /// Open the pane without toggling it. Used when the shortcut is pressed from
    /// another section: you asked for the filters, so arriving with them shut
    /// would be the shortcut answering a question you did not ask.
    @MainActor
    static func show() {
        UserDefaults.standard.set(true, forKey: visibleKey)
    }

    @MainActor
    static func toggle() {
        let now = UserDefaults.standard.bool(forKey: visibleKey)
        UserDefaults.standard.set(!now, forKey: visibleKey)
    }
}

// MARK: - Storage and matching for an arbitrary combination

extension MacHotKeyCombo {

    /// Load from a named defaults key, falling back when absent or malformed.
    ///
    /// The global-search combination has its own `load()`/`save()` pair with a
    /// private key, which stays exactly as it is. This is the same three-field
    /// format under a different key, added rather than substituted so nothing
    /// that already works has to be re-verified.
    static func load(forKey key: String, fallback: MacHotKeyCombo) -> MacHotKeyCombo {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return fallback }
        let parts = raw.components(separatedBy: "|")
        guard parts.count == 3,
              let code = UInt32(parts[0]),
              let mods = UInt32(parts[1]) else { return fallback }
        return MacHotKeyCombo(keyCode: code, modifiers: mods, label: parts[2])
    }

    func save(forKey key: String) {
        UserDefaults.standard.set("\(keyCode)|\(modifiers)|\(label)", forKey: key)
    }

    /// Does this key-down event match?
    ///
    /// `deviceIndependentFlagsMask` first. Raw `modifierFlags` carries
    /// device-specific bits — which physical shift was pressed, whether caps
    /// lock is on — and comparing them unmasked means a shortcut that works
    /// until the day caps lock is left on.
    func matches(_ event: NSEvent) -> Bool {
        guard !isEmpty else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return UInt32(event.keyCode) == keyCode
            && MacHotKeyCombo.carbonModifiers(from: flags) == modifiers
    }
}

// MARK: - The shortcut

@MainActor
@Observable
final class MacSatchelFilterShortcut {

    static let shared = MacSatchelFilterShortcut()

    /// ⌘⇧F. ⌘F is find, and this app has a real find-in-PDF two panes away.
    static let fallback = MacHotKeyCombo(keyCode: UInt32(kVK_ANSI_F),
                                         modifiers: UInt32(cmdKey | shiftKey),
                                         label: "⇧⌘F")

    private static let defaultsKey = "tracemac.satchel.filterhotkey"

    /// Fully qualified on purpose: a stored property's default value cannot say
    /// `Self`, and unqualified static lookup does not reach into the type from
    /// an instance-property initialiser.
    private(set) var combo: MacHotKeyCombo =
        .load(forKey: MacSatchelFilterShortcut.defaultsKey,
              fallback: MacSatchelFilterShortcut.fallback)

    private var monitor: Any?
    /// Set by whoever installs the monitor. Given the section to switch to when
    /// the shortcut is pressed from somewhere else in the app.
    private var onFire: (() -> Void)?

    private init() {}

    // MARK: Recording

    /// Combinations that are refused, with the sentence shown for each.
    ///
    /// Keyed by `(keyCode, carbon modifiers)`. Deliberately short: this is the
    /// set whose loss cannot be recovered from inside the app, not a list of
    /// shortcuts somebody might prefer to keep.
    private static let reserved: [(code: Int, mods: UInt32, what: String)] = [
        (kVK_ANSI_Q,     UInt32(cmdKey), "Quit"),
        (kVK_ANSI_W,     UInt32(cmdKey), "Close Window"),
        (kVK_ANSI_Comma, UInt32(cmdKey), "Settings"),
        (kVK_ANSI_H,     UInt32(cmdKey), "Hide"),
        (kVK_ANSI_M,     UInt32(cmdKey), "Minimise"),
    ]

    /// Apply a recorded combination.
    ///
    /// - Returns: nil on success, or the sentence to put on screen. **Never a
    ///   silent no-op** — this control advertises an action and Session 69 was
    ///   spent twice on controls that advertised one and performed none.
    @discardableResult
    func update(to candidate: MacHotKeyCombo) -> String? {
        guard candidate.modifiers != 0 else {
            return "Needs at least one of ⌃ ⌥ ⇧ ⌘."
        }
        if let clash = Self.reserved.first(where: {
            UInt32($0.code) == candidate.keyCode && $0.mods == candidate.modifiers
        }) {
            return "\(candidate.label) is \(clash.what). Pick something else — this shortcut is matched before the menu, so it would take that away."
        }
        combo = candidate
        candidate.save(forKey: Self.defaultsKey)
        return nil
    }

    func reset() {
        combo = Self.fallback
        combo.save(forKey: Self.defaultsKey)
    }

    // MARK: The monitor

    /// Install the listener. Safe to call more than once.
    ///
    /// Installed from `TraceMacContentView` rather than from the Satchel view,
    /// so the shortcut means something from every section. A shortcut that does
    /// nothing on five of seven tabs is a shortcut you stop trusting, and
    /// "nothing happened" is indistinguishable from "it is broken" — which is
    /// the report this app keeps getting and deserving.
    func install(onFire: @escaping () -> Void) {
        self.onFire = onFire
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // `MainActor.assumeIsolated` is not needed: local monitors are
            // delivered on the main thread from `sendEvent:`, and the closure is
            // already main-actor-isolated by the file's default isolation.
            guard let self, self.combo.matches(event) else { return event }
            self.onFire?()
            // Swallowed. Returning the event as well would let it continue to
            // the menu and to the responder chain, and the whole reason this
            // beats a menu key equivalent is that it lands while focus is
            // inside the document list or the PDF view.
            return nil
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onFire = nil
    }
}
