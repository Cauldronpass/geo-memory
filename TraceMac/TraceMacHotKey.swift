// TraceMacHotKey.swift
// The system-wide shortcut for global search. Spec §9.4, step two of it.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.
//
// ── Why Carbon, in 2026 ──────────────────────────────────────────────────
//
// `RegisterEventHotKey` is the only route to a system-wide shortcut that needs
// **no permission at all**. The alternative, `NSEvent.addGlobalMonitorForEvents`,
// requires Accessibility, which means a System Settings trip and a toggle that
// silently resets on some updates. The spec calls this out and prefers Carbon;
// so does this file.
//
// The cost is one real limitation, and it decided the default shortcut:
// **Carbon knows four modifiers — command, shift, option, control — and fn is
// not one of them.** David asked for fn+Space first. It cannot be registered
// this way at any price, and the honest answer was to say so rather than build
// three variants of a thing that was never going to fire. ⌃⌥Space instead, by
// his choice, with a picker in Settings.
//
// ── The failure that must be visible ─────────────────────────────────────
//
// `RegisterEventHotKey` returns an `OSStatus`, and a combination another app
// already owns comes back non-zero. A shortcut that quietly failed to register
// is the exact defect Session 69 spent an evening on twice: a control that
// advertises an action and performs none. So registration reports its result,
// Settings shows it, and the old shortcut is only released once the new one is
// known to have taken.

import AppKit
import Carbon.HIToolbox

// MARK: - The combination

struct MacHotKeyCombo: Equatable, Sendable {
    /// Virtual key code, e.g. `kVK_Space` (49). Layout-independent — the code is
    /// the physical key, so this survives a keyboard-layout change, which is the
    /// reason it is stored rather than the character.
    var keyCode: UInt32
    /// Carbon modifier mask: `cmdKey | optionKey | controlKey | shiftKey`.
    var modifiers: UInt32
    /// What to draw in Settings and in the menu, captured when the key was
    /// recorded. Stored rather than derived: turning a virtual key code back
    /// into a printable name means `UCKeyTranslate` and a live layout, and this
    /// is a label, not a source of truth.
    var label: String

    /// ⌃⌥Space.
    ///
    /// Worth knowing, and not a mistake: macOS binds ⌃⌥Space to *Select next
    /// source in the Input menu* by default. With one input source installed
    /// that binding does nothing, and registration succeeds. If a second source
    /// is ever added, this will be the shortcut that stops working, and Settings
    /// will say so rather than leaving it a mystery.
    static let `default` = MacHotKeyCombo(keyCode: UInt32(kVK_Space),
                                          modifiers: UInt32(controlKey | optionKey),
                                          label: "⌃⌥Space")

    var isEmpty: Bool { keyCode == 0 && modifiers == 0 }

    // MARK: Storage
    //
    // `UserDefaults.standard`, deliberately NOT the App Group suite. Session 69
    // watched `group.com.david.trace` detach from `cfprefsd` on macOS — the
    // console said so and the Settings panel emptying itself agreed — and this
    // is a Mac-only preference that no other target needs to read. Nothing is
    // gained by putting it in the suite with the known problem.

    private static let key = "tracemac.search.hotkey"

    static func load() -> MacHotKeyCombo {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return .default }
        let parts = raw.components(separatedBy: "|")
        guard parts.count == 3,
              let code = UInt32(parts[0]),
              let mods = UInt32(parts[1]) else { return .default }
        return MacHotKeyCombo(keyCode: code, modifiers: mods, label: parts[2])
    }

    func save() {
        UserDefaults.standard.set("\(keyCode)|\(modifiers)|\(label)",
                                  forKey: MacHotKeyCombo.key)
    }

    static func clearSaved() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: Translation from a recorded key press

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.option)  { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.shift)   { mask |= UInt32(shiftKey) }
        return mask
    }

    /// Menu-style symbols, in Apple's order: ⌃⌥⇧⌘.
    static func label(flags: NSEvent.ModifierFlags, keyCode: UInt16, characters: String?) -> String {
        var out = ""
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option)  { out += "⌥" }
        if flags.contains(.shift)   { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        return out + keyName(keyCode: keyCode, characters: characters)
    }

    private static func keyName(keyCode: UInt16, characters: String?) -> String {
        switch Int(keyCode) {
        case kVK_Space:        return "Space"
        case kVK_Return:       return "Return"
        case kVK_Tab:          return "Tab"
        case kVK_Escape:       return "Esc"
        case kVK_Delete:       return "Delete"
        case kVK_LeftArrow:    return "←"
        case kVK_RightArrow:   return "→"
        case kVK_UpArrow:      return "↑"
        case kVK_DownArrow:    return "↓"
        default:
            let text = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "Key \(keyCode)" : text.uppercased()
        }
    }
}

