//  TraceMacAccountsView.swift
//  TraceMac — the Accounts tab in Directory (D504). Mac only.
//
//  David, 2026-09-23: *"I have been regularly looking at my retirement accounts
//  and manually adding the various accounts up... a simple input screen that
//  would then populate the note."*
//
//  ── The one decision everything else follows from ─────────────────────────
//
//  **The note is the store.** There is no database, no JSON sidecar and no
//  second copy: this screen reads one markdown file to learn his accounts,
//  their groups and their history, and writes the same file on Save. So the
//  thing he reads on his phone IS the thing the Mac wrote, and "push it to my
//  phone" costs nothing — iCloud already carries it and Dayflow already opens
//  it by path.
//
//  **He never opens that file.** The first version of this design was explained
//  through the file and drew the file, and he read it as being asked to type
//  into markdown. The file is an output. This screen is the input.
//
//  ── Blank means carry ─────────────────────────────────────────────────────
//
//  Nothing is pre-filled. A field left empty carries the previous figure and is
//  labelled `carried`, on screen and in the note. Pre-filling would have made a
//  retyped identical number indistinguishable from an untouched one, which is a
//  claim about his data the screen cannot check — the class this project cares
//  about most.
//
//  ── Accounts and groups are data ──────────────────────────────────────────
//
//  Both live in the note, not in this file. He said *"the accounts do not change
//  (when they do I will let you know)"* — he should not have to. Add an account
//  takes a name and a group, and a group name that does not exist creates the
//  group.
//
//  ── Why every account is stored in every snapshot ─────────────────────────
//
//  He asked for a graph later ("*maybe the various account types but that could
//  be another design*"). A history of grand totals cannot draw one. Storing each
//  account's figure per snapshot costs a few lines a month and means the chart,
//  whenever it is built, has months of real data behind it rather than starting
//  from empty. **This is the only part of this build that exists for a screen
//  that does not exist yet**, and it is the cheap half.

import SwiftUI

// MARK: - Model

struct MacAccount: Identifiable, Hashable {
    var group: String
    var name: String
    var id: String { name }
}

struct MacAccountFigure: Hashable {
    var value: Int
    /// True when this figure was carried forward rather than typed that day.
    var carried: Bool
}

struct MacAccountSnapshot: Identifiable {
    /// `yyyy-MM-dd`, which sorts correctly as a string and is what the note shows.
    var date: String
    var figures: [String: MacAccountFigure]
    var id: String { date }

    /// **The sum of what this snapshot holds, not of the accounts that exist
    /// now.** Removing an account should not silently rewrite what last year's
    /// total was.
    var total: Int { figures.values.reduce(0) { $0 + $1.value } }
}

struct MacAccountsBook {
    var accounts: [MacAccount] = []
    /// Oldest first.
    var snapshots: [MacAccountSnapshot] = []

    var latest: MacAccountSnapshot? { snapshots.last }
    var previous: MacAccountSnapshot? {
        snapshots.count >= 2 ? snapshots[snapshots.count - 2] : nil
    }

    /// Groups in the order their first account appears, so the screen and the
    /// note always agree and neither re-sorts under him.
    var groups: [String] {
        var seen: [String] = []
        for a in accounts where !seen.contains(a.group) { seen.append(a.group) }
        return seen
    }

    func accounts(in group: String) -> [MacAccount] {
        accounts.filter { $0.group == group }
    }
}

// MARK: - Money

enum MacMoney {
    private static let display: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    /// `$1,184,400`
    static func dollars(_ value: Int) -> String {
        "$" + (display.string(from: NSNumber(value: value)) ?? "\(value)")
    }

