// TraceMacTaskComposer.swift
// What the + button does. Mac-only.
//
// Session 80 (2026-08-31). David: "Using the quick keyboard action should not
// assume i want it in personal. Hitting the plus symbol however should
// automatically put it to personal if i dont do anything else since the plus
// symbol on Mac should give the option to change the list."
//
// ── Two captures, two defaults, and the difference is deliberate ─────────
//
// ⇧⏎ in the quick panel is "get it out of my head". It lands in the **Inbox**
// and keeps no opinion about where it belongs, because the whole value of that
// gesture is that it does not make you decide anything. It is invoked from
// wherever you were, over whatever you were doing.
//
// The + is the opposite gesture. You are already in the app, you reached for a
// button, and you have a screen in front of you. That is a considered add, so
// it commits: **Personal by default**, with the list one click away.
//
// The rule that falls out: *a capture that cannot show you where it went must
// not choose*; a capture that can show you, must.
//
// ── Why this is a popover and not the inline row ─────────────────────────
//
// Today already has "Add a to-do" under its task list, and that stays. It is
// the contextual add: this day, one line, no decisions. The + is the same act
// with the decisions visible — list, date, note, all on screen before you
// commit. One screen can carry both because the difference is legible: the
// inline row has no options and the + is nothing but options.
//
// ── No backspace-decline here, on purpose ───────────────────────────────
//
// The quick panel earns its backspace trick because it has one row and no space
// for an affordance. This has space. The parsed date gets a visible clear
// button instead, because a visible control beats a learned gesture wherever
// there is room for one, and having BOTH would be two ways to do one thing —
// which is how a UI starts feeling haunted.

import SwiftUI
import AppKit

struct MacTaskComposer: View {

