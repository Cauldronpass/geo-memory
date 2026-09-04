// MacEndeavorPhrasing.swift
// The phone's endeavor date phrasing, on the Mac. Mac-only target.
//
// Session 83 (2026-09-03), D257. `endeavorDateLabel` and
// `endeavorCountdownLabel` live in `Dayflow/DayflowEndeavorViews.swift`, which
// TraceMac cannot see, and the Endeavors list needs the same words the phone
// uses ("20 – 28 Nov 2026", "Starts in 78 days") so the two lists agree.
//
// **This is a byte-for-byte copy of the Dayflow block, sliced from that file
// by a script rather than retyped.** It exists only because moving the two
// functions into `Trace/` needs `membershipExceptions` entries for Dayflow and
// TraceMac, which is a pbxproj edit, which needs Xcode closed. At the next
// Xcode-closed window: move this block to `Trace/EndeavorPhrasing.swift`,
// delete it from BOTH `DayflowEndeavorViews.swift` and this file, and add the
// two membership entries. Until then, a change to one must be made to both —
// the backlog carries the item.

import SwiftUI

// MARK: - Date phrasing

/// "14 – 24 Sep 2026", "Since 2 Mar 2026", "From 30 Jul 2026", "No dates yet".
///
/// Prose, not ISO. The ISO form is what is stored; this is what is read. The
/// year is dropped from the first date when both fall in the same one, because
/// "14 Sep 2026 – 24 Sep 2026" makes a reader do work for nothing.
///
/// AN OPEN-ENDED ENDEAVOR READS DIFFERENTLY DEPENDING ON DIRECTION. The first
/// version said "Since" for every one of them, which is fine for a renovation
/// that began in March and plainly wrong for a trip that starts tomorrow —
/// "since" looks backwards. David caught it on his second Endeavor, 2026-07-29.
///
/// "From" rather than "Starts", because the countdown line directly underneath
/// already says "Starts tomorrow" and two verbs stacked read as a stutter.
func endeavorDateLabel(_ e: Endeavor, on now: Date = Date()) -> String {
    let day = DateFormatter(); day.dateFormat = "d MMM"
    let full = DateFormatter(); full.dateFormat = "d MMM yyyy"
    let cal = Calendar.current

    switch (e.starts, e.ends) {
    case let (start?, end?):
        if cal.component(.year, from: start) == cal.component(.year, from: end) {
            return "\(day.string(from: start)) – \(full.string(from: end))"
        }
        return "\(full.string(from: start)) – \(full.string(from: end))"
    case let (start?, nil):
        let hasBegun = cal.startOfDay(for: start) <= cal.startOfDay(for: now)
        return hasBegun ? "Since \(full.string(from: start))"
                        : "From \(full.string(from: start))"
    case let (nil, end?):
        return "Until \(full.string(from: end))"
    default:
        return "No dates yet"
    }
}

/// The line underneath — the thing a date range is actually for.
/// "Starts in 48 days" · "Day 3 of 11" · "Ended 2 months ago".
func endeavorCountdownLabel(_ e: Endeavor, on now: Date = Date()) -> String? {
    switch e.status(on: now) {
    case .upcoming:
        guard let days = e.daysUntilStart(on: now) else { return nil }
        if days == 0 { return "Starts today" }
        if days == 1 { return "Starts tomorrow" }
        return "Starts in \(days) days"
    case .active:
        guard let index = e.dayIndex(on: now) else { return nil }
        if let total = e.totalDays { return "Day \(index) of \(total)" }
        return "Day \(index)"
    case .past:
        guard let ends = e.ends else { return nil }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "Ended \(f.localizedString(for: ends, relativeTo: now))"
    case .idea, .onHold, .cancelled:
        return nil
    }
}
