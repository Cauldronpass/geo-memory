// TraceMacCalendar.swift
// The one place that answers "when does a week start?"
//
// Session 64. David, clicking a Sunday in the month grid: *"When i click July
// 12 Sunday, it excludes Monday the 6th and adds Monday the 13th which is the
// next week and wrong."*
//
// `TraceMacJournalView.weekVisits` asked `Calendar.current` for the week
// containing the selected day. On a US locale `Calendar.current.firstWeekday`
// is Sunday, so the interval it handed back ran Sunday to Saturday, while
// every other week-shaped thing in Trace runs Monday to Sunday:
//
//   * the month grid pads with `(firstWeekday + 5) % 7  // Mon=0, Sun=6`
//   * the day-of-week header row reads M T W T F S S
//   * the week notes are `Notes/Horizons/YYYY-Www.md`, and an ISO 8601 week
//     starts on Monday
//   * `HorizonCalendarHeader.weekDates` sets `comps.weekday = 2` by hand
//
// Four places already knew the answer, and each one stated it separately.
// That is not a convention, it is four coincidences. The fifth caller asked
// the locale instead and got a different answer.
//
// Why it hid for so long: Monday through Saturday the error is one day at each
// end (it pulls in the previous Sunday and drops the following one), which
// still looks like a plausible week. On a Sunday it is a whole week off, which
// is how David finally caught it.
//
// Rejected: patching `weekVisits` alone. That fixes the symptom and leaves the
// same trap armed for the sixth caller. Where a fact is app-wide, name it once
// and read it; do not re-derive it per call site. Same lesson as the `remind:`
// loss in Session 63, in a different costume: a rule beats an enumeration.

import Foundation

extension Calendar {

    /// Monday-first, ISO 8601. Use this for anything that reasons about weeks:
    /// week boundaries, week numbers, grid padding, "this week" ranges.
    ///
    /// Deliberately **not** `Calendar.current`, which carries the user's locale
    /// first-weekday. That is Sunday in en_US, and Trace's weeks start on
    /// Monday everywhere they are drawn or written.
    ///
    /// `Locale.current` is kept so month and weekday *names* still localise.
    /// Only the week boundary is pinned.
    static let traceWeek: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.locale = Locale.current
        return c
    }()

    /// The same calendar with a fixed locale, for building and parsing the
    /// `YYYY-Www` note filenames, which must not vary by machine.
    static let traceWeekPOSIX: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()
}
