#if targetEnvironment(simulator)
import Foundation
import UIKit
import PDFKit

// MARK: - Satchel simulator seed
//
// Session 50. Same pattern and same reason as `NotionService+SimulatorSeed.swift`:
// injected only in the Simulator so layouts can be verified without the real
// data source. `#if targetEnvironment(simulator)` wraps the entire file, so
// **none of this compiles into a device build** and there is no runtime check
// to get wrong.
//
// Why Satchel needs one at all: `NoteStore` calls `activateLocalMode()` on the
// Simulator because iCloud is never available there, and local mode points at
// the app's OWN sandbox Documents folder. Satchel's sandbox is new and empty,
// so the Simulator shows an empty library forever, no matter how correct the
// container entitlement is. Seeding is the only way to see the real screens
// without installing on a device.
//
// The seed writes REAL files, not just sidecars — `iOSDocumentStore.reload()`
// enumerates document files and derives everything from them, so sidecars alone
// would list nothing. PDFs are generated with `UIGraphicsPDFRenderer` and images
// with `UIGraphicsImageRenderer`, which means they are genuine, openable files
// and the step 8 viewer will have something to render.
//
// Shape of the data: 14 documents, matching the mockup's "14 documents · 4 in
// kit" header. 5 manual pins and 5 documents on an active trip, so Kit has 10
// members, the grid shows the locked 2 pins + 2 trip split, `Show all` appears
// (membership > 4), and the footnote carries real counts. The remaining 4 are
// unpinned and unfiled-to-a-trip so Recent, the filing chips and every Browse
// facet have something in them.
//
// To reseed: delete the app from the Simulator, or bump `seedVersion`.

enum SatchelSimulatorSeed {

    /// Bump to force a reseed on next launch.
    private static let seedVersion = "satchel.simulatorSeed.v1"

    // MARK: Endeavor

    /// The Endeavor list the stubbed store returns in the Simulator.
    ///
    /// Deliberately dated to be **active today** rather than using the mockup's
    /// Sep 14–24 range. Auto Kit membership only triggers inside a Travel
    /// Endeavor's date range, so a future-dated trip would show none of the
    /// behaviour this seed exists to demonstrate.
    static var endeavors: [Endeavor] {
        let cal = Calendar.current
        let now = Date()
        return [
            Endeavor(
                id: tripEndeavorID,
                name: "Japan 2026",
                type: "Travel",
                start: cal.date(byAdding: .day, value: -2, to: now),
                end: cal.date(byAdding: .day, value: 28, to: now)
            ),
            Endeavor(
                id: "sim-endeavor-kitchen",
                name: "Kitchen Remodel",
                type: "Project",
                start: cal.date(byAdding: .day, value: -60, to: now),
                end: nil
            )
        ]
    }

    static let tripEndeavorID = "sim-endeavor-japan-2026"

    // MARK: Seeding

    @MainActor
    static func seedIfNeeded(noteStore: NoteStore) {
        guard noteStore.hasAccess else { return }
        guard !UserDefaults.standard.bool(forKey: seedVersion) else { return }

        // Belt and braces: never seed into a library that already has anything
        // in it. The UserDefaults flag is per-install, so bumping `seedVersion`
        // on an already-seeded Simulator would otherwise write a SECOND set of
        // 14 and silently double the library. With this guard the only reseed
        // path is deleting the app, which wipes the sandbox first.
        let existing = (try? noteStore.listDocumentFiles(in: "Documents")) ?? []
        guard existing.isEmpty else {
            UserDefaults.standard.set(true, forKey: seedVersion)
            return
        }

        for (index, spec) in specs.enumerated() {
            write(spec, index: index, noteStore: noteStore)
        }

        UserDefaults.standard.set(true, forKey: seedVersion)
    }

    @MainActor
    private static func write(_ spec: Spec, index: Int, noteStore: NoteStore) {
        let stamp = filenameStamp(for: spec.created, index: index)
        let filename = "\(stamp)-\(spec.slug).\(spec.isImage ? "jpg" : "pdf")"

        let data: Data = spec.isImage
            ? imageData(title: spec.title)
            : pdfData(title: spec.title, subtitle: spec.description, pages: spec.pages)
        guard !data.isEmpty else { return }

        do {
            _ = try noteStore.writeDocument(data, category: spec.category, filename: filename)
        } catch {
            return
        }

        let base = "Documents/\(spec.category)/\(stamp)-\(spec.slug)"
        try? noteStore.writeFile("\(base).md", content: sidecar(for: spec))
    }

    /// Key order matches `IOSDocumentStore.renderSidecar` exactly, so a seeded
    /// sidecar is byte-shaped like one Satchel wrote itself. If they diverged,
    /// the first real save would rewrite every seeded file for no reason.
    private static func sidecar(for spec: Spec) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"