    /// `1,184,400` — for a column that already reads as money.
    static func plain(_ value: Int) -> String {
        display.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// `+$18,400` / `−$4,200`, with the sign carried in words rather than colour
    /// alone.
    static func signed(_ value: Int) -> String {
        value < 0 ? "−" + dollars(-value) : "+" + dollars(value)
    }

    /// **Accepts what a person pastes out of a brokerage page**: `$612,000.00`,
    /// `612000`, `612,000`. Returns nil for anything with no digits in it, which
    /// is what makes an empty field mean "carry" rather than "zero".
    static func parse(_ text: String) -> Int? {
        let kept = text.filter { $0.isNumber || $0 == "." || $0 == "-" }
        guard kept.contains(where: { $0.isNumber }), let d = Double(kept) else { return nil }
        return Int(d.rounded())
    }
}

// MARK: - The file

/// Reads and writes `Notes/Finance/Retirement.md`.
///
/// The note is in two halves. Everything above the marker is written for him and
/// is what his phone shows; the block below it is written for this screen. The
/// block is an HTML comment so a renderer hides it, it sits last so it is out of
/// the way when it is not hidden, and it is one record per line so a half-synced
/// file loses a line rather than the file.
enum MacAccountsFile {

    /// **`Notes/Projects/`, and it moved here after the first try failed in his
    /// hands** (2026-09-23).
    ///
    /// D504 put it in `Notes/Finance/` on a privacy argument I introduced and he
    /// never asked for: a folder the phone does not browse or search does not
    /// surface in front of anyone. The cost turned out to be the whole point of
    /// the feature. The phone's note router answers exactly four prefixes -
    /// `Notes/Endeavors/`, `Notes/Projects/`, `Notes/Horizons/` and `Calendar/` -
    /// and drops everything else silently, so `dayflow://note?path=` brought the
    /// app forward and did nothing. **A note he cannot browse to and cannot link
    /// to is a note he cannot read**, which is the one thing he asked for.
    ///
    /// `Notes/Projects/` browses, searches, and already has a door. If hiding it
    /// is ever worth more than reaching it, the fix is a fifth branch in
    /// `resolveNoteRoute`, not a folder nothing routes to.
    static let path = "Notes/Projects/Retirement.md"

    private static let open  = "<!-- trace-accounts v1"
    private static let close = "-->"

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let readable: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    private static let shortDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "M/d"
        return f
    }()

    static func key(for date: Date) -> String { stamp.string(from: date) }

    static func readableDate(_ key: String) -> String {
        guard let d = stamp.date(from: key) else { return key }
        return readable.string(from: d)
    }

    static func shortDate(_ key: String) -> String {
        guard let d = stamp.date(from: key) else { return key }
        return shortDay.string(from: d)
    }