// MARK: - Registration

/// Owns the one registered hot key and re-registers when it changes.
///
/// `@Observable` so Settings can watch `lastError` without a notification, and a
/// singleton because there is exactly one system-wide shortcut and Carbon would
/// hand a second registration of the same combination an error anyway.
@MainActor
@Observable
final class MacHotKeyCenter {

    static let shared = MacHotKeyCenter()

    private(set) var combo: MacHotKeyCombo = .load()
    /// `nil` when the current combination is registered and live. A sentence
    /// when it is not, shown verbatim in Settings.
    private(set) var lastError: String?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// 'TrSc'. Four bytes, checked in the C callback so this app ignores hot key
    /// events that are not its own.
    fileprivate static let signature: OSType = 0x54725363

    private init() {}

    // MARK: Install

    /// Installs the Carbon handler once and registers the stored combination.
    /// Safe to call more than once; the handler is installed on the first call
    /// only.
    @discardableResult
    func start() -> Bool {
        installHandlerIfNeeded()
        return register(combo)
    }

    /// Swaps in a new combination. **The old one is released first and put back
    /// if the new one is refused**, so a rejected shortcut leaves the user with
    /// the working one rather than with nothing.
    @discardableResult
    func update(to newCombo: MacHotKeyCombo) -> Bool {
        let previous = combo
        if register(newCombo) {
            combo = newCombo
            newCombo.save()
            return true
        }
        _ = register(previous)
        return false
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // A C function pointer, so it captures nothing. It reaches the singleton
        // by name, which is a global reference rather than a capture and is what
        // makes this legal.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &identifier)
            guard status == noErr, identifier.signature == MacHotKeyCenter.signature else {
                return OSStatus(eventNotHandledErr)
            }
            // The callback arrives on the main thread already, but `Task { @MainActor }`
            // is what lets a C callback call into an isolated type without an
            // `assumeIsolated` the compiler cannot check.
            Task { @MainActor in MacHotKeyCenter.shared.fire() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    private func register(_ candidate: MacHotKeyCombo) -> Bool {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        guard !candidate.isEmpty else {
            lastError = "No shortcut set."
            return false
        }
        var ref: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: MacHotKeyCenter.signature, id: 1)
        let status = RegisterEventHotKey(candidate.keyCode,
                                         candidate.modifiers,
                                         identifier,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        guard status == noErr, ref != nil else {
            lastError = "\(candidate.label) could not be registered — another app is probably using it."
            return false
        }
        hotKeyRef = ref
        lastError = nil
        return true
    }

    // MARK: Fire

    /// Show the floating search panel.
    ///
    /// **This used to summon the main window**, because the panel was drawn
    /// inside it. David, on first real use: *"When i was in another app and hit
    /// the hotkey... the search was hidden by other apps"* and *"I wonder if the
    /// hotkey could surface just the search window without having to load the
    /// full app window."* Both were the same cause. A 1200×750 window is a heavy
    /// answer to *"what is Megan's number"*, and an ordinary window obeys
    /// ordinary window ordering, which is how it ended up behind something.
    ///
    /// The fallback still exists and is not dead code: `MacQuickPanelController`
    /// needs the two stores, and it gets them from `TraceMacContentView`'s
    /// launch task. Before the first window has ever appeared there is nothing
    /// to draw with, so the shortcut opens the app — once — rather than doing
    /// nothing.
    private func fire() {
        if MacQuickPanelController.shared.isConfigured {
            MacQuickPanelController.shared.toggle()
            return
        }
        NSApp.activate()
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
        }
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        MacSearchTrigger.shared.pending = true
    }
}

// MARK: - The request

/// A pending "open search", set by the hot key and consumed by the window.
///
/// **Not a notification.** A notification posted at the moment the window is
/// being restored lands before anything is listening, and the fix for that is
/// the hand-tuned `asyncAfter` delay this project removed four of in Session 63.
/// A held flag consumed in `.task(id:)` fires whether the view is already up or
/// arrives a beat later, which is the same pattern every deep link here uses.
@MainActor
@Observable
final class MacSearchTrigger {
    static let shared = MacSearchTrigger()
    var pending = false
    private init() {}
}
