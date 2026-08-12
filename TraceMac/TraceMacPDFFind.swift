// TraceMacPDFFind.swift
// Paints the search term inside the PDF you just opened, and steps through the hits.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.
//
// ── What this can and cannot highlight, measured ──────────────────────────
//
// `PDFDocument.findString` searches the **text layer**. A PDF that has one — a
// bill, a statement, a rehearsal sheet exported from a word processor — is
// highlighted exactly. A phone-scanned page has no text layer, which is the
// whole reason `MacTextExtraction` OCRs it, and there is nothing here for
// PDFKit to find. Same for a PNG screenshot.
//
// Counted against David's own Satchel rather than assumed: **six of eight PDFs
// carry a text layer.** The two that do not are `2026-07-28-scan` and
// `2026-08-01-scan`, both from the phone scanner. Those two and the eight
// screenshots are found by search and read in the panel; they are just not
// painted.
//
// **So the chip says how many it found, including zero.** A document that opens
// with nothing highlighted, after a search that clearly matched it, otherwise
// reads as a broken highlighter rather than as a page with no text layer — and
// the user has no way to tell those apart. See `emptyReason`.
//
// Making the other case work means storing Vision's bounding boxes at
// extraction time and drawing overlay rectangles: a sidecar format change and a
// new overlay view. Deliberately not built yet.

import AppKit
import PDFKit

/// The find state for one open PDF.
///
/// Modelled on `PreviewZoomController`, which is the established way this app
/// talks to the `PDFView`: `@Observable` rather than `ObservableObject`
/// (TraceMac has never imported Combine, and reaching for it cost a build
/// once), a weak `@ObservationIgnored` reference to the AppKit view, and no
/// `@MainActor` annotation because every caller is already on the main thread.
@Observable
final class MacPDFFind {

    /// What to look for. Set by the search panel's hand-off; cleared when the
    /// user dismisses the chip or opens a different document by hand.
    var query: String = ""

    private(set) var matches: [PDFSelection] = []
    /// Zero-based index into `matches`.
    private(set) var current: Int = 0
    /// True once a search has actually run against a loaded document, which is
    /// what separates "no hits" from "not searched yet".
    private(set) var didRun = false

    /// The document this query was aimed at, container-relative.
    ///
    /// The list clears the highlight when you select something else by hand,
    /// and it needs to tell that from the selection the deep link itself just
    /// made. Comparing paths says so directly. The alternative — checking
    /// whether the pending deep-link binding is still set — depends on
    /// `onChange` running before the task that clears it, which is a race, and
    /// races of exactly this shape are what the binding pattern replaced four
    /// `asyncAfter` delays to remove.
    @ObservationIgnored var targetPath: String?

    @ObservationIgnored private weak var view: PDFView?
    /// The query the current `matches` were produced from. Guards against
    /// re-running the search on every SwiftUI update pass.
    @ObservationIgnored private var applied: String?

    var count: Int { matches.count }
    var isShowing: Bool { didRun && !query.isEmpty }

    /// Why the chip is showing zero. `nil` when there is nothing to explain.
    var emptyReason: String? {
        guard isShowing, matches.isEmpty else { return nil }
        guard let document = view?.document else { return "not loaded yet" }
        return document.string?.contains(where: { $0.isLetter || $0.isNumber }) == true
            ? "not on this page set"
            : "scanned page, no text layer"
    }

    // MARK: Attachment

    /// Takes the view reference and nothing else.
    ///
    /// **Writes no observed property**, on purpose. This is called from
    /// `makeNSView`, and assigning `matches` or `didRun` there mutates state
    /// during a SwiftUI update pass — the runtime warning `PreviewZoomController.attach`
    /// already defers a runloop turn to avoid. `view` and `applied` are
    /// `@ObservationIgnored`, so they are free. Setting `applied` to nil is what
    /// makes the next `applyIfNeeded` re-run against the new document.
    func bind(_ pdfView: PDFView) {
        view = pdfView
        applied = nil
    }

    func detach() {
        view?.highlightedSelections = nil
        view = nil
        targetPath = nil
        applied = nil
        matches = []
        current = 0
        didRun = false
        query = ""
    }

    // MARK: Search

    /// Runs the search if the query changed since the last run.
    ///
    /// Called from `updateNSView` **and** from the end of the async iCloud load,
    /// because either can be the moment a document first exists. A PDF whose
    /// bytes were still downloading when the deep link arrived would otherwise
    /// open with the term unpainted and never recover — the blank-page bug's
    /// cousin, and the reason `PDFViewRepresentable.load` has the comment it has.
    func applyIfNeeded() {
        guard let view, let document = view.document else { return }
        guard applied != query else { return }
        applied = query

        let terms = MacSearchEngine.terms(in: query)
        guard !terms.isEmpty else {
            view.highlightedSelections = nil
            matches = []
            current = 0
            didRun = false
            return
        }

        // Stale hits from the document this controller was last bound to.
        // Cleared here rather than in `bind`, which must not write observed
        // state.
        view.highlightedSelections = nil

        var found: [PDFSelection] = []
        for term in terms {
            // `.diacriticInsensitive` as well as `.caseInsensitive`: this
            // container already holds `Megan’s Wedding Week`, and a user who
            // typed a plain apostrophe should still find the typographic one.
            found += document.findString(term, withOptions: [.caseInsensitive, .diacriticInsensitive])
        }

        // Reading order, not term order. Two terms searched separately produce
        // every hit for the first followed by every hit for the second, so
        // "next match" would jump to the end of the document and back without
        // this.
        found.sort { lhs, rhs in
            // Tuple comparison, not array. `Array` does not conform to
            // `Comparable` in the standard library; tuples of `Comparable`
            // elements up to six wide do.
            Self.position(of: lhs, in: document) < Self.position(of: rhs, in: document)
        }

        matches = found
        current = 0
        didRun = true
        repaint()
        if !found.isEmpty { view.go(to: found[0]) }
    }

    private static func position(of selection: PDFSelection,
                                 in document: PDFDocument) -> (Int, CGFloat, CGFloat) {
        guard let page = selection.pages.first else { return (0, 0, 0) }
        let bounds = selection.bounds(for: page)
        // Page, then down the page, then across. `maxY` negated because PDF
        // coordinates put the origin at the bottom of the page.
        return (document.index(for: page), -bounds.maxY, bounds.minX)
    }

    // MARK: Stepping

    func next() {
        guard !matches.isEmpty else { return }
        current = (current + 1) % matches.count
        reveal()
    }

    func previous() {
        guard !matches.isEmpty else { return }
        current = (current - 1 + matches.count) % matches.count
        reveal()
    }

    func clear() {
        query = ""
        targetPath = nil
        applied = ""
        matches = []
        current = 0
        didRun = false
        view?.highlightedSelections = nil
    }

    private func reveal() {
        repaint()
        guard matches.indices.contains(current) else { return }
        view?.go(to: matches[current])
    }

    /// Every hit in yellow, the one you are on in orange.
    ///
    /// `highlightedSelections` rather than `setCurrentSelection`: the latter
    /// paints the system selection colour over the top and the two fight, so the
    /// current match would look like every other one on some appearances.
    private func repaint() {
        guard let view else { return }
        for (index, selection) in matches.enumerated() {
            selection.color = index == current
                ? NSColor.systemOrange.withAlphaComponent(0.55)
                : NSColor.systemYellow.withAlphaComponent(0.40)
        }
        view.highlightedSelections = matches.isEmpty ? nil : matches
    }
}
