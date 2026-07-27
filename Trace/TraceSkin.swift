import SwiftUI

// MARK: - TraceSkin
//
// Session 48 (Trace redesign, Home/People/Notes/tab-bar) — new standing build
// requirement from Session 47's addendum: centralize the redesigned screens'
// colors, card treatment, and shared pill-segment control in one file,
// mirroring DayflowSkin.swift's own pattern (see that file's header comment)
// so a future reskin (as happened for Dayflow in Session 29/30) means editing
// this file, not every view. Home/PeopleView/NotesView all draw from here
// instead of hardcoding hex values.
//
// Values below are read directly off trace-redesign-mockup-v7.html (vault
// mirror, canonical reference for this redesign). Not independently verified
// in Xcode/Simulator — same standing limitation DayflowSkin's own header notes
// call out; check contrast/weights on first real build.

// MARK: - Background & card

extension View {
    /// Mockup body background (#e9e9ee) — the light warm-gray canvas behind
    /// Home/People/Notes' cards. Deliberately its own color rather than
    /// reusing Color(UIColor.systemGroupedBackground) (what the rest of Trace
    /// still uses) so this redesign's palette can be re-tuned independently
    /// later without touching unrelated screens.
    func traceBackground() -> some View {
        self.background(Color.traceCanvas.ignoresSafeArea())
    }

    /// Mockup `.card` treatment — white, 18pt radius, soft flat shadow.
    func traceCard() -> some View {
        self
            .background(Color.traceCardBackground, in: RoundedRectangle(cornerRadius: 18))
            .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 1)
    }
}

// MARK: - Colors

extension Color {
    static let traceCanvas         = Color(red: 0.914, green: 0.914, blue: 0.933) // #e9e9ee
    static let traceCardBackground = Color.white
    static let traceInk            = Color(red: 0.110, green: 0.110, blue: 0.118) // #1c1c1e — primary text
    static let traceSecondary      = Color(red: 0.557, green: 0.557, blue: 0.576) // #8e8e93 — secondary text
    static let traceTertiary       = Color(red: 0.780, green: 0.780, blue: 0.800) // #c7c7cc — calendar-cell gray
    static let traceHairline       = Color(red: 0.933, green: 0.933, blue: 0.941) // #eeeef0 — row dividers
    static let traceSegmentTrack   = Color(red: 0.925, green: 0.933, blue: 0.941) // #eceef0 — pill toggle track / search bar fill
    static let traceBlue           = Color(red: 0.039, green: 0.518, blue: 1.0)   // #0a84ff — today marker, agenda dot
    static let traceOrange         = Color(red: 1.0,   green: 0.584, blue: 0.0)   // #ff9500 — has-note / week-has-visits marker
    static let tracePurple         = Color(red: 0.686, green: 0.322, blue: 0.871) // #af52de — active filter indicator
    static let traceAmberInk       = Color(red: 0.788, green: 0.463, blue: 0.039) // #c9760a — avatar-initial text
    static let traceAmberBg        = Color(red: 1.0,   green: 0.933, blue: 0.878) // #ffeee0 — avatar background
    static let traceGreen          = Color(red: 0.204, green: 0.780, blue: 0.349) // #34c759 — has-note dot (day cell)
    /// "Dormant" relationship staleness cue — the orange row-subtitle color
    /// used on People-tab rows. Same hue family as traceOrange; kept as its
    /// own token since it's tied to a specific semantic (stale relationship),
    /// not the generic "has note" marker.
    static let traceStale          = Color(red: 0.788, green: 0.463, blue: 0.039) // #c9760a
}

// MARK: - Section title

extension View {
    /// The small bold uppercase gray section header ("This Week", "Jump To",
    /// "Showing: Agenda", …) used throughout the redesigned screens.
    func traceSectionTitleStyle() -> some View {
        self
            .font(.system(size: 12.5, weight: .bold))
            .foregroundStyle(Color.traceSecondary)
            .textCase(.uppercase)
    }
}

// MARK: - TraceSegmentedControl
//
// Reusable pill toggle — Home's Recent Activity/Coming Up, People's
// Interactions/People, Notes' Day/Week. One shared component so all three
// stay visually identical and a restyle only ever happens here, not per view.
// Deliberately custom rather than native `Picker(.segmented)` — the mockup's
// pill (white active segment, soft shadow, gray track) doesn't match the
// system segmented style closely enough to reuse it as-is.

struct TraceSegmentedControl<Option: Hashable>: View {
    let options: [Option]
    let label: (Option) -> String
    @Binding var selection: Option

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.self) { option in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selection = option }
                } label: {
                    Text(label(option))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(selection == option ? Color.traceInk : Color.traceSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            selection == option ? Color.white : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .shadow(color: .black.opacity(selection == option ? 0.08 : 0), radius: 2, x: 0, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.traceSegmentTrack, in: RoundedRectangle(cornerRadius: 10))
    }
}
