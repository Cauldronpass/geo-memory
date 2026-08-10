// DayflowNoteTags.swift
// Dayflow
//
// Tags on a note, as pills beside the document chips.
//
// WHERE TAGS LIVE, and why. David asked for "a definitive place for tags in the
// note itself rather than anywhere in the note", then rejected a line under the
// title as distracting while writing: *"can we add it as a pill by the document
// pills? I would press a button and tag options are available including 'add a
// tag'."*
//
// So the interface is pills, and the storage is **one line at the end of the
// note's prose**. Three alternatives were considered:
//
//   - Frontmatter (`tags: [travel, japan]`). Unambiguous, and how Endeavors carry
//     their fields — but daily and project notes have no frontmatter anywhere in
//     this vault, and that format is shared with Trace's editor. Adding it means a
//     format migration across two apps for a feature that does not need one.
//   - A side-car JSON keyed by path, the way `DayflowFlagStore` holds pins. Clean,
//     no format change — but tags would be invisible in Trace, invisible in
//     Obsidian, and the existing `#tag` search would stop finding them.
//   - Anywhere in the body, no canonical place. What he explicitly asked to move
//     away from.
//
// A trailing line keeps tags IN the file, so Trace renders them, Obsidian sees
// them, and `DayflowNotesView`'s existing `#tag` search keeps working with no new
// index. It also hides nothing: the invisible-character bug fixed in
// `MarkdownEditorView` on 2026-07-30 is a standing argument against storing
// anything the user cannot see.
//
// And the direction is the safe one. Moving from a body line to a side file later
// is a read; moving from a side file back into the body is a migration.
//
// THE READING RULE, which has to be stated exactly or it becomes folklore: the
// tag line is the **last non-empty line of the editor's text**, and only when
// every token on it is a `#tag`. A `#tag` typed mid-prose still renders purple and
// is still found by search — it simply is not a pill. That is the price of a
// canonical place, and it is a smaller price than tags scattered through prose.
//
// NOT the last line of the FILE. `DayflowProjectNoteView` appends a serialized
// Related Notes table after the prose when composing the file, so "last line of
// the file" would sometimes be that table. The editor's text is prose only in all
// three hosts, which makes it the stable thing to anchor on.

import SwiftUI

// MARK: - The canonical line

// Every member is `nonisolated`: this is pure string manipulation with no actor
// involvement, and under the project's default main-actor isolation it would
// otherwise be MainActor-bound — which produced "Call to main actor-isolated
// static method 'normalize' in a synchronous nonisolated context" the moment
// `apply` passed it to `map`, a nonisolated generic. Marking the members is the
// honest fix; hopping to the main actor to lowercase a string would not be.
enum NoteTagLine {

    /// Tags on the note, without their `#`. Empty when the last line is prose.
    nonisolated static func parse(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        guard let last = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              isTagLine(last)
        else { return [] }

        return tokens(last).map { String($0.dropFirst()) }
    }

    /// Returns `text` with its tag line replaced by `tags` (or removed when empty).
    ///
    /// Idempotent on purpose: it strips the existing line before appending, so
    /// applying twice cannot leave two tag lines. Anything that writes a
    /// well-known line into a file a human also edits has to be able to survive
    /// its own previous output.
    nonisolated static func apply(_ tags: [String], to text: String) -> String {
        var lines = text.components(separatedBy: "\n")

        // Drop the existing tag line and any blank lines that were holding it off
        // the prose, so removing every tag does not leave a gap behind.
        if let index = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           isTagLine(lines[index]) {
            lines.removeSubrange(index..<lines.count)
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeLast()
            }
        } else {
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeLast()
            }
        }

        let cleaned = tags
            .map(normalize)
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { out, tag in
                // Case-insensitive dedupe, first spelling wins. "#Japan" and
                // "#japan" are one tag to a human and must be one here too.
                if !out.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                    out.append(tag)
                }
            }

        guard !cleaned.isEmpty else {
            return lines.joined(separator: "\n")
        }

        let line = cleaned.map { "#\($0)" }.joined(separator: " ")
        if lines.isEmpty { return line }
        return lines.joined(separator: "\n") + "\n\n" + line
    }

    /// A tag as it is written: no `#`, no spaces, no leading punctuation.
    ///
    /// Spaces become hyphens rather than being rejected — David typing "open
    /// items" should get `#open-items`, not an error message.
    nonisolated static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let collapsed = trimmed
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return collapsed.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    nonisolated private static func tokens(_ line: String) -> [String] {
        line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
    }

    /// True only when EVERY token is a tag. One stray word and the line is prose
    /// that happens to mention a tag, which must not be swallowed by an edit.
    nonisolated private static func isTagLine(_ line: String) -> Bool {
        let parts = tokens(line)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { $0.hasPrefix("#") && $0.count > 1 }
    }
}

// MARK: - The bar

/// Pills for the note's tags, plus the button that changes them, plus (optionally)
/// the attach button at the trailing edge.
///
/// Sits beside `SatchelDocumentChips` on every note screen that has one, because
/// "what is attached to this note" and "what is this note about" are the same kind
/// of question and belong in the same band of the screen.
///
/// **Writes through the host's own save path**, via `text` and `onCommit`, rather
/// than writing the file itself. Editing the file behind a live editor is the bug
/// that made Satchel overwrite Trace's titles on 2026-07-28: two writers, one
/// file, last one wins. Here there is still exactly one writer.
struct DayflowNoteTagBar: View {

