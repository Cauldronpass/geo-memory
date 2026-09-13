import SwiftUI

// MARK: - DayflowWeekNoteView
//
// The week note on the phone (D394, Session 103). `Notes/Horizons/YYYY-Www.md`
// had no phone surface at all: the Mac's Days list opens one from its week rule
// (D255), and Dayflow drew the same headings deliberately inert because the
// phone's note editor is date-shaped all the way down and a week note is a
// file, not a date.
//
// **The screen exists because the file has two halves and only one of them is
// David's.** The bullets above the `---` are his. Everything below the rule is
// the Check-in Log, written by `NoteStore.appendToWeeklyCheckInLog` from this
// same phone, from a geofence, with no idea a screen has the file open. A
// screen that read the whole file, held it while he typed and wrote it back
// would silently swallow any check-in that landed in between: the D348 class
// exactly, a loss with nothing on screen to show it happened.
//
// So this screen edits the head and splices. It never writes the tail it
// displays; on every save it re-reads the file from disk, recomputes the
// boundary against THAT content, and puts its edited head in front of whatever
// the log now says. A check-in that arrived mid-edit survives, and the band
// below refreshes to show it.
//
// **Why not `DayflowNoteFullPageView`.** D394's logged recommendation was to
// teach the full-page daily editor to take a relative path as well as a date.
// Reading it says otherwise: it is date-bound throughout, with a `@Binding
// selectedDate` shared with ContentView, a Today/Tomorrow pill, and a calendar
// picker that jumps it to any day. A week is none of those things, and bending
// that screen would have left three pieces of date chrome pointing at a file
// with no date. `DayflowProjectNoteView` is the right shape (a full page keyed
// by a name rather than a day) and this screen is built to its pattern, but as
// its own file rather than a generalisation of it: a project note carries
// endeavors, an agenda anchor and promoted tasks, none of which a week note
// has, and the splice below is the opposite of that screen's
// write-the-whole-file save.
//
// Dayflow/ is a buildable folder, so this file needs no `project.pbxproj` edit.

struct DayflowWeekNoteView: View {
    /// `Notes/Horizons/2026-W37.md`.
    let relativePath: String
    var onBack: () -> Void

    /// The half David writes: everything above the `---` rule, title line
    /// removed. The ONLY thing the editor is bound to.
    @State private var headText: String = ""
    /// The half the check-in writer owns: the `---` rule and everything under
    /// it, shown read-only. Never edited here and never composed here, only
    /// ever copied forward from the file as it stands at save time.
    @State private var tail: String = ""
    /// The file's own `# ` line, kept exactly as the writer spelled it so a
    /// save cannot quietly restyle the heading.
    @State private var fileTitle: String?
    @State private var isLoading = true
    /// The log band starts open. "Can I see the week note on iOS" was the ask
    /// and the check-ins are most of what is in one; tapping the band's header
    /// hands the whole screen to the editor when there is writing to do.
    @State private var logShown = true

