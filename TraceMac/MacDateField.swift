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
    /// Adds a time to the button's text and an hour-and-minute picker under the
    /// month. Off by default: an endeavor's start and end are days, and only a
    /// booking needs the clock.
    var includesTime: Bool = false

    @State private var showing = false

    /// `Fri 31 Jul 2026`. The weekday is the point: it is how a trip date is
    /// actually held in mind, and it is the thing `.stepperField` cannot show.
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE d MMM yyyy"
        return f
    }()

    /// `9:05 AM`, when the field carries one.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f
    }()

    /// The grid's binding, which **keeps the time when the day changes.**
    ///
    /// `MacEditorialMonthGrid` hands back the day you clicked, and every
    /// existing caller wanted exactly that because a task's date is a day. A
    /// booking's is not: picking 21 November for a 4pm check-in must not turn
    /// it into midnight. So the picked day and the held time are merged here,
    /// at the one call site that carries a clock, rather than by changing what
    /// the grid means for its three other callers.
    private var dayBinding: Binding<Date> {
        Binding(
            get: { date },
            set: { picked in
                guard includesTime else { date = picked; return }
                let cal = Calendar.current
                let time = cal.dateComponents([.hour, .minute], from: date)
                var day = cal.dateComponents([.year, .month, .day], from: picked)
                day.hour = time.hour
                day.minute = time.minute
                date = cal.date(from: day) ?? picked
            }
        )
    }

    private var buttonText: String {
        let day = Self.formatter.string(from: date)
        guard includesTime else { return day }
        return day + " · " + Self.timeFormatter.string(from: date)
    }

    var body: some View {
        LabeledContent(label) {
            Button {
                showing = true
            } label: {
                Text(buttonText)
                    .font(MacType.body)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    // **`MacEditorialMonthGrid`, not `DatePicker(.graphical)`.**
                    // David, comparing this popover with the task card's Pick
                    // day: *"the calendar picker works great but the theme
                    // doesnt match the rest of the app."* He is right, and it
                    // is the exact drift that grid's own comment warns about:
                    // the task card, the compose rail and Today all draw one
                    // month through one component, and this was a fourth
                    // drawing of the same thing in Apple's dress rather than
                    // the app's. It is also Monday-first via `Calendar.traceWeek`,
                    // which the system picker is not.
                    MacEditorialMonthGrid(selected: dayBinding)
                    if includesTime {
                        MacEditorialRule.hair
                        HStack(spacing: 10) {
                            Text("Time").editorialFieldLabel()
                            DatePicker("", selection: $date, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(14)
                .background(MacEditorialColor.paper)
                // **The date-only popover closes on the click that picks a day;
                // the date-and-time one does not.** A graphical picker commits
                // on that click, so a confirm step would be a second click for
                // a decision already made. With a time field under it there is
                // a second decision still to make, and closing on the first
                // would put the time out of reach — so that popover dismisses
                // the way every macOS popover does, by clicking away from it.
                // No Done button either way: it would be chrome for one case
                // and a redundant click for the other.
                .onChange(of: date) { _, _ in
                    guard !includesTime else { return }
                    showing = false
                }
            }
        }
    }
}
