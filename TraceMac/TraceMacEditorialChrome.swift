// TraceMacEditorialChrome.swift
// The furniture every Editorial screen is built from: the masthead, the
// section label, the day-navigation row, and the floating capture square.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.
//
// Session 79 (2026-08-30). `MacEditorial.swift` holds the tokens; this holds
// the three or four assemblies of them that Today, Upcoming and Tasks all
// repeat. Same reason `TraceMacSectionHeader.swift` exists for the RECORDS
// sections: the value is not the pixels, it is that there is one answer to
// "where does the top of a screen begin" instead of one answer per screen.
//
// Expressions here are kept deliberately short and their types written out.
// Session 79 lost a build to "unable to type-check this expression in
// reasonable time" in a file nobody had touched, and the cheapest insurance
// is not writing four-ternary view modifiers in the first place.

import SwiftUI
import AppKit

// MARK: - Masthead

/// The top of an Editorial screen: 3pt ink rule, caps standfirst, the subject
/// in serif, 1pt ink rule.
///
/// Two shapes, because there are two kinds of screen. A DATED one leads with a
/// numeral and its weekday ("31 Monday"); a NAMED one leads with its own title
/// ("Upcoming", "Tasks"). Passing both would be a screen that has not decided
/// what it is, so the initialisers are separate and neither takes the other's
/// argument.
struct MacEditorialMasthead: View {

    private let kicker: String
    private let numeral: String?
    private let weekday: String?
    private let title: String?

    /// When set, the subject grows a chevron and becomes the door to whatever
    /// the screen wants to unfold beneath it — on both Today and Upcoming that
    /// is a month grid. The phone puts the same chevron in the same place, so
    /// this is parity rather than invention.
    ///
    /// These are `let` and they are arguments to BOTH initialisers, not `var`s
    /// with defaults. Session 80 shipped them as the latter and the build
    /// failed with "extra arguments at positions #3, #4": declaring any
    /// explicit `init` removes the memberwise one, so property defaults are
    /// reachable from nowhere. If a third initialiser is ever added here, it
    /// carries these two as well.
    private let onTapSubject: (() -> Void)?
    private let unfolded: Bool

    /// "AUGUST" over "31 Monday".
    init(kicker: String,
         numeral: String,
         weekday: String,
         onTapSubject: (() -> Void)? = nil,
         unfolded: Bool = false) {
        self.kicker = kicker
        self.numeral = numeral
        self.weekday = weekday
        self.title = nil
        self.onTapSubject = onTapSubject
        self.unfolded = unfolded
    }

    /// "NEXT TWO WEEKS" over "Upcoming".
    init(kicker: String,
         title: String,
         onTapSubject: (() -> Void)? = nil,
         unfolded: Bool = false) {
        self.kicker = kicker
        self.numeral = nil
        self.weekday = nil
        self.title = title
        self.onTapSubject = onTapSubject
        self.unfolded = unfolded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacEditorialRule.heavy
            VStack(alignment: .leading, spacing: 1) {
                Text(kicker).editorialKicker()
                subjectLine
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .onTapGesture { onTapSubject?() }
            MacEditorialRule.ink
        }
    }

    @ViewBuilder
    private var subjectLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let numeral {
                Text(numeral)
                    .font(MacEditorialType.mastheadNumeral)
                    .foregroundStyle(MacEditorialColor.ink)
            }
            if let weekday {
                Text(weekday)
                    .font(MacEditorialType.mastheadWeekday)
                    .foregroundStyle(MacEditorialColor.noteText)
            }
            if let title {
                Text(title)
                    .font(MacEditorialType.masthead)
                    .foregroundStyle(MacEditorialColor.ink)
            }
            Spacer(minLength: 0)
            if onTapSubject != nil {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MacEditorialColor.faint)
                    .rotationEffect(unfolded ? .degrees(180) : .zero)
            }
        }
    }
}

// MARK: - Section label

