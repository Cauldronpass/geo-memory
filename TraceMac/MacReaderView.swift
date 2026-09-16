// MacReaderView.swift
// TraceMac. D422 — the reader and the Shelf, on the Mac.
//
// Approved mockup: `System/Trace-Swift/tracemac-reader-mockup-v1.html` (D421).
// David, after the phone's reader: *"include this reading experience on the mac
// too"*, then *"build"*.
//
// What is the same as the phone, and why it can be: the article format and the
// shelf's rules live in `Trace/SatchelArticleText.swift`, and the article is
// drawn by the same `SatchelArticleBody` the phone uses. Up Next, New, Read,
// Done, Keep for later and the saved place are the same sidecar keys, now
// written by this store too, so reading on either machine moves the other.
//
// What is different because it is a Mac, all from the mockup:
//
// * The Shelf is a tab over Satchel's list, not a rail section.
// * An article opens in the right column as a Read tab beside Details and Note.
// * No hiding bars. Focus (⇧⌘R) folds the rail and the list; esc returns.
// * The text stops at a reading measure, however wide the window.
// * Aa is a popover. The Mac keeps its own size and theme.
//
// **⇧⌘R and not the mockup's ⌘.** Command-period is the system's Cancel on a
// Mac; binding it would take Cancel away from every sheet in Satchel.

import SwiftUI
import AppKit
import LinkPresentation

// MARK: - Focus

/// Whether the reader has the whole window. A shared object because the rail
/// it hides is drawn by `TraceMacContentView` and the list by
/// `TraceMacDocumentsView`, and neither owns the other.
@Observable
final class MacReaderFocus {
    static let shared = MacReaderFocus()
    var isOn = false
}

/// Draws its content unless the reader is in focus. A wrapper rather than an
/// `if` in the host, because the host is `TraceMacContentView`'s body, which is
/// already at the type-checker's limit.
struct MacReaderFocusHider<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var focus = MacReaderFocus.shared

    var body: some View {
        if !focus.isOn {
            content()
        }
    }
}

// MARK: - Preferences and themes

enum MacReaderPrefs {
    static let size = "tracemac.reader.size"
    static let serif = "tracemac.reader.serif"
    static let spacing = "tracemac.reader.spacing"
    static let theme = "tracemac.reader.theme"
    static let recapShown = "tracemac.reader.recapShown"

    static let defaultSize: Double = 18
    static let sizeRange: ClosedRange<Double> = 14...26
}

enum MacReaderTheme: String {
    case system, light, sepia, dark
}

struct MacReaderPalette {
    let background: Color
    let ink: Color
    let secondary: Color
    let faint: Color
    let card: Color
    let accent: Color

    var articleInk: SatchelArticleInk {
        SatchelArticleInk(ink: ink, secondary: secondary, faint: faint, card: card, accent: accent)
    }

    private static func hex(_ value: String) -> Color {
        Color(nsColor: NSColor(hex: value))
    }

    /// The Mac's own paper and ink, so the reader matches the rest of TraceMac.
    static let light = MacReaderPalette(
        background: hex("FFFFFF"), ink: hex("1A1814"), secondary: hex("6E6A64"),
        faint: hex("A6A29B"), card: hex("F7F5F0"), accent: hex("C24D2A"))

    static let sepia = MacReaderPalette(
        background: hex("F8F1E3"), ink: hex("3B2F22"), secondary: hex("7D6B57"),
        faint: hex("B9A78F"), card: hex("EFE5D1"), accent: hex("A86A1F"))

    /// The Mac's warm dark paper, not the phone's grey.
    static let dark = MacReaderPalette(
        background: hex("1B1916"), ink: hex("EDE7DA"), secondary: hex("A69F90"),
        faint: hex("6E6759"), card: hex("23201B"), accent: hex("D0603C"))

    static func resolve(_ theme: MacReaderTheme, macIsDark: Bool) -> MacReaderPalette {
        switch theme {
        case .light: return .light
        case .sepia: return .sepia
        case .dark: return .dark
        case .system: return macIsDark ? .dark : .light
        }
    }
}

// MARK: - Tools, in the right column's tab row

