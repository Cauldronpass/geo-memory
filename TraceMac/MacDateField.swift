// MacDateField.swift
// A date, shown as text, edited in a calendar popover. Mac-only.
//
// Session 65. David, on the endeavor settings sheet: *"I dont like the date
// picker with spinning months and days, etc. Id rather just have a small
// calendar to pick the day."*
//
// He is describing `DatePicker`'s macOS default, `.stepperField` — three number
// fields and a pair of arrows. It is compact and it is genuinely bad for the
// thing it is used for here: picking a day you are thinking about as a day of
// the week, not as a number. Nobody knows offhand that the trip starts on the
// 31st; they know it starts on the Friday.
//
// ── Why a popover and not just `.graphical` ───────────────────────────────
//
// `.datePickerStyle(.graphical)` is the one-word fix and it draws a full
// month inline, around 200pt tall. The endeavor sheet has two dates, so
// switching both would have made a 380pt sheet roughly twice as tall as the
// five fields it exists to collect, with two calendars competing for attention
// and the buttons pushed off the bottom of most windows.
//
// So the calendar is the same `.graphical` picker, in a popover behind a button
// that reads the date back in the form he thinks in: `Fri 31 Jul 2026`. One
// calendar on screen at a time, and the resting state of the sheet is still a
// list of fields.
//
// This is also the macOS convention rather than an invention — Calendar and
// Reminders both put the month behind the date, not beside it.
//
// ── Its own file ──────────────────────────────────────────────────────────
//
// `MacVisitDetailView` has the other date picker in the app, and it is the head
// of the read-only-fields problem Phase 4 is about. When that gets fixed it
// should use this rather than grow a second calendar, which is why this is not
// a private helper inside the endeavor sheet. Same reasoning as `MacIconBadge`
// and `MacAvatar`: a component two screens will want is a file, not a nested
// struct. `TraceMac/` is a buildable folder, so a new file here needs no
// project edit.

import SwiftUI

struct MacDateField: View {

    let label: String
    @Binding var date: Date

    @State private var showing = false

    /// `Fri 31 Jul 2026`. The weekday is the point: it is how a trip date is
    /// actually held in mind, and it is the thing `.stepperField` cannot show.
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE d MMM yyyy"
        return f
    }()

    var body: some View {
        LabeledContent(label) {
            Button {
                showing = true
            } label: {
                Text(Self.formatter.string(from: date))
                    .font(MacType.body)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                DatePicker("", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding(10)
                    // The popover has no Done button on purpose. A graphical
                    // picker commits on the click that selects the day, so a
                    // confirm step would be a second click for a decision
                    // already made — and the binding has already written by the
                    // time anyone could press it.
                    .onChange(of: date) { _, _ in showing = false }
            }
        }
    }
}
