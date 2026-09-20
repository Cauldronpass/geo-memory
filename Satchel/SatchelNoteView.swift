// SatchelNoteView.swift
// Satchel only. D444, Session 107.
//
// **The document's own note, on the phone.** D433 gave every document a note of
// its own, separate from the project link and the endeavor, and D440 started
// writing highlights into it. Until this screen there was nowhere on the phone
// to READ one: the note existed in `Notes/Reading/`, the sidecar pointed at it,
// and Satchel showed no sign of it. David: *"we should ... allow a view of the
// note on a document."*
//
// **Editable, not a preview.** A note he can only look at is a note he cannot
// correct, and the whole point of the reading note is that it becomes his. The
// file is read on open and written on leave, the same shape the reader uses for
// the saved place: no write per keystroke, and nothing written when nothing
// changed.
//
// A plain `TextEditor`. Trace's `MarkdownEditorView` is the richer thing, and
// Satchel does not compile it (its target membership is a short, deliberate
// list); adding it here would be a project-file edit for a screen that holds a
// dozen lines of quotes.

import SwiftUI

struct SatchelNoteView: View {
    let document: TraceMacDocument
    let store: iOSDocumentStore

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var loaded: String = ""
    @State private var path: String = ""
    @FocusState private var writing: Bool

    var body: some View {
        NavigationStack {
            Group {
                if path.isEmpty {
                    ProgressView()
                } else {
                    TextEditor(text: $text)
                        .font(.system(size: 16))
                        .lineSpacing(3)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                        .focused($writing)
                }
            }
            .satchelBackground()
            .navigationTitle("Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
                ToolbarItem(placement: .keyboard) {
                    Spacer()
                }
            }
        }
        .onAppear { load() }
        .onDisappear { save() }
    }

    /// The note this document already has, or the one it would get. **Nothing is
    /// written here**: a note is only created when he types something, so
    /// opening the screen out of curiosity leaves no file behind.
    private func load() {
        let existing: String = document.noteFile ?? ""
        path = existing.isEmpty ? SatchelHighlightNote.path(forTitle: document.title) : existing
        let raw: String = (try? NoteStore.shared.readFile(path)) ?? ""
        text = raw
        loaded = raw
    }

    private func save() {
        guard !path.isEmpty else { return }
        let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != loaded else { return }
        guard !trimmed.isEmpty else { return }
        let body: String = trimmed.hasPrefix("# ") ? trimmed : "# \(document.title)\n\n" + trimmed
        do {
            try NoteStore.shared.writeFile(path, content: body)
            loaded = text
            // Record the link the first time, so Send to note and this screen
            // agree about where the note is.
            if (document.noteFile ?? "").isEmpty {
                let rendered: String = SatchelHighlightText.render(
                    SatchelHighlightText.parse(document.highlightsRaw))
                _ = try? store.writeHighlights(rendered, for: document, noteFile: path)
            }
        } catch {
            // A failed write leaves what he typed on screen rather than
            // pretending it was saved.
        }
    }
}
