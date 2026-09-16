// SatchelReaderView.swift
// Satchel only. D419 — the reader. Build 5 of the reading shelf, redesigned
// before it was built.
//
// Approved mockup: `System/Trace-Swift/satchel-reader-mockup-v1.html`. David:
// *"the reading experience should be nice or I will not read these articles."*
// The research behind it (Matter, Instapaper, GoodLinks) is in D419; the short
// version is that all three keep headings, quotes and the article's own photos,
// hide their controls while you read, and put the finish at the foot.
//
// What is on this screen, top to bottom: the kicker, the headline, byline and
// date, the recap folded to a card, the lead photo, the article, then Done and
// Keep for later, then the next thing to read. Nothing floats over the text
// except a two-point progress line.
//
// **Nothing new on disk.** The article comes from `## Text` (in the D419 format,
// see `SatchelArticleText`), the place from `read_position`, done from `read:`.
// Text settings are this phone's preference, in `@AppStorage`, like every fold
// in the app.

import SwiftUI

// MARK: - Which screen a document opens in

/// An article opens in the reader; everything else opens in the viewer, as
/// before. **One decision in one place**, instead of the same `if` at the eight
/// places a document can be tapped — which is how one of them ends up opening
/// an article in the old viewer and nobody notices for a month.
///
/// Decided on the document as it was when tapped, not live: "Fetch again"
/// clears `article:` for a moment, and a screen that swapped itself out from
/// under him mid-read because of that would be a bug with no visible cause.
struct SatchelOpenView: View {
    let document: TraceMacDocument
    let store: iOSDocumentStore
    let siblings: [TraceMacDocument]

    init(document: TraceMacDocument, store: iOSDocumentStore, siblings: [TraceMacDocument] = []) {
        self.document = document
        self.store = store
        self.siblings = siblings
    }

    var body: some View {
        if SatchelReaderView.canRead(document) {
            SatchelReaderView(document: document, store: store)
        } else {
            SatchelViewerView(document: document, store: store, siblings: siblings)
        }
    }
}

// MARK: - Themes

enum SatchelReaderTheme: String, CaseIterable {
    /// Light by day, Dark at night, following the phone. The default.
    case system, light, sepia, dark
}

struct SatchelReaderPalette {
    let background: Color
    let ink: Color
    let secondary: Color
    let faint: Color
    let card: Color
    let accent: Color
    let isDark: Bool

    static let light = SatchelReaderPalette(
        background: .white,
        ink: Color(red: 0.110, green: 0.110, blue: 0.118),       // #1c1c1e
        secondary: Color(red: 0.431, green: 0.431, blue: 0.451), // #6e6e73
        faint: Color(red: 0.690, green: 0.690, blue: 0.714),     // #b0b0b6
        card: Color(red: 0.961, green: 0.961, blue: 0.969),      // #f5f5f7
        accent: Color(red: 0.039, green: 0.518, blue: 1.000),    // #0a84ff
        isDark: false)

    /// Warm paper. The ink is brown rather than black, because black on cream
    /// is the contrast Sepia exists to take away.
    static let sepia = SatchelReaderPalette(
        background: Color(red: 0.973, green: 0.945, blue: 0.890), // #f8f1e3
        ink: Color(red: 0.231, green: 0.184, blue: 0.133),        // #3b2f22
        secondary: Color(red: 0.490, green: 0.420, blue: 0.341),  // #7d6b57
        faint: Color(red: 0.725, green: 0.655, blue: 0.561),      // #b9a78f
        card: Color(red: 0.937, green: 0.898, blue: 0.820),       // #efe5d1
        accent: Color(red: 0.659, green: 0.416, blue: 0.122),     // #a86a1f
        isDark: false)

    /// Near-black, not black, and the text a shade off white: pure white on
    /// pure black blooms on an OLED screen in a dark room.
    static let dark = SatchelReaderPalette(
        background: Color(red: 0.110, green: 0.110, blue: 0.118), // #1c1c1e
        ink: Color(red: 0.902, green: 0.902, blue: 0.910),        // #e6e6e8
        secondary: Color(red: 0.596, green: 0.596, blue: 0.616),  // #98989d
        faint: Color(red: 0.388, green: 0.388, blue: 0.400),      // #636366
        card: Color(red: 0.173, green: 0.173, blue: 0.180),       // #2c2c2e
        accent: Color(red: 0.392, green: 0.659, blue: 1.000),     // #64a8ff
        isDark: true)