        var out = "---\n"
        out += "title: \(spec.title)\n"
        out += "tags: [" + spec.tags.joined(separator: ", ") + "]\n"
        out += "created: \(fmt.string(from: spec.created))\n"
        if let note = spec.linkedNote { out += "linked_note: \(note)\n" }
        if !spec.description.isEmpty {
            out += "description: \"\(spec.description.replacingOccurrences(of: "\"", with: "'"))\"\n"
        }
        out += "icon: \(spec.icon.rawValue)\n"
        out += "tint: \(spec.tint.rawValue)\n"
        if let endeavor = spec.endeavor {
            out += "endeavor: \(endeavor)\n"
            out += "endeavor_name: \(spec.endeavorName ?? "")\n"
        }
        if spec.pinned { out += "pinned: true\n" }
        // Not nested under `pinned` — trip documents carry an order too, and
        // nesting it here is what made the seeded trip order never take effect.
        if let order = spec.kitOrder { out += "kit_order: \(order)\n" }
        out += "---\n"
        return out
    }

    // MARK: Spec

    private struct Spec {
        let slug: String
        let title: String
        let category: String
        let icon: DocumentIcon
        let tint: DocumentTint
        let tags: [String]
        var description: String = ""
        var linkedNote: String? = nil
        var endeavor: String? = nil
        var endeavorName: String? = nil
        var pinned: Bool = false
        var kitOrder: Int? = nil
        var isImage: Bool = false
        var pages: Int = 1
        var daysAgo: Int = 0

        /// Anchored to the start of the day so two calls in the same run cannot
        /// straddle a second boundary and produce different filenames.
        var created: Date {
            let today = Calendar.current.startOfDay(for: Date())
            return Calendar.current.date(byAdding: .day, value: -daysAgo, to: today) ?? today
        }
    }

    private static var specs: [Spec] {
        [
            // ── Manual pins (5, so Kit membership exceeds the 4-tile grid and
            //    `Show all` has a reason to exist) ──────────────────────────
            Spec(slug: "passport", title: "Passport", category: "Personal",
                 icon: .passport, tint: .teal, tags: ["identity", "travel"],
                 description: "US passport. Expires March 2031.",
                 pinned: true, kitOrder: 0, pages: 2, daysAgo: 420),

            Spec(slug: "insurance-card", title: "Insurance card", category: "Personal",
                 icon: .card, tint: .rose, tags: ["insurance", "medical"],
                 description: "BCBS PPO member card, front and back.",
                 pinned: true, kitOrder: 1, isImage: true, daysAgo: 300),

            Spec(slug: "global-entry", title: "Global Entry", category: "Personal",
                 icon: .id, tint: .green, tags: ["identity", "travel"],
                 description: "Global Entry card. Known Traveler Number on the reverse.",
                 pinned: true, kitOrder: 2, daysAgo: 260),

            Spec(slug: "drivers-license", title: "Driver's license", category: "Personal",
                 icon: .id, tint: .blue, tags: ["identity"],
                 description: "Illinois driver's license.",
                 pinned: true, kitOrder: 3, isImage: true, daysAgo: 190),

            Spec(slug: "medical-allergies", title: "Medical — allergies", category: "Personal",
                 icon: .medical, tint: .red, tags: ["medical", "emergency"],
                 description: "Allergy list and emergency contacts. One page, carry always.",
                 pinned: true, kitOrder: 4, daysAgo: 150),

            // ── Active trip (Japan 2026). These fold into Kit automatically
            //    from the Endeavor's date range — nothing is written to their
            //    sidecars to make that happen. ──────────────────────────────
            Spec(slug: "jal-6042-boarding-pass", title: "JAL 6042", category: "Trip",
                 icon: .plane, tint: .indigo, tags: ["flight", "boarding", "japan-2026"],
                 description: "JAL 6042, ORD to HND. Seat 34K.",
                 endeavor: tripEndeavorID, endeavorName: "Japan 2026", kitOrder: 0, daysAgo: 1),

            Spec(slug: "jr-rail-pass", title: "JR Rail Pass", category: "Trip",
                 icon: .train, tint: .green, tags: ["rail", "transit", "japan-2026"],
                 description: "7-day Japan Rail Pass voucher. Exchange at the airport counter.",
                 endeavor: tripEndeavorID, endeavorName: "Japan 2026", kitOrder: 1, daysAgo: 2),

            Spec(slug: "ryokan-confirmation", title: "Ryokan confirmation", category: "Trip",
                 icon: .lodging, tint: .rose, tags: ["lodging", "japan-2026"],
                 description: "Two nights, Hakone. Dinner included both evenings.",
                 endeavor: tripEndeavorID, endeavorName: "Japan 2026", kitOrder: 2, isImage: true, daysAgo: 4),

            Spec(slug: "rental-agreement-kyoto", title: "Rental agreement, Kyoto", category: "Trip",
                 icon: .contract, tint: .blue, tags: ["contract", "lodging", "japan-2026"],
                 description: "Short-term rental agreement, Kyoto. Six pages, signed.",
                 endeavor: tripEndeavorID, endeavorName: "Japan 2026", kitOrder: 3, pages: 6, daysAgo: 6),

            Spec(slug: "travel-insurance", title: "Travel insurance", category: "Trip",
                 icon: .contract, tint: .gray, tags: ["insurance", "japan-2026"],
                 description: "Policy summary and 24-hour assistance number.",
                 endeavor: tripEndeavorID, endeavorName: "Japan 2026", kitOrder: 4, pages: 3, daysAgo: 9),

            // ── Unpinned, no trip — Recent, filing chips, Browse facets ────
            Spec(slug: "marriott-denver-receipt", title: "Marriott Denver receipt", category: "Receipts",
                 icon: .receipt, tint: .amber, tags: ["receipt", "travel", "reimbursable"],
                 description: "Two nights at the Denver City Center property at the conference rate, including parking. Total 438.94.",
                 linkedNote: "Notes/Journal/2026-07-26.md", pages: 2, daysAgo: 0),

            Spec(slug: "comed-electric-bill", title: "ComEd electric bill", category: "Project",
                 icon: .home, tint: .green, tags: ["bills", "utilities", "home"],
                 description: "Residential electricity bill, 1,347 kWh. Due end of month.",
                 linkedNote: "Notes/Projects/Home Bills.md", daysAgo: 3),

            Spec(slug: "home-inspection-photos", title: "Home inspection photos", category: "Place",
                 icon: .home, tint: .green, tags: ["inspection", "property"],
                 description: "1400 Oak St. Roof, basement and electrical panel.",
                 isImage: true, daysAgo: 7),

            Spec(slug: "pricing-workshop-whiteboard", title: "Pricing workshop whiteboard", category: "Inbox",
                 icon: .photo, tint: .gray, tags: ["whiteboard", "pricing"],
                 description: "Shot with the camera, not deskewed, by design — a whiteboard is not a page.",
                 isImage: true, daysAgo: 11)
        ]
    }

    // MARK: File generation

    /// Filenames must be identical on every run. The time component therefore
    /// comes from the spec's index, NOT the clock — `Date()` would produce a
    /// different `HHmmss` each launch, so a reseed would add 14 new documents
    /// beside the old 14 rather than overwriting them.
    private static func filenameStamp(for date: Date, index: Int) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return "\(fmt.string(from: date))-\(String(format: "%06d", 120000 + index))"
    }

    @MainActor
    private static func pdfData(title: String, subtitle: String, pages: Int) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)

        return renderer.pdfData { context in
            for page in 0..<max(1, pages) {
                context.beginPage()

                let titleAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 24, weight: .bold),
                    .foregroundColor: UIColor.black
                ]
                title.draw(at: CGPoint(x: 56, y: 72), withAttributes: titleAttrs)

                let bodyAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: UIColor.darkGray
                ]
                let body = subtitle.isEmpty ? "Simulator seed document." : subtitle
                body.draw(
                    with: CGRect(x: 56, y: 116, width: 500, height: 120),
                    options: [.usesLineFragmentOrigin],
                    attributes: bodyAttrs,
                    context: nil
                )

                // Filler rules, so a page looks like a page at thumbnail size.
                UIColor(white: 0.90, alpha: 1).setFill()
                var y: CGFloat = 250
                var row = 0
                while y < 700 {
                    let width: CGFloat = row % 3 == 2 ? 300 : 500
                    UIBezierPath(
                        roundedRect: CGRect(x: 56, y: y, width: width, height: 8),
                        cornerRadius: 4
                    ).fill()
                    y += 22
                    row += 1
                }

                let footAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 10, weight: .regular),
                    .foregroundColor: UIColor.lightGray
                ]
                "Page \(page + 1) of \(max(1, pages))".draw(
                    at: CGPoint(x: 56, y: 730), withAttributes: footAttrs
                )
            }
        }
    }

    @MainActor
    private static func imageData(title: String) -> Data {
        let size = CGSize(width: 1200, height: 900)
        let renderer = UIGraphicsImageRenderer(size: size)

        let image = renderer.image { _ in
            UIColor(white: 0.16, alpha: 1).setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()

            // A lighter card, so the photo reads as a photo of something.
            UIColor(white: 0.97, alpha: 1).setFill()
            UIBezierPath(
                roundedRect: CGRect(x: 120, y: 110, width: 960, height: 680),
                cornerRadius: 12
            ).fill()

            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 40, weight: .semibold),
                .foregroundColor: UIColor.darkGray
            ]
            title.draw(at: CGPoint(x: 168, y: 176), withAttributes: attrs)

            UIColor(white: 0.86, alpha: 1).setFill()
            var y: CGFloat = 268
            var row = 0
            while y < 720 {
                let width: CGFloat = row % 4 == 3 ? 480 : 840
                UIBezierPath(
                    roundedRect: CGRect(x: 168, y: y, width: width, height: 14),
                    cornerRadius: 7
                ).fill()
                y += 40
                row += 1
            }
        }

        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }
}
#endif
