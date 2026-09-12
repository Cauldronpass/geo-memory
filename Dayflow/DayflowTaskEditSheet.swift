import SwiftUI
import UIKit

// MARK: - DayflowTaskEditSheet
//
// Edit an existing Things task's title, date, list, and notes — added
// 2026-07-20 after David asked to "modify the name of the task or the date or
// the list by clicking on the text" from the Agenda, Anytime, and Upcoming
// rows. Presented as a `.sheet(item:)` wherever a task row's title is tapped:
// DayflowAgendaSection.swift, DayflowAnytimeView.swift, DayflowUpcomingView.swift,
// DayflowInboxView.swift.
//
// **Notes section added 2026-07-20 (second pass).** David asked for a way to
// add/see a task's description — previously there was no round-trip for this
// at all (`/add` could write notes but nothing ever read them back). Backend
// now sends `notes` on every GET endpoint and accepts it on `/update`; this
// sheet prefills a multi-line text box with the real current notes and saves
// whatever's there, including a deliberate clear to blank (see
// `ThingsService.update(...)`'s doc comment for the nil-vs-empty-string
// convention this relies on).
//
// Reuses DayflowWhenPickerSheet for the date row (kind: .task, so This
// Evening/Someday show). Those two buckets are Things-native concepts the
// Mini's `/update` endpoint can't express (same open question already logged
// for quick-add — see DayflowModels.swift's `isThingsNativeBucket` doc
// comment); picking either here just clears the task's date rather than
// silently no-op'ing or guessing a stand-in date.
//
// List picker is a plain Menu over DayflowThingsAreas.displayNames plus a
// "No List" option — matching the quick-add sheet's chip set. Free-typed list
// names aren't supported here any more than they are there (Dayflow-Design-
// Plan.md "Open questions" — list-name normalization is still unresolved).
//
// Save calls ThingsService.update(taskID:title:date:clearDate:list:), which
// re-fetches Today/Anytime/Upcoming on success since an edit can move a task
// between those buckets. `onSaved` is an additional caller-supplied hook (each
// of the three call sites also refreshes its own local view state).

struct DayflowTaskEditSheet: View {
    let taskID: String
    let initialTitle: String
    let initialDate: Date?
    let initialList: String?
    let initialNotes: String?
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var when: DayflowWhenValue
    @State private var list: String?
    @State private var notes: String
    /// Which of this sheet's own sub-sheets is showing (Session 88, D283).
    ///
    /// **There were three `.sheet` modifiers on this one view**, and this
    /// codebase already knows what that costs: *"two `.sheet` modifiers on one
    /// view is a coin flip and the later one wins silently"* (the Mac's D36,
    /// quoted in `DayflowEndeavorViews`). The date picker was declared first
    /// and lost, which is why the Date row did nothing. One host, one
    /// presentation, and adding a fourth is a case rather than a race.
    @State private var subSheet: SubSheet? = nil
    @State private var showingLinkKinds = false

    private enum SubSheet: Identifiable {
        case when
        case link(DayflowTaskLinkKind)
        case document
        /// A place or a person opened FROM the Linked section.
        case record(WikiLinkTarget)
        /// A project note opened from the Linked section.
        case projectNote(String)
        /// A daily note opened from the Linked section.
        ///
        /// `Date` is not `Identifiable` and two different days must be two
        /// different presentations, so the id carries the day.
        case dailyNote(Date)
        /// An endeavor opened from the Linked section.
        ///
        /// **Presented here rather than routed to.** `dayflow://endeavor?id=`
        /// asks the app to present a screen, and this sheet is already
        /// presented, so the route was queued behind it and never arrived -
        /// the console said so twice: *"Currently, only presenting a single
        /// sheet is supported. The next sheet will be presented when the
        /// currently presented sheet gets dismissed."* Opening it inside this
        /// sheet needs no dismissal and no timing.
        case endeavor(String)
        var id: String {
            switch self {
            case .when:              return "when"
            case .link(let kind):    return "link-" + kind.rawValue
            case .document:          return "document"
            case .record(let t):     return "record-" + t.id
            case .projectNote(let n):return "note-" + n
            case .dailyNote(let d):  return "daily-\(d.timeIntervalSince1970)"
            case .endeavor(let id):  return "endeavor-" + id
            }
        }
    }
    @State private var isSaving = false
    /// Session 78 — repeat, seeded from the live reminder on appearance
    /// (the init only gets the ThingsTask's `repeats` Bool, not the rule).
    @State private var repeatRule: ReminderTaskStore.DayflowRepeatRule = .none
    @State private var initialRepeatRule: ReminderTaskStore.DayflowRepeatRule = .none
    /// Session 78 — link a person/place: appends their [[wikilink]] to the
    /// notes, which the task rows render as a tappable chip.
    @State private var showWebLinkEntry = false
    /// Session 78 — the Reminder section (David: "i dont see the reminder
    /// option"). One datetime picker covers both the When card's cases: a
    /// same-day time, or a lead alarm days before the due day.
    @State private var remindOn = false
    @State private var remindAt = Date()
    @State private var initialRemindAt: Date? = nil
    @State private var webLinkText = ""
    /// Session 81 (D227's iOS half) — document links. Parsed off the live
    /// `notes` text, resolved against the shared chip store the way the
    /// person/place chips resolve against Notion. No cached titles.
    @State private var chipStore = TraceSatchelChipStore.shared
    /// Every endeavor's name, loaded once when this sheet opens.
    ///
    /// One read per sheet, never per row: `EndeavorFile.nameIndex` walks the
    /// endeavor files, which is cheap once and unaffordable repeatedly. The
    /// same split the Mac's task card and task row already make.
    @State private var endeavorNames: Set<String> = []
    @State private var wikiMiss: DayflowWikiMissNotice? = nil
    @Environment(\.openURL) private var openURL
    @State private var satchelUnavailable = false
    /// Session 81 (D239) — the SHORTCUT row's rename/add entry.
    @State private var showShortcutEntry = false
    @State private var shortcutText = ""