/// "TO DO" with an optional quiet count at the right: the one row that opens
/// a section inside a page.
struct MacEditorialSectionLabel: View {

    let text: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(text).editorialSectionLabel()
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(MacEditorialType.meta)
                    .foregroundStyle(MacEditorialColor.faint)
            }
        }
        .padding(.bottom, 6)
    }
}

// MARK: - Day navigation

/// YESTERDAY · TODAY · TOMORROW. The active one is ink, not accent: the accent
/// on this screen belongs to the endeavor line and the selected day in the
/// month grid, and a third claimant would make it mean "something is here"
/// rather than "you are here".
struct MacEditorialDayNav: View {

    @Binding var date: Date
    private let cal = Calendar.current

    var body: some View {
        HStack(spacing: 22) {
            word("Yesterday", offset: -1)
            word("Today", offset: 0)
            word("Tomorrow", offset: 1)
            Spacer(minLength: 0)
        }
        .padding(.bottom, 12)
    }

    private func word(_ label: String, offset: Int) -> some View {
        let target: Date = dayOffset(offset)
        let active: Bool = cal.isDate(date, inSameDayAs: target)
        let weight: Font.Weight = active ? .bold : .semibold
        let tint: Color = active ? MacEditorialColor.ink : MacEditorialColor.faint
        return Text(label)
            .font(.system(size: 10, weight: weight))
            .textCase(.uppercase)
            .tracking(1.6)
            .foregroundStyle(tint)
            .contentShape(Rectangle())
            .onTapGesture { date = target }
    }

    private func dayOffset(_ days: Int) -> Date {
        cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: Date())) ?? Date()
    }
}

// MARK: - Capture square

/// The ink + square, bottom-trailing (D188). The phone's own affordance, the
/// same square, on every screen that has a queue.
struct MacEditorialPlus: View {

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(MacEditorialColor.ink)
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(MacEditorialColor.paper)
            }
            .frame(width: MacEditorialLayout.plusSize,
                   height: MacEditorialLayout.plusSize)
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .padding(MacEditorialLayout.plusInset)
    }
}

// MARK: - Not built yet

/// An honest placeholder wearing the right clothes.
///
/// It exists because the sidebar's three DAY rows landed together while their
/// screens did not, and a row that opens nothing is worse than a row that says
/// what it is waiting for. Delete each use as its screen arrives; delete the
/// type when the last one goes.
struct MacEditorialSoon: View {

    let kicker: String
    let title: String
    let line: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacEditorialMasthead(kicker: kicker, title: title)
            Text(line)
                .font(MacEditorialType.note)
                .foregroundStyle(MacEditorialColor.faint)
                .padding(.top, 22)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MacEditorialLayout.margin)
        .padding(.top, MacEditorialLayout.topMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MacEditorialColor.paper)
    }
}

// MARK: - Arrow keys

/// Up/down move the sidebar; left/right step the day on Today.
///
/// Session 79. The Editorial sidebar replaced `List(selection:)`, and `List`
/// was the thing giving arrow-key traversal for free. This gives it back, and
/// gives the day a keyboard too — a calendar you can only move with the mouse
/// is a calendar you stop moving.
///
/// Same shape as `MacSatchelFilterShortcut`, deliberately: a local monitor,
/// installed by the root view, uninstalled with it. A local monitor is
/// delivered from `-[NSApplication sendEvent:]` on the main thread, and this
/// file's default isolation is MainActor, so no `assumeIsolated` dance.
///
/// **What it refuses**, and refusing is most of the design:
///
///   * Anything with a real modifier held. ⌘← is "back" somewhere and always
///     will be; this only ever wants the bare key.
///   * Anything at all while a text view or text field has focus. Arrows are
///     how you move a caret, and a day that jumps while you are editing the
///     day note is the worst possible bug to ship. `NSTextField`'s editor is
///     an `NSTextView`, so the first check covers both.
///
/// Arrow keys carry `.function` (and the numeric pad flag) in
/// `modifierFlags` on macOS, which is why those two are subtracted before the
/// "no modifiers" test rather than tripping it.
@MainActor
final class MacEditorialArrowKeys {