    /// The day the screen is about: Today passes the day in view, Upcoming
    /// passes `nil`. A typed date always wins over it.
    let defaultDate: Date?
    let onAdded: () -> Void
    /// Which list to open on. `nil` keeps the + button's own default, Personal,
    /// which is the considered-add rule this file is named for.
    ///
    /// A document passes the Inbox (D230): a task made from a document has made
    /// no when-decision yet, and the document is its context the way an agenda
    /// anchor is. Declared after `onAdded` and defaulted, so the memberwise
    /// order every existing call site uses is untouched.
    var defaultList: String? = nil
    /// Machinery lines appended to whatever note the line itself produces —
    /// a `satchel:doc:` marker, today. Not shown in the composer: it is not
    /// something he typed and not something he can usefully edit here.
    var extraNoteLines: [String] = []
    /// Hand the typed text to a different KIND of new thing (D249), or `nil` for
    /// a composer with no rail.
    ///
    /// **Required, and `nil` is a stated answer rather than a default.** A
    /// defaulted closure nobody passes is one of the six shapes Session 80 cost
    /// us; making this explicit means the document panel had to say out loud
    /// that it does not want the rail, which is true and worth reading.
    let onSwitch: ((MacNewKind, String) -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var list = ReminderTaskStore.personalListName
    @State private var seededList = false
    @State private var dateCleared = false
    @State private var saving = false
    @State private var pickingDay = false
    @State private var pickingList = false
    @State private var keyMonitor: Any? = nil
    @State private var pickedDay = Calendar.current.startOfDay(for: Date())
    /// A date chosen in the grid. Overrides both the typed date and the
    /// screen's day, and survives a further edit to the text — once you have
    /// pointed at a day on a calendar you have been more explicit than any
    /// parser, and a later keystroke must not quietly take that back.
    @State private var chosenDay: Date? = nil

    /// **One field, not three Bools.** Tab moves between these in declaration
    /// order and `@FocusState` with an enum is the only way to say "the list
    /// row is focused" as a fact rather than as three flags that can all be
    /// true at once.
    private enum Field: Hashable { case text, list, when, cancel, add }
    @FocusState private var field: Field?

    private var store: ReminderTaskStore { ReminderTaskStore.shared }

    private var parsed: ParsedTaskLine { TaskLineParser.parse(text) }

    /// Precedence, most explicit first: a day you POINTED AT beats a day you
    /// typed, which beats the day the screen is about. Clearing beats all
    /// three.
    private var effectiveDate: Date? {
        // The chosen list wins over every other source, including a date typed
        // into the line. Not silently: `whenRow` says so on screen, because a
        // parser that visibly read "friday" and then a task that has no date is
        // the app appearing to lose what you told it.
        if listRefusesDates { return nil }
        if dateCleared { return nil }
        return chosenDay ?? parsed.date ?? defaultDate
    }

    /// Inbox and Someday hold no dates (D210). The rule lives on the store so
    /// this screen cannot drift from the four write paths that enforce it.
    private var listRefusesDates: Bool {
        ReminderTaskStore.listRefusesDates(list)
    }

    /// A time only ever comes from the words. Picking a day on a grid says
    /// nothing about an hour, so it must not carry one over from a phrase the
    /// pick has just overruled.
    private var effectiveRemind: Date? {
        if listRefusesDates || dateCleared || chosenDay != nil { return nil }
        return parsed.remindAt
    }

    private var canAdd: Bool {
        !parsed.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !saving
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New task").editorialKicker()
            MacEditorialRule.heavy.padding(.top, 5)

            TextField("What needs doing", text: $text)
                .textFieldStyle(.plain)
                .font(MacEditorialType.subject)
                .foregroundStyle(MacEditorialColor.ink)
                .focused($field, equals: .text)
                .padding(.top, 13)
                .padding(.bottom, 4)
                .onSubmit { add() }

            // The same hint the quick panel shows, for the same reason and in
            // the same words. This field understands the identical syntax, and
            // a shorthand that is advertised in one capture field and not the
            // other is worse than one advertised nowhere: it teaches you a rule
            // and then appears to break it.
            //
            // Hidden once either has parsed, because the WHEN and NOTE rows
            // below are then showing the result, which is strictly better
            // information than the instruction.
            if !parsed.hasDate && !parsed.hasNote {
                Text("try \u{201c}friday\u{201d} or // note")
                    .font(MacEditorialType.meta)
                    .foregroundStyle(MacEditorialColor.faint)
                    .padding(.bottom, 9)
            }

            if onSwitch != nil { kindRail }

            MacEditorialRule.hair
            listRow
            MacEditorialRule.hair
            whenRow
            if parsed.hasNote {
                MacEditorialRule.hair
                noteRow
            }
            MacEditorialRule.hair
            footer
        }
        .padding(18)
        .frame(width: 380)
        .background(MacEditorialColor.paper)
        // **A sheet, not a popover** (Session 80, second pass). David: "when I
        // click anytime with my mouse the word Anytime you can see is over
        // lapping the New Task and the Add task overlaps the calendar."
        //
        // `NSPopover` measures its content once, at presentation, and does not
        // grow when that content later does. Unfolding the month grid added
        // ~180pt inside a window that had already decided how big it was, so
        // the new rows drew ON TOP of the old ones. Nothing was wrong with the
        // layout; the container was wrong for a view that changes height.
        //
        // A sheet re-lays out, which is the whole requirement. It costs the
        // arrow anchoring to the + button, and that is a fair price for a
        // composer that can open a calendar without eating itself.
        .onAppear {
            // Seeded once. `onAppear` can run again on a rebuild, and
            // re-seeding would throw away a list he had already picked.
            if !seededList, let defaultList { list = defaultList; seededList = true }
            DispatchQueue.main.async { field = .text }
            installKeys()
        }
        .onDisappear { removeKeys() }
        // Escape unwinds one layer at a time. Closing the whole composer
        // because you changed your mind about a date would throw away the line
        // you had already typed.
        .onExitCommand {
            if pickingDay { pickingDay = false; field = .when } else { dismiss() }
        }
    }

