// TraceMacTextExtraction.swift
// Reads the words out of a screenshot or a PDF, once, when it arrives.
// Spec §8 step 2. Mac-only — do not add to iOS, Widget, or Share Extension targets.
//
// ── Why at capture and not at query time ─────────────────────────────────
//
// `DocumentScanService` already sends a captured document to Claude and gets
// back a title, tags and a description. Useful, and it is why the Lou Malnati's
// screenshot carries "$70.09" in its description. But **the full text is never
// stored**, so searching a phrase that is in the PDF matches nothing, because
// only the summary exists.
//
// Extract once, store it in the sidecar, and from then on literal search finds
// words inside the file, offline, instantly, at no cost — and Ask gets the same
// text for free later, as ordinary sidecar content with no image tokens. The
// alternative, sending images to a model on every question, is slower, costs
// image tokens forever, and sends the document out repeatedly rather than never.
//
// **Nothing here touches the network.** Vision and PDFKit are on-device, which
// is also why the `private` tag does not exclude a document from this: §5b binds
// Ask, which sends text to an API. This does not send anything anywhere.

import Foundation
import Vision
import PDFKit
import ImageIO
import CoreGraphics

enum MacTextExtraction {

    /// Sidecars are markdown files in an iCloud container that four apps read.
    /// A 300-page scanned PDF would otherwise put a megabyte of OCR into one,
    /// and every device would sync it forever.
    ///
    /// **The cap is stated in the file when it bites** — see `truncationNotice`.
    /// Silent truncation reads as "that is all there was", which is the one
    /// thing a search index must never imply.
    nonisolated static let maxCharacters = 20_000

    /// Only relevant to a scanned PDF, where each page costs an OCR pass. A PDF
    /// with a real text layer is read whole regardless of length, because that
    /// is one cheap call.
    nonisolated static let maxOCRPages = 25

    nonisolated static let truncationNotice = "…text truncated at 20,000 characters."

    // MARK: - Entry point