    static let shared = MacEditorialArrowKeys()
    private init() {}

    enum Direction { case up, down, left, right }

    private var monitor: Any?
    private var onMove: ((Direction) -> Void)?

    func install(onMove: @escaping (Direction) -> Void) {
        self.onMove = onMove
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let direction = self.direction(for: event) else { return event }
            self.onMove?(direction)
            // Swallowed: an arrow that both moves the sidebar and continues to
            // the responder chain would scroll something as well.
            return nil
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onMove = nil
    }

    private func direction(for event: NSEvent) -> Direction? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.subtracting([.function, .numericPad]).isEmpty else { return nil }
        guard !isEditingText else { return nil }
        guard !isSheetUp else { return nil }
        switch event.keyCode {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        default:  return nil
        }
    }

    private var isEditingText: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if responder is NSTextView { return true }
        if responder is NSTextField { return true }
        return false
    }

    /// **This monitor has to stand down while a sheet is up** (Session 80).
    ///
    /// It is a singleton installed once for the whole app, it is installed
    /// EARLY, and it swallows bare arrows by returning `nil`. That is correct
    /// for the day nav and it is why the task composer's own key monitor never
    /// received a single arrow: this one had already eaten them. David: "the
    /// arrows work for moving between screens as you say. it just doesnt work
    /// to choose the list type in the plus sign window."
    ///
    /// The lesson is about app-wide monitors generally, not about this one. A
    /// monitor that swallows a key is not a local decision — it is a claim on
    /// that key for the entire process, and every later feature that wants the
    /// same key has to be given back. So the claim needs a boundary, and
    /// "something modal is in front of the day" is the honest one: the day nav
    /// is about the window BEHIND the sheet, and moving it while someone is
    /// looking at a sheet would be wrong even if nothing else wanted the arrow.
    ///
    /// Both directions are checked: the sheet itself may be key
    /// (`sheetParent`), or the parent window may still be key with the sheet
    /// attached (`attachedSheet`).
    ///
    /// Returning `nil` from `direction(for:)` means this monitor returns the
    /// EVENT rather than swallowing it, which is what lets the next monitor in
    /// the chain see it at all.
    private var isSheetUp: Bool {
        guard let key = NSApp.keyWindow else { return false }
        return key.sheetParent != nil || key.attachedSheet != nil
    }
}

// MARK: - Inbox count

/// The two settings that decide who gets told about an un-triaged Inbox.
///
/// Session 80. David: "can we have a subtle notice (maybe a circle with a
/// number next to it on the tasks tab rail for the number of inbox items we
/// have? If we can do this then Id like that to be an option to toggle in the
/// settings and another button to repeat that notification as a badge on the
/// icon. I dont really like icon badges but the task subtle circle idea might
/// be just enough of a push for me."
///
/// **Two separate switches, not one with a "level".** They are different kinds
/// of interruption and he already knows he feels differently about them: the
/// sidebar count is visible only when you are looking at the app, which is when
/// you have already chosen to think about tasks. A Dock badge follows you
/// across every other thing you do all day. Collapsing those into one control
/// would force a person who wants the first to accept the second.
///
/// Both default OFF. A count that appears without being asked for is the app
/// deciding on his behalf that an un-triaged Inbox is a problem, and he has
/// said plainly that he is wary of exactly that.
enum MacInboxCountSetting {
    static let sidebarKey = "tracemac.inboxCount.sidebar"
    static let dockKey = "tracemac.inboxCount.dock"
}

/// A small accent circle carrying a count. Nothing if the count is zero — an
/// empty Inbox should look like nothing at all, not like a zero, because a zero
/// is still a number asking to be read.
struct MacEditorialCount: View {

    let count: Int