    /// Repeats need a date to anchor to.
    private var dateless: Bool {
        switch when {
        case .none, .someday, .thisEvening: return true
        case .today, .date: return false
        }
    }
    /// A save the bridge accepted and Things did not keep. See
    /// `ThingsService.lastWriteMismatch`.
    @State private var writeMismatch: String? = nil

    init(taskID: String, initialTitle: String, initialDate: Date?, initialList: String?,
         initialNotes: String? = nil, onSaved: @escaping () -> Void = {}) {
        self.taskID = taskID
        self.initialTitle = initialTitle
        self.initialDate = initialDate
        self.initialList = initialList
        self.initialNotes = initialNotes
        self.onSaved = onSaved
        _title = State(initialValue: initialTitle)
        _when = State(initialValue: initialDate.map { DayflowWhenValue.date($0) } ?? .none)
        _list = State(initialValue: (initialList?.isEmpty ?? true) ? nil : initialList)
        _notes = State(initialValue: initialNotes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Task title", text: $title)
                }

                Section("Date") {
                    Button {
                        subSheet = .when
                    } label: {
                        HStack {
                            Text("Date").foregroundStyle(.primary)
                            Spacer()
                            Text(when.label).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Section("List") {
                    // **A push, not a menu** (Session 88, D281's second
                    // instance). This was a `Menu` and it did not present at
                    // all - David: *"looking at the task edit screen, the list
                    // is not clickable."* Every other control in the same sheet
                    // takes its taps, and the endeavor details sheet's Type
                    // picker failed the same way the same day: **a menu inside
                    // a sheet does not present in this app.**
                    Picker("List", selection: listBinding) {
                        Text("No List").tag("")
                        ForEach(DayflowThingsAreas.displayNames, id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                Section("Reminder") {
                    Toggle("Remind me", isOn: $remindOn)
                        .disabled(dateless)
                    if remindOn {
                        DatePicker("At", selection: $remindAt,
                                   displayedComponents: [.date, .hourAndMinute])
                    }
                    if dateless {
                        Text("A reminder needs a date to anchor to.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Repeat") {
                    // Same fix as List above, and found by looking rather than
                    // by being told: David reported List, and Repeat was the
                    // identical construction in the identical sheet.
                    Picker("Repeat", selection: $repeatRule) {
                        ForEach(ReminderTaskStore.DayflowRepeatRule.allCases, id: \.self) { rule in
                            Text(rule.label).tag(rule)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .disabled(dateless && repeatRule == .none)
                    if dateless && repeatRule != .none {
                        Text("A repeat needs a date to anchor to.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Linked") {
                    // **`.borderless`, not `.plain`** (Session 88).
                    //
                    // David, on the row this session had just made tappable:
                    // *"in the task editor, shouldnt the link be clickable? its
                    // not."* It was a Button and it did nothing, because a
                    // `Form` row containing MORE THAN ONE button stops routing
                    // taps to `.plain` ones - the row wants to be the single
                    // tap target and `.plain` does not opt out of that.
                    // `.borderless` does.
                    //
                    // **Every row in this section has that shape**, and the
                    // other two predate this session: the document row's open
                    // button and the shortcut row's Run and Change have been
                    // dead since D227 and D239 shipped them in Session 81.
                    // Nobody noticed because a button that does nothing looks
                    // exactly like a button you have not pressed.
                    //
                    // Sibling of D283: the control was fine and the container
                    // decided otherwise, and the tell in both cases was that
                    // several controls failed together while everything else
                    // on the same screen worked.
                    ForEach(linkedNames, id: \.name) { link in
                        HStack(spacing: 8) {
                            Image(systemName: link.icon)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            // **The row opens what it names** (warning
                            // FOURTEEN). It listed the record and stopped,
                            // which is worse than silence because it proves the
                            // door could have been there. Through the one
                            // resolver (D282), so a place, a person, a note and
                            // an endeavor all open from here and an unresolved
                            // name says why instead of doing nothing.
                            //
                            // This is also the door the row mark on Today,
                            // Upcoming and Quick Find relies on: those marks are
                            // passive by design, and the chain they end in is
                            // tap the row, read the Linked section, open it.
                            Button { resolveLink(link.name) } label: {
                                Text(link.name)
                                    .foregroundStyle(Color.dayflowInk)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            Spacer()
                            Button {
                                removeLink(link.name)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    // Session 81 — the D227 document links, resolved live
                    // against the document store. A path the store cannot
                    // resolve renders "(missing)", refuses to navigate, and
                    // still offers removal — same contract as the Mac chip.
                    ForEach(linkedDocumentPaths, id: \.self) { docPath in
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Button {
                                openDocument(docPath)
                            } label: {
                                Text(documentTitle(for: docPath))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.borderless)
                            Spacer()
                            Button {
                                removeDocumentLink(docPath)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    // Session 81 (D239) — the SHORTCUT row: the decoded name,
                    // never the raw URL (the name is the only part carrying
                    // information; the rest is boilerplate). Tap runs it;
                    // Change renames it KEEPING every other query item
                    // (rewrittenShortcutURL); the xmark removes it.
                    if shortcutURL != nil {
                        HStack(spacing: 8) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Button {
                                if let url = shortcutURL { UIApplication.shared.open(url) }
                            } label: {
                                Text(shortcutName ?? "Run shortcut")
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.borderless)
                            Spacer()
                            Button("Change") {
                                shortcutText = shortcutName ?? ""
                                showShortcutEntry = true
                            }
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .buttonStyle(.borderless)
                            Button {
                                removeShortcut()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    // **A dialog, not a menu** (D283). This was a `Menu` and
                    // it did not present - David, having tested it: *"they do
                    // nothing thats true."* Fourth confirmed instance, and the
                    // rule is now stated rather than suspected: a `Menu` inside
                    // a sheet's content does not present in this app.
                    // `.confirmationDialog` is not a sheet and presents fine
                    // from inside one.
                    Button { showingLinkKinds = true } label: {
                        Label("Link a person, place, document or web address",
                              systemImage: "link")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .confirmationDialog("Link", isPresented: $showingLinkKinds,
                                        titleVisibility: .visible) {
                        Button("Person") { subSheet = .link(.person) }
                        Button("Place") { subSheet = .link(.place) }
                        // Session 78 — David: "what about adding a link to an
                        // external web address...isnt that a third option?"
                        Button("Web address") { showWebLinkEntry = true }
                        // Session 81 — the fourth kind (D227): a Satchel
                        // document, linked by PATH via a marker line.
                        Button("Document") { subSheet = .document }
                        // Offered only when there is none — a task carries at
                        // most one shortcut, and the row's Change is the door
                        // once it exists (the Mac card's rule).
                        if shortcutURL == nil {
                            Button("Shortcut") {
                                shortcutText = ""
                                showShortcutEntry = true
                            }
                        }
                        Button("Cancel", role: .cancel) { }
                    }
                }

                // Added 2026-07-20 (second pass) — real read/write round-trip
                // to Things' own notes field, prefilled with whatever's
                // actually there. TextEditor has no built-in placeholder, so
                // one is overlaid manually when empty, matching the pattern
                // DayflowQuickAddSheet's own new Notes row uses.
                if let writeMismatch {
                    Section {
                        Text(writeMismatch)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Notes") {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $notes)
                            .frame(minHeight: 90)
                        if notes.isEmpty {
                            Text("Add a note (optional)")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }

                    // Detected links in the notes text — 2026-07-24, David's
                    // ask, after a screenshot showed a `Shortcuts://` URL
                    // sitting inert in this field (he stores quick-action
                    // shortcut links here). Deliberately a separate row below
                    // the TextEditor, not a tap target inside the actively-
                    // edited text itself — no simulator here to verify a more
                    // invasive approach against, and this way normal
                    // typing/editing is completely untouched.
                    ForEach(detectedLinks, id: \.absoluteString) { url in
                        Button {
                            UIApplication.shared.open(url)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "link")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.blue)
                                Text(url.absoluteString)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.blue)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Edit Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .task { endeavorNames = Set(EndeavorFile.nameIndex(from: NoteStore.shared).keys) }
            .dayflowWikiMissAlert($wikiMiss)
            // **ONE `.sheet` on this view.** It had three, which is why the
            // Date row was dead (D283); they were folded into `subSheet` this
            // session and then I added a second one back an hour later for the
            // Linked row, and the console said exactly what it had said
            // before: *"only presenting a single sheet is supported."* The
            // rule is not "avoid three", it is **one host, always**, and a new
            // destination is a case rather than a modifier.
            .sheet(item: $subSheet) { which in
                switch which {
                case .when:
                    // Session 78 round 3 (David, off TestFlight: "Clicking the
                    // date in any task edit gives me a different experience
                    // than the nice feeling I get from the main screens. Its a
                    // week at a time and the view doesnt match") — the old
                    // week-paged DayflowWhenPickerSheet is retired from here;
                    // this is the app's own month language.
                    DayflowDatePickSheet(current: when) { picked in
                        when = picked
                    }
                case .link(let kind):
                    DayflowTaskLinkPicker(kind: kind) { name in
                        appendLink(name)
                    }
                case .document:
                    DayflowTaskDocumentPicker { docPath in
                        appendDocumentLink(docPath)
                    }
                case .record(let target):
                    NavigationStack {
                        DayflowWikiSummaryView(target: target)
                    }
                case .projectNote(let title):
                    NavigationStack {
                        DayflowProjectNoteView(title: title) { subSheet = nil }
                    }
                case .dailyNote(let day):
                    DayflowNoteFullPageView(selectedDate: Binding(
                        get: { day },
                        set: { _ in }
                    ))
                case .endeavor(let id):
                    NavigationStack {
                        DayflowEndeavorView(endeavorID: id)
                    }
                }
            }
            .alert("Satchel isn't installed", isPresented: $satchelUnavailable) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("This document lives in Satchel, the documents app. Install it on this device to open it.")
            }
            .alert("Web address", isPresented: $showWebLinkEntry) {
                TextField("example.com/page", text: $webLinkText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Add") {
                    appendWebLink(webLinkText)
                    webLinkText = ""
                }
                // One tap even on the phone (and immune to the Simulator's
                // separate clipboard, which ate David's first paste): reads
                // the pasteboard directly. iOS shows its paste-permission
                // banner the first time — expected.
                Button("Paste & Add") {
                    appendWebLink(UIPasteboard.general.string ?? "")
                    webLinkText = ""
                }
                Button("Cancel", role: .cancel) { webLinkText = "" }
            }
            .alert("Shortcut", isPresented: $showShortcutEntry) {
                TextField("Shortcut name", text: $shortcutText)
                Button("Save") {
                    applyShortcutName(shortcutText)
                    shortcutText = ""
                }
                Button("Cancel", role: .cancel) { shortcutText = "" }
            } message: {
                Text("The shortcut's name, as it appears in the Shortcuts app. Leave empty to remove it from this task.")
            }
            .task {
                let current = ReminderTaskStore.shared.repeatRule(taskID: taskID)
                repeatRule = current
                initialRepeatRule = current
                if let alarm = ReminderTaskStore.shared.remindDate(taskID: taskID) {
                    remindOn = true
                    remindAt = alarm
                    initialRemindAt = alarm
                } else if let due = initialDate {
                    // Seed the picker somewhere sensible for a fresh toggle:
                    // 9 AM on the due day, the When card's first chip.
                    remindAt = Calendar.current.date(
                        bySettingHour: 9, minute: 0, second: 0, of: due) ?? due
                }
                // Session 81 — after the synchronous seeding, so the repeat
                // and reminder rows never wait on a sidecar sweep. Loaded
                // here so a task opened before any note screen has populated
                // the store still resolves titles rather than "(missing)".
                await chipStore.loadIfNeeded()
            }
        }
    }

    /// The optional list as a non-optional selection, `""` meaning none.
    /// The same mapping `DayflowBookingSheet.statusBinding` makes, for the same
    /// reason: SwiftUI can tag an optional and every call site then has to
    /// spell it, and one that forgets shows an empty picker.
    private var listBinding: Binding<String> {
        Binding(get: { list ?? "" }, set: { list = $0.isEmpty ? nil : $0 })
    }

    // MARK: Linked people/places (Session 78)

    /// **This used to be a binary classifier and it made things up.** It asked
    /// whether the name was a Notion Place and, if not, drew a PERSON glyph and
    /// called it one. David, on a task linked to an endeavor: *"there is no
    /// icon to tell me that the task I called How'd was from an endeavor."*
    /// There was worse than no icon - there was the wrong one, asserting that
    /// Test Trip 2 is a person.
    ///
    /// Same class as the `LinkedRecord` bug D270 found on the Mac and one notch
    /// worse: that one said "Not in People or Places", which is an admission.
    /// This one made a claim.
    ///
    /// Four kinds now, in the Mac's own precedence - place, person, endeavor,
    /// then nothing recognised - so adding endeavors only catches what used to
    /// fall through to a false answer.
    ///
    /// **Warning TWELVE decides the last glyph.** An unrecognised name draws a
    /// plain `link` while Notion is still loading or has failed, and only draws
    /// a question mark once the answer is actually known. A question mark over
    /// a cold launch would be the screen reporting an absence it cannot tell
    /// from ignorance - the rule `unresolvedMessage` on the endeavor screen has
    /// followed since Session 71.
    ///
    /// The scanner is `NoteStore.wikilinkTargets`, the app's own parser, rather
    /// than the hand-rolled `[[`/`]]` walk that was here. That walk was a fifth
    /// opinion about what a link is and it could not read the `[[name|alias]]`
    /// form at all.
    private var linkedNames: [(name: String, icon: String)] {
        let notion = NotionService.shared
        let settled = notion.placesLoad == .loaded && notion.peopleLoad == .loaded
        return NoteStore.wikilinkTargets(in: notes)
            .filter { !$0.hasPrefix("visit:") }
            .map { name in
                if notion.places.contains(where: { $0.name == name }) {
                    return (name, "mappin.and.ellipse")
                }
                if notion.people.contains(where: { $0.name == name }) {
                    return (name, "person")
                }
                if endeavorNames.contains(name) { return (name, "flag") }
                return (name, settled ? "questionmark.circle" : "link")
            }
    }

    /// A bare host gets https:// — URLs in notes are detected by their
    /// scheme, on the row chip and in this sheet both.
    /// Opens a linked record from the Linked section, through the shared
    /// resolver. `openURL` covers notes and endeavors; the record cases hand
    /// back to this sheet's own `wikiLinkTarget` sheet.
    /// **Everything opens INSIDE this sheet, and nothing routes out of it.**
    ///
    /// `follow`'s defaults use `openURL`, which asks the APP to present a
    /// screen - and a sheet cannot ask the app to present something over
    /// itself. The console said so twice while the endeavor link was still
    /// routing: *"only presenting a single sheet is supported. The next sheet
    /// will be presented when the currently presented sheet gets dismissed."*
    /// A queued presentation behind a sheet nobody dismisses is a dead link.
    ///
    /// The alternative was dismiss-then-route, and it is the worse answer
    /// here: `openNote` in `DayflowEndeavorViews` records that a dismissal and
    /// a presentation in the same turn is how the routed destination gets
    /// dropped, and that it has to wait on the presentation's own `onDismiss`
    /// - which the HOST owns, not this sheet. Presenting in place needs no
    /// timing and no cooperation from a file this one should not be reaching
    /// into.
    ///
    /// So this deliberately uses `resolve` rather than `follow`: every case is
    /// answered locally. `follow` stays the right call for hosts that ARE a
    /// screen and can route.
    private func resolveLink(_ name: String) {
        switch DayflowWikiLink.resolve(name) {
        case .place(let place):    subSheet = .record(.place(place))
        case .person(let person):  subSheet = .record(.person(person))
        case .endeavor(let id, _): subSheet = .endeavor(id)
        case .dailyNote(let day):  subSheet = .dailyNote(day)
        case .note(let note):
            // A daily note in the notes list resolves by its own date so the
            // full page opens on the right day; anything else is a project
            // note, opened by title. Same split `openNote` makes on the
            // endeavor screen, for the same reason: those two screens exist
            // and re-implementing either here would be a second answer.
            if note.isDaily, let day = DayflowRelatedNotesEngine.parseDailyNoteDate(note.title) {
                subSheet = .dailyNote(day)
            } else {
                subSheet = .projectNote(note.title)
            }
        case .miss(let miss):      wikiMiss = DayflowWikiMissNotice(name: name, miss: miss)
        }
    }

    private func appendWebLink(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let url = trimmed.contains("://") ? trimmed : "https://" + trimmed
        notes = notes.isEmpty ? url : notes + "\n" + url
    }

    private func appendLink(_ name: String) {
        guard !notes.contains("[[\(name)]]") else { return }
        notes = notes.isEmpty ? "[[\(name)]]" : notes + "\n[[\(name)]]"
    }

    private func removeLink(_ name: String) {
        notes = notes
            .replacingOccurrences(of: "\n[[\(name)]]", with: "")
            .replacingOccurrences(of: "[[\(name)]]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Linked documents (Session 81, D227's iOS half)

    /// The `satchel:doc:` marker lines in the notes text, in order, deduped.
    /// Parsed off `notes` (the live edit), not the task, so a document added
    /// in this visit shows its row before Save.
    private var linkedDocumentPaths: [String] {
        var seen = Set<String>()
        return notes.split(separator: "\n").compactMap { line -> String? in
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix(ThingsTask.documentMarkerPrefix) else { return nil }
            let docPath = String(s.dropFirst(ThingsTask.documentMarkerPrefix.count))
            guard !docPath.isEmpty, seen.insert(docPath).inserted else { return nil }
            return docPath
        }
    }

    /// Live resolution, no cached title — the D227 rule: a chip displaying
    /// one name while pointing at another is worse than one that briefly
    /// says nothing.
    private func documentTitle(for docPath: String) -> String {
        chipStore.all.first { $0.relativePath == docPath }?.title ?? "(missing)"
    }

    private func openDocument(_ docPath: String) {
        guard chipStore.all.contains(where: { $0.relativePath == docPath }),
              let url = TraceSatchelHandoff.documentURL(path: docPath) else { return }
        UIApplication.shared.open(url, options: [:]) { accepted in
            if !accepted { satchelUnavailable = true }
        }
    }

    /// Appended at the end, after whatever prose is there — the composer's
    /// prose-before-machinery order, kept by hand here because this sheet
    /// edits the raw notes text.
    private func appendDocumentLink(_ docPath: String) {
        let marker = ThingsTask.documentMarkerPrefix + docPath
        guard !notes.contains(marker) else { return }
        notes = notes.isEmpty ? marker : notes + "\n" + marker
    }

    private func removeDocumentLink(_ docPath: String) {
        let marker = ThingsTask.documentMarkerPrefix + docPath
        notes = notes
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces) != marker }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Shortcut (Session 81, D239 — the Mac card's treatment)

    /// The shortcut token's range in the live notes text — from the scheme
    /// (any case; RFC 3986, and David's own note reads `Shortcuts://`) to the
    /// first whitespace. The token may share a line with prose, so edits
    /// replace the TOKEN, never the line.
    private var shortcutTokenRange: Range<String.Index>? {
        guard let start = notes.range(of: ThingsTask.shortcutScheme, options: .caseInsensitive)
        else { return nil }
        let token = notes[start.lowerBound...].prefix { !$0.isWhitespace && $0 != "\"" }
        return start.lowerBound..<token.endIndex
    }

    private var shortcutURL: URL? {
        guard let r = shortcutTokenRange else { return nil }
        let raw = notes[r]
        // Lowercase the scheme before building the URL — `URL` keeps whatever
        // case it is given, and not every opener is as forgiving as the spec.
        let normalised = ThingsTask.shortcutScheme + raw.dropFirst(ThingsTask.shortcutScheme.count)
        return URL(string: String(normalised))
    }

    private var shortcutName: String? {
        guard let url = shortcutURL,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        return items.first(where: { $0.name == "name" })?.value
    }

    /// Renaming KEEPS every other query item (`&input=`, `&text=`) — the Mac
    /// card's rewrittenShortcutURL, same reasoning: a Shortcuts URL can carry
    /// more than a name, and rebuilding from the name alone silently drops it
    /// the first time such a shortcut is renamed.
    private func rewrittenShortcutURL(name: String) -> String {
        let encodedFallback = name.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) ?? name
        let plain = "\(ThingsTask.shortcutScheme)run-shortcut?name=\(encodedFallback)"
        guard let url = shortcutURL,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return plain }
        var items = (parts.queryItems ?? []).filter { $0.name != "name" }
        items.insert(URLQueryItem(name: "name", value: name), at: 0)
        parts.queryItems = items
        return parts.string ?? plain
    }

    /// Empty name removes; otherwise the token is rewritten in place, or
    /// appended after the prose when there is none.
    private func applyShortcutName(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            removeShortcut()
            return
        }
        let rewritten = rewrittenShortcutURL(name: name)
        if let r = shortcutTokenRange {
            notes.replaceSubrange(r, with: rewritten)
        } else {
            notes = notes.isEmpty ? rewritten : notes + "\n" + rewritten
        }
    }

    private func removeShortcut() {
        guard let r = shortcutTokenRange else { return }
        notes.removeSubrange(r)
        notes = notes
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
    }

    // MARK: Link detection

    /// Every distinct `scheme://...` token in `notes`, in the order they
    /// first appear. Deliberately a plain whitespace-split + `URL(string:)`
    /// scan rather than `NSDataDetector` — `NSDataDetector`'s `.link` type is
    /// tuned toward recognizable real-world schemes (http/https/mailto/tel),
    /// and whether it reliably recognizes an arbitrary custom app scheme like
    /// `Shortcuts://` isn't something this environment can verify without a
    /// simulator. A direct `URL(string:)` parse succeeds for any well-formed
    /// `scheme://...` string regardless of whether the scheme is "known," so
    /// it's the safer bet for the exact case David hit.
    private var detectedLinks: [URL] {
        var seen = Set<String>()
        var links: [URL] = []
        for token in notes.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            // The shortcut is the SHORTCUT row's job (Session 81, D239): its
            // name shows and runs there, and a second row spelling the raw
            // URL is the redundancy that row exists to remove.
            guard !ThingsTask.isShortcutLine(token) else { continue }
            guard token.contains("://"),
                  let url = URL(string: String(token)),
                  let scheme = url.scheme, !scheme.isEmpty
            else { continue }
            guard seen.insert(url.absoluteString).inserted else { continue }
            links.append(url)
        }
        return links
    }

    private func save() {
        isSaving = true
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        let clearDate: Bool
        let date: Date?
        switch when {
        case .none:
            clearDate = true
            date = nil
        case .date(let d):
            clearDate = false
            date = d
        case .today:
            clearDate = false
            date = Date()
        case .thisEvening, .someday:
            // Things-native buckets /update can't express — clear rather than
            // silently no-op or fake a stand-in date. See header comment.
            clearDate = true
            date = nil
        }

        // Always passed (never nil) — see ThingsService.update()'s doc comment.
        // Trimmed so trailing/leading whitespace-only edits don't register as
        // "notes changed" when they're really just accidental taps.
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        // Reminder deltas (Session 78): a set/changed alarm rides remindAt;
        // switching the toggle off rides clearRemind. Untouched = both nil,
        // the store's carry-the-alarm redate behavior applies as before.
        let remindChanged = remindOn ? (initialRemindAt != remindAt) : (initialRemindAt != nil)
        let remindArg: Date? = (remindOn && remindChanged) ? remindAt : nil
        let clearRemindArg = !remindOn && initialRemindAt != nil
        Task {
            let success = await ReminderTaskStore.shared.update(
                taskID: taskID, title: trimmedTitle, date: date, clearDate: clearDate,
                list: list, notes: trimmedNotes,
                remindAt: remindArg, clearRemind: clearRemindArg
            )
            // Repeat is its own write, only when it changed — and only with
            // a date to anchor to (the reminder without one would produce a
            // rule Reminders can't fire).
            if success, repeatRule != initialRepeatRule, !clearDate {
                _ = await ReminderTaskStore.shared.setRepeat(taskID: taskID, rule: repeatRule)
            }
            await MainActor.run {
                isSaving = false
                if success {
                    writeMismatch = nil
                    onSaved()
                    dismiss()
                } else {
                    // **The sheet stays open and now says why.** Before this it
                    // stayed open and said nothing, which reads as a save that
                    // is still thinking. `lastWriteMismatch` is set only when
                    // the bridge reported success and the value did not take;
                    // any other failure keeps the generic line.
                    writeMismatch = ReminderTaskStore.shared.lastWriteMismatch
                        ?? (ReminderTaskStore.shared.lastError ?? "Reminders did not accept the change.")
                    ReminderTaskStore.shared.lastWriteMismatch = nil
                }
            }
        }
    }
}

// MARK: - Link picker (Session 78)

enum DayflowTaskLinkKind: String, Identifiable {
    case person, place
    var id: String { rawValue }
}

/// A minimal searchable name list — deliberately simpler than the Related
/// Notes flow's candidate picker (no description step: a task link is just
/// the chip; the WHY lives in the task title itself).
struct DayflowTaskLinkPicker: View {
    let kind: DayflowTaskLinkKind
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    /// Session 78 — David: the cursor should land in the search field so he
    /// can just type. (His screenshot was THIS picker, not the Related Notes
    /// one, which got the same fix separately — two pickers, two fixes.)
    @FocusState private var searchFocused: Bool

    private var names: [String] {
        let all: [String]
        switch kind {
        case .person:
            all = NotionService.shared.people.filter { !$0.isArchived }.map(\.name)
        case .place:
            all = NotionService.shared.places.map(\.name)
        }
        let sorted = all.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        guard !search.isEmpty else { return sorted }
        return sorted.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List(names, id: \.self) { name in
                Button {
                    onPick(name)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: kind == .person ? "person" : "mappin.and.ellipse")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(name).foregroundStyle(.primary)
                    }
                }
            }
            .searchable(text: $search)
            .searchFocused($searchFocused)
            .navigationTitle(kind == .person ? "Link a Person" : "Link a Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    searchFocused = true
                }
            }
        }
    }
}

// MARK: - Date pick sheet (Session 78 round 3)
//
// The edit sheet's Date row, in the app's own calendar language:
// Today (sun) / Tomorrow (sunrise) / Clear (slash) rows over the SAME month
// grid the Today masthead unfolds (DayflowMonthUnfold, note and pin dots
// included). Replaces DayflowWhenPickerSheet here — its week-at-a-time view
// was the last date surface out of step with the skin.

struct DayflowDatePickSheet: View {
    let current: DayflowWhenValue
    var onPick: (DayflowWhenValue) -> Void
    @Environment(\.dismiss) private var dismiss

    private var currentDate: Date {
        switch current {
        case .date(let d): return d
        case .today: return Date()
        default: return Date()
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("WHEN")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(Color.dayflowInk)
                    .padding(.bottom, 6)
                Rectangle().fill(Color.dayflowInk).frame(height: 1)
                quickRow("Today", systemImage: "sun.max") { pick(.today) }
                hairline
                quickRow("Tomorrow", systemImage: "sunrise") {
                    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                    pick(.date(Calendar.current.startOfDay(for: tomorrow)))
                }
                hairline
                DayflowMonthUnfold(selectedDate: currentDate, onPick: { day in
                    pick(.date(day))
                }, hint: "tap a day to set it")
                quickRow("Clear date", systemImage: "slash.circle",
                         tint: Color.dayflowAccent) { pick(.none) }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .presentationDetents([.height(600), .large])
        .presentationBackground(Color.dayflowPaper)
    }

    private func pick(_ value: DayflowWhenValue) {
        UISelectionFeedbackGenerator().selectionChanged()
        onPick(value)
        dismiss()
    }

    private var hairline: some View {
        Rectangle().fill(Color.dayflowHairline).frame(height: 1)
    }

    private func quickRow(_ label: String, systemImage: String,
                          tint: Color = .dayflowInk,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 14))
                    .frame(width: 20)
                Text(label)
                    .font(.dayflowSerif(16))
                Spacer()
            }
            .foregroundStyle(tint)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}


// MARK: - Document picker (Session 81, D227's iOS half)

/// Satchel documents, newest first — the linking case is nearly always a
/// document scanned minutes ago, so the one he wants is already on top and
/// the common path needs no search at all (which is also why the search
/// field does NOT autofocus here, unlike the person/place picker: raising
/// the keyboard would cover the list the common path never types into).
/// Single-pick, like the pickers beside it; reopen to add another.
struct DayflowTaskDocumentPicker: View {
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var chipStore = TraceSatchelChipStore.shared

    private var documents: [TraceMacDocument] {
        let sorted = chipStore.all.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
        guard !search.isEmpty else { return sorted }
        return sorted.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List(documents, id: \.relativePath) { doc in
                Button {
                    onPick(doc.relativePath)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "doc.text")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(doc.title)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        if let created = doc.created {
                            Text(created, format: .dateTime.month(.abbreviated).day())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .searchable(text: $search)
            .navigationTitle("Link a Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await chipStore.loadIfNeeded() }
        }
    }
}