    // MARK: - The kind rail (D249)
    //
    // David: "can you rewrite the plus sign on these screens to offer up a new
    // project note, a new person, a new endeavor or a new task? lets think
    // about the best way to do that with joy in the app."
    //
    // ── Why this is not a menu on the + ──────────────────────────────────
    //
    // The four are not equals. A task is captured dozens of times a week and a
    // person is added maybe once; a flat four-item menu makes the constant act
    // pay the same price as the rare one, and the whole reason the + exists is
    // that capture should cost nothing. His call, put to him plainly: task
    // first.
    //
    // ── You name the thing before you say what kind it is ────────────────
    //
    // The rail is not a mode switch you set before typing. The composer opens as
    // a task, focused, exactly as it always did — press +, type, Return, and
    // nothing about that path has changed. The other three sit underneath as
    // quiet words, and picking one carries WHAT YOU HAVE ALREADY TYPED into that
    // creator as its name.
    //
    // That is the whole joy of it, and it matches how the thought actually
    // arrives: you do not think "I want to create a person", you think "Megan
    // Weiss" and then notice she is not in there yet. Type the name, change your
    // mind about the kind, keep the name.
    //
    // Two pieces of this app's own grammar said this was the shape: the task
    // card's offer line ("+ REMIND · + REPEAT · + LINK"), quiet caps under the
    // main thing; and D235's rule that you decline a guess AFTER seeing it
    // rather than deciding before.
    //
    // ── The composer does not create three more kinds of thing ───────────
    //
    // It emits a request and dismisses. `TraceMacContentView` performs it,
    // because that view is already the one funnel every route goes through
    // (D112) and it is where the stores live. A composer that knew how to write
    // a Notion person would be a second creator to keep in step with the first.

    /// The rail's three doors need a NAME to carry, so they are inert until
    /// there is one.
    ///
    /// The first version let you click PROJECT NOTE with an empty field, where
    /// it hit a `guard !stem.isEmpty` and returned without a word — a control
    /// that accepts a click and swallows it, which is the D225 bug this project
    /// has now paid for three times. Faint-and-inert says the same thing
    /// honestly, and it reinforces the design rather than fighting it: you name
    /// the thing first, and until you have, there is nothing to hand over.
    private var kindRail: some View {
        let named: Bool = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 16) {
            ForEach(MacNewKind.allCases) { kind in
                MacKindWord(kind: kind,
                            current: kind == .task,
                            armed: named,
                            action: { switchTo(kind) })
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 10)
    }

    /// Hand the line over and get out of the way. The text is passed RAW, not
    /// `parsed.title`: "friday" is a date to a task and part of a name to
    /// everything else, and silently deleting a word because the task parser
    /// recognised it would be the composer editing a name it does not own.
    private func switchTo(_ kind: MacNewKind) {
        guard kind != .task, let onSwitch else { return }
        let seed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        dismiss()
        onSwitch(kind, seed)
    }

    // MARK: - Rows