    /// **A name with a `|` in it would split its own record**, so the separator
    /// is taken out at the door rather than escaped everywhere after it.
    static func clean(_ name: String) -> String {
        name.replacingOccurrences(of: "|", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Parse

    static func parse(_ text: String) -> MacAccountsBook {
        var book = MacAccountsBook()
        guard let opened = text.range(of: open) else { return book }
        let tail = text[opened.upperBound...]
        guard let closed = tail.range(of: close) else { return book }

        var figuresByDate: [String: [String: MacAccountFigure]] = [:]
        var dates: [String] = []

        for raw in tail[..<closed.lowerBound].split(separator: "\n") {
            let parts = raw.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let kind = parts.first else { continue }
            switch kind {
            case "A":
                guard parts.count >= 3, !parts[2].isEmpty else { continue }
                book.accounts.append(MacAccount(group: parts[1], name: parts[2]))
            case "S":
                guard parts.count >= 5, let value = Int(parts[3]) else { continue }
                let date = parts[1]
                if figuresByDate[date] == nil {
                    figuresByDate[date] = [:]
                    dates.append(date)
                }
                figuresByDate[date]?[parts[2]] =
                    MacAccountFigure(value: value, carried: parts[4] == "carried")
            default:
                continue
            }
        }

        book.snapshots = dates.sorted().map {
            MacAccountSnapshot(date: $0, figures: figuresByDate[$0] ?? [:])
        }
        return book
    }

    // MARK: Render

    static func render(_ book: MacAccountsBook) -> String {
        var out = "# Retirement\n\n"

        if let latest = book.latest {
            out += "**\(MacMoney.dollars(latest.total))**\n\n"
            var line = readableDate(latest.date)
            if let prior = book.previous {
                let delta = latest.total - prior.total
                let word = delta < 0 ? "down" : "up"
                line += " · \(word) \(MacMoney.dollars(abs(delta))) since \(shortDate(prior.date))"
            }
            out += line + "\n"

            for group in book.groups {
                let rows = book.accounts(in: group).compactMap { account -> (MacAccount, MacAccountFigure)? in
                    guard let figure = latest.figures[account.name] else { return nil }
                    return (account, figure)
                }
                guard !rows.isEmpty else { continue }
                let subtotal = rows.reduce(0) { $0 + $1.1.value }
                out += "\n## \(group) — \(MacMoney.dollars(subtotal))\n\n"
                for (account, figure) in rows {
                    let carried = figure.carried ? "  *(carried from \(shortDate(lastEntered(account.name, before: latest.date, in: book) ?? latest.date)))*" : ""
                    out += "- \(account.name) — \(MacMoney.dollars(figure.value))\(carried)\n"
                }
            }
        } else {
            out += "_No entries yet._\n"
        }

        if book.snapshots.count > 1 {
            out += "\n## History\n\n| Date | Total | Change |\n|---|---|---|\n"
            var previousTotal: Int? = nil
            var lines: [String] = []
            for snapshot in book.snapshots {
                let change = previousTotal.map { MacMoney.signed(snapshot.total - $0) } ?? "—"
                lines.append("| \(readableDate(snapshot.date)) | \(MacMoney.dollars(snapshot.total)) | \(change) |")
                previousTotal = snapshot.total
            }
            out += lines.reversed().joined(separator: "\n") + "\n"
        }

        out += "\n\(open)\n"
        out += "Written by Trace on the Mac. Edit the numbers there, not here.\n"
        for account in book.accounts {
            out += "A|\(account.group)|\(account.name)\n"
        }
        for snapshot in book.snapshots {
            for account in book.accounts {
                guard let figure = snapshot.figures[account.name] else { continue }
                out += "S|\(snapshot.date)|\(account.name)|\(figure.value)|\(figure.carried ? "carried" : "entered")\n"
            }
        }
        out += "\(close)\n"
        return out
    }

    /// The date a figure was last actually typed, so "carried from 8/15" names
    /// the day the number is really from rather than the last time Save was
    /// pressed. **A carried figure carried twice would otherwise claim to be
    /// newer than it is.**
    private static func lastEntered(_ name: String, before date: String,
                                    in book: MacAccountsBook) -> String? {
        for snapshot in book.snapshots.reversed() where snapshot.date <= date {
            if let figure = snapshot.figures[name], !figure.carried { return snapshot.date }
        }
        return nil
    }
}

// MARK: - The screen

struct TraceMacAccountsView: View {

    @Environment(NoteStore.self) private var noteStore

    @State private var book = MacAccountsBook()
    /// What he has typed this sitting, by account name. Absent or unparseable
    /// means carry.
    @State private var typed: [String: String] = [:]
    @State private var asOf = Date()
    @State private var loaded = false
    @State private var showingEditor = false
    /// Non-nil while editing an existing account; nil while adding one. The
    /// sheet is one sheet because it asks the same two questions either way.
    @State private var editingOriginal: MacAccount? = nil
    @State private var newName = ""
    @State private var newGroup = ""
    @State private var savedMessage: String? = nil
    @State private var errorMessage: String? = nil
    /// Shown inside the sheet rather than behind it, so a name clash is read
    /// next to the field that caused it.
    @State private var sheetError: String? = nil

    private var previousFigures: [String: MacAccountFigure] {
        book.latest?.figures ?? [:]
    }

    private func value(for account: MacAccount) -> Int {
        if let entered = MacMoney.parse(typed[account.name] ?? "") { return entered }
        return previousFigures[account.name]?.value ?? 0
    }

    private func isEntered(_ account: MacAccount) -> Bool {
        MacMoney.parse(typed[account.name] ?? "") != nil
    }

    private func subtotal(_ group: String) -> Int {
        book.accounts(in: group).reduce(0) { $0 + value(for: $1) }
    }

    private var total: Int {
        book.accounts.reduce(0) { $0 + value(for: $1) }
    }

    /// Measured against the newest stored snapshot, which is what "since" means
    /// on screen. Nil when there is nothing to compare with — and **nil prints
    /// nothing**, rather than a change of zero, which would be a claim.
    private var delta: Int? {
        guard let latest = book.latest else { return nil }
        return total - latest.total
    }

    private var carriedCount: Int {
        book.accounts.filter { !isEntered($0) }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if book.accounts.isEmpty {
                    empty
                } else {
                    ForEach(book.groups, id: \.self) { group in
                        groupSection(group)
                    }
                    addButton
                    totalBar
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(MacEditorialType.meta)
                        .foregroundStyle(MacEditorialColor.accent)
                        .padding(.top, 10)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            guard !loaded else { return }
            load()
            loaded = true
        }
        .sheet(isPresented: $showingEditor) { editorSheet }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("AS OF").editorialFieldLabel()
            MacDateField(label: "", date: $asOf)
            if let latest = book.latest {
                Text("Last entry \(MacAccountsFile.readableDate(latest.date))")
                    .font(MacEditorialType.meta)
                    .foregroundStyle(MacEditorialColor.muted)
            }
            Spacer()
            if let savedMessage {
                Text(savedMessage)
                    .font(MacEditorialType.meta)
                    .foregroundStyle(MacEditorialColor.muted)
            }
        }
        .padding(.bottom, 4)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No accounts yet.")
                .font(MacEditorialType.rowTitle)
                .foregroundStyle(MacEditorialColor.muted)
            Text("Add one to start. Names and groups live in the note, so they can change without a build.")
                .font(MacEditorialType.meta)
                .foregroundStyle(MacEditorialColor.muted)
            addButton
        }
        .padding(.top, 24)
    }