    var body: some View {
        if count > 0 {
            // **Grey, not accent** (Session 80). David: "can you make the one
            // in the circle less alarming. maybe a light gray?"
            //
            // Right, and the reason is what accent MEANS here. Everywhere else
            // in this app accent marks something acting or needing an answer —
            // a live tab, a parsed date, a shortcut you can fire. An Inbox with
            // things in it is the normal state of an inbox, not a problem, and
            // painting the ordinary case in the alarm colour is how an app
            // starts feeling like it is nagging.
            //
            // Hairline fill with muted text: legible at a glance, invisible to
            // peripheral vision, which is the correct volume for a number whose
            // job is to be there when you look for it.
            Text("\(count)")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(MacEditorialColor.muted)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .frame(minWidth: 17)
                .background(MacEditorialColor.hairline, in: Capsule())
        }
    }
}

/// Mirrors the Inbox count onto the Dock tile, or clears it.
///
/// Kept here rather than in a view so there is ONE writer. A badge written from
/// two places is a badge that gets stuck: whichever caller runs last wins, and
/// the one that was supposed to clear it may not be the last.
@MainActor
enum MacDockBadge {
    static func set(_ count: Int, enabled: Bool) {
        NSApp.dockTile.badgeLabel = (enabled && count > 0) ? "\(count)" : nil
    }
}

// MARK: - Escape

/// Escape, for a view that is not a control and not a window.
///
/// **`.onExitCommand` was tried first and does not reach an expanded card.**
/// It is delivered through the responder chain to something that has focus, and
/// a card is a stack of rows with no focus of its own — David: "expanding the
/// task in the Today screen and then hitting escape still does not
/// minimize/collapse it back and it should."
///
/// So: a local key monitor, the same instrument as `MacEditorialArrowKeys` and
/// for the same reason (D201 final). It exists only while the card does, which
/// is the whole of its scope — no flags, no singleton, nothing to reset.
///
/// **Two stand-downs, both learned rather than guessed:**
///
///   * While a text field or view is first responder. Escape there cancels
///     what you are typing, and closing the card out from under a half-edited
///     title would throw the edit away.
///   * While a sheet is up. The card is behind it, and D202's rule applies:
///     a monitor that swallows a key is a claim on it for the whole process,
///     so the claim needs a boundary.
///
/// Returns the event when it does not act, so the next monitor still sees it.
struct MacEditorialEscape: ViewModifier {

    /// Whether Escape should also fire while a text field has focus.
    ///
    /// Off by default, because for most views Escape inside a field means
    /// "cancel what I am typing". The task card passes `true` — David: "If I am
    /// in a field within the expanded task window like the note and hit escape
    /// it should likewise collapse" — and makes it safe by COMMITTING the edit
    /// on the way out rather than discarding it. That is the condition on this
    /// flag: turn it on only where something else saves the work first.
    var includingTextFields: Bool = false
    let onEscape: () -> Void
    @State private var monitor: Any? = nil

    func body(content: Content) -> some View {
        content
            .onAppear { install() }
            .onDisappear { remove() }
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }          // escape
            guard let key = NSApp.keyWindow else { return event }
            if key.sheetParent != nil || key.attachedSheet != nil { return event }
            // The quick panel is an `NSPanel` and owns Escape for closing
            // itself. Without this, a card left open behind the panel would eat
            // the panel's own dismissal — the D202 trap, one layer further out.
            if key is NSPanel { return event }
            if !includingTextFields {
                let responder = key.firstResponder
                if responder is NSTextView || responder is NSTextField { return event }
            }
            onEscape()
            return nil
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

extension View {
    /// Close-on-Escape for a view with no focus of its own. Apply it to the
    /// thing that EXISTS only while open, so its lifetime is the scope.
    func escapeCloses(includingTextFields: Bool = false,
                      _ onEscape: @escaping () -> Void) -> some View {
        modifier(MacEditorialEscape(includingTextFields: includingTextFields,
                                    onEscape: onEscape))
    }
}

// MARK: - Month grid

/// One month, Monday-first, in Editorial dress. Reusable on purpose: the task
/// card's Pick day, the compose rail's date step, and Today's month rail are
/// three drawings of the same thing, and Session 64's own lesson (see
/// `TraceMacCalendar.swift`) is that a fact answered per call site gets five
/// different answers.
///
/// Week start comes from `Calendar.traceWeek` — ISO 8601, Monday — and NOT from
/// `Calendar.current`, whose first weekday is Sunday in en_US. That is the exact
/// bug that file was written to kill.
struct MacEditorialMonthGrid: View {