    @Binding var text: String
    let onCommit: (String) -> Void
    /// Optional attach control, drawn at the trailing edge of this row.
    ///
    /// It is here rather than on a row of its own because this band is already
    /// the note's chrome — what the note is about, what is attached to it — and
    /// a second row for one button is the real-estate complaint that kept the
    /// Add Document bar off the home card. Optional so a host without a
    /// `MarkdownEditorView` to drive can leave it out; nil draws nothing.
    var attach: Binding<MarkdownAttachKind?>? = nil

    @State private var showingAdd = false
    @State private var draft = ""

    private var tags: [String] { NoteTagLine.parse(text) }

    /// Tags used anywhere in the vault, minus the ones already on this note.
    /// Sourced from `TagIndex`, the same index that backs `#` autocomplete in the
    /// editor, so the menu cannot offer a different vocabulary from the one
    /// typing offers.
    private var suggestions: [String] {
        let mine = Set(tags.map { $0.lowercased() })
        return TagIndex.shared.allTags()
            .filter { !mine.contains($0.lowercased()) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                // `.systemPurple`, matching `MarkdownTextStorage.styleTag` exactly
                // (line ~610) rather than SwiftUI's `Color.purple`, which is a
                // different hue. A tag should not change colour depending on
                // whether you are looking at the pill or the text.
                Text("#\(tag)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .systemPurple))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(uiColor: .systemPurple).opacity(0.12), in: Capsule())
            }

            Menu {
                if !tags.isEmpty {
                    // "Remove #travel", not "#travel" with a checkmark.
                    //
                    // A checked row that untoggles is a standard iOS idiom and it
                    // was still wrong here: David could not find how to remove a
                    // tag at all. The idiom only reads as a toggle once you are
                    // *in* the menu knowing that is what you came for — and the
                    // thing that got him there, a bare `#` glyph, did not look
                    // like a control. Naming the verb removes the guess.
                    Section("On this note") {
                        ForEach(tags, id: \.self) { tag in
                            Button(role: .destructive) {
                                toggle(tag)
                            } label: {
                                Label("Remove #\(tag)", systemImage: "minus.circle")
                            }
                        }
                    }
                }
                if !suggestions.isEmpty {
                    Section("Used elsewhere") {
                        // Capped. The menu is for picking, not for browsing the
                        // whole vocabulary — a menu long enough to scroll is worse
                        // than typing the tag.
                        ForEach(suggestions.prefix(12), id: \.self) { tag in
                            Button("#\(tag)") { toggle(tag) }
                        }
                    }
                }
                Divider()
                Button {
                    draft = ""
                    showingAdd = true
                } label: {
                    Label("Add a tag…", systemImage: "plus")
                }
            } label: {
                // ALWAYS carries a word. It used to collapse to a bare `#` as soon
                // as the note had any tags — which is exactly when you next need
                // it, and exactly when it stopped looking like a button. The pills
                // beside it are not tappable (they are state, the button is the
                // action — the same split as the Kit chip in Satchel's viewer), so
                // if this does not read as a control there is no way in at all.
                HStack(spacing: 3) {
                    Image(systemName: "number")
                        .font(.system(size: 10, weight: .bold))
                    Text(tags.isEmpty ? "Tag" : "Edit")
                        .font(.system(size: 11.5, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .opacity(0.7)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.10), in: Capsule())
            }

            Spacer(minLength: 0)

            // Trailing edge, opposite the tag controls: state and "what is this
            // note about" on the left, "put something into it" on the right.
            //
            // Carries the word "Attach" and a chevron for the same reason the
            // tag button now always carries a word — a bare glyph did not read
            // as a control, and this button exists precisely because the last
            // paperclip in this app was unreachable.
            if let attach {
                Menu {
                    Button {
                        attach.wrappedValue = .camera
                    } label: { Label("Take Photo", systemImage: "camera") }
                    Button {
                        attach.wrappedValue = .library
                    } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                    Button {
                        attach.wrappedValue = .scan
                    } label: { Label("Camera Scan", systemImage: "doc.viewfinder") }
                    Button {
                        attach.wrappedValue = .pdf
                    } label: { Label("PDF from Files", systemImage: "doc.badge.plus") }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 10, weight: .bold))
                        Text("Attach")
                            .font(.system(size: 11.5, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .opacity(0.7)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.10), in: Capsule())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .alert("Add a tag", isPresented: $showingAdd) {
            TextField("travel", text: $draft)
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) { draft = "" }
            Button("Add") { add(draft) }
        } message: {
            Text("No # needed. Spaces become hyphens.")
        }
    }

    // MARK: Editing

    /// Adds when absent, removes when present. One action for both, because the
    /// menu shows a checkmark for what is on the note — a separate "remove" list
    /// would be a second place to keep in step.
    private func toggle(_ tag: String) {
        let name = NoteTagLine.normalize(tag)
        guard !name.isEmpty else { return }

        var current = NoteTagLine.parse(text)
        if let index = current.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            current.remove(at: index)
        } else {
            current.append(name)
            TagIndex.shared.add(name)
        }
        write(current)
    }

    private func add(_ raw: String) {
        let name = NoteTagLine.normalize(raw)
        draft = ""
        guard !name.isEmpty else { return }
        var current = NoteTagLine.parse(text)
        guard !current.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        current.append(name)
        TagIndex.shared.add(name)
        write(current)
    }

    private func write(_ tags: [String]) {
        let updated = NoteTagLine.apply(tags, to: text)
        guard updated != text else { return }
        text = updated
        onCommit(updated)
    }
}
