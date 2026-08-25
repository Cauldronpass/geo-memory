import SwiftUI
import WidgetKit
import UIKit

// MARK: - CaptureView
//
// The entire app. One screen: today's date, a full-bleed text field
// auto-focused on appear, and a single commit button. Modeled on Drafts by
// Agile Tortoise per David's explicit request — "when you open the app it
// goes directly into input text mode."
//
// **Design decisions locked with David before this was written** (2026-07-24,
// Dayflow-HANDOFF.md Session 44 addendum):
//   - Return key inserts a normal newline — does NOT submit. iOS gives no
//     reliable way to distinguish "wants a new line" from "wants to submit"
//     on Return alone, and David wants real multi-line notes (closer to how
//     Drafts itself works), so committing is a separate explicit action —
//     the checkmark button below.
//   - Nothing programmatically closes the app after Send — iOS has no API
//     for an app to voluntarily quit itself. Confirmed acceptable: the
//     field clears and stays focused, ready for the next note; David
//     backgrounds it himself with a swipe when actually done.
//   - "At the end of the day the note starts blank again" — David's own
//     phrasing. In-progress (unsent) text IS persisted across backgrounding
//     within the same calendar day, so a partial thought isn't lost if you
//     swipe away and come back later the same day — but a day boundary
//     crossing (a fresh launch on a new day, OR the app happening to still
//     be open when midnight passes) discards whatever was left unsent and
//     starts blank. See `resetIfNewDay()` below — checked both on appear
//     and any time the app becomes active again, so the "still open at
//     midnight" case is covered too, not just a fresh next-day launch.
//   - **Swipe-to-day, added 2026-07-24** (app expansion item 2): swiping
//     left on the header row moves the note's TARGET day forward one day
//     per swipe (Today → Tomorrow → the day after, etc.) rather than
//     moving already-saved content — Jot commits are a single explicit
//     action, so it's simpler and safer to just change which day's file
//     that action writes to than to write-then-move. Swiping right walks
//     it back one day at a time, floored at Today; tapping the day pill
//     jumps straight back to Today. Deliberately NOT wired to the whole
//     screen/text canvas — a DragGesture layered over JotTextView's
//     UITextView would compete with the text view's own tap/scroll/
//     selection gestures, an unnecessary risk for a feature that doesn't
//     need the whole screen. Confined to the header row instead, which
//     has no competing gestures of its own. The target always resets to
//     Today right after a successful send (David's call, so a run of
//     several notes doesn't silently keep going to a stale future day) —
//     swipe again before each note if you want to add more than one to
//     the same future day.
//   - **Swipe-right-to-Inbox, added 2026-07-24** (app expansion backlog
//     item 3 — deferred at the time the Dayflow Inbox itself was built,
//     picked up this session). Same `Notes/Inbox/` file-per-note storage
//     Dayflow's own Inbox screen and `QuickAppendSheet.swift`'s `.inbox`
//     destination already write to — nothing new on the storage side, just
//     a second door in. **Real conflict caught and resolved before
//     building**: swipe-right on the header was already spoken for (walks
//     the day target back toward Today) — but only when `dayOffset > 0`.
//     At Today (`dayOffset == 0`), the existing `max(0, dayOffset - 1)`
//     swipe-right was a dead no-op (floors at 0, nothing visibly changes),
//     so David's call: repurpose it there specifically — **swipe-right to
//     Inbox only fires when already on Today**; if you'd swiped left one
//     or more times first, swipe-right keeps its original job of walking
//     the target back a day at a time, unchanged. A second right-swipe
//     while already targeting Inbox cancels back to Today (same toggle
//     feel as the day pill's tap-to-reset); swiping left out of Inbox mode
//     clears it and moves to Tomorrow instead, same as swiping left always
//     has. Matches the app's one other real design principle (see the
//     "committing is a separate explicit action" note above): the swipe
//     only sets the target — an "→ Inbox" pill appears, same mechanism as
//     the day-target pill — the checkmark still has to be tapped to
//     actually write anything. `targetIsInbox` and `dayOffset` are
//     mutually exclusive by construction (every transition that sets one
//     clears the other) — never both true.
//   - **Quick Pin, added 2026-07-25** (backlog item 4, "add current
//     location pin to my day note"). A new toolbar button (see
//     JotFormattingToolbar.swift/JotTextView.swift — the actual location
//     fetch + Notion save lives in that file's `dropPin()`, not here) that
//     does a lighter version of Trace's own FAB "Quick Pin" flow
//     (QuickPinLabelSheet.swift): same underlying save
//     (`NotionService.saveCapture`, same silent nearest-place-within-500m
//     auto-link), but with the 6-button label grid and 4-second countdown
//     removed — David's own reason for never using the Trace version.
//     **Confirmed with David: saves the instant the button is tapped**,
//     same as Trace's version already does — NOT deferred until this
//     view's own checkmark commit, since dropping a pin is its own
//     complete, deliberate action, independent of whether the surrounding
//     note ever gets committed. This is Jot's first dependency on anything
//     beyond `NoteStore`/iCloud — `NotionService` (shared `group.com.david.
//     trace` App Group, newly added to Jot's entitlements for this) and
//     `LocationManager` (CoreLocation, new Info.plist usage-description
//     key). See `warmUpPinDependencies()` below and this feature's Xcode-
//     setup notes in Dayflow-HANDOFF.md for exactly what that needed.
struct CaptureView: View {
    @State private var text: String = ""
    @State private var errorMessage: String?
    @State private var justSaved = false
    @State private var savedConfirmationText = "Added"
    @State private var dayOffset = 0
    /// See this type's header comment ("Swipe-right-to-Inbox") — mutually
    /// exclusive with `dayOffset > 0` by construction. Reset alongside
    /// `dayOffset` everywhere the target goes back to Today: after a
    /// successful commit, on the pill's tap-to-reset, and on a day
    /// boundary crossing in `resetIfNewDay()`.
    @State private var targetIsInbox = false
    @Environment(\.scenePhase) private var scenePhase
    /// Session 45 addendum 6 — set by JotTextView's onCaptureTap when a
    /// `[label](capture:ID)` marker is tapped; drives the CaptureSummaryView
    /// sheet below. A plain optional rather than .sheet(item:) since String
    /// isn't Identifiable — see the sheet modifier's Binding for how it's
    /// cleared on dismiss.
    @State private var tappedCaptureID: String? = nil
    /// **Tap-to-jump calendar, added 2026-07-25** (David: swipe-to-day is
    /// good for one day at a time, but wanted a faster way to reach a date
    /// further out). Tapping the header date label (not the target pill —
    /// that still just resets to Today) opens a small popover calendar
    /// anchored top-left under the header, mockup-approved
    /// (`jot-calendar-jump-mockup-v2.html`, styled after David's own
    /// macOS Calendar reference screenshot: month grid, prev/next chevrons,
    /// no week-number column, Dayflow's blue/gray palette instead of the
    /// screenshot's orange). Same today-or-later floor as the swipe gesture
    /// — David's explicit call: past dates go through the Dayflow app
    /// itself, not Jot. Tapping a date sets the target and dismisses
    /// immediately, same "no separate confirm" feel as the pill's own
    /// tap-to-reset; tapping anywhere outside the popover dismisses without
    /// changing anything. Uses the system `DatePicker(.graphical)` rather
    /// than a hand-built grid — gets correct month/leap-year/locale
    /// handling for free, restyled via `.tint` to Dayflow's blue and
    /// wrapped in a rounded card to match the popover look, rather than
    /// matching the mockup's exact custom cell layout pixel-for-pixel.
    @State private var showingDatePicker = false
    @State private var pickerDate = Date()

