// TraceMacSearchPanel.swift
// ⌘K. One field over everything — notes, Satchel, People, Places, Endeavors.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.
//
// The entry point the app has never had. TraceMac has 25 search fields and all
// but one of them match names, in the one list that was already showing the
// thing. This searches bodies, and it searches from anywhere.
//
// ── The two loads this panel must not lie about ───────────────────────────
//
// Notes are on disk; People and Places come from Notion into memory at launch.
// A search run before either has landed finds nothing and **says nothing is
// there**, which is indistinguishable from the record not existing. The spec
// names the Notion half (§6, *"do not ship this half"*); the container half is
// the same bug and is not in the spec, because `NoteStore.hasAccess` is false
// for the first moment of every launch too. Both are handled here, and a
// *failed* load says failed rather than sitting on a spinner that never stops.
//
// This is the fourth appearance of this shape in the project — `resolveGeofencePlace`,
// `resolvePendingCheckIn`, D83, and now search.

import SwiftUI

struct TraceMacSearchPanel: View {

    @Binding var isPresented: Bool
    /// Called with the chosen destination, and the query that found it, once
    /// the panel has closed itself. Routing lives in `TraceMacContentView`,
    /// which owns the pending-link bindings; this view only says where.
    ///
    /// The query rides along so the PDF viewer can paint the term on the page
    /// rather than only in the result row. It is the search text verbatim —
    /// splitting it into terms is `MacSearchEngine`'s job and is done again at
    /// the other end, from the same function, so the two cannot drift.
    var onOpen: (MacSearchDestination, String) -> Void
    /// Jump to a screen rather than open a record. Defaulted so a preview or a
    /// test can build this view without wiring navigation it does not need.
    var onGoTo: (MacSection, String?) -> Void = { _, _ in }

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    @State private var query = ""
    @State private var corpus = MacSearchCorpus()
    @State private var documents: [TraceMacDocument] = []
    @State private var results: [MacSearchResult] = []
    @State private var expanded: Set<MacSearchKind> = []
    @State private var selection = 0
    @State private var preview: MacSearchResult? = nil
    // Ask (spec §8 step 3). Nothing here runs until the button is pressed —
    // never as you type, which is the whole distinction between the two halves
    // of this panel. Search is a string comparison on this Mac; Ask is an HTTPS
    // request with the notes in it.
    @State private var answer: MacAskAnswer? = nil
    @State private var asking = false
    @State private var askError: String? = nil
    @State private var askedQuestion = ""
    @AppStorage("tracemac.ask.includeNotion") private var includeNotionInAsk = false
    @State private var previewText = ""
    @FocusState private var fieldFocused: Bool

    /// Whether shift is held RIGHT NOW, so the field can say what Return will
    /// do before Return is pressed (Session 80, David's design: "what about one
    /// hotkey but i hold the shift key down when i hit enter to make it a
    /// task? when i hold shift the text goes blue to give me another clue?").
    ///
    /// A `flagsChanged` monitor, because a modifier held on its own produces no
    /// key press and `onKeyPress` will never see it. Same local-monitor shape
    /// as `MacEditorialArrowKeys` and `MacSatchelFilterShortcut`, installed
    /// while this panel is on screen and removed with it.
    @State private var shiftHeld = false
    @State private var flagsMonitor: Any? = nil
    /// The signature of a parse the user declined with backspace. Not a plain
    /// Bool: the suppression has to survive a trailing space (same signature)
    /// and die on a real edit (different signature), and a Bool cannot tell
    /// those apart.
    @State private var unparsedSignature: String? = nil
    /// Whether the last change to `query` made it longer. The backspace
    /// un-parse only arms while you are typing FORWARD, so backspace behaves
    /// like backspace once you have started editing.
    @State private var queryGrew = false
    @State private var session = MacQuickPanelSession.shared
    /// Set for a couple of seconds after a successful capture.
    @State private var addNotice: String? = nil
    /// Compact by default, tall on request. Remembered, because it is a
    /// preference about how you read rather than about one search.
    @AppStorage("tracemac.search.tall") private var tall = false

    // MARK: Derived

    private var groups: [MacSearchGroup] {
        MacSearchEngine.grouped(results)
    }

    /// The rows actually on screen, in the order they are drawn. Arrow keys and
    /// Return both index into this and nothing else, so the keyboard can never
    /// select a row that is hidden behind a "N more".
    private var visible: [MacSearchResult] {
        groups.flatMap { group in
            expanded.contains(group.kind)
                ? group.items
                : Array(group.items.prefix(MacSearchEngine.groupLimit))
        }
    }