/// Aa, focus, Safari, share. Drawn in `TraceMacDocumentsView`'s tab row beside
/// Read · Details · Note, so the reader itself has no header of its own.
struct MacReaderTools: View {
    let doc: TraceMacDocument

    @State private var showSettings = false
    @State private var focus = MacReaderFocus.shared
    @AppStorage(MacReaderPrefs.size) private var textSize: Double = MacReaderPrefs.defaultSize

    var body: some View {
        HStack(spacing: 12) {
            Button {
                showSettings.toggle()
            } label: {
                Text("Aa").font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Text settings")
            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                MacReaderSettings()
            }

            Button {
                focus.isOn.toggle()
            } label: {
                Image(systemName: focus.isOn
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .help(focus.isOn ? "Leave focus (esc)" : "Focus (⇧⌘R)")

            if let web = TraceMacDocument.openableURL(doc.url) {
                Button {
                    NSWorkspace.shared.open(web)
                } label: {
                    Image(systemName: "safari")
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Open the original (⌘↩)")

                ShareLink(item: web) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
                .help("Share")
            }

            sizeKeys
        }
        .font(.system(size: 13))
        .foregroundStyle(MacEditorialColor.muted)
    }

    /// ⌘+ and ⌘−, as invisible buttons: the keys belong to the reader, and a
    /// visible pair of A buttons would say the same thing Aa already says.
    private var sizeKeys: some View {
        ZStack {
            Button("Larger") { step(1) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Larger") { step(1) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Smaller") { step(-1) }
                .keyboardShortcut("-", modifiers: .command)
            if focus.isOn {
                Button("Leave focus") { focus.isOn = false }
                    .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func step(_ delta: Double) {
        let next: Double = textSize + delta
        textSize = min(MacReaderPrefs.sizeRange.upperBound, max(MacReaderPrefs.sizeRange.lowerBound, next))
    }
}

// MARK: - Aa

struct MacReaderSettings: View {
    @AppStorage(MacReaderPrefs.size) private var textSize: Double = MacReaderPrefs.defaultSize
    @AppStorage(MacReaderPrefs.serif) private var serif: Bool = true
    @AppStorage(MacReaderPrefs.spacing) private var spacing: Int = 1
    @AppStorage(MacReaderPrefs.theme) private var themeRaw: String = MacReaderTheme.system.rawValue

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            label("Text size")
            HStack(spacing: 10) {
                Text("A").font(.system(size: 11))
                Slider(value: $textSize, in: MacReaderPrefs.sizeRange, step: 1)
                Text("A").font(.system(size: 18))
            }
            label("Font")
            Picker("Font", selection: $serif) {
                Text("New York").tag(true)
                Text("San Francisco").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            label("Line spacing")
            Picker("Line spacing", selection: $spacing) {
                Text("Tight").tag(0)
                Text("Normal").tag(1)
                Text("Loose").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            label("Theme")
            HStack {
                swatch(.light, name: "Light")
                Spacer()
                swatch(.sepia, name: "Sepia")
                Spacer()
                swatch(.dark, name: "Dark")
            }
            .padding(.horizontal, 6)
            Divider().padding(.vertical, 10)
            Toggle("Match the Mac", isOn: matchesMac)
                .toggleStyle(.switch)
        }
        .padding(14)
        .frame(width: 280)
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .bold))
            .tracking(1.4)
            .foregroundStyle(.secondary)
            .padding(.top, 10)
            .padding(.bottom, 6)
    }

    private var matchesMac: Binding<Bool> {
        Binding(
            get: { themeRaw == MacReaderTheme.system.rawValue },
            set: { on in
                if on {
                    themeRaw = MacReaderTheme.system.rawValue
                } else {
                    let fallback: MacReaderTheme = colorScheme == .dark ? .dark : .light
                    themeRaw = fallback.rawValue
                }
            }
        )
    }

    private var shownTheme: MacReaderTheme {
        let chosen: MacReaderTheme = MacReaderTheme(rawValue: themeRaw) ?? .system
        if chosen != .system { return chosen }
        return colorScheme == .dark ? .dark : .light
    }

    private func swatch(_ theme: MacReaderTheme, name: String) -> some View {
        let colors: MacReaderPalette = MacReaderPalette.resolve(theme, macIsDark: false)
        let ring: Color = shownTheme == theme ? MacEditorialColor.accent : Color.clear
        return Button {
            themeRaw = theme.rawValue
        } label: {
            VStack(spacing: 4) {
                Text("Aa")
                    .font(.system(size: 13, weight: .semibold, design: .serif))
                    .foregroundStyle(colors.ink)
                    .frame(width: 40, height: 40)
                    .background(colors.background, in: Circle())
                    .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                    .padding(3)
                    .overlay(Circle().stroke(ring, lineWidth: 2.5))
                Text(name).font(.system(size: 11))
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Scroll tracking

/// Where the reader is. Its own observable object so scrolling redraws the
/// progress line and the foot, not the article (the phone's reason, D419).
@Observable
final class MacReaderTracker {
    var offset: CGFloat = 0
    var scrollable: CGFloat = 0
    var content: CGFloat = 0

    var fraction: Double {
        guard content > 0 else { return 0 }
        guard scrollable > 1 else { return 1 }
        return min(1, max(0, Double(offset / scrollable)))
    }
}

struct MacReaderMetrics: Equatable {
    var offset: CGFloat
    var scrollable: CGFloat
    var content: CGFloat
}

// MARK: - The reader

struct MacReaderView: View {

    let opened: TraceMacDocument
    let store: TraceMacDocumentStore
    /// Select another document in Satchel's list (the next article).
    let onOpen: (TraceMacDocument) -> Void

    @Environment(\.colorScheme) private var colorScheme

    @AppStorage(MacReaderPrefs.size) private var textSize: Double = MacReaderPrefs.defaultSize
    @AppStorage(MacReaderPrefs.serif) private var serif: Bool = true
    @AppStorage(MacReaderPrefs.spacing) private var spacing: Int = 1
    @AppStorage(MacReaderPrefs.theme) private var themeRaw: String = MacReaderTheme.system.rawValue
    @AppStorage(MacReaderPrefs.recapShown) private var recapShown: Bool = true

    @State private var parsed = SatchelArticleText.Parsed()
    @State private var minutes: Int = 1
    @State private var tracker = MacReaderTracker()
    @State private var scroll = ScrollPosition(edge: .top)
    @State private var restored = false
    @State private var finished = false
    @State private var lead: NSImage?

    static func canRead(_ doc: TraceMacDocument) -> Bool {
        SatchelShelf.isArticle(doc) && !doc.extractedText.isEmpty
    }

    private var current: TraceMacDocument {
        store.documents.first { $0.relativePath == opened.relativePath } ?? opened
    }

    private var palette: MacReaderPalette {
        let theme: MacReaderTheme = MacReaderTheme(rawValue: themeRaw) ?? .system
        return MacReaderPalette.resolve(theme, macIsDark: colorScheme == .dark)
    }

    var body: some View {
        let colors: MacReaderPalette = palette
        ScrollView {
            page(colors)
        }
        .scrollPosition($scroll)
        .onScrollGeometryChange(for: MacReaderMetrics.self) { geo in
            Self.metrics(from: geo)
        } action: { _, new in
            tracker.offset = new.offset
            tracker.scrollable = new.scrollable
            tracker.content = new.content
        }
        .background(colors.background)
        .overlay(alignment: .top) {
            MacReaderProgressLine(tracker: tracker, color: colors.accent)
        }
        .overlay(alignment: .bottom) {
            MacReaderFoot(tracker: tracker, minutes: minutes, colors: colors)
        }
        .task(id: current.extractedText) {
            parsed = SatchelArticleText.parse(current.extractedText)
            minutes = SatchelShelf.minutes(current)
        }
        .task(id: current.url) {
            lead = await MacReaderLead.image(for: current.url)
        }
        .task {
            await restore()
        }
        .onDisappear {
            savePosition()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            savePosition()
        }
    }

    private static func metrics(from geo: ScrollGeometry) -> MacReaderMetrics {
        let top: CGFloat = geo.contentInsets.top
        let bottom: CGFloat = geo.contentInsets.bottom
        let scrollable: CGFloat = geo.contentSize.height + top + bottom - geo.containerSize.height
        return MacReaderMetrics(offset: geo.contentOffset.y + top,
                                scrollable: max(0, scrollable),
                                content: geo.contentSize.height)
    }

    // MARK: Page

    private func page(_ colors: MacReaderPalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(colors)
            SatchelArticleBody(blocks: parsed.blocks, size: textSize, serif: serif,
                               spacing: spacing, colors: colors.articleInk, photoBleed: 0)
                .textSelection(.enabled)
            ending(colors)
        }
        // **A reading measure** (D421): about seventy characters at the default
        // size, however wide the window. Full-width prose on a 27-inch screen
        // is a line the eye cannot find the start of again.
        .frame(maxWidth: 640)
        .padding(.horizontal, 40)
        .padding(.top, 34)
        .padding(.bottom, 64)
        .frame(maxWidth: .infinity)
    }

    private func header(_ colors: MacReaderPalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(kicker)
                .font(.system(size: 11, weight: .medium))
                .tracking(2.2)
                .foregroundStyle(colors.secondary)
            Text(current.title)
                .font(.system(size: CGFloat(textSize) * 1.85, weight: .bold, design: serif ? .serif : .default))
                .foregroundStyle(colors.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, 10)
            if let byline = bylineLine {
                Text(byline)
                    .font(.system(size: 13))
                    .foregroundStyle(colors.secondary)
                    .padding(.top, 12)
            }
            if !current.description.isEmpty {
                recap(colors)
            }
            if let lead, lead.size.width >= 300 {
                Image(nsImage: lead)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(.top, 20)
            }
        }
        .padding(.bottom, CGFloat(textSize) * 1.2)
    }

    private func recap(_ colors: MacReaderPalette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("RECAP")
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(colors.faint)
                Spacer(minLength: 0)
                Button(recapShown ? "Hide" : "Show") { recapShown.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(colors.secondary)
            }
            if recapShown {
                Text(current.description)
                    .font(.system(size: 13.5))
                    .foregroundStyle(colors.ink)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.top, 18)
    }

    private var kicker: String {
        let site: String = SatchelShelf.site(current).uppercased()
        let time: String = "\(minutes) MIN"
        return site.isEmpty ? time : site + " \u{00B7} " + time
    }

    private var bylineLine: String? {
        var parts: [String] = []
        if let byline = parsed.byline {
            parts.append(byline.lowercased().hasPrefix("by ") ? byline : "By " + byline)
        }
        if let published = parsed.published {
            parts.append(published.formatted(.dateTime.month(.abbreviated).day().year()))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    // MARK: The end

    private func ending(_ colors: MacReaderPalette) -> some View {
        VStack(spacing: 0) {
            Text("\u{00B7}   \u{00B7}   \u{00B7}")
                .foregroundStyle(colors.faint)
                .padding(.top, 10)
                .padding(.bottom, 22)
            finishButtons(colors)
            Text(keysLine)
                .font(.system(size: 11.5))
                .foregroundStyle(colors.secondary)
                .padding(.top, 10)
            if let next = nextUp {
                nextCard(next.document, label: next.label, colors: colors)
                    .padding(.top, 24)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var keysLine: String {
        let site: String = SatchelShelf.site(current)
        let original: String = site.isEmpty ? "open the original" : site + " \u{00B7} open the original"
        return current.readOn == nil ? "⌘D Done \u{00B7} " + original + " ⌘↩" : original + " ⌘↩"
    }

    @ViewBuilder
    private func finishButtons(_ colors: MacReaderPalette) -> some View {
        if let readOn = current.readOn {
            VStack(spacing: 10) {
                Text("Read " + readOn.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(colors.secondary)
                finishButton("Mark unread", primary: false, colors: colors) { keepForLater() }
            }
        } else {
            HStack(spacing: 10) {
                finishButton("Done", primary: true, colors: colors) { markDone() }
                    .keyboardShortcut("d", modifiers: .command)
                finishButton("Keep for later", primary: false, colors: colors) { keepForLater() }
            }
        }
    }

    private func finishButton(_ title: String, primary: Bool, colors: MacReaderPalette,
                              action: @escaping () -> Void) -> some View {
        let fill: Color = primary ? colors.accent : colors.card
        let ink: Color = primary ? Color.white : colors.ink
        return Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: 190)
                .padding(.vertical, 10)
                .background(fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private struct NextUp {
        let document: TraceMacDocument
        let label: String
    }

    private var nextUp: NextUp? {
        let docs: [TraceMacDocument] = store.documents
        let path: String = opened.relativePath
        let queue: [TraceMacDocument] = SatchelShelf.upNext(docs).filter { $0.relativePath != path }
        if let first = queue.first {
            let label: String = queue.count == 1 ? "UP NEXT" : "UP NEXT \u{00B7} 1 OF \(queue.count)"
            return NextUp(document: first, label: label)
        }
        let fresh: [TraceMacDocument] = SatchelShelf.newArrivals(docs).filter { $0.relativePath != path }
        if let first = fresh.first {
            return NextUp(document: first, label: "NEWEST IN NEW")
        }
        return nil
    }

    private func nextCard(_ doc: TraceMacDocument, label: String, colors: MacReaderPalette) -> some View {
        Button {
            savePosition()
            onOpen(doc)
        } label: {
            HStack(spacing: 12) {
                MacShelfCover(document: doc, side: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(.system(size: 9.5, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(colors.secondary)
                    Text(doc.title)
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .foregroundStyle(colors.ink)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    Text(MacShelfRow.subtitle(doc))
                        .font(.system(size: 11.5))
                        .foregroundStyle(colors.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(11)
            .frame(width: 460)
            .background(colors.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Actions

    /// Done on the Mac marks it read and stays on the page, which now says so.
    /// The phone goes back because a phone has one screen; here the list is
    /// still beside it, and the next article is one click below.
    private func markDone() {
        finished = true
        _ = try? store.setRead(Date(), for: current)
        MacReaderFocus.shared.isOn = false
        NotificationCenter.default.post(name: .reloadDocuments, object: nil)
    }

    private func keepForLater() {
        savePosition()
        finished = true
        _ = try? store.setRead(nil, for: current)
    }

    // MARK: Place

    private func savePosition() {
        guard restored, !finished, tracker.content > 0 else { return }
        let doc: TraceMacDocument = current
        let value: Double = tracker.fraction
        let wanted: Double? = value < 0.02 ? nil : value
        let before: Double? = doc.readPosition
        if before == nil && wanted == nil { return }
        if let before, let wanted, abs(before - wanted) < 0.01 { return }
        _ = try? store.setReadPosition(wanted, for: doc)
    }

    private func restore() async {
        restored = false
        let saved: Double = current.readPosition ?? 0
        guard saved > 0.02, saved < 0.98 else {
            restored = true
            return
        }
        var waited = 0
        while tracker.scrollable < 1, waited < 30 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        try? await Task.sleep(for: .milliseconds(250))
        scroll.scrollTo(y: CGFloat(saved) * tracker.scrollable)
        restored = true
    }
}

// MARK: - Progress and the foot

struct MacReaderProgressLine: View {
    let tracker: MacReaderTracker
    let color: Color

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(color.opacity(0.85))
                .frame(width: geo.size.width * CGFloat(tracker.fraction), height: 2)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}

struct MacReaderFoot: View {
    let tracker: MacReaderTracker
    let minutes: Int
    let colors: MacReaderPalette

    var body: some View {
        Text(line)
            .font(.system(size: 11.5))
            .monospacedDigit()
            .foregroundStyle(colors.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(
                LinearGradient(colors: [colors.background.opacity(0), colors.background],
                               startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45))
            )
            .allowsHitTesting(false)
    }

    private var line: String {
        let fraction: Double = tracker.fraction
        if fraction >= 0.98 { return "Finished \u{00B7} \(minutes) min" }
        let percent: Int = Int((fraction * 100).rounded())
        let left: Int = max(1, Int((Double(minutes) * (1 - fraction)).rounded()))
        return "\(percent)% \u{00B7} \(left) min left"
    }
}

// MARK: - The lead photo

/// The link's own preview picture, from the card cache the Preview pane already
/// fills (`MacLinkPreview`). Nothing new is fetched or stored for the reader.
enum MacReaderLead {
    static func image(for urlString: String) async -> NSImage? {
        guard let metadata = await MacLinkPreview.metadata(for: urlString),
              let provider = metadata.imageProvider else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            provider.loadObject(ofClass: NSImage.self) { object, _ in
                let image: NSImage? = object as? NSImage
                continuation.resume(returning: image)
            }
        }
    }
}

// MARK: - The Shelf

/// Satchel's list as a shelf: Up Next numbered and draggable, New with recaps,
/// Read folded at the foot. The phone's Shelf screen as a list column.
struct MacShelfList: View {
    let store: TraceMacDocumentStore
    let searchText: String
    @Binding var selected: TraceMacDocument?

    @AppStorage("tracemac.shelf.readExpanded") private var readExpanded = false
    @State private var dropTarget: String? = nil

    private var visible: [TraceMacDocument] {
        let tokens: [String] = DocumentSearch.tokens(from: searchText)
        guard !tokens.isEmpty else { return store.documents }
        return store.documents.filter { DocumentSearch.matches($0, tokens: tokens) }
    }

    var body: some View {
        let docs: [TraceMacDocument] = visible
        let queue: [TraceMacDocument] = SatchelShelf.upNext(docs)
        let fresh: [TraceMacDocument] = SatchelShelf.newArrivals(docs)
        let done: [TraceMacDocument] = Array(SatchelShelf.read(docs).prefix(12))
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                tierLabel("Up next", detail: countLine(queue))
                if queue.isEmpty {
                    emptyLine("Nothing queued. Right-click an article in New and choose Read next.")
                }
                ForEach(Array(queue.enumerated()), id: \.element.relativePath) { item in
                    queueRow(item.element, index: item.offset, queue: queue)
                }
                tierLabel("New", detail: countLine(fresh))
                if fresh.isEmpty {
                    emptyLine("Nothing new.")
                }
                ForEach(fresh) { doc in
                    row(doc, index: nil, showRecap: true)
                }
                readHeader(count: done.count)
                if readExpanded {
                    ForEach(done) { doc in
                        row(doc, index: nil, showRecap: false)
                    }
                }
                Spacer(minLength: 40)
            }
        }
    }

    private func countLine(_ docs: [TraceMacDocument]) -> String {
        docs.isEmpty ? "" : "\(docs.count) \u{00B7} \(SatchelShelf.totalMinutes(docs)) min"
    }

    private func tierLabel(_ title: String, detail: String) -> some View {
        HStack {
            Text(title).editorialListLabel()
            Spacer()
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(MacEditorialColor.muted)
        }
        .padding(.horizontal, MacEditorialLayout.margin)
        .padding(.top, 16)
        .padding(.bottom, 6)
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(MacEditorialType.meta)
            .foregroundStyle(MacEditorialColor.faint)
            .padding(.horizontal, MacEditorialLayout.margin)
            .padding(.vertical, 8)
    }

    private func readHeader(count: Int) -> some View {
        Button {
            readExpanded.toggle()
        } label: {
            HStack {
                Text("Read").editorialListLabel()
                Spacer()
                Text(readCountLine(count))
                    .font(.system(size: 11))
                    .foregroundStyle(MacEditorialColor.muted)
            }
            .padding(.horizontal, MacEditorialLayout.margin)
            .padding(.top, 16)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func readCountLine(_ count: Int) -> String {
        guard count > 0 else { return "" }
        let chevron: String = readExpanded ? "\u{2304}" : "\u{203A}"
        return "\(count) " + chevron
    }

    private func row(_ doc: TraceMacDocument, index: Int?, showRecap: Bool) -> some View {
        let isSelected: Bool = selected?.relativePath == doc.relativePath
        return MacShelfRow(doc: doc, index: index, showRecap: showRecap, isSelected: isSelected)
            .contentShape(Rectangle())
            .onTapGesture { selected = doc }
            .contextMenu { menu(for: doc) }
    }

    /// Up Next rows drag to reorder. Dropping one on another puts it in that
    /// row's place, then every position is rewritten (`reorderUpNext`).
    private func queueRow(_ doc: TraceMacDocument, index: Int, queue: [TraceMacDocument]) -> some View {
        let isTarget: Bool = dropTarget == doc.relativePath
        return row(doc, index: index, showRecap: false)
            .overlay(alignment: .top) {
                if isTarget {
                    Rectangle().fill(MacEditorialColor.accent).frame(height: 2)
                }
            }
            .draggable(doc.relativePath)
            .dropDestination(for: String.self) { items, _ in
                guard let moved = items.first else { return false }
                reorder(queue, moving: moved, before: doc.relativePath)
                return true
            } isTargeted: { on in
                if on {
                    dropTarget = doc.relativePath
                } else if dropTarget == doc.relativePath {
                    dropTarget = nil
                }
            }
    }

    private func reorder(_ queue: [TraceMacDocument], moving path: String, before target: String) {
        guard path != target, let moving = queue.first(where: { $0.relativePath == path }) else { return }
        var ordered: [TraceMacDocument] = queue.filter { $0.relativePath != path }
        let at: Int = ordered.firstIndex { $0.relativePath == target } ?? ordered.count
        ordered.insert(moving, at: at)
        try? store.reorderUpNext(ordered)
        dropTarget = nil
    }

    @ViewBuilder
    private func menu(for doc: TraceMacDocument) -> some View {
        if doc.readOn != nil {
            Button("Mark unread") { _ = try? store.setRead(nil, for: doc) }
        } else {
            if doc.readNext == nil {
                Button("Read next") { _ = try? store.setReadNext(true, for: doc) }
            } else {
                Button("Back to New") { _ = try? store.setReadNext(false, for: doc) }
            }
            Button("Mark read") { _ = try? store.setRead(Date(), for: doc) }
        }
        if let web = TraceMacDocument.openableURL(doc.url) {
            Divider()
            Button("Open the original") { NSWorkspace.shared.open(web) }
        }
    }
}

struct MacShelfRow: View {
    let doc: TraceMacDocument
    let index: Int?
    let showRecap: Bool
    let isSelected: Bool

    static func subtitle(_ doc: TraceMacDocument) -> String {
        var parts: [String] = []
        let site: String = SatchelShelf.site(doc)
        if !site.isEmpty { parts.append(site) }
        parts.append("\(SatchelShelf.minutes(doc)) min")
        if let line = SatchelShelf.readLine(doc) { parts.append(line) }
        return parts.joined(separator: " \u{00B7} ")
    }

    var body: some View {
        let wash: Color = isSelected ? MacEditorialColor.canvas : Color.clear
        HStack(alignment: .top, spacing: 11) {
            Text(index.map { "\($0 + 1)" } ?? "")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(MacEditorialColor.accent)
                .frame(width: 16, alignment: .trailing)
                .padding(.top, 12)
            MacShelfCover(document: doc, side: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(doc.title)
                    .font(MacEditorialType.rowTitle)
                    .foregroundStyle(MacEditorialColor.ink)
                    .lineLimit(2)
                Text(Self.subtitle(doc))
                    .font(MacEditorialType.meta)
                    .foregroundStyle(MacEditorialColor.muted)
                    .lineLimit(1)
                if showRecap, !doc.description.isEmpty {
                    Text(doc.description)
                        .font(MacEditorialType.meta)
                        .foregroundStyle(MacEditorialColor.muted)
                        .lineLimit(2)
                }
                progress
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, MacEditorialLayout.margin - 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(wash)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(MacEditorialColor.accent).frame(width: 3)
            }
        }
        .overlay(alignment: .bottom) { MacEditorialRule.hair }
    }

    @ViewBuilder
    private var progress: some View {
        if doc.readOn == nil, let position = doc.readPosition, position > 0.02, position < 0.98 {
            ZStack(alignment: .leading) {
                Capsule().fill(MacEditorialColor.hairline)
                Capsule().fill(MacEditorialColor.accent)
                    .frame(width: 120 * CGFloat(position))
            }
            .frame(width: 120, height: 3)
            .padding(.top, 3)
        }
    }
}

/// The link's preview picture as a square, or the site's first letter.
struct MacShelfCover: View {
    let document: TraceMacDocument
    let side: CGFloat

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                MacEditorialColor.panel
                Text(initial)
                    .font(.system(size: side * 0.36, weight: .bold))
                    .foregroundStyle(MacEditorialColor.faint)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.17, style: .continuous))
        .task(id: document.url) {
            image = await MacReaderLead.image(for: document.url)
        }
    }

    private var initial: String {
        let site: String = SatchelShelf.site(document)
        let source: String = site.isEmpty ? document.title : site
        guard let first = source.first(where: { $0.isLetter || $0.isNumber }) else { return "\u{2013}" }
        return String(first).uppercased()
    }
}
