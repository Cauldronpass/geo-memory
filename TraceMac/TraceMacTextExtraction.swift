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
    static let maxCharacters = 20_000

    /// Only relevant to a scanned PDF, where each page costs an OCR pass. A PDF
    /// with a real text layer is read whole regardless of length, because that
    /// is one cheap call.
    static let maxOCRPages = 25

    static let truncationNotice = "…text truncated at 20,000 characters."

    // MARK: - Entry point

    /// Everything readable in the file, or `nil` if it is not a kind this can
    /// read. An empty string is a real answer: it means the pass ran and found
    /// nothing, which is different from not having run.
    ///
    /// **Synchronous, and must be called off the main thread.** Vision on a full
    /// page is tens of milliseconds and a scanned PDF is that per page.
    nonisolated static func extract(from url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return cap(fromPDF(url)) }
        if ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "bmp"].contains(ext) {
            return cap(fromImage(url))
        }
        return nil
    }

    private static func cap(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        return String(trimmed.prefix(maxCharacters)) + "\n\n" + truncationNotice
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
    private static func fromPDF(_ url: URL) -> String {
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
    private static func render(_ page: PDFPage) -> CGImage? {
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

    private static func fromImage(_ url: URL) -> String {
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
    private static func ocr(_ image: CGImage) -> String {
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