    /// Everything readable in the file, or `nil` if it is not a kind this can
    /// read. An empty string is a real answer: it means the pass ran and found
    /// nothing, which is different from not having run.
    ///
    /// **Synchronous, and must be called off the main thread.** Vision on a full
    /// page is tens of milliseconds and a scanned PDF is that per page.
    ///
    /// Everything in this file is `nonisolated`, including the constants. The
    /// project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so without it
    /// the helpers below would be main-actor isolated and this method could not
    /// call them — and the `Task.detached` at the call site would be detaching
    /// only to hop back.
    nonisolated static func extract(from url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return cap(fromPDF(url)) }
        if ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "bmp"].contains(ext) {
            return cap(fromImage(url))
        }
        return nil
    }

    nonisolated private static func cap(_ text: String) -> String {
        let trimmed = stripControls(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        return String(trimmed.prefix(maxCharacters)) + "\n\n" + truncationNotice
    }

    /// Strips control characters a PDF text layer can carry through.
    ///
    /// **Found in the live container, Session 71**, while round-tripping the
    /// phone's new sidecar parser against David's real documents: the sidecar
    /// for "Megan & Ryan Wedding Timeline" holds eight `NUL` bytes inside its
    /// `## Text` section. They are valid UTF-8 and Swift handles them fine,
    /// which is exactly why nothing ever complained — but `grep` reclassifies
    /// the file as binary, and they ride into the search index and into an Ask
    /// prompt as noise nobody can see.
    ///
    /// Tabs, newlines and carriage returns are kept; those are layout.
    /// Everything else below `0x20` is not text and never was.
    ///
    /// **Only affects future extractions.** A sidecar that already carries a
    /// `## Text` heading is never re-read, by design, so those eight bytes stay
    /// until that document is extracted again. Eight bytes is not worth a
    /// migration that rewrites every sidecar in the container.
    nonisolated private static func stripControls(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isJunk) else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.filter { !isJunk($0) }))
    }

    nonisolated private static func isJunk(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "\t", "\n", "\r": return false
        default: return scalar.value < 0x20 || scalar.value == 0x7F
        }
    }

    // MARK: - Local headline

    /// A title and a one-line description read off text this machine already
    /// extracted. **No network, ever.**
    ///
    /// Built for the private case. A document tagged `private` cannot be sent to
    /// the AI without dropping the tag, and dropping it is permanent — so the
    /// choice used to be an untitled `CleanShot 2026-08-14 at 20.19.45.png`
    /// forever, or sending a bank statement to an API. David: *"I really want to
    /// avoid the info going to Anthropic for the private things like bank
    /// account numbers."* This is the third option, and it costs nothing.
    ///
    /// **Deliberately not clever.** It takes the first substantial line as a
    /// title and the next stretch as a description. It is not summarising and it
    /// does not pretend to; a heuristic that guessed and got it subtly wrong
    /// would be worse than the filename, because the filename never looks like
    /// it knows something.
    ///
    /// Returns `nil` when there is nothing usable, so the caller can SAY so
    /// rather than silently doing nothing.
    nonisolated static func localHeadline(from text: String) -> (title: String, description: String)? {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        // **Start at the first letter.** David's loan page produced
        // `- 1-07 Direct Parent PLUS`, and his verdict was exact: *"that prefix
        // doesnt mean anything."* A row label, a plan code, a bullet — OCR
        // reads them in the order they sit on the page, and the words are what
        // he is naming the document by. Trimming to the first letter turns that
        // line into `Direct Parent PLUS`, which is what he retyped by hand.
        func trimmedToWords(_ line: String) -> String {
            var t = Substring(line)
            while let f = t.first, !f.isLetter { t = t.dropFirst() }
            return String(t).trimmingCharacters(in: .whitespaces)
        }

        // A line that is mostly digits and punctuation is an account number or
        // a date row, not a name. Six characters, at least two words, and more
        // than half of it letters.
        func looksLikeAName(_ line: String) -> Bool {
            let c = trimmedToWords(line)
            guard c.count >= 6, c.split(separator: " ").count >= 2 else { return false }
            let letters = c.filter { $0.isLetter }.count
            return Double(letters) / Double(c.count) >= 0.6
        }

        guard let titleLine = lines.first(where: looksLikeAName)
                ?? lines.first(where: { trimmedToWords($0).count >= 4 })
                ?? lines.first
        else { return nil }

        let title = String(trimmedToWords(titleLine).prefix(70))
            .trimmingCharacters(in: .whitespaces)
        let rest = lines
            .drop { $0 != titleLine }
            .dropFirst()
            .joined(separator: " ")
        let description = String(rest.prefix(220)).trimmingCharacters(in: .whitespaces)
        return (title, description)
    }

    /// Which of `vocabulary` actually appear in `text`, as whole words.
    ///
    /// **Recognition, not invention.** A local pass cannot know that a Colorado
    /// State loan page deserves a tag called "tuition" unless that tag already
    /// exists somewhere in the library — so this matches against a vocabulary
    /// the caller supplies (tags already in use, people already in Notion) and
    /// proposes nothing beyond it. That is a real limit and the caller should
    /// say so rather than let an empty result read as "nothing here".
    ///
    /// Whole-word matching, done by collapsing everything non-alphanumeric to
    /// single spaces and padding both sides. Substring matching would tag a
    /// document "csu" because the text contains "focus", and one wrong tag
    /// costs more trust than ten missing ones.
    ///
    /// Terms shorter than three characters are skipped: at that length the
    /// false-positive rate stops being worth the recall.
    nonisolated static func vocabularyMatches(in text: String, vocabulary: [String]) -> [String] {
        let haystack = " " + normalised(text) + " "
        guard haystack.count > 2 else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for term in vocabulary {
            let needle = normalised(term)
            guard needle.count >= 3, seen.insert(needle).inserted else { continue }
            if haystack.contains(" " + needle + " ") { out.append(term) }
        }
        return out
    }

    /// A typed hint split into the things it is naming.
    ///
    /// Commas first, because "loan, hannah, csu" is how a person writes a list;
    /// whitespace after, because "loan hannah" is how they write it when in a
    /// hurry. Both mean the same thing here.
    nonisolated static func hintTerms(in raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet(charactersIn: ",;"))
            .flatMap { $0.split(separator: " ") }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 }
    }

    /// `#tag` markers in a typed hint. Explicit, so they are always honoured.
    ///
    /// Added after bare words from a sentence became eleven tags. A hash is two
    /// characters and it removes every guess: prose stays prose, and anything
    /// he actually wants filed under is said out loud.
    nonisolated static func hashTags(in raw: String) -> [String] {
        raw.split(separator: "#").dropFirst().compactMap { chunk in
            let term = chunk.prefix { $0.isLetter || $0.isNumber || $0 == "-" }
            let t = String(term).lowercased()
            return t.count >= 2 ? t : nil
        }
    }

    nonisolated private static func normalised(_ raw: String) -> String {
        let folded = raw.lowercased()
        var out = ""
        var lastWasSpace = false
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - PDF

    /// The text layer first, and OCR only if there is not one.
    ///
    /// Most PDFs that arrive here — a bill, a statement, a rehearsal sheet
    /// exported from a word processor — carry their text already, and reading it
    /// is one call with no image decoding at all. A phone-scanned page carries
    /// none, and that is the case worth the OCR.
    ///
    /// The test is **whether the text layer has letters in it**, not whether the
    /// string is non-empty. A scanned PDF often returns page separators and
    /// whitespace, which is a non-empty string that says nothing, and treating
    /// that as success is how a scanned bill ends up unsearchable while looking
    /// like it worked.
    nonisolated private static func fromPDF(_ url: URL) -> String {
        guard let pdf = PDFDocument(url: url) else { return "" }

        var layer = ""
        for index in 0..<pdf.pageCount {
            if let page = pdf.page(at: index), let text = page.string {
                layer += text
                layer += "\n"
            }
        }
        if layer.contains(where: { $0.isLetter || $0.isNumber }) {
            return layer
        }

        var out = ""
        let pages = min(pdf.pageCount, maxOCRPages)
        for index in 0..<pages {
            guard let page = pdf.page(at: index), let image = render(page) else { continue }
            let text = ocr(image)
            if !text.isEmpty {
                out += text
                out += "\n"
            }
        }
        if pdf.pageCount > pages {
            out += "\n…OCR stopped after \(pages) of \(pdf.pageCount) pages."
        }
        return out
    }

    /// A PDF page as a bitmap Vision can read.
    ///
    /// 2× the media box. Below that, 8-point receipt type falls under the size
    /// Vision reliably resolves; far above it, the OCR pass gets slower without
    /// reading anything new.
    nonisolated private static func render(_ page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let width = Int(box.width * scale)
        let height = Int(box.height * scale)
        guard width > 0, height > 0 else { return nil }

        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }

        // White, not transparent. A PDF page draws its ink and nothing else, so
        // on a cleared context the result is dark text on black and Vision reads
        // very little of it.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.origin.x, y: -box.origin.y)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    // MARK: - Image

    nonisolated private static func fromImage(_ url: URL) -> String {
        // ImageIO rather than `NSImage`: it has no actor isolation, which is what
        // lets this run inside a detached task, and it is the same route
        // `ScanImage.downscaled` takes for the same reason.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "" }
        return ocr(image)
    }

    // MARK: - Vision

    /// `VNRecognizeTextRequest` rather than the newer Swift `RecognizeTextRequest`.
    /// The old one is soft-deprecated and entirely functional; the new one would
    /// be a shape I am confident about rather than certain of, in a file that
    /// cannot be compiled here. Worth revisiting when something else in this app
    /// is already being built against the new Vision API.
    nonisolated private static func ocr(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // On by default, stated because it is the setting that matters for
        // receipts: it is what turns "Ma1natis" back into "Malnatis".
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return "" }

        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