    var articleInk: SatchelArticleInk {
        SatchelArticleInk(ink: ink, secondary: secondary, faint: faint, card: card, accent: accent)
    }

    static func resolve(_ theme: SatchelReaderTheme, phoneIsDark: Bool) -> SatchelReaderPalette {
        switch theme {
        case .light: return .light
        case .sepia: return .sepia
        case .dark: return .dark
        case .system: return phoneIsDark ? .dark : .light
        }
    }
}

/// The reading preferences, one set for every article. Keys live here so the
/// reader and the Aa sheet cannot drift onto two spellings of the same key.
enum SatchelReaderPrefs {
    static let size = "satchel.reader.size"
    static let serif = "satchel.reader.serif"
    static let spacing = "satchel.reader.spacing"
    static let theme = "satchel.reader.theme"
    static let recapShown = "satchel.reader.recapShown"

    static let defaultSize: Double = 18
    static let sizeRange: ClosedRange<Double> = 14...28

    static func lineGap(size: Double, spacing: Int) -> CGFloat {
        SatchelArticleLayout.lineGap(size: size, spacing: spacing)
    }
}

// MARK: - Scroll tracking

/// Where the reader is, in its own observable object **so that scrolling does
/// not redraw the article.** Sixty updates a second into a `@State` on the
/// reader would re-run the reader's whole body, every paragraph included. Only
/// the two small views that read this — the progress line and the minutes
/// left — are invalidated by it.
@Observable
final class SatchelReaderTracker {
    var offset: CGFloat = 0
    var scrollable: CGFloat = 0
    var content: CGFloat = 0

    /// 0 at the top, 1 at the end. An article shorter than the screen is
    /// already at its end.
    var fraction: Double {
        guard content > 0 else { return 0 }
        guard scrollable > 1 else { return 1 }
        return min(1, max(0, Double(offset / scrollable)))
    }
}

struct SatchelReaderMetrics: Equatable {
    var offset: CGFloat
    var scrollable: CGFloat
    var content: CGFloat
}

// MARK: - The reader

struct SatchelReaderView: View {

    static func canRead(_ doc: TraceMacDocument) -> Bool {
        SatchelShelf.isArticle(doc) && !doc.extractedText.isEmpty
    }

    private let opened: TraceMacDocument
    let store: iOSDocumentStore

    /// The article on screen. A path rather than a document, so the tap on
    /// "Up next" swaps the article in place and the live copy always comes
    /// from the store.
    @State private var path: String

    init(document: TraceMacDocument, store: iOSDocumentStore) {
        self.opened = document
        self.store = store
        _path = State(initialValue: document.relativePath)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SatchelChrome.self) private var chrome: SatchelChrome?

    @AppStorage(SatchelReaderPrefs.size) private var textSize: Double = SatchelReaderPrefs.defaultSize
    @AppStorage(SatchelReaderPrefs.serif) private var serif: Bool = true
    @AppStorage(SatchelReaderPrefs.spacing) private var spacing: Int = 1
    @AppStorage(SatchelReaderPrefs.theme) private var themeRaw: String = SatchelReaderTheme.system.rawValue
    @AppStorage(SatchelReaderPrefs.recapShown) private var recapShown: Bool = true

    @State private var parsed = SatchelArticleText.Parsed()
    @State private var minutes: Int = 1
    @State private var tracker = SatchelReaderTracker()
    @State private var scroll = ScrollPosition(edge: .top)

    /// False until the saved place has been scrolled to. **Nothing is saved
    /// before then**: the view opens at the top, and saving that would
    /// overwrite the place he left with zero before it had been restored.
    @State private var restored = false
    /// Done or Keep for later was pressed; the place is not saved over it.
    @State private var finished = false

    @State private var barsHidden = false
    @State private var lastToggle = Date.distantPast
    @State private var travel: CGFloat = 0

    @State private var showSettings = false
    @State private var showDetails = false
    @State private var refetching = false

    private var current: TraceMacDocument {
        store.documents.first { $0.relativePath == path } ?? opened
    }

    private var palette: SatchelReaderPalette {
        let theme: SatchelReaderTheme = SatchelReaderTheme(rawValue: themeRaw) ?? .system
        return SatchelReaderPalette.resolve(theme, phoneIsDark: colorScheme == .dark)
    }