    // MARK: A group

    private func groupSection(_ group: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.uppercased())
                    .font(MacEditorialType.sectionLabel)
                    .tracking(MacEditorialType.sectionTracking)
                    .foregroundStyle(MacEditorialColor.ink)
                Spacer()
                Text(MacMoney.dollars(subtotal(group)))
                    .font(MacEditorialType.time)
                    .foregroundStyle(MacEditorialColor.muted)
            }
            .padding(.bottom, 5)
            MacEditorialRule.hair

            ForEach(book.accounts(in: group)) { account in
                accountRow(account)
                MacEditorialRule.hair
            }
        }
        .padding(.top, 18)
    }

    private func accountRow(_ account: MacAccount) -> some View {
        let entered = isEntered(account)
        let prior = previousFigures[account.name]?.value
        return HStack(spacing: 12) {
            // **The pencil is drawn, not hidden behind a right-click.**
            // D505 shipped this as a context menu on the name alone and David's
            // next question was "where is the edit" - the same answer the Visits
            // clock glyph earned earlier the same day. A control nobody can see
            // is a control that is not there. The context menu stays, on the
            // whole row rather than on four characters of text, for whoever
            // reaches for it.
            HStack(spacing: 6) {
                Text(account.name)
                    .font(MacEditorialType.fieldValue)
                    .foregroundStyle(MacEditorialColor.ink)
                Button {
                    beginEdit(account)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(MacEditorialColor.faint)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Rename this account or move it to another group")
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(prior.map { "was \(MacMoney.plain($0))" } ?? "new")
                .font(MacEditorialType.meta)
                .foregroundStyle(MacEditorialColor.faint)
                .frame(width: 120, alignment: .trailing)

            TextField("", text: Binding(
                get: { typed[account.name] ?? "" },
                set: { typed[account.name] = $0 }
            ))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .font(MacEditorialType.fieldValue)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(MacEditorialColor.paper, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(entered ? MacEditorialColor.accent : MacEditorialColor.hairline,
                                  lineWidth: 1)
            }
            .frame(width: 132)

            Text(entered ? "updated" : (prior == nil ? "not set" : "carried"))
                .font(MacEditorialType.meta)
                .foregroundStyle(entered ? MacEditorialColor.accent : MacEditorialColor.muted)
                .frame(width: 74, alignment: .leading)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Edit…") { beginEdit(account) }
            Button("Remove \(account.name)", role: .destructive) { remove(account) }
        }
    }

    private var addButton: some View {
        Button {
            editingOriginal = nil
            newName = ""
            newGroup = book.groups.last ?? ""
            showingEditor = true
        } label: {
            Text("+ Add an account")
                .font(MacEditorialType.meta)
                .foregroundStyle(MacEditorialColor.muted)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(MacEditorialColor.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
        }
        .buttonStyle(.plain)
        .padding(.top, 10)
    }

    // MARK: Total

    private var totalBar: some View {
        VStack(spacing: 0) {
            MacEditorialRule.ink
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TOTAL").editorialFieldLabel()
                    Text(MacMoney.dollars(total))
                        .font(.system(size: 29, weight: .semibold, design: .serif))
                        .monospacedDigit()
                        .foregroundStyle(MacEditorialColor.ink)
                    if let delta, let latest = book.latest {
                        Text("\(MacMoney.signed(delta)) since \(MacAccountsFile.shortDate(latest.date))")
                            .font(MacEditorialType.meta)
                            .foregroundStyle(MacEditorialColor.accent)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(book.accounts.isEmpty)
                    Text("Writes the note. \(carriedCount) of \(book.accounts.count) carried.")
                        .font(MacEditorialType.meta)
                        .foregroundStyle(MacEditorialColor.muted)
                }
            }
            .padding(.top, 13)
        }
        .padding(.top, 22)
    }

    // MARK: Add sheet

    private var editorSheet: some View {
        let isEdit = editingOriginal != nil
        return VStack(alignment: .leading, spacing: 14) {
            Text(isEdit ? "Edit account" : "Add an account")
                .font(MacEditorialType.subject)
            if isEdit {
                // Said plainly, because a rename that quietly orphaned this
                // account's past figures would be the worst outcome here and is
                // exactly what the naive version does.
                Text("Renaming carries every past figure with it. History is kept.")
                    .font(MacEditorialType.meta)
                    .foregroundStyle(MacEditorialColor.muted)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("NAME").editorialFieldLabel()
                TextField("Fidelity 401(k)", text: $newName)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("GROUP").editorialFieldLabel()
                TextField("Employer plans", text: $newGroup)
                    .textFieldStyle(.roundedBorder)
                if !book.groups.isEmpty {
                    // Existing groups offered rather than remembered: a typo
                    // here silently makes a second group beside the right one,
                    // which is the D491 duplicate-list shape on a smaller scale.
                    HStack(spacing: 6) {
                        ForEach(book.groups, id: \.self) { group in
                            Button(group) { newGroup = group }
                                .buttonStyle(.link)
                                .font(MacEditorialType.meta)
                        }
                    }
                }
            }
            if let sheetError {
                Text(sheetError)
                    .font(MacEditorialType.meta)
                    .foregroundStyle(MacEditorialColor.accent)
            }
            HStack {
                Spacer()
                Button("Cancel") { showingEditor = false; sheetError = nil }
                Button(isEdit ? "Save" : "Add") { commitEditor() }
                    .buttonStyle(.borderedProminent)
                    .disabled(MacAccountsFile.clean(newName).isEmpty
                              || MacAccountsFile.clean(newGroup).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    // MARK: Actions

    private func load() {
        let text = (try? noteStore.readFile(MacAccountsFile.path)) ?? ""
        book = MacAccountsFile.parse(text)
    }

    private func beginEdit(_ account: MacAccount) {
        editingOriginal = account
        newName = account.name
        newGroup = account.group
        sheetError = nil
        showingEditor = true
    }

    /// Adds a new account, or renames and re-groups an existing one.
    ///
    /// **A rename has to carry the history with it**, because every stored
    /// figure is keyed by the account's name. Renaming the account alone would
    /// leave its past figures filed under a name nothing refers to: the row
    /// would read "new", the previous balance would vanish, the totals of every
    /// past snapshot would stay right, and nothing on screen would say why. That
    /// is a screen making a claim it cannot support, and it is the whole reason
    /// this is more than two lines.
    private func commitEditor() {
        let name = MacAccountsFile.clean(newName)
        let group = MacAccountsFile.clean(newGroup)
        guard !name.isEmpty, !group.isEmpty else { return }

        let clash = book.accounts.contains {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
                && $0.name != editingOriginal?.name
        }
        guard !clash else {
            // In the sheet, not behind it: he is looking at the field he has to
            // change.
            sheetError = "There is already an account called \(name)."
            return
        }

        if let original = editingOriginal {
            guard let index = book.accounts.firstIndex(where: { $0.name == original.name }) else { return }
            book.accounts[index] = MacAccount(group: group, name: name)
            if name != original.name {
                for i in book.snapshots.indices {
                    if let figure = book.snapshots[i].figures.removeValue(forKey: original.name) {
                        book.snapshots[i].figures[name] = figure
                    }
                }
                // What he has typed this sitting and not yet saved moves too.
                if let inFlight = typed.removeValue(forKey: original.name) {
                    typed[name] = inFlight
                }
            }
        } else {
            book.accounts.append(MacAccount(group: group, name: name))
        }

        showingEditor = false
        editingOriginal = nil
        sheetError = nil
        persistStructure()
    }

    /// **Removes it from the list going forward and leaves history alone.** Past
    /// snapshots keep their figures and their totals, because what the total was
    /// in July is not changed by closing an account in September.
    private func remove(_ account: MacAccount) {
        book.accounts.removeAll { $0.name == account.name }
        typed[account.name] = nil
        persistStructure()
    }

    /// **The account list is configuration; the balances are an entry.** Adding,
    /// renaming, re-grouping or removing writes the note straight away, so a
    /// rename cannot be lost by closing the tab before Save. Figures still wait
    /// for Save, because a half-typed column is not a snapshot.
    ///
    /// No new snapshot is created here - `render` rewrites the file from the
    /// accounts and the history it already has.
    private func persistStructure() {
        do {
            try noteStore.writeFile(MacAccountsFile.path, content: MacAccountsFile.render(book))
            errorMessage = nil
        } catch {
            errorMessage = "Could not write the note: \(error.localizedDescription)"
        }
    }

    private func save() {
        let date = MacAccountsFile.key(for: asOf)
        var figures: [String: MacAccountFigure] = [:]
        for account in book.accounts {
            let entered = MacMoney.parse(typed[account.name] ?? "")
            let value = entered ?? previousFigures[account.name]?.value ?? 0
            figures[account.name] = MacAccountFigure(value: value, carried: entered == nil)
        }

        var updated = book
        // Saving twice on one date replaces rather than appends: a corrected
        // typo should not leave a false step in the history.
        updated.snapshots.removeAll { $0.date == date }
        updated.snapshots.append(MacAccountSnapshot(date: date, figures: figures))
        updated.snapshots.sort { $0.date < $1.date }

        do {
            try noteStore.writeFile(MacAccountsFile.path,
                                    content: MacAccountsFile.render(updated))
            book = updated
            typed = [:]
            errorMessage = nil
            savedMessage = "Saved \(MacAccountsFile.readableDate(date))"
        } catch {
            // Said on the screen rather than swallowed: a Save that looks like it
            // worked and did not is the thing this project keeps writing down.
            errorMessage = "Could not write the note: \(error.localizedDescription)"
            savedMessage = nil
        }
    }
}
