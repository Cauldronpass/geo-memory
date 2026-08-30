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

    /// "AUGUST" over "31 Monday".
    init(kicker: String, numeral: String, weekday: String) {
        self.kicker = kicker
        self.numeral = numeral
        self.weekday = weekday
        self.title = nil
    }

    /// "NEXT TWO WEEKS" over "Upcoming".
    init(kicker: String, title: String) {
        self.kicker = kicker
        self.numeral = nil
        self.weekday = nil
        self.title = title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacEditorialRule.heavy
            VStack(alignment: .leading, spacing: 1) {
                Text(kicker).editorialKicker()
                subjectLine
            }
            .padding(.vertical, 9)
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
}