    /// What is still arriving, or what failed. `nil` when everything is in.
    private var notice: String? {
        var waiting: [String] = []
        var failed: [String] = []

        if !noteStore.hasAccess { waiting.append("your notes") }
        switch notionService.peopleLoad {
        case .loaded: break
        case .failed: failed.append("People")
        case .idle, .loading: waiting.append("People")
        }
        switch notionService.placesLoad {
        case .loaded: break
        case .failed: failed.append("Places")
        case .idle, .loading: waiting.append("Places")
        }

        var parts: [String] = []
        if !waiting.isEmpty { parts.append("Still loading \(list(waiting)) — results are incomplete.") }
        if !failed.isEmpty  { parts.append("\(list(failed)) could not be loaded, so \(failed.count == 1 ? "it is" : "they are") not being searched.") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Everything the query was actually run against, so the footer's number
    /// means something. People and Places are in it only once Notion has
    /// answered — counting them while they are still arriving would overstate
    /// the search by exactly the amount the notice is warning about.
    private var searchedCount: Int {
        corpus.notes.count
            + documents.count
            + (notionService.peopleLoad == .loaded ? notionService.people.count : 0)
            + (notionService.placesLoad == .loaded ? notionService.places.count : 0)
    }

    private func list(_ items: [String]) -> String {
        switch items.count {
        case 0:  return ""
        case 1:  return items[0]
        case 2:  return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    // MARK: Body

    var body: some View {
        // No scrim and no inset any more. This used to be an overlay drawn
        // inside the main window, over a dimmed copy of the app; it is now the
        // entire content of a floating `NSPanel` (see `TraceMacQuickPanel`), so
        // the thing behind it is whatever David was actually doing. Clicking
        // away dismisses it through `hidesOnDeactivate` rather than through a
        // scrim this view has to draw.
        panel
            .frame(width: 720)
            // Room for the card's own shadow to fall. The window is borderless
            // and draws none, so without this the shadow is clipped at the
            // window edge and reads as a hard line — which, with the titled
            // frame that used to be here as well, is what David saw.
            .padding(24)
            .onExitCommand { close() }
            .onAppear { installFlagsMonitor() }
            .onDisappear { removeFlagsMonitor() }
            .onChange(of: query) { old, new in
                queryGrew = new.count > old.count
                // Clearing the field clears the refusal with it. Otherwise a
                // declined parse would haunt the next thing typed into a panel
                // that is reused between openings.
                if new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    unparsedSignature = nil
                }
            }
            // Fires on appear AND again when the container resolves. A panel
            // opened in the first second of a launch would otherwise hold an
            // empty corpus for the rest of its life. One modifier, not two — a
            // plain `.task` beside this one would load the whole container
            // twice on every open.
            .task(id: noteStore.hasAccess) { await loadSources() }
            .task(id: query) { await runSearch() }
            // Every opening, not just the first. David: *"the only thing i need
            // is for the cursor to be ready for me in the search window when I
            // hit the shortcut."*
            //
            // The field starts empty each time, the way Spotlight does. Leaving
            // the last question in it means the first thing on screen is an
            // answer to something you have already stopped asking, and the
            // results underneath it are equally stale.
            .task(id: session.opens) {
                query = ""
                answer = nil
                askError = nil
                addNotice = nil
                preview = nil
                expanded = []
                selection = 0
                unparsedSignature = nil
                queryGrew = false
                fieldFocused = true
            }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            field
            if query.isEmpty {
                // **The landing state.** David, with the Things phone
                // screenshot: "when we click the magnifying glass the options
                // should be similar to the IOS experience."
                //
                // An empty search box is a question with no hint of what it
                // accepts. This is the answer the phone gives: here is where you
                // could go, with how much is waiting in each. It also makes the
                // panel useful for the thing it is opened for most often — not
                // finding a record, just going somewhere.
                //
                // It disappears the moment you type, because then the results
                // ARE the answer and a list of destinations underneath them is
                // furniture.
                Divider()
                goToRows
            }
            if !query.isEmpty { hintRow }
            if let notice {
                Divider()
                noticeRow(notice)
            }
            if !query.isEmpty {
                Divider()
                content
                Divider()
                askRow
            }
            Divider()
            footer
        }
        // **Opaque, not a material.** A material samples what is behind it, and
        // what is behind this is the scrim, so the translucent background pulled
        // the dimming *through* the panel and greyed the thing you are reading.
        // David, on first sight: *"the search window also goes gray so it is
        // hard to read."* The scrim is meant to dim the app, not the panel.
        // The single source of chrome for this panel. The window behind it is
        // borderless, transparent and shadowless on purpose (see
        // `MacQuickPanelController.makePanel`), so everything visible — the
        // corner radius, the hairline, the shadow — is drawn exactly once, here.
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        .shadow(color: .black.opacity(0.30), radius: 22, y: 8)
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search notes, tasks, Satchel, people, places", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .regular))
                // Accent, not blue. David asked for blue and blue is spoken
                // for: baby blue means somebody else's calendar (D193) and the
                // meeting palette owns the other one. The accent already means
                // "active, or acting" everywhere in this app, which is exactly
                // what holding shift is announcing, so it needs no new
                // vocabulary.
                .foregroundStyle(taskMode ? MacEditorialColor.accent : Color.primary)
                .focused($fieldFocused)
                // **On the field, not on an ancestor.** The text field is first
                // responder, and on macOS the text system claims the arrow keys
                // for caret movement — so a handler on the enclosing view is
                // offered them only if the field declines, which it does not.
                // David: *"i can press the down arrow and it goes to the
                // description of what i was looking at but i have no way just
                // using the keyboard to go to the main item."* The selection was
                // never moving; the caret was.
                //
                // `onKeyPress` attached to the focused view runs before the
                // default handling, which is the whole difference.
                .onKeyPress(.downArrow) {
                    guard answer == nil else { return .ignored }
                    move(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard answer == nil else { return .ignored }
                    move(-1)
                    return .handled
                }
                // **Backspace declines a parsed date** (David, Session 80,
                // naming Todoist as the reference). One press turns the date
                // off and the words go back into the title; the hint row
                // changes so you can see that is what happened.
                //
                // Armed only while the last change GREW the string. Once you
                // are deleting, backspace is backspace. The residual false fire
                // is a mid-string edit: click into the middle of a finished
                // line and backspace, and this eats it, because a SwiftUI
                // `TextField` does not expose its caret. It costs one keystroke
                // and can fire at most once per parse, which is the price of
                // not rewriting this field as an `NSTextView` (deferred,
                // Session 80).
                //
                // `.ignored` genuinely falls through to normal text editing
                // here: the arrow handlers above have relied on that since they
                // were written. The Return breakage in this file's history was
                // `.onSubmit`, an ACTION, not default editing.
                .onKeyPress(.delete) {
                    let live = rawParse
                    guard queryGrew, live.hasDate,
                          unparsedSignature != live.signature else { return .ignored }
                    unparsedSignature = live.signature
                    queryGrew = false
                    return .handled
                }
                // **⌘⏎ and ⌘E live here, not on their buttons.**
                //
                // `.keyboardShortcut` on a `Button` is a *menu* key equivalent:
                // AppKit resolves it through the main menu, which belongs to the
                // active application. This panel is `.nonactivatingPanel` and is
                // deliberately key while TraceMac is **not** active — so there
                // is no menu in play and the shortcut is never matched. David:
                // *"Command E is not working."* ⌘⏎ was equally dead and had not
                // been tried yet.
                //
                // The buttons keep their labels and their click behaviour. Only
                // the promise of a key equivalent moved, to the one place that
                // actually receives keys here: the focused field.
                //
                // **Return is handled here too, and `.onSubmit` is gone.**
                //
                // Third attempt at "the app does not come forward", and the
                // stop rule in this project is three. The first two both
                // assumed the trigger fired and worked on what happens after
                // it. It does not fire.
                //
                // `.onSubmit` was carrying plain Return. Then addendum 17 added
                // an `onKeyPress` for `.return` on the same field to catch ⌘⏎ —
                // and a key claimed by `onKeyPress` has left the field's own
                // input handling by the time the modifier check runs.
                // `.ignored` hands the event to the **next responder**, not back
                // to the text field's submit action. So plain Return has been
                // going nowhere since that change, which is exactly when this
                // symptom appeared.
                //
                // One handler owns Return now, both variants of it. Nothing is
                // handed back to anything.
                .onKeyPress(keys: [.return, "e"], phases: .down) { press in
                    switch press.key {
                    case .return:
                        if press.modifiers.contains(.shift) {
                            addTaskToInbox()
                        } else if press.modifiers.contains(.command) {
                            addToToday()
                        } else {
                            activate()
                        }
                        return .handled
                    case "e":
                        guard press.modifiers.contains(.command) else { return .ignored }
                        tall.toggle()
                        return .handled
                    default:
                        return .ignored
                    }
                }
            if !query.isEmpty {
                Button {
                    query = ""
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        // No `.onAppear { fieldFocused = true }` here. It fired once in the
        // panel's whole life, because the panel is reused between presses — the
        // reason the caret was missing from the second press onwards. Focus is
        // claimed on `session.opens` instead.
    }

    /// `↩ SEARCH · ⇧↩ NEW TASK`, the live half in ink and the other faint.
    ///
    /// The colour of the text tells you the mode has changed; this tells you
    /// what the mode IS. Without it the accent is a mood ring — you can see
    /// something is different and you have to press Return to find out what.
    /// One row, and only while there is a line to act on, so the resting panel
    /// is unchanged.
    private var hintRow: some View {
        let line: ParsedTaskLine = capture
        let stamp: String? = line.dateLabel
        let declined: Bool = unparsedSignature != nil && rawParse.hasDate
        let searchTint: Color = taskMode ? MacEditorialColor.faint : MacEditorialColor.ink
        // Ink rather than faint once the line carries a date OR a note, even
        // with shift up: the half is now saying something about what will
        // happen, and a fact drawn in the "nothing here" colour is a fact
        // nobody reads. Faint is for the offer; ink is for the consequence.
        let carries: Bool = stamp != nil || line.hasNote
        let taskTint: Color = taskMode
            ? MacEditorialColor.accent
            : (carries ? MacEditorialColor.ink : MacEditorialColor.faint)

        return HStack(spacing: 8) {
            Text("\u{21a9} Search")
                .foregroundStyle(searchTint)
            Text("\u{00b7}")
                .foregroundStyle(MacEditorialColor.faint)
            if let stamp {
                Text("\u{21e7}\u{21a9}")
                    .foregroundStyle(taskTint)
                // `.textCase(nil)` because this is HIS text in a row of
                // furniture, and uppercasing it would hide the one thing he is
                // checking: which words survived the strip.
                Text("\u{201c}\(line.title)\u{201d}")
                    .textCase(nil)
                    .foregroundStyle(taskTint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Priority over the title, so a long line loses its tail rather
                // than losing the date — the date is the half that can surprise
                // you.
                Text("\u{2192} \(stamp)")
                    .foregroundStyle(taskTint)
                    .layoutPriority(1)
            } else {
                Text("\u{21e7}\u{21a9} New task")
                    .foregroundStyle(taskTint)
                if declined {
                    // Says the backspace landed. Without it, declining a parse
                    // and mistyping a word look identical.
                    Text("\u{00b7} date off")
                        .foregroundStyle(MacEditorialColor.faint)
                } else {
                    // **The syntax, shown only when there is nothing better to
                    // say.** David, Session 80: "We left the hot key pills
                    // without the knowledge that the natural language is a
                    // possibility and also the // for note."
                    //
                    // He is right, and the omission had a shape worth naming: a
                    // feature that only announces itself once you have already
                    // used it is a feature for the person who wrote it. The
                    // parse preview is excellent AFTER you type a date and
                    // silent before, which is exactly backwards for learning.
                    //
                    // It costs no row and no new state, because it lives in the
                    // slot the parse preview will occupy the moment there is a
                    // parse. Type a date and the hint is replaced by what the
                    // date actually resolved to — the teaching disappears the
                    // instant it is no longer the most useful thing to say.
                    //
                    // `.textCase(nil)`: these are characters to type, and
                    // uppercasing them would misrepresent the one thing they
                    // exist to show.
                    Text("\u{00b7} try \u{201c}friday\u{201d} or // note")
                        .textCase(nil)
                        .foregroundStyle(MacEditorialColor.faint)
                        .lineLimit(1)
                }
            }
            // A marker, not the note itself. The note text is still sitting in
            // the field after the `//`, unedited, so repeating it here would
            // spend the row's whole width saying something already on screen.
            // What is NOT on screen is whether the delimiter was accepted, and
            // that is exactly what this says. Priority above the title for the
            // same reason the date has it.
            if line.hasNote {
                Text("\u{00b7} + note")
                    .foregroundStyle(taskTint)
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 9.5, weight: .bold))
        .textCase(.uppercase)
        .tracking(1.6)
        .padding(.horizontal, 17)
        .padding(.bottom, 11)
    }

    // MARK: - Go to

    /// Pools first, then context lists — the same axis split the Tasks screen
    /// uses (D213), so the two surfaces describe his tasks the same way. A
    /// panel that grouped them differently would be teaching a second model of
    /// the same data.
    ///
    /// Counts come straight off the store, and empty lists are hidden on the
    /// same reasoning as the rail: a column of zeros is a column you stop
    /// reading.
    @ViewBuilder
    private var goToRows: some View {
        let store = ReminderTaskStore.shared
        let hidden: Set<String> = [ReminderTaskStore.inboxListName,
                                   ReminderTaskStore.somedayListName]
        let lists: [(String, Int)] = store.listNames
            .filter { name in !hidden.contains(name) }
            .map { name -> (String, Int) in
                (name, store.allTasks.filter { task in task.list == name }.count)
            }
            .filter { pair in pair.1 > 0 }

        VStack(alignment: .leading, spacing: 0) {
            Text("Go to").editorialFieldLabel()
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 2)
            goToRow("Today", "sun.max", nil) { onGoTo(.today, nil) }
            goToRow("Upcoming", "calendar", nil) { onGoTo(.upcoming, nil) }
            goToRow("Inbox", "tray", store.inboxCount) { onGoTo(.tasks, nil) }

            if !lists.isEmpty {
                Text("Lists").editorialFieldLabel()
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
                ForEach(lists, id: \.0) { name, count in
                    goToRow(name, "list.bullet", count) { onGoTo(.tasks, name) }
                }
            }
        }
        .padding(.bottom, 8)
    }

    private func goToRow(_ label: String, _ icon: String, _ count: Int?,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(MacEditorialColor.faint)
                    .frame(width: 16)
                Text(label)
                    .font(MacEditorialType.fieldValue)
                    .foregroundStyle(MacEditorialColor.ink)
                Spacer(minLength: 8)
                // Zero draws nothing, same rule as the sidebar count: an empty
                // pool should look like nothing, not like a number.
                if let count, count > 0 {
                    Text("\(count)")
                        .font(MacEditorialType.time)
                        .foregroundStyle(MacEditorialColor.faint)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func noticeRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
            Text(text)
            Spacer(minLength: 0)
        }
        .font(MacType.meta)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    @ViewBuilder
    private var content: some View {
        if let answer {
            answerPane(answer)
        } else if let preview {
            previewPane(preview)
        } else if results.isEmpty {
            HStack {
                Text("No matches for “\(query)”.")
                    .font(MacType.body)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        } else {
            resultsList
        }
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups) { group in
                        Section {
                            let shown = expanded.contains(group.kind)
                                ? group.items
                                : Array(group.items.prefix(MacSearchEngine.groupLimit))
                            ForEach(shown) { result in
                                row(result)
                                    .id(result.id)
                            }
                            if group.items.count > shown.count {
                                Button {
                                    expanded.insert(group.kind)
                                } label: {
                                    Text("\(group.items.count - shown.count) more")
                                        .font(MacType.meta)
                                        .foregroundStyle(Color.traceOrange)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Image(systemName: group.kind.icon)
                                Text(group.kind.label.uppercased())
                                    .tracking(MacType.labelTracking)
                                Text("\(group.items.count)")
                                    .foregroundStyle(.tertiary)
                                Spacer()
                            }
                            .font(MacType.label)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(Color(nsColor: .windowBackgroundColor))
                        }
                    }
                }
            }
            .frame(height: resultsHeight)
            .onChange(of: selection) {
                guard visible.indices.contains(selection) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(visible[selection].id, anchor: .center)
                }
            }
        }
    }

    private func row(_ result: MacSearchResult) -> some View {
        let isSelected = visible.indices.contains(selection) && visible[selection].id == result.id
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                highlighted(result.title)
                    .font(MacType.rowEmphasis)
                    .lineLimit(1)
                if !result.subtitle.isEmpty {
                    Text(result.subtitle)
                        .font(MacType.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let snippet = result.snippet {
                    // The base colour is passed in rather than applied on the
                    // outside. Whether an outer `.foregroundStyle` on a
                    // concatenated `Text` beats the styles already baked into
                    // its runs is a rule I would be relying on rather than
                    // stating, and the failure would be silent: the highlight
                    // simply stops being orange.
                    highlighted(snippet, base: .secondary)
                        .font(MacType.meta)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            // Only on the selected row, and only when it says something the row
            // does not already: that Return will read this here rather than open
            // a screen. Session 69's whole cleanup was controls that promised
            // what they could not do.
            if isSelected {
                Text(result.destination == .preview ? "⏎ preview" : "⏎ open")
                    .font(MacType.meta)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Stronger than it was, and with a bar down the leading edge. At 16%
        // accent the selected row read clearly next to an unselected one and
        // barely at all on its own — which is the state it is actually in while
        // you are looking at a row rather than comparing the list.
        .background(isSelected ? Color.accentColor.opacity(0.28) : .clear)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(Color.accentColor).frame(width: 3)
            }
        }
        .contentShape(Rectangle())
        // **The result is passed, not looked up.** This used to write
        // `selection` and then call `activate()`, which read `selection` back on
        // the very next line — a SwiftUI `@State` write is not guaranteed to be
        // visible to a synchronous read in the same closure, so a click could
        // open whatever was selected *before* it. Handing the row over removes
        // the question rather than betting on the answer.
        .onTapGesture { activate(result) }
    }

    /// The matched terms, bolded and tinted in place.
    ///
    /// Plain `String` ranges and concatenated `Text`, not `AttributedString`.
    /// The first version took index ranges out of an `AttributedSubstring` slice
    /// and then mutated the parent it was sliced from, which is only safe while
    /// nothing shifts and is a bad thing to be only-safe-while.
    private func highlighted(_ text: String, base: Color? = nil) -> Text {
        func plain(_ piece: Text) -> Text { base.map { piece.foregroundStyle($0) } ?? piece }
        let terms = MacSearchEngine.terms(in: query)
        guard !terms.isEmpty, !text.isEmpty else { return plain(Text(text)) }

        var marked = Array(repeating: false, count: text.count)
        for term in terms {
            var from = text.startIndex
            while let found = text.range(of: term, options: .caseInsensitive,
                                         range: from..<text.endIndex) {
                let lower = text.distance(from: text.startIndex, to: found.lowerBound)
                let upper = text.distance(from: text.startIndex, to: found.upperBound)
                for i in lower..<min(upper, marked.count) { marked[i] = true }
                guard found.upperBound < text.endIndex else { break }
                from = found.upperBound
            }
        }

        var out = Text("")
        var run = ""
        var runMarked = false
        func flush() {
            guard !run.isEmpty else { return }
            let piece = Text(run)
            out = out + (runMarked ? piece.bold().foregroundStyle(Color.traceOrange) : plain(piece))
            run = ""
        }
        for (i, character) in text.enumerated() {
            if marked[i] != runMarked { flush(); runMarked = marked[i] }
            run.append(character)
        }
        flush()
        return out
    }

    private func previewPane(_ result: MacSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    preview = nil
                } label: {
                    Image(systemName: "chevron.left")
                    Text("Results")
                }
                .buttonStyle(.plain)
                .font(MacType.meta)
                .foregroundStyle(Color.traceOrange)
                Spacer()
                Text(result.previewPath ?? "")
                    .font(MacType.meta)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                Text(previewText.isEmpty ? "Empty note." : previewText)
                    .font(MacType.row)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .frame(height: listHeight)
        }
    }

    // MARK: Ask

    /// The button, with the scope written on it.
    ///
    /// **"Ask about 121 records", not "Ask".** Spec §7 asks for the scope on the
    /// button and it earns its width: this is the control that sends the text of
    /// those records to an API, and the number is the one fact a person needs
    /// before pressing it. A bare "Ask" would be a button whose consequence you
    /// have to already know.
    @ViewBuilder
    private var askRow: some View {
        HStack(spacing: 10) {
            if answer != nil {
                Button {
                    answer = nil
                    askError = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Results")
                    }
                }
                .buttonStyle(.plain)
                .font(MacType.meta)
                .foregroundStyle(Color.traceOrange)
            } else {
                Button {
                    Task { await runAsk() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkle")
                        Text(asking ? "Reading…" : "Ask about \(askScope) records")
                    }
                    .font(MacType.row)
                }
                .buttonStyle(.borderedProminent)
                .disabled(asking || query.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if asking { ProgressView().controlSize(.small) }

            // On screen as well as on a key, so the shortcut is learned from a
            // label rather than from a footer. The key itself is handled on the
            // text field — see the `onKeyPress` there for why a
            // `.keyboardShortcut` on this button silently did nothing.
            if answer == nil {
                // **"Add to note", not "Add to today".** David: *"rename the
                // pill that says add to today which is confusing since i think
                // that is the note add."* He was right, and it was worse than
                // ambiguous — it was ambiguous in exactly the place where the
                // distinction now matters. "Today" is the name of a SCREEN, a
                // task state, and a date, and this button is none of those: it
                // appends a line to the daily note. The label says the noun the
                // line lands in.
                Button {
                    addToToday()
                } label: {
                    Label("Add to note", systemImage: "text.append")
                        .font(MacType.meta)
                }
                .buttonStyle(.bordered)
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Append this line to today's note (⌘⏎)")

                // Its sibling, and the reason the rename could not wait. Two
                // buttons side by side ARE the explanation: one writes a line,
                // the other makes a commitment, and neither label needs a
                // sentence once the other is standing next to it.
                //
                // On screen as well as on ⇧⏎, for the same reason the note
                // button is: a shortcut nobody can discover is a shortcut for
                // the person who wrote it. The hint row under the field teaches
                // the key; this pill is how you do it before you have learned
                // the key.
                Button {
                    addTaskToInbox()
                } label: {
                    Label("New task", systemImage: "checklist")
                        .font(MacType.meta)
                }
                .buttonStyle(.bordered)
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Add this line to the Reminders Inbox (⇧⏎). A date at the end sets the due date, backspace declines it, and // starts a note.")

                // **A labelled button, not the icon it was.** The icon sat in
                // the footer between a `Spacer` and a run of grey key hints, at
                // 10pt, and David's next message was *"is there no way to switch
                // between the expanded view and the compact view?"* — which is
                // the only review a control ever gets. It is next to Ask now,
                // with a word on it.
                Button { tall.toggle() } label: {
                    Label(tall ? "Shorter" : "Taller",
                          systemImage: tall
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right")
                        .font(MacType.meta)
                }
                .buttonStyle(.bordered)
                .help(tall ? "Shorter panel (⌘E)" : "Taller panel (⌘E)")
            }

            Spacer()

            // The error is deliberately NOT on this row. A sentence that names
            // a setting to change does not fit beside a button, and truncating
            // it makes it useless — David's first 429 was cut off mid-word. It
            // gets a full-width row below instead.
            if let addNotice {
                Label(addNotice, systemImage: "checkmark.circle")
                    .font(MacType.meta)
                    .foregroundStyle(Color.traceOrange)
            } else if answer == nil, askError == nil {
                // Said every time, on the control that does it. Search never
                // leaves the Mac and this does, and the difference should not
                // live only in a document nobody has open.
                // Two lines and a width, because the row gained a fourth
                // button (New task) and this is the only compressible thing on
                // it — an HStack shrinks Text before it shrinks a Button, so
                // left alone it would truncate mid-word, which is the exact
                // failure the note above this block was written about. Wrapping
                // costs a few points of footer height; truncating costs the
                // sentence.
                Text("Sends your notes to Claude. Search does not.")
                    .font(MacType.meta)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .frame(maxWidth: 190, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)

        if let askError {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                Text(askError)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .font(MacType.meta)
            .foregroundStyle(.orange)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    /// How much of the panel is list.
    ///
    /// David: *"the window itself is very small. I like small except when i want
    /// to look at the details in which case it should allow me to expand the
    /// window length."*
    ///
    /// **A toggle rather than a draggable edge.** The window is borderless, so a
    /// resizable style mask would offer a drag target with nothing to see and
    /// nothing to aim at, and it would fight `NSHostingController`, which sizes
    /// the window from its content rather than the other way round. One key,
    /// both directions, no aiming — the same argument as every other control
    /// here.
    ///
    /// Capped against the screen, because the panel sits a third of the way down
    /// and a fixed tall height would run off the bottom of a laptop display.
    private var listHeight: CGFloat {
        guard tall else { return 420 }
        let available = NSScreen.main?.visibleFrame.height ?? 900
        return min(760, available * 0.62)
    }

    /// The height the results list is actually given.
    ///
    /// **`.frame(maxHeight:)` was the bug and `.frame(height:)` is the fix.**
    /// `NSHostingController` sizes the window by asking the content what it
    /// wants with an unspecified proposal, and a `ScrollView` asked that
    /// question answers with almost nothing — it scrolls precisely so it does
    /// not need a natural height. A `maxHeight` only caps; it never asks. So the
    /// list was handed roughly one row.
    ///
    /// That is the whole of David's *"the window itself is very small"* **and**
    /// his *"it goes to the description of what i was looking at"*: with a
    /// viewport shorter than a single row, `scrollTo(anchor: .center)` centres
    /// the selected row and the middle of a row is its description. The arrow
    /// keys were working by then. There was nowhere to put the result.
    ///
    /// Estimated from the rows rather than fixed, so a two-hit search does not
    /// open a half-empty panel. Generous per row on purpose: over-estimating
    /// costs a little whitespace, under-estimating costs a scroll, and this is a
    /// `ScrollView` either way.
    private var resultsHeight: CGFloat {
        let rows = CGFloat(visible.count) * 56
        let headers = CGFloat(groups.count) * 28
        let more = CGFloat(groups.filter { $0.items.count > MacSearchEngine.groupLimit }.count) * 24
        return min(listHeight, max(96, rows + headers + more))
    }

    /// Everything Ask is allowed to read, counted the way the prompt will count
    /// it. People and Places are in only when the Settings toggle says so.
    private var askScope: Int {
        corpus.notes.count
            + documents.filter { $0.category != "_to_delete" }.count
            + (includeNotionInAsk ? notionService.people.count + notionService.places.count : 0)
    }

    private func answerPane(_ answer: MacAskAnswer) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(askedQuestion)
                    .font(MacType.meta)
                    .foregroundStyle(.tertiary)

                Text(answer.text)
                    .font(MacType.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !answer.citations.isEmpty {
                    Divider()
                    Text("SOURCES")
                        .font(MacType.label)
                        .tracking(MacType.labelTracking)
                        .foregroundStyle(.secondary)
                    // Clickable, because an answer whose sources you cannot open
                    // is not checkable. They route through exactly the same
                    // function a search result does.
                    ForEach(answer.citations) { citation in
                        Button {
                            close()
                            // Empty, not the question. A question is not a
                            // search term, and highlighting it inside a PDF
                            // would paint whatever words it happened to share
                            // with the page.
                            onOpen(citation.destination, "")
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("[\(citation.number)]")
                                    .font(MacType.meta)
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                                Text(citation.title)
                                    .font(MacType.row)
                                    .foregroundStyle(Color.traceOrange)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider()
                Text(answer.receipt)
                    .font(MacType.meta)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
        }
        .frame(height: listHeight)
    }

    /// Append the typed line to today's daily note.
    ///
    /// **`NoteStore.appendToDailyNote` does all of it already** — creates
    /// `Calendar/<today>.md` with its date header when there is none, appends to
    /// the end of the prose when there is, coordinates the write, and posts
    /// `.noteStoreCalendarDidChange` so the Daily screen reloads without being
    /// touched. It is the same function the phone captures through. Writing a
    /// second one here is how the two would drift.
    ///
    /// It appends *above* a trailing `## Related Notes` table rather than at the
    /// true end of file. That is deliberate and predates this: a July bug where
    /// text appended below the table was silently swallowed by the Related Notes
    /// parser on the next load. Still the bottom of what David wrote.
    ///
    /// **The panel stays open and the field clears**, because *"new / subsequent
    /// adds to the daily note would append to the bottom of what is there"*
    /// describes a run of captures, not one. Closing after each would make the
    /// second one cost another shortcut press.
    // MARK: - Shift capture (D196)

    /// True while shift is down and there is something to capture.
    ///
    /// Gated on non-empty text on purpose: shift is held for a hundred reasons
    /// (a capital letter, a selection) and colouring an empty field accent for
    /// each of them would make the signal noise. It only means something once
    /// there is a line that could become a task.
    private var taskMode: Bool {
        shiftHeld && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the line says on its own terms, before the user's refusal is
    /// applied. The backspace handler needs this one, because it has to see the
    /// parse in order to decline it.
    private var rawParse: ParsedTaskLine { TaskLineParser.parse(query) }

    /// What ⇧⏎ and the New task pill will actually create. Recomputed rather
    /// than cached: it is one `NSDataDetector` pass over a short string against
    /// a static detector, and a cache here would be a third piece of state that
    /// can disagree with the field.
    ///
    /// **Both capture paths read this one property**, so the pill and the key
    /// can never do different things — the failure that makes a parser feel
    /// haunted rather than helpful.
    private var capture: ParsedTaskLine {
        let live = rawParse
        if let unparsedSignature, unparsedSignature == live.signature {
            return live.withoutDate()
        }
        return live
    }

    /// Shift is not a key press, it is a key *state*, so `onKeyPress` never
    /// sees it — a modifier alone produces `flagsChanged`, not `keyDown`. A
    /// local monitor is the only way to know it is down before Return is hit,
    /// and knowing that BEFORE is the entire point: the accent is a promise
    /// about what Return is going to do, and a promise made afterwards is a
    /// report.
    ///
    /// Local, not global: no Accessibility permission, and it fires only while
    /// this panel is key. Same instrument as `MacSatchelFilterShortcut`, and the
    /// event is returned unswallowed because the text system still needs shift
    /// for capital letters.
    private func installFlagsMonitor() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let down = event.modifierFlags.contains(.shift)
            if down != shiftHeld { shiftHeld = down }
            return event
        }
    }

    private func removeFlagsMonitor() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        // The panel is reused between presses (see the focus note on `field`),
        // so a stale `true` left here would paint the next opening accent for a
        // shift nobody is holding.
        shiftHeld = false
    }

    /// ⇧⏎ — the line becomes a task in the Inbox list.
    ///
    /// **Inbox, not Today.** ⌘⏎ already appends to the daily NOTE, which is
    /// journal: a line you wrote down. A task is a commitment, and the whole
    /// point of the Inbox list (D158) is that capture does not have to decide
    /// where a commitment belongs at the moment of having it. Giving this a
    /// date here would be that decision, made badly, at the worst possible time.
    ///
    /// Same aftermath as `addToToday`: field clears, panel stays open, notice
    /// for 2.5s. A run of captures is one shortcut press, not one per thought.
    private func addTaskToInbox() {
        let line = capture
        guard !line.title.isEmpty else { return }
        let stamp = line.dateLabel
        let hadNote = line.hasNote
        query = ""
        askError = nil
        fieldFocused = true
        Task {
            let ok = await ReminderTaskStore.shared.addTask(
                title: line.title,
                date: line.date,
                list: ReminderTaskStore.inboxListName,
                notes: line.note,
                remindAt: line.remindAt)
            if ok {
                // The date is repeated back. A parser's one real failure mode
                // is landing the right words on the wrong day, and the notice
                // is the last moment that is cheap to catch.
                // The destination is repeated back too (Session 81): a
                // dated capture graduates to Personal at birth (addTask's
                // D225 rule), and a notice claiming the Inbox for it would be
                // the lie that hid this path's dropped-date bug for a session.
                var said = line.date == nil ? "Added to Inbox" : "Added to Personal"
                if let stamp { said += " \u{00b7} \(stamp)" }
                if hadNote { said += " \u{00b7} + note" }
                addNotice = said
                try? await Task.sleep(for: .seconds(2.5))
                addNotice = nil
            } else {
                // The only way this fails is Reminders access, and a silent
                // no-op on a capture is how you lose the thought AND the trust.
                addNotice = nil
                askError = "Could not add the task \u{2014} Trace does not have access to Reminders."
            }
        }
    }

    private func addToToday() {
        let line = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        do {
            try noteStore.appendToDailyNote(line)
            query = ""
            askError = nil
            addNotice = "Added to note"
            fieldFocused = true
            Task {
                // The corpus is now one line out of date, and the very next
                // thing someone does after capturing is search for it. Cheap:
                // 107 files on a detached walk.
                await loadSources()
                try? await Task.sleep(for: .seconds(2.5))
                addNotice = nil
            }
        } catch {
            addNotice = nil
            askError = error.localizedDescription
        }
    }

    private func runAsk() async {
        let question = query.trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty, !asking else { return }
        asking = true
        askError = nil
        askedQuestion = question
        defer { asking = false }
        do {
            answer = try await MacAskService.ask(question,
                                                 corpus: corpus,
                                                 documents: documents,
                                                 people: notionService.people,
                                                 places: notionService.places,
                                                 includeNotionRecords: includeNotionInAsk)
        } catch {
            askError = error.localizedDescription
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if query.isEmpty {
                Text("Titles and bodies. Nothing leaves this Mac.")
            } else {
                Text("\(results.count) \(results.count == 1 ? "match" : "matches") in \(searchedCount) records")
            }
            Spacer()
            Text("↑↓ move   ⏎ open   ⌘⏎ add   esc close")
        }
        .font(MacType.meta)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Actions

    private func move(_ delta: Int) {
        guard !visible.isEmpty else { return }
        preview = nil
        selection = min(max(0, selection + delta), visible.count - 1)
    }

    /// Open a row. `target` is the clicked row; `nil` means "whatever the arrow
    /// keys are on", which is the Return path.
    private func activate(_ target: MacSearchResult? = nil) {
        // Return re-asks while an answer is up rather than opening a row the
        // user has stopped looking at.
        if answer != nil { Task { await runAsk() }; return }
        guard let result = target ?? (visible.indices.contains(selection) ? visible[selection] : nil)
        else { return }
        if result.destination == .preview {
            previewText = result.previewPath.flatMap { try? noteStore.readFile($0) } ?? ""
            preview = result
            return
        }
        let text = query
        close()
        onOpen(result.destination, text)
    }

    private func close() {
        isPresented = false
    }

    // MARK: Loading

    private func loadSources() async {
        guard noteStore.hasAccess, let url = noteStore.containerURL else { return }
        // The walk reads every markdown file in the container — the same work
        // `findWikilinkMentions` detaches for, and for the same reason.
        let built = await Task.detached { MacSearchCorpus.build(containerURL: url) }.value
        corpus = built

        let store = TraceMacDocumentStore(noteStore: noteStore)
        await store.reload()
        documents = store.documents

        await runSearch(debounce: false)
    }

    private func runSearch(debounce: Bool = true) async {
        if debounce {
            // Enough to swallow a fast typist's inter-key gap, short enough that
            // the list feels like it is keeping up. `.task(id:)` cancels the
            // previous run, so an abandoned query never lands.
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
        }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            selection = 0
            preview = nil
            answer = nil
            askError = nil
            return
        }
        // A new query invalidates the old answer. Leaving it on screen under
        // a different question is the worst available outcome: the text still
        // reads as an answer and nothing says it was for something else.
        answer = nil
        askError = nil
        results = MacSearchEngine.run(query: query,
                                      corpus: corpus,
                                      documents: documents,
                                      people: notionService.people,
                                      places: notionService.places,
                                      // Straight off the store, not a snapshot
                                      // taken at load. Tasks change under this
                                      // panel constantly — ⇧⏎ adds one from the
                                      // panel itself — and a corpus copied once
                                      // would go stale mid-session.
                                      tasks: ReminderTaskStore.shared.allTasks)
        selection = 0
        expanded = []
        preview = nil
    }
}