    @Binding var selected: Date
    /// Days that should wear a dot: notes, or anything the host wants marked.
    var marked: Set<String> = []

    @State private var monthAnchor: Date? = nil
    /// The day under the pointer. Things' own pleasure: the grid answers the
    /// mouse before you click it. Session 80, David: "the day under the mouse
    /// should have a slight shading to it... This is the behavior of Things
    /// that makes it a pleasure to use."
    @State private var hoveredKey: String? = nil
    /// Two-finger scroll pages the month. A local `.scrollWheel` monitor,
    /// installed only while the pointer is over the grid, because SwiftUI has
    /// no scroll-wheel modifier and a `DragGesture` never sees a trackpad
    /// swipe. Swallowing the event is deliberate — scrolling the day column
    /// underneath while aiming at a calendar is worse than not scrolling.
    @State private var scrollMonitor: Any? = nil
    @State private var scrollAccum: CGFloat = 0

    private let cal = Calendar.traceWeek

    private var month: Date {
        monthAnchor ?? startOfMonth(selected)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            MacEditorialRule.accent
            weekdayRow
            grid
        }
        .onHover { inside in
            if inside { installScroll() } else { removeScroll() }
        }
        .onDisappear { removeScroll() }
    }

    // MARK: Scroll to page

    private func installScroll() {
        guard scrollMonitor == nil else { return }
        scrollAccum = 0
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            scrollAccum += event.scrollingDeltaY
            // Natural scrolling: fingers up is a negative delta and means
            // forward in time, matching the phone.
            if scrollAccum < -14 { step(1); scrollAccum = 0 }
            else if scrollAccum > 14 { step(-1); scrollAccum = 0 }
            return nil
        }
    }

    private func removeScroll() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        hoveredKey = nil
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 0) {
            chevron("chevron.left") { step(-1) }
            Spacer(minLength: 0)
            Text(monthTitle)
                .font(.system(size: 10, weight: .bold))
                .textCase(.uppercase)
                .tracking(2)
                .foregroundStyle(MacEditorialColor.accent)
            Spacer(minLength: 0)
            chevron("chevron.right") { step(1) }
        }
        .padding(.bottom, 8)
    }

    private func chevron(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(MacEditorialColor.faint)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var monthTitle: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: month)
    }

    private func step(_ months: Int) {
        guard let moved = cal.date(byAdding: .month, value: months, to: month) else { return }
        monthAnchor = startOfMonth(moved)
    }

    // MARK: Grid

    private var weekdayRow: some View {
        HStack(spacing: 1) {
            ForEach(Array(weekdayInitials.enumerated()), id: \.offset) { pair in
                Text(pair.element)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(MacEditorialColor.faint)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 8)
    }

    /// Monday-first initials, localised. `veryShortWeekdaySymbols` is
    /// Sunday-first regardless of the calendar, so it is rotated by hand rather
    /// than trusted.
    private var weekdayInitials: [String] {
        let symbols = DateFormatter().veryShortWeekdaySymbols ?? ["S", "M", "T", "W", "T", "F", "S"]
        guard symbols.count == 7 else { return symbols }
        return Array(symbols[1...6]) + [symbols[0]]
    }

    private var grid: some View {
        VStack(spacing: 1) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { week in
                HStack(spacing: 1) {
                    ForEach(Array(week.element.enumerated()), id: \.offset) { cell in
                        dayCell(cell.element)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private func dayCell(_ day: Date) -> some View {
        // Typed lets before any modifier — see the file header.
        let inMonth: Bool = cal.isDate(day, equalTo: month, toGranularity: .month)
        let isSelected: Bool = cal.isDate(day, inSameDayAs: selected)
        let isToday: Bool = cal.isDateInToday(day)
        let hasMark: Bool = marked.contains(Self.key(day))
        let number: String = String(cal.component(.day, from: day))

        let tint: Color = {
            if isSelected { return MacEditorialColor.paper }
            if !inMonth { return MacEditorialColor.hairline }
            if isToday { return MacEditorialColor.accent }
            return MacEditorialColor.noteText
        }()
        let key: String = Self.key(day)
        let isHovered: Bool = (hoveredKey == key)
        let fill: Color = {
            if isSelected { return MacEditorialColor.ink }
            if isHovered { return MacEditorialColor.accent.opacity(0.12) }
            return Color.clear
        }()
        let weight: Font.Weight = isSelected ? .bold : .regular
        let dot: Color = hasMark && !isSelected ? MacEditorialColor.faint : Color.clear

        return VStack(spacing: 1) {
            Text(number)
                .font(.system(size: 11, weight: weight).monospacedDigit())
                .foregroundStyle(tint)
            Circle().fill(dot).frame(width: 3, height: 3)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 26)
        .background(fill)
        .contentShape(Rectangle())
        .onHover { inside in hoveredKey = inside ? key : (hoveredKey == key ? nil : hoveredKey) }
        .onTapGesture { selected = cal.startOfDay(for: day) }
    }

    // MARK: Month maths

    private func startOfMonth(_ d: Date) -> Date {
        cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
    }

    /// Six rows always. A month that fits in five still gets six, because a grid
    /// that changes height as you page months makes everything under it jump.
    private var weeks: [[Date]] {
        let first = startOfMonth(month)
        let weekday = cal.component(.weekday, from: first)
        // ISO: Monday == 2 in the Gregorian numbering Calendar reports.
        let leading = (weekday - cal.firstWeekday + 7) % 7
        guard let gridStart = cal.date(byAdding: .day, value: -leading, to: first) else { return [] }
        var out: [[Date]] = []
        for row in 0..<6 {
            var week: [Date] = []
            for col in 0..<7 {
                let offset = row * 7 + col
                if let d = cal.date(byAdding: .day, value: offset, to: gridStart) {
                    week.append(d)
                }
            }
            out.append(week)
        }
        return out
    }

    static func key(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

// MARK: - Pill

/// A bordered action pill that answers the pointer.
///
/// Session 80, David on the month grid's hover shading: "We might want to do
/// the same thing for other pills as well in the app." He is right, and the
/// reason is worth stating: a control that changes under the pointer tells you
/// it is a control BEFORE you commit to clicking it. Everything in this design
/// is quiet, so the hover state is doing work the styling deliberately isn't.
///
/// Tint is the accent at 12%, the same wash the month grid's hovered day uses,
/// so "the pointer is here" reads identically everywhere.
struct MacEditorialPill: View {

    let label: String
    var destructive: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        let tint: Color = destructive ? MacEditorialColor.accent : MacEditorialColor.noteText
        let edge: Color = destructive ? MacEditorialColor.accent : MacEditorialColor.hairline
        let wash: Color = hovering ? MacEditorialColor.accent.opacity(0.12) : Color.clear

        return Button(action: action) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(tint)
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .background(wash, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(edge, lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The quiet glyph-and-word actions under the pills — Done, Anytime, Someday.
/// Same hover wash, no border: these are verbs, not buttons.
struct MacEditorialVerb: View {

    let label: String
    let glyph: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        let tint: Color = hovering ? MacEditorialColor.ink : MacEditorialColor.muted

        return Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: glyph).font(.system(size: 12))
                Text(label).font(.system(size: 12.5))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(hovering ? MacEditorialColor.accent.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