    /// Editor body size, David's ask 2026-08-24. Seeded from UserDefaults at
    /// launch and written by the settings sheet the toolbar's slider button
    /// presents; `JotTextView` takes it as a binding so the two never
    /// disagree. See `loadJotFontSize()` in JotFormattingToolbar.swift for
    /// why this is a fixed settable number rather than Dynamic Type.
    @State private var fontSize: CGFloat = loadJotFontSize()

    private static let draftTextKey = "jot_draft_text"
    private static let draftDateKey = "jot_draft_date"

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static var todayKey: String { dayKeyFormatter.string(from: Date()) }

    private var headerDateLabel: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: Date())
    }

    /// The day a commit right now would write to — `Date()` shifted forward
    /// by `dayOffset` days. `dayOffset` is always >= 0 (swipe right floors
    /// at Today), so this is always today or later, never in the past.
    private var targetDate: Date {
        Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date()
    }

    /// nil when targeting plain Today (the pill is hidden in that case) —
    /// "Inbox" when `targetIsInbox`, else "Tomorrow" for one day-swipe,
    /// otherwise an abbreviated weekday + date. Renamed from
    /// `targetDayLabel` when Inbox targeting was added, since it's no
    /// longer describing only a day.
    private var targetPillLabel: String? {
        if targetIsInbox { return "Inbox" }
        guard dayOffset != 0 else { return nil }
        if dayOffset == 1 { return "Tomorrow" }
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f.string(from: targetDate)
    }

    var body: some View {
        // Outer ZStack added for the tap-to-jump calendar popover (see
        // showingDatePicker's declaration) — everything that existed before
        // is still the first child, unchanged, just now wrapped instead of
        // being the top-level view.
        ZStack(alignment: .topLeading) {
            captureContent

            if showingDatePicker {
                // Full-screen invisible tap-outside-to-dismiss catcher,
                // drawn above captureContent but below the popover itself
                // (later ZStack children stack on top). Blocks interaction
                // with the rest of the screen while the popover is open,
                // same as a modal would, without a visible scrim — matches
                // the mockup, which had no dark overlay behind the popover.
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showingDatePicker = false
                        }
                    }

                calendarPopover
                    .padding(.top, 46)
                    .padding(.leading, 18)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
            }
        }
    }

    @ViewBuilder
    private var captureContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(headerDateLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        pickerDate = targetDate
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showingDatePicker.toggle()
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }

                // Target pill — only visible once a swipe has moved the
                // target off plain Today, either a future day or Inbox.
                // Tapping it resets to Today immediately; see the header
                // comment above for why swipe-right (not just the tap) also
                // walks a day target back one day at a time, or cancels an
                // Inbox target. Inbox gets its own color (purple, matching
                // the tint the Dayflow Inbox filing sheet's own "Log as
                // Interaction/Visit" swipe actions use) so it's visually
                // distinct from a day target at a glance, not just by text.
                if let targetPillLabel {
                    Text("→ \(targetPillLabel)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(targetIsInbox ? Color.purple : Color.blue, in: Capsule())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                dayOffset = 0
                                targetIsInbox = false
                            }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { value in
                        let horizontal = value.translation.width
                        let vertical = value.translation.height
                        // Require a mostly-horizontal, deliberate swipe so an
                        // accidental diagonal touch on the header doesn't
                        // silently change the target day.
                        guard abs(horizontal) > abs(vertical) * 1.5, abs(horizontal) > 40 else { return }
                        withAnimation(.easeInOut(duration: 0.15)) {
                            if horizontal < 0 {
                                // Swipe left always means "further out,"
                                // whether that's advancing a day target or
                                // leaving Inbox mode behind for Tomorrow.
                                targetIsInbox = false
                                dayOffset += 1
                            } else if dayOffset > 0 {
                                // Already targeting a future day — swipe
                                // right keeps its original job, unchanged.
                                dayOffset -= 1
                            } else if targetIsInbox {
                                // Second right-swipe at Today while already
                                // in Inbox mode cancels it — same
                                // toggle-back-off feel as the pill's own
                                // tap-to-reset.
                                targetIsInbox = false
                            } else {
                                // At Today, nothing targeted — this swipe
                                // used to be a dead no-op (floors at 0), so
                                // it's free to mean "target the Inbox
                                // instead" here specifically. See the
                                // Swipe-right-to-Inbox header comment.
                                targetIsInbox = true
                            }
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
            )

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 4)
            }

            ZStack(alignment: .bottomTrailing) {
                // Formatting toolbar added 2026-07-24 (app expansion item 1):
                // JotTextView wraps UITextView so the toolbar can attach as
                // the keyboard's inputAccessoryView and reach the cursor —
                // see JotTextView.swift's header comment for why this
                // replaced the plain SwiftUI TextEditor. It handles its own
                // autofocus (becomeFirstResponder in makeUIView), so the
                // old @FocusState/.focused() wiring is gone.
                JotTextView(
                    text: $text,
                    fontSize: $fontSize,
                    onPinSucceeded: {
                        errorMessage = nil
                        savedConfirmationText = "Pin dropped"
                        withAnimation { justSaved = true }
                        Task {
                            try? await Task.sleep(nanoseconds: 900_000_000)
                            withAnimation { justSaved = false }
                        }
                    },
                    onPinFailed: { message in
                        errorMessage = message
                    },
                    onCaptureTap: { captureID in
                        tappedCaptureID = captureID
                    }
                )
                    .padding(.horizontal, 12)
                    .onChange(of: text) { _, newValue in
                        persistDraft(newValue)
                    }

                Button {
                    commit()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(canCommit ? Color.blue : Color.gray.opacity(0.4), in: Circle())
                        .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 3)
                }
                .buttonStyle(.plain)
                .disabled(!canCommit)
                .padding(16)
                .opacity(justSaved ? 0 : 1)
                .animation(.easeInOut(duration: 0.15), value: justSaved)

                // Brief confirmation in the same corner the button occupies —
                // a small, self-contained polish touch, not a separate design
                // round: fades in as the button fades out, then both clear
                // after ~0.9s.
                if justSaved {
                    Text(savedConfirmationText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.green, in: Capsule())
                        .padding(16)
                        .transition(.opacity)
                }
            }
        }
        .onAppear {
            resetIfNewDay()
            warmUpPinDependencies()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                resetIfNewDay()
            }
        }
        // Capture summary sheet — Session 45 addendum 6. Binding-backed
        // rather than .sheet(item:) since tappedCaptureID is a plain String?;
        // setting the binding to false on dismiss clears it the same as a
        // .sheet(item:) would.
        .sheet(isPresented: Binding(
            get: { tappedCaptureID != nil },
            set: { if !$0 { tappedCaptureID = nil } }
        )) {
            if let captureID = tappedCaptureID {
                CaptureSummaryView(captureID: captureID)
                    .environment(NotionService.shared)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    /// System `DatePicker(.graphical)` restyled to sit inside a small
    /// popover card rather than a hand-built calendar grid — see
    /// `showingDatePicker`'s declaration for why. `in: startOfToday...`
    /// disables every date before today at the picker level (matches the
    /// swipe gesture's own floor), so there's no separate validation needed
    /// once a date comes back through `onChange`.
    @ViewBuilder
    private var calendarPopover: some View {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        DatePicker(
            "Jump to date",
            selection: $pickerDate,
            in: startOfToday...,
            displayedComponents: .date
        )
        .datePickerStyle(.graphical)
        .labelsHidden()
        .tint(Color(red: 0.231, green: 0.435, blue: 0.878)) // Dayflow's blue
        .frame(width: 260)
        .padding(8)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 8)
        .onChange(of: pickerDate) { _, newValue in
            let cal = Calendar.current
            let startPicked = cal.startOfDay(for: newValue)
            let days = cal.dateComponents([.day], from: startOfToday, to: startPicked).day ?? 0
            withAnimation(.easeInOut(duration: 0.15)) {
                dayOffset = max(0, days)
                targetIsInbox = false
                showingDatePicker = false
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    /// Added alongside Quick Pin (2026-07-25) — starts location updates and
    /// fetches Trace's places list as early as possible, so a tap on the
    /// pin toolbar button usually finds `LocationManager.shared.location`
    /// and `NotionService.shared.places` already populated instead of
    /// waiting on them cold (`JotTextView.swift`'s `dropPin()` still polls
    /// briefly if a fix genuinely isn't ready yet — this just makes that
    /// the uncommon case). Safe to call on every appear:
    /// `requestPermission()`/`startUpdating()` are themselves safe no-ops
    /// once already authorized/running (`LocationManager.swift`, unchanged
    /// here), and a repeat `fetchPlaces()` just refreshes the same array.
    private func warmUpPinDependencies() {
        LocationManager.shared.requestPermission()
        LocationManager.shared.startUpdating()
        Task { await NotionService.shared.fetchPlaces() }
    }

    private var canCommit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Discards a persisted draft left over from a previous calendar day —
    /// David's explicit ask. Restores today's persisted draft (if any) when
    /// the day matches, so backgrounding mid-thought and coming back later
    /// the same day picks up where you left off.
    private func resetIfNewDay() {
        let savedDay = UserDefaults.standard.string(forKey: Self.draftDateKey)
        if savedDay != Self.todayKey {
            text = ""
            dayOffset = 0
            targetIsInbox = false
            UserDefaults.standard.set("", forKey: Self.draftTextKey)
            UserDefaults.standard.set(Self.todayKey, forKey: Self.draftDateKey)
        } else if text.isEmpty {
            let saved = UserDefaults.standard.string(forKey: Self.draftTextKey) ?? ""
            if !saved.isEmpty {
                text = saved
            }
        }
    }

    private func persistDraft(_ value: String) {
        UserDefaults.standard.set(value, forKey: Self.draftTextKey)
        UserDefaults.standard.set(Self.todayKey, forKey: Self.draftDateKey)
    }

    /// Writes through `NoteStore.shared.appendToDailyNote(_:date:)` (day
    /// targets) or straight to a new `Notes/Inbox/<timestamp>.md` file
    /// (Inbox target, `targetIsInbox`) — same filename convention
    /// `QuickAppendSheet.swift`'s own `.inbox` destination and
    /// `DayflowNotesInboxView.swift`'s `createNote()` already use
    /// (`inboxTimestamp()` below is a direct copy of the former). On
    /// success, clears the field/persisted draft, resets the target back to
    /// Today, and shows a brief confirmation. On failure (iCloud
    /// unavailable — the one real failure mode either write call can
    /// throw), leaves the typed text AND the target in place and shows an
    /// inline error rather than silently losing what was typed or quietly
    /// resetting which target it was headed to — this app has exactly one
    /// job, so a silent failure here would be the worst possible outcome.
    ///
    /// **iCloud-not-ready race, fixed 2026-07-24**: `NoteStore.init()`
    /// resolves its iCloud container URL on a background thread, so
    /// `NoteStore.shared.hasAccess` can still be false for a moment right
    /// after a fresh launch. Jot auto-focuses the text field instantly, so
    /// it was possible to type a quick note and hit send before that
    /// resolves — David hit exactly this once. Rather than failing on the
    /// very first attempt, wait briefly (up to ~3s, checked every 150ms)
    /// for `hasAccess` to flip true before trying the write. If it's
    /// genuinely still not ready after that, this IS a real iCloud problem
    /// (not signed in, iCloud Drive off, provisioning mismatch) and the
    /// existing error message is the correct thing to show.
    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let commitDate = targetDate
        let sendToInbox = targetIsInbox
        // A commit only "lands on today's daily note" when it's neither a
        // future-day target nor an Inbox target — this drives both the
        // confirmation text and the widget-reload check below.
        let isToday = dayOffset == 0 && !sendToInbox
        let confirmationText = sendToInbox
            ? "Added to Inbox"
            : (isToday ? "Added" : "Added to \(targetPillLabel ?? "later")")
        Task { @MainActor in
            if !NoteStore.shared.hasAccess {
                for _ in 0..<20 {
                    if NoteStore.shared.hasAccess { break }
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            }
            do {
                if sendToInbox {
                    let ts = Self.inboxTimestamp()
                    try NoteStore.shared.writeFile("Notes/Inbox/\(ts).md", content: trimmed)
                } else {
                    try NoteStore.shared.appendToDailyNote(trimmed, date: commitDate)
                }
                text = ""
                errorMessage = nil
                persistDraft("")
                savedConfirmationText = confirmationText
                withAnimation { justSaved = true }
                // Reset the target back to Today right after a successful
                // send — David's call (see the swipe-to-day design note
                // above, which applies identically to an Inbox target), so
                // a run of several notes doesn't silently keep landing
                // somewhere other than today's daily note.
                dayOffset = 0
                targetIsInbox = false
                // Widget added 2026-07-24: nudge WidgetKit to redraw the Jot
                // widget right away instead of waiting on its own ~30-minute
                // timeline refresh, so a note typed here shows up on the
                // Home Screen immediately. Only relevant when the note
                // actually landed on today's daily-note file — a note
                // swiped forward to a future day, or sent to the Inbox,
                // doesn't change what the widget (today's note start)
                // should be showing. Cheap no-op either way if the widget
                // isn't on the Home Screen at all.
                if isToday {
                    WidgetCenter.shared.reloadTimelines(ofKind: "JotWidget")
                }
                try? await Task.sleep(nanoseconds: 900_000_000)
                withAnimation { justSaved = false }
            } catch {
                errorMessage = "Couldn't save — check iCloud, then try again."
            }
        }
    }

    /// Same filename convention `QuickAppendSheet.swift`'s `.inbox`
    /// destination and `DayflowNotesInboxView.swift`'s `createNote()` both
    /// already use — kept as a direct copy rather than a shared helper
    /// since Jot is its own app target with no existing dependency on
    /// either of those files.
    private static func inboxTimestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }
}