    var body: some View {
        let colors: SatchelReaderPalette = palette
        let bars: Visibility = barsHidden ? Visibility.hidden : Visibility.visible
        let barScheme: ColorScheme = colors.isDark ? ColorScheme.dark : ColorScheme.light
        ScrollView {
            page(colors)
        }
        .scrollPosition($scroll)
        .onScrollGeometryChange(for: SatchelReaderMetrics.self) { geo in
            Self.metrics(from: geo)
        } action: { old, new in
            scrolled(from: old, to: new)
        }
        .background(colors.background.ignoresSafeArea())
        .overlay(alignment: .top) {
            SatchelReaderProgressLine(tracker: tracker, color: colors.accent)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent(colors) }
        .toolbarBackground(colors.background, for: .navigationBar, .bottomBar)
        .toolbarColorScheme(barScheme, for: .navigationBar, .bottomBar)
        .toolbarVisibility(bars, for: .navigationBar, .bottomBar)
        .animation(.easeInOut(duration: 0.2), value: barsHidden)
        .tint(colors.accent)
        .sheet(isPresented: $showSettings) {
            SatchelReaderSettingsSheet()
        }
        .navigationDestination(isPresented: $showDetails) {
            SatchelViewerView(document: current, store: store)
        }
        .onAppear { chrome?.hidesTabBar = true }
        .onDisappear {
            savePosition()
            chrome?.hidesTabBar = false
        }
        .onChange(of: scenePhase) { _, phase in
            // The app can be killed from the background without another word,
            // so the place is saved on the way there, not only on leaving.
            if phase != .active { savePosition() }
        }
        .task(id: current.extractedText) {
            let text: String = current.extractedText
            parsed = SatchelArticleText.parse(text)
            minutes = SatchelShelf.minutes(current)
        }
        .task(id: path) {
            await restore()
        }
    }

    private static func metrics(from geo: ScrollGeometry) -> SatchelReaderMetrics {
        let top: CGFloat = geo.contentInsets.top
        let bottom: CGFloat = geo.contentInsets.bottom
        let scrollable: CGFloat = geo.contentSize.height + top + bottom - geo.containerSize.height
        return SatchelReaderMetrics(offset: geo.contentOffset.y + top,
                                    scrollable: max(0, scrollable),
                                    content: geo.contentSize.height)
    }

    // MARK: Page