    private var stem: String {
        ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// The Monday of this week, used only to NAME a file that does not exist
    /// yet. Reading it back out of the stem rather than off the clock is what
    /// keeps this screen and the check-in writer from ever disagreeing about
    /// which week they are looking at (Session 89's one-definition rule).
    private var weekDate: Date { NoteStore.weekStart(fromStem: stem) ?? Date() }

    private var displayTitle: String { fileTitle ?? NoteStore.weekLabel(for: weekDate) }

    private var isFlagged: Bool { DayflowFlagStore.shared.isFlagged(relativePath) }

    /// How many check-ins the log holds, for the band's header. Counts entry
    /// lines, not the bold day sub-headers.
    private var checkInCount: Int {
        tail.components(separatedBy: "\n").filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("**") && t.contains("\u{2014}")
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    VStack(alignment: .leading, spacing: 0) {
                        // **A definite height, not a flexible one.** An editor
                        // inside a scrolling parent collapses to nothing; this
                        // screen sidesteps that by never nesting the two, and
                        // by handing the editor a real number either way.
                        MarkdownEditorView(
                            text: $headText,
                            onSave: { newText in save(newText) },
                            placeholder: "What this week is about.",
                            relativePath: relativePath
                        )
                        .frame(height: logShown
                               ? max(170, geo.size.height * 0.45)
                               : geo.size.height)

                        if logShown {
                            logBand(maxHeight: geo.size.height * 0.55)
                        }
                    }
                }
            }
        }
        .background(Color.dayflowPaper.ignoresSafeArea())
        .task { await load() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    DayflowFlagStore.shared.toggleFlag(relativePath)
                } label: {
                    Image(systemName: isFlagged ? "pin.fill" : "pin")
                        .font(.system(size: 13))
                        .foregroundStyle(isFlagged ? Color.dayflowInk : .secondary)
                        .frame(width: 28, height: 28)
                        .background(.quaternary.opacity(0.6), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFlagged ? "Unpin this week" : "Pin this week")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            VStack(alignment: .leading, spacing: 4) {
                Text("WEEK")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(2.2)
                    .foregroundStyle(Color.dayflowAccent)
                Text(displayTitle)
                    .font(.dayflowSerif(26, weight: .heavy))
                    .foregroundStyle(Color.dayflowInk)
                    .lineLimit(2)
                Rectangle().fill(Color.dayflowInk).frame(height: 1)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 24)
            .padding(.top, 2)
        }
        .padding(.bottom, 2)
    }

    // MARK: The read-only half

    /// **Read-only on purpose, and it says so.** The band's subtitle is not
    /// decoration: a screen that showed this text in the same editor as the
    /// bullets would be inviting an edit it then throws away on the next
    /// check-in. Wikilinks are drawn as the file spells them, brackets and all,
    /// rather than styled as links: nothing here is tappable yet, and text that
    /// looks tappable and is not is the same lie in a smaller font.
    private func logBand(maxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Color.dayflowHairline).frame(height: 1)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { logShown.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(checkInCount > 0 ? "CHECK-IN LOG (\(checkInCount))" : "CHECK-IN LOG")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.8)
                        .foregroundStyle(Color.dayflowFaint)
                    Text("written by your check-ins")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.dayflowFaint.opacity(0.7))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.dayflowFaint)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            ScrollView {
                Text(logText)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.dayflowInk.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
            }
            .frame(maxHeight: maxHeight)
        }
    }

    /// The tail with its leading `---` rule and the `Check-in Log:` marker
    /// removed: the band's own header already says both of those things, and
    /// repeating them costs two lines of a small screen.
    private var logText: String {
        var lines = tail.components(separatedBy: "\n")
        while let first = lines.first {
            let t = first.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t == NoteStore.weekLogRule || t == NoteStore.weekLogMarker {
                lines.removeFirst()
            } else {
                break
            }
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "No check-ins this week yet." : text
    }

    // MARK: Load and save

    private func load() async {
        isLoading = true
        let raw = (try? NoteStore.shared.readFile(relativePath)) ?? ""
        let parts = Self.split(raw)
        fileTitle = parts.title
        headText = parts.head.trimmingCharacters(in: .newlines)
        tail = parts.tail
        isLoading = false
    }

    private func save(_ edited: String) {
        headText = edited
        // **Re-read before writing, every time.** This is the whole reason the
        // screen is shaped this way. The copy loaded at open is already stale
        // the moment a geofence fires, and the check-in writer does not know
        // this screen exists.
        let fresh = (try? NoteStore.shared.readFile(relativePath)) ?? ""
        // **Reading a week must not create one.** The Days list used to refuse
        // to open a week at all because the check-in writer mints a file from a
        // template when one is missing, and a screen that did the same would
        // scatter empty scaffolds across iCloud for every week browsed. Opening
        // writes nothing; an empty edit on a file that does not exist writes
        // nothing either.
        if fresh.isEmpty, edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        let source = fresh.isEmpty ? NoteStore.weekTemplate(for: weekDate) : fresh
        let parts = Self.split(source)

        let titleLine = "# " + (parts.title ?? NoteStore.weekLabel(for: weekDate))
        var out = titleLine + "\n\n" + edited.trimmingCharacters(in: .newlines)
        let freshTail = parts.tail.trimmingCharacters(in: .newlines)
        if !freshTail.isEmpty {
            out += "\n\n" + freshTail
        }
        if !out.hasSuffix("\n") { out += "\n" }

        try? NoteStore.shared.writeFile(relativePath, content: out)

        // Show whatever arrived while he was typing, rather than leaving the
        // band displaying the copy from open.
        fileTitle = parts.title
        tail = parts.tail
    }

    // MARK: The split

    /// Cut a week note into the half David writes and the half the check-in
    /// writer owns.
    ///
    /// **The boundary is the `---` immediately above the `Check-in Log:`
    /// marker, never simply the first `---` in the file.** A horizontal rule
    /// typed in his own notes would otherwise hand the rest of his writing to
    /// the read-only side, where the next save copies it back verbatim below a
    /// line he did not put there: his text, still on disk, now living in the
    /// machine's half and no longer editable from this screen.
    ///
    /// A file with no marker at all has no log yet, so the whole body is his.
    static func split(_ raw: String) -> (title: String?, head: String, tail: String) {
        var lines = raw.components(separatedBy: "\n")
        var title: String?
        if let first = lines.first, first.hasPrefix("# ") {
            title = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            lines.removeFirst()
        }
        guard let markerIdx = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(NoteStore.weekLogMarker)
        }) else {
            return (title, lines.joined(separator: "\n"), "")
        }
        // Walk back over blank lines only. Anything else between the rule and
        // the marker means this is not the template's separator, so the marker
        // itself becomes the boundary and nothing of his is captured.
        var boundary = markerIdx
        var i = markerIdx - 1
        while i >= 0 {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t == NoteStore.weekLogRule { boundary = i; break }
            if !t.isEmpty { break }
            i -= 1
        }
        let head = lines[0..<boundary].joined(separator: "\n")
        let tail = lines[boundary...].joined(separator: "\n")
        return (title, head, tail)
    }
}

extension DayflowWeekNoteView {
    /// Open the week a date falls in. Declared in an extension so the
    /// memberwise initializer above survives.
    init(date: Date, onBack: @escaping () -> Void) {
        self.init(relativePath: NoteStore.weekPath(for: date), onBack: onBack)
    }
}