    /// The whole reason the + exists as its own thing. Personal is selected,
    /// not assumed: the value is on screen before you commit, so choosing
    /// nothing is a decision you can see rather than one made for you.
    /// **Not a `Menu`.** The first version made the Menu itself the focusable
    /// thing, and David reported the obvious symptom: "when i highlight the
    /// list id like the down arrow to move through the options and that doesnt
    /// work."
    ///
    /// A focused `Menu` treats the down arrow as "open me" and swallows it
    /// before `onKeyPress` is consulted, so the cycling handler never ran. Same
    /// trap on the When row, where a focused `Button` competed with
    /// `.focusable()` for the focus itself.
    ///
    /// The fix is the same in both places and it is a rule worth keeping:
    /// **when a row needs custom key handling, the focusable view must be inert
    /// — a plain container, not a control that already has opinions about
    /// keys.** The control moves to the tap gesture instead.
    private var listRow: some View {
        row("List") {
            HStack(spacing: 5) {
                Text(list)
                    .font(MacEditorialType.fieldValue)
                    .foregroundStyle(MacEditorialColor.ink)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(MacEditorialColor.faint)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(focusWash(.list), in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .focusable()
            .focused($field, equals: .list)
            .onTapGesture { field = .list; pickingList = true }
            // Keys are handled by `installKeys()`, not here. See that function
            // for why `onKeyPress` was abandoned on both rows.
            .popover(isPresented: $pickingList, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.listNames, id: \.self) { name in
                        Button {
                            list = name
                            pickingList = false
                            field = .list
                        } label: {
                            HStack(spacing: 8) {
                                Text(name)
                                    .font(MacEditorialType.fieldValue)
                                    .foregroundStyle(MacEditorialColor.ink)
                                Spacer(minLength: 12)
                                if name == list {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(MacEditorialColor.accent)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
                .frame(minWidth: 180)
            }
        }
    }

    @ViewBuilder
    private var whenRow: some View {
        if listRefusesDates {
            // Stated, not disabled-and-silent. The sentence names the rule and
            // names the way out, which is the difference between a control that
            // refuses you and one that explains itself.
            row("When") {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Anytime")
                        .font(MacEditorialType.fieldValue)
                        .foregroundStyle(MacEditorialColor.faint)
                    Text("\(list) holds no dates. Choose another list to schedule it.")
                        .font(MacEditorialType.meta)
                        .foregroundStyle(MacEditorialColor.faint)
                }
            }
        } else {
            datedWhenRow
        }
    }

    private var datedWhenRow: some View {
        let day: Date? = effectiveDate
        let typed: Bool = (parsed.hasDate || chosenDay != nil) && !dateCleared
        return row("When") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    // The value IS the control ("when I click on the when date
                    // a calendar allows me to change it"), and it is an inert
                    // focusable container rather than a Button — see the note
                    // on `listRow`. A Button here competed with `.focusable()`
                    // and the arrows never arrived.
                    Text(day.map(Self.dayText) ?? "Anytime")
                        .font(MacEditorialType.fieldValue)
                        // Accent when the date was CHOSEN, typed or picked; ink
                        // when it was inherited from the screen. The chosen one
                        // is the surprising one, so it is the one marked.
                        .foregroundStyle(typed ? MacEditorialColor.accent : MacEditorialColor.ink)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(focusWash(.when), in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                        .focusable()
                        .focused($field, equals: .when)
                        .onTapGesture { field = .when; openPicker() }
                        // Keys via `installKeys()`. See there.
                    if day != nil {
                        Button {
                            dateCleared = true
                            chosenDay = nil
                            pickingDay = false
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(MacEditorialColor.faint)
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("No date")
                    }
                    if dateCleared, parsed.hasDate {
                        Button("Undo") { dateCleared = false }
                            .buttonStyle(.plain)
                            .font(MacEditorialType.meta)
                            .foregroundStyle(MacEditorialColor.accent)
                    }
                }
                // Unfolds in place rather than opening a second popover. A
                // popover inside a popover is a dismissal puzzle on macOS, and
                // the app already reads "the calendar unfolds where you asked
                // for it" everywhere else (the masthead, the Pick day pill).
                if pickingDay {
                    MacEditorialMonthGrid(selected: $pickedDay)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                        .onChange(of: pickedDay) { _, picked in
                            chosenDay = Calendar.current.startOfDay(for: picked)
                            dateCleared = false
                            pickingDay = false
                            field = .when
                        }
                }
            }
        }
    }

    /// Shown, not editable. Everything in this popover comes from the one field
    /// above it; a second editable box for the note would make the `//` a
    /// pointless detour on the way to a control that was there anyway.
    private var noteRow: some View {
        row("Note") {
            Text(parsed.note ?? "")
                .font(MacEditorialType.fieldValue)
                .foregroundStyle(MacEditorialColor.noteText)
                .lineLimit(3)
        }
    }

    private func row<Content: View>(_ label: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label)
                .editorialFieldLabel()
                .frame(width: 64, alignment: .leading)
                .padding(.top, 8)
            content()
                .padding(.vertical, 6)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 32)
    }

    /// **The footer is in the tab chain** (David, Session 80: "can you allow
    /// the tabing to go to cancel and add task buttons too?").
    ///
    /// Which finishes the thought the rest of this popover started: a composer
    /// you can fill in from the keyboard but have to reach for the mouse to
    /// COMMIT is a composer that still costs you the mouse. The last two stops
    /// were the ones that mattered most.
    ///
    /// `.focusable()` on both, even though a `Button` is nominally focusable
    /// already: under the default macOS keyboard setting Tab visits text fields
    /// and little else, and being explicit is what makes the chain the same on
    /// every machine rather than depending on a System Settings checkbox.
    ///
    /// Return and Space are handled in `installKeys()` like every other row
    /// here, NOT left to the Buttons' own activation. The monitor swallows both
    /// keys once focus is off the text field, so a Button would never see them
    /// anyway — and having one row's keys arrive by a different route than the
    /// rest is how a keyboard path develops a hole nobody can explain.
    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .font(MacEditorialType.meta)
                .foregroundStyle(MacEditorialColor.muted)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(focusWash(.cancel), in: RoundedRectangle(cornerRadius: 6))
                .focusable()
                .focused($field, equals: .cancel)
            MacEditorialPill(label: saving ? "Adding\u{2026}" : "Add task") { add() }
                .opacity(canAdd ? 1 : 0.4)
                .allowsHitTesting(canAdd)
                .padding(3)
                .background(focusWash(.add), in: RoundedRectangle(cornerRadius: 9))
                .focusable()
                .focused($field, equals: .add)
        }
        .padding(.top, 13)
    }

    // MARK: - Keyboard

    /// **Why a local `NSEvent` monitor and not `onKeyPress`.**
    ///
    /// Third attempt, and the stop rule in this project is three. The first two
    /// were both SwiftUI focus APIs and both failed the same way: Tab moved the
    /// focus, the wash appeared, and the arrow keys did nothing. David, twice:
    /// "the down arrow to move through the options and that doesnt work", then
    /// "everything works now except for being able to cycle the list or select
    /// when only using the keyboard."
    ///
    /// The reason is that macOS routes arrow keys into **spatial focus
    /// navigation** before a focused view's `onKeyPress` is consulted — the
    /// arrows were being spent trying to move focus to a neighbour, found
    /// nothing in that direction, and were swallowed. And an inert focusable
    /// has no activation callback at all, so Return and Space had nowhere to
    /// land either. Attempt one hit the sibling version of this: a `Menu` reads
    /// the down arrow as "open me".
    ///
    /// A local key monitor sits in front of all of that. It is the same
    /// instrument as `MacSatchelFilterShortcut` and the quick panel's shift
    /// detection — the mechanism this codebase already trusts for keys SwiftUI
    /// will not hand over. Returning `nil` swallows the event so focus
    /// navigation does not ALSO happen.
    ///
    /// **Scoped three ways**, because an app-wide monitor is a loaded gun:
    /// it is installed and removed with this view, it does nothing unless
    /// `field` is `.list` or `.when`, and it steps aside entirely while either
    /// picker is open so the popover and the grid keep their own keys.
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let field, field != .text else { return event }
            guard !pickingList, !pickingDay else { return event }
            // The When row is static text when the list refuses dates, so it
            // has no focusable and `field` should never be `.when` — except it
            // can be, if the list was CHANGED while When held the focus. Left
            // unguarded, arrows would quietly set a date that `effectiveDate`
            // then discards: a control that appears to work and does nothing.
            if field == .when && listRefusesDates { return event }
            switch event.keyCode {
            case 125, 126:                  // down, up
                // Only the two value rows spend an arrow. On the buttons the
                // event is handed back so macOS can go on using arrows to move
                // the focus, which is the only sensible meaning they have
                // there.
                guard field == .list || field == .when else { return event }
                let step = event.keyCode == 125 ? 1 : -1
                if field == .list { cycleList(step) } else { nudge(step) }
                return nil
            case 36, 76, 49:                // return, keypad enter, space
                switch field {
                case .list: pickingList = true
                case .when: openPicker()
                case .cancel: dismiss()
                // `add()` guards on `canAdd`, so Return on a disabled Add is a
                // no-op rather than a half-made task.
                case .add: add()
                case .text: return event
                }
                return nil
            default:
                // Tab and Escape are deliberately NOT in this switch. Tab is
                // how you got here and Escape is how you leave; taking either
                // one would trap the focus in a row that only meant to borrow
                // the arrows.
                return event
            }
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// A one-key wash rather than a system focus ring: the ring is drawn
    /// outside the control and this popover's rows are tight enough that it
    /// collides with the hairlines. Same job, inside the bounds.
    private func focusWash(_ which: Field) -> Color {
        field == which ? MacEditorialColor.accent.opacity(0.13) : Color.clear
    }

    /// Wraps at both ends. A cycle you can fall off is a cycle you have to
    /// count, and there are few enough lists that going the long way round is
    /// never expensive.
    private func cycleList(_ step: Int) {
        let names = store.listNames
        guard !names.isEmpty else { return }
        let at = names.firstIndex(of: list) ?? 0
        let next = (at + step + names.count) % names.count
        list = names[next]
    }

    /// Arrow on the When row moves a day. With no date yet it starts from the
    /// screen's day (or today), because the first press should produce a date
    /// rather than nothing.
    private func nudge(_ days: Int) {
        let cal = Calendar.current
        let from = effectiveDate ?? defaultDate ?? cal.startOfDay(for: Date())
        chosenDay = cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: from))
        dateCleared = false
    }

    private func openPicker() {
        pickedDay = effectiveDate ?? defaultDate ?? Calendar.current.startOfDay(for: Date())
        pickingDay.toggle()
    }

    // MARK: - Values

    /// `nonisolated` because it is passed as a function reference to `map`,
    /// which is a synchronous nonisolated context — the warning Xcode showed as
    /// "Call to main actor-isolated static method 'dayText' in a synchronous
    /// nonisolated context". It touches only `Calendar` and `DateFormatter`
    /// locals, so it has no business being actor-isolated in the first place;
    /// it inherited that from the enclosing `View`.
    nonisolated private static func dayText(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInTomorrow(day) { return "Tomorrow" }
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM"
        return f.string(from: day)
    }

    // MARK: - Add

    private func add() {
        guard canAdd else { return }
        let line = parsed
        let day = effectiveDate
        let remind = effectiveRemind
        let destination = list
        // Prose first, machinery after — the placement `rebuiltNotes` keeps and
        // `noteProse` strips.
        let notes: String? = {
            let prose = line.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let all = (prose.isEmpty ? [] : [prose]) + extraNoteLines
            return all.isEmpty ? nil : all.joined(separator: "\n")
        }()
        saving = true
        Task {
            _ = await store.addTask(title: line.title,
                                    date: day,
                                    list: destination,
                                    notes: notes,
                                    remindAt: remind)
            await store.refreshAll()
            saving = false
            onAdded()
            dismiss()
        }
    }
}