    private func page(_ colors: SatchelReaderPalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SatchelReaderArticle(
                kicker: kicker,
                title: current.title,
                byline: bylineLine,
                recap: current.description,
                recapShown: recapShown,
                leadAddress: current.url,
                blocks: parsed.blocks,
                size: textSize,
                serif: serif,
                spacing: spacing,
                colors: colors,
                onToggleRecap: { recapShown.toggle() }
            )
            ending(colors)
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 36)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        // A tap anywhere that is not a button brings the bars back, or sends
        // them away. GoodLinks' rule, and the only way back to the controls
        // mid-article without scrolling.
        .onTapGesture { setBars(hidden: !barsHidden) }
    }

    private var kicker: String {
        let site: String = SatchelShelf.site(current).uppercased()
        let time: String = "\(minutes) MIN"
        return site.isEmpty ? time : site + "  ·  " + time
    }

    private var bylineLine: String? {
        var parts: [String] = []
        if let byline = parsed.byline {
            let lower: String = byline.lowercased()
            parts.append(lower.hasPrefix("by ") ? byline : "By " + byline)
        }
        if let published = parsed.published {
            parts.append(published.formatted(.dateTime.month(.abbreviated).day().year()))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: The end

    @ViewBuilder
    private func ending(_ colors: SatchelReaderPalette) -> some View {
        VStack(spacing: 0) {
            Text("·   ·   ·")
                .font(.system(size: 15))
                .foregroundStyle(colors.faint)
                .padding(.top, 12)
                .padding(.bottom, 22)
            finishButtons(colors)
            Button {
                openOriginal()
            } label: {
                Text(originalLine)
                    .font(.system(size: 12.5))
                    .foregroundStyle(colors.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .padding(.bottom, 28)
            if let next = nextUp {
                nextCard(next.document, label: next.label, colors: colors)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var originalLine: String {
        let site: String = SatchelShelf.site(current)
        return site.isEmpty ? "Open the original" : site + " · open the original"
    }

    @ViewBuilder
    private func finishButtons(_ colors: SatchelReaderPalette) -> some View {
        if let readOn = current.readOn {
            // Already finished: say when, and offer the way back onto the shelf.
            VStack(spacing: 10) {
                Text("Read " + readOn.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(colors.secondary)
                finishButton("Mark unread", primary: false, colors: colors) { keepForLater() }
            }
        } else {
            HStack(spacing: 10) {
                finishButton("Done", primary: true, colors: colors) { markDone() }
                finishButton("Keep for later", primary: false, colors: colors) { keepForLater() }
            }
        }
    }

    private func finishButton(_ title: String, primary: Bool, colors: SatchelReaderPalette,
                              action: @escaping () -> Void) -> some View {
        let fill: Color = primary ? colors.accent : colors.card
        let ink: Color = primary ? Color.white : colors.ink
        return Button(action: action) {
            Text(title)
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(fill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private struct NextUp {
        let document: TraceMacDocument
        let label: String
    }

    /// The first of Up Next, or, with the queue empty, the newest in New — so
    /// the end of one article is never a dead end while there is anything on
    /// the shelf.
    private var nextUp: NextUp? {
        let docs: [TraceMacDocument] = store.documents
        let queue: [TraceMacDocument] = SatchelShelf.upNext(docs).filter { $0.relativePath != path }
        if let first = queue.first {
            let label: String = queue.count == 1 ? "UP NEXT" : "UP NEXT · 1 OF \(queue.count)"
            return NextUp(document: first, label: label)
        }
        let fresh: [TraceMacDocument] = SatchelShelf.newArrivals(docs).filter { $0.relativePath != path }
        if let first = fresh.first {
            return NextUp(document: first, label: "NEWEST IN NEW")
        }
        return nil
    }

    private func nextCard(_ doc: TraceMacDocument, label: String, colors: SatchelReaderPalette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(colors.secondary)
                .padding(.leading, 2)
            Button {
                open(doc)
            } label: {
                HStack(spacing: 12) {
                    SatchelCoverThumb(document: doc, side: 58)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(doc.title)
                            .font(.system(size: 15, weight: .semibold, design: .serif))
                            .foregroundStyle(colors.ink)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                        Text(nextSubtitle(doc))
                            .font(.system(size: 12))
                            .foregroundStyle(colors.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(11)
                .background(colors.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func nextSubtitle(_ doc: TraceMacDocument) -> String {
        var parts: [String] = []
        let site: String = SatchelShelf.site(doc)
        if !site.isEmpty { parts.append(site) }
        parts.append("\(SatchelShelf.minutes(doc)) min")
        if let position = doc.readPosition, position > 0.02, position < 0.98 {
            parts.append("\(Int((position * 100).rounded()))% read")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbarContent(_ colors: SatchelReaderPalette) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showSettings = true
            } label: {
                Text("Aa").font(.system(size: 17, weight: .semibold))
            }
            .accessibilityLabel("Text settings")
            Button {
                openOriginal()
            } label: {
                Image(systemName: "safari")
            }
            .accessibilityLabel("Open in Safari")
            if let web = TraceMacDocument.openableURL(current.url) {
                ShareLink(item: web) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            Menu {
                Button {
                    showDetails = true
                } label: {
                    Label("Document details", systemImage: "info.circle")
                }
                Button {
                    refetch()
                } label: {
                    Label("Fetch again", systemImage: "arrow.clockwise")
                }
                .disabled(refetching)
            } label: {
                Image(systemName: "ellipsis")
            }
        }
        ToolbarItem(placement: .bottomBar) {
            SatchelReaderRemaining(tracker: tracker, minutes: minutes,
                                   refetching: refetching, color: colors.secondary)
        }
    }

    // MARK: Actions

    private func openOriginal() {
        guard let web = TraceMacDocument.openableURL(current.url) else { return }
        openURL(web)
    }

    /// Done: read today, off the shelf, back to where he came from. Kept in the
    /// library with a "read" line, as every read article is.
    private func markDone() {
        finished = true
        _ = try? store.setRead(Date(), for: current)
        dismiss()
    }

    /// Back to New (the store's rule: a spent queue position is not restored).
    /// The place IS kept, because "later" means he will pick up where he was.
    private func keepForLater() {
        savePosition()
        finished = true
        _ = try? store.setRead(nil, for: current)
        dismiss()
    }

    /// Swap the next article in, in place. The one being left keeps its place.
    private func open(_ doc: TraceMacDocument) {
        savePosition()
        finished = false
        restored = false
        barsHidden = false
        path = doc.relativePath
        scroll.scrollTo(edge: .top)
    }

    /// Read the page again from scratch, in the D419 format. What an article
    /// saved before the reader needs to get its headings and photos. Runs the
    /// recap again, which is why it is a menu item and never automatic.
    private func refetch() {
        let doc: TraceMacDocument = current
        refetching = true
        Task {
            await SatchelArticleSweep.retry(doc, store: store, noteStore: NoteStore.shared)
            refetching = false
        }
    }

    // MARK: Place

    /// Written on leave, never per scroll (D407). Rounded to a hundredth of the
    /// article for the comparison, so opening and closing without reading does
    /// not rewrite the sidecar and wake iCloud.
    private func savePosition() {
        guard restored, !finished, tracker.content > 0 else { return }
        let doc: TraceMacDocument = current
        let value: Double = tracker.fraction
        let wanted: Double? = value < 0.02 ? nil : value
        let before: Double? = doc.readPosition
        if before == nil && wanted == nil { return }
        if let before, let wanted, abs(before - wanted) < 0.01 { return }
        _ = try? store.updateSidecar(for: doc, readPosition: .some(wanted))
    }

    /// Scroll to the saved place once the article has laid out.
    ///
    /// **A fraction, not points** (D407), so a size change since the last read
    /// lands on the same passage. Photos that have not loaded yet make it a
    /// little early rather than a little late, which is the right way to miss.
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

    // MARK: Bars

    private func scrolled(from old: SatchelReaderMetrics, to new: SatchelReaderMetrics) {
        tracker.offset = new.offset
        tracker.scrollable = new.scrollable
        tracker.content = new.content
        guard restored else { return }

        // A photo arriving, or the bars themselves changing the insets, moves
        // the offset without a finger on the glass. Reacting to that is how a
        // hiding bar shows itself again and flickers.
        if abs(old.content - new.content) > 0.5 || abs(old.scrollable - new.scrollable) > 0.5 {
            travel = 0
            return
        }
        if Date().timeIntervalSince(lastToggle) < 0.4 {
            travel = 0
            return
        }
        // At the top and at the end the bars belong on screen: arriving, and
        // finishing, are when he wants the controls.
        let nearTop: Bool = new.offset < 40
        let nearEnd: Bool = new.offset > new.scrollable - 40
        if nearTop || nearEnd {
            if barsHidden { setBars(hidden: false) }
            travel = 0
            return
        }
        let delta: CGFloat = new.offset - old.offset
        if (delta > 0) != (travel > 0) { travel = 0 }
        travel += delta
        if travel > 24, !barsHidden {
            setBars(hidden: true)
        } else if travel < -70, barsHidden {
            setBars(hidden: false)
        }
    }

    private func setBars(hidden: Bool) {
        barsHidden = hidden
        lastToggle = Date()
        travel = 0
    }
}

// MARK: - The article

/// Headline to last paragraph. Its own view so the reader's chrome changing —
/// bars, sheets — is not a reason to rebuild the text.
struct SatchelReaderArticle: View {
    let kicker: String
    let title: String
    let byline: String?
    let recap: String
    let recapShown: Bool
    let leadAddress: String
    let blocks: [SatchelArticleText.Block]
    let size: Double
    let serif: Bool
    let spacing: Int
    let colors: SatchelReaderPalette
    let onToggleRecap: () -> Void

    @State private var lead: UIImage?

    private var design: Font.Design { serif ? .serif : .default }
    private var bodySize: CGFloat { CGFloat(size) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            SatchelArticleBody(blocks: blocks, size: size, serif: serif, spacing: spacing,
                               colors: colors.articleInk, photoBleed: 22)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: leadAddress) {
            lead = SatchelLinkPreview.image(for: leadAddress)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(kicker)
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(colors.secondary)
            Text(title)
                .font(.system(size: bodySize * 1.55, weight: .bold, design: design))
                .foregroundStyle(colors.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            if let byline {
                Text(byline)
                    .font(.system(size: 13))
                    .foregroundStyle(colors.secondary)
                    .padding(.top, 10)
            }
            if !recap.isEmpty {
                recapCard
            }
            leadPhoto
        }
        .padding(.bottom, bodySize * 1.1)
    }

    private var recapCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("RECAP")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(colors.secondary)
                Spacer(minLength: 0)
                Button(recapShown ? "Hide" : "Show", action: onToggleRecap)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(colors.secondary)
                    .buttonStyle(.plain)
            }
            if recapShown {
                Text(recap)
                    .font(.system(size: 13.5))
                    .foregroundStyle(colors.ink)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, 16)
    }

    /// The link's own preview picture, edge to edge. **Only a real photo**: some
    /// pages offer a favicon-sized image as their preview, and a 64-pixel logo
    /// stretched across the screen is worse than no picture.
    @ViewBuilder
    private var leadPhoto: some View {
        if let lead, lead.size.width * lead.scale >= 300 {
            Image(uiImage: lead)
                .resizable()
                .scaledToFit()
                .padding(.horizontal, -22)
                .padding(.top, 18)
        }
    }
}

// MARK: - The two views that follow the scroll

struct SatchelReaderProgressLine: View {
    let tracker: SatchelReaderTracker
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

struct SatchelReaderRemaining: View {
    let tracker: SatchelReaderTracker
    let minutes: Int
    let refetching: Bool
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            if refetching {
                ProgressView().controlSize(.small)
                Text("Fetching again")
            } else {
                Text(line)
            }
        }
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(color)
        .monospacedDigit()
    }

    private var line: String {
        let fraction: Double = tracker.fraction
        if fraction >= 0.98 { return "Finished · \(minutes) min" }
        let left: Int = max(1, Int((Double(minutes) * (1 - fraction)).rounded()))
        return "\(left) min left"
    }
}

// MARK: - Aa

/// One sheet, four controls, one set of settings for every article. The
/// article behind it changes as he drags, because both read the same keys.
struct SatchelReaderSettingsSheet: View {

    @AppStorage(SatchelReaderPrefs.size) private var textSize: Double = SatchelReaderPrefs.defaultSize
    @AppStorage(SatchelReaderPrefs.serif) private var serif: Bool = true
    @AppStorage(SatchelReaderPrefs.spacing) private var spacing: Int = 1
    @AppStorage(SatchelReaderPrefs.theme) private var themeRaw: String = SatchelReaderTheme.system.rawValue

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Text size")
            sizeRow
            sectionLabel("Font")
            Picker("Font", selection: $serif) {
                Text("New York").tag(true)
                Text("San Francisco").tag(false)
            }
            .pickerStyle(.segmented)
            sectionLabel("Line spacing")
            Picker("Line spacing", selection: $spacing) {
                Text("Tight").tag(0)
                Text("Normal").tag(1)
                Text("Loose").tag(2)
            }
            .pickerStyle(.segmented)
            sectionLabel("Theme")
            themeGroup
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
            .padding(.top, 14)
            .padding(.bottom, 7)
    }

    private var sizeRow: some View {
        HStack(spacing: 12) {
            Text("A").font(.system(size: 13))
            Slider(value: $textSize, in: SatchelReaderPrefs.sizeRange, step: 1)
            Text("A").font(.system(size: 22))
        }
    }

    private var themeGroup: some View {
        VStack(spacing: 12) {
            HStack {
                swatch(.light, name: "Light")
                Spacer()
                swatch(.sepia, name: "Sepia")
                Spacer()
                swatch(.dark, name: "Dark")
            }
            .padding(.horizontal, 8)
            Divider()
            Toggle("Match the phone", isOn: matchesPhone)
        }
    }

    /// On: Light by day, Dark at night. Off: whatever is showing now stays.
    /// Picking a swatch turns it off, because a chosen theme is a choice.
    private var matchesPhone: Binding<Bool> {
        Binding(
            get: { themeRaw == SatchelReaderTheme.system.rawValue },
            set: { on in
                if on {
                    themeRaw = SatchelReaderTheme.system.rawValue
                } else {
                    let fallback: SatchelReaderTheme = colorScheme == .dark ? .dark : .light
                    themeRaw = fallback.rawValue
                }
            }
        )
    }

    private var shownTheme: SatchelReaderTheme {
        let chosen: SatchelReaderTheme = SatchelReaderTheme(rawValue: themeRaw) ?? .system
        if chosen != .system { return chosen }
        return colorScheme == .dark ? .dark : .light
    }

    private func swatch(_ theme: SatchelReaderTheme, name: String) -> some View {
        let colors: SatchelReaderPalette = SatchelReaderPalette.resolve(theme, phoneIsDark: false)
        let selected: Bool = shownTheme == theme
        let ring: Color = selected ? Color.satchelBlue : Color.clear
        return Button {
            themeRaw = theme.rawValue
        } label: {
            VStack(spacing: 6) {
                Text("Aa")
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .foregroundStyle(colors.ink)
                    .frame(width: 54, height: 54)
                    .background(colors.background, in: Circle())
                    .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                    .padding(4)
                    .overlay(Circle().stroke(ring, lineWidth: 3))
                Text(name)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }
}