// MARK: - What the + can make (D249)

/// The four things the app's + offers, in the order the rail draws them.
///
/// Task is first and always current: the composer IS the task case, and the
/// other three are doors out of it. Declared here rather than in
/// `TraceMacContentView` because this is the file that shows them.
/// A rail choice, in flight. `Identifiable` so it can drive `.sheet(item:)` —
/// a fresh `id` per request means picking Person twice in a row presents twice,
/// where a `Bool` would have been already-true the second time.
struct MacNewRequest: Identifiable {
    let id = UUID()
    let kind: MacNewKind
    let seed: String
}

enum MacNewKind: String, CaseIterable, Identifiable {
    case task
    case person
    case endeavor
    case projectNote

    var id: String { rawValue }

    var label: String {
        switch self {
        case .task:        "Task"
        case .person:      "Person"
        case .endeavor:    "Endeavor"
        case .projectNote: "Project note"
        }
    }

    /// `nil` for Task, which needs no shortcut: it is where you already are.
    var shortcut: Character? {
        switch self {
        case .task:        nil
        case .person:      "2"
        case .endeavor:    "3"
        case .projectNote: "4"
        }
    }
}

/// One word on the rail.
///
/// Its own type only because it needs hover state, and hover is doing real work
/// here: everything in this design is quiet, so a word that warms under the
/// pointer is what says it is a control at all (Session 80, the month grid).
private struct MacKindWord: View {

    let kind: MacNewKind
    /// The kind the composer already is. Drawn in ink and inert — clicking
    /// "Task" while composing a task should do nothing, and a control that
    /// accepts the click and swallows it is the D225 bug.
    let current: Bool
    /// False until the line has something in it. The doors carry a NAME, so
    /// with nothing typed there is nothing to carry.
    let armed: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        let live: Bool = !current && armed
        let tint: Color = current ? MacEditorialColor.ink
            : (!armed ? MacEditorialColor.hairline
               : (hovering ? MacEditorialColor.accent : MacEditorialColor.faint))
        let word = Text(kind.label)
            .font(MacEditorialType.quietLabel)
            .textCase(.uppercase)
            .tracking(MacEditorialType.quietTracking)
            .foregroundStyle(tint)
        return Group {
            if !live {
                word
            } else if let key = kind.shortcut {
                Button(action: action) { word.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
                    .onHover { hovering = $0 }
            } else {
                Button(action: action) { word.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .onHover { hovering = $0 }
            }
        }
    }
}
