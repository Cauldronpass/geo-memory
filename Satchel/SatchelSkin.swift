import SwiftUI
import UIKit

// MARK: - SatchelSkin
//
// Satchel's design tokens, in one file. Same pattern and same reason as
// `TraceSkin.swift` and `DayflowSkin.swift`: a future restyle edits this file,
// not every view. Build step 5 in `Satchel-Build-Starter.md`.
//
// Every value is read off `satchel-mockup-v4.html` (vault mirror), the approved
// 8-frame reference. Not verified in the Simulator — same standing limitation
// the other two skin files call out. Check contrast and weights on first run.
//
// The tint palette here is the rendering half of `DocumentTint`, whose tokens
// live in `TraceDocumentModels.swift`. Tokens are Foundation-only because they
// are also compiled into TraceMac; the Colors are here because only Satchel
// draws them. Changing a palette hex is a one-line edit in this file and
// touches no sidecar on disk.

// MARK: - Colors

extension Color {
    /// Screen background (#f5f5f7). Note this is NOT Trace's #e9e9ee canvas —
    /// Satchel's mockup runs a lighter ground so the white cards read as
    /// slightly more raised. Deliberate, not a transcription error.
    static let satchelCanvas    = Color(red: 0.961, green: 0.961, blue: 0.969) // #f5f5f7
    static let satchelCard      = Color.white
    static let satchelInk       = Color(red: 0.110, green: 0.110, blue: 0.118) // #1c1c1e — primary text
    static let satchelSecondary = Color(red: 0.557, green: 0.557, blue: 0.576) // #8e8e93 — secondary text
    static let satchelTertiary  = Color(red: 0.690, green: 0.690, blue: 0.714) // #b0b0b6 — timestamps, counts
    static let satchelHairline  = Color(red: 0.933, green: 0.933, blue: 0.941) // #eeeef0 — row dividers
    static let satchelFill      = Color(red: 0.925, green: 0.933, blue: 0.941) // #eceef0 — search bar, tag pills
    static let satchelGrip      = Color(red: 0.780, green: 0.780, blue: 0.800) // #c7c7cc — reorder grips

    static let satchelBlue      = Color(red: 0.039, green: 0.518, blue: 1.000) // #0a84ff — links, FAB
    static let satchelBlueDeep  = Color(red: 0.000, green: 0.376, blue: 0.875) // #0060df — FAB gradient end
    /// Manual Kit pin marker. Orange, and only ever used for that.
    static let satchelPin       = Color(red: 1.000, green: 0.584, blue: 0.000) // #ff9500
    /// Active-trip (auto) Kit marker and Endeavor emphasis. Indigo, and only that.
    static let satchelAuto      = Color(red: 0.345, green: 0.337, blue: 0.839) // #5856d6
    static let satchelAI        = Color(red: 0.686, green: 0.322, blue: 0.871) // #af52de — "AI" badge ink
    static let satchelAIFill    = Color(red: 0.965, green: 0.925, blue: 0.984) // #f6ecfb — "AI" badge fill
}

// MARK: - Tint palette

extension DocumentTint {
    /// Tile background.
    var background: Color {
        switch self {
        case .teal:   return Color(red: 0.859, green: 0.941, blue: 0.945) // #dbf0f1
        case .blue:   return Color(red: 0.898, green: 0.941, blue: 1.000) // #e5f0ff
        case .green:  return Color(red: 0.894, green: 0.969, blue: 0.918) // #e4f7ea
        case .rose:   return Color(red: 0.992, green: 0.918, blue: 0.953) // #fdeaf3
        case .indigo: return Color(red: 0.925, green: 0.933, blue: 1.000) // #eceeff
        case .amber:  return Color(red: 1.000, green: 0.949, blue: 0.878) // #fff2e0
        case .red:    return Color(red: 1.000, green: 0.902, blue: 0.914) // #ffe6e9
        case .gray:   return Color(red: 0.925, green: 0.933, blue: 0.941) // #eceef0
        }
    }

    /// Glyph colour drawn on `background`.
    var foreground: Color {
        switch self {
        case .teal:   return Color(red: 0.055, green: 0.486, blue: 0.525) // #0e7c86
        case .blue:   return Color(red: 0.039, green: 0.518, blue: 1.000) // #0a84ff
        case .green:  return Color(red: 0.141, green: 0.541, blue: 0.239) // #248a3d
        case .rose:   return Color(red: 0.812, green: 0.184, blue: 0.467) // #cf2f77
        case .indigo: return Color(red: 0.345, green: 0.337, blue: 0.839) // #5856d6
        case .amber:  return Color(red: 0.788, green: 0.463, blue: 0.039) // #c9760a
        case .red:    return Color(red: 0.843, green: 0.000, blue: 0.082) // #d70015
        case .gray:   return Color(red: 0.420, green: 0.420, blue: 0.439) // #6b6b70
        }
    }
}

// MARK: - Backgrounds and cards

extension View {
    func satchelBackground() -> some View {
        self.background(Color.satchelCanvas.ignoresSafeArea())
    }

    /// Mockup `.card` — white, 18pt radius, soft flat shadow.
    func satchelCard() -> some View {
        self
            .background(Color.satchelCard, in: RoundedRectangle(cornerRadius: 18))
            .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 1)
    }

    /// Background for the `List`-based screens. Deliberately deeper than
    /// `satchelCanvas`: white rows on #f5f5f7 are a two-percent difference, so an
    /// inset-grouped list of them reads as one flat grey slab with no visible row
    /// edges. The card-on-canvas screens get away with it because tinted marks and
    /// chips carry the separation; a plain list has nothing else to do that work.
    func satchelListBackground() -> some View {
        self.background(Color.satchelFill.ignoresSafeArea())
    }

    /// Mockup `.kit-tile` / `.browse-chip` — same shadow, tighter radius.
    func satchelTile(cornerRadius: CGFloat = 16) -> some View {
        self
            .background(Color.satchelCard, in: RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 1)
    }
}

// MARK: - Section title

struct SatchelSectionTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.system(size: 12.5, weight: .bold))
                .kerning(0.6)
                .foregroundStyle(Color.satchelSecondary)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
    }
}

extension SatchelSectionTitle where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title: title) { EmptyView() }
    }
}

// MARK: - Collapsible section title
//
// Session 73. David: *"please make Kind of thing and the browse sections as
// expandable so they both dont take up the full space if i dont want them to.
// Recent is a nice thing to see most of the time."*
//
// Two rows of chips plus a second titled row of colours had pushed Recent below
// the fold on an iPhone, and Recent is the section he actually reads.
//
// ── The count is not decoration ───────────────────────────────────────────
//
// A collapsed section shows its count. Without it a folded Browse is a bare
// word with nothing under it, which is indistinguishable from a section that
// has nothing IN it — and Session 72 was spent twice on exactly that confusion,
// once on a suppressed bucket header and once on a decision rendered nowhere.
// **If the app is hiding something, it says how much.**
//
// ── The whole row is the target ───────────────────────────────────────────
//
// Not just the chevron. A 9pt glyph is a poor thumb target and the label beside
// it looks tappable anyway, so making only the glyph work would produce a row
// that responds to some taps and not others — which reads as broken rather than
// as precise. Same reasoning as `chipGestures` being applied to every chip and
// not only the long ones.
struct SatchelCollapsibleSectionTitle<Trailing: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    /// Drawn when collapsed. See the note above: a folded section has to say
    /// how much it is holding.
    var collapsedCount: Int? = nil
    /// Words instead of a bare number, for a section whose count is not one
    /// number. Up Next folds to "3 queued · 1 new", which a single integer
    /// cannot say and which is exactly what he needs to know before deciding
    /// whether to unfold it. Takes precedence over `collapsedCount`.
    var collapsedNote: String? = nil
    /// A door on the right — Kit's is the only one left after D418, and it has
    /// to stay because the Kit screen holds the trip-slots stepper.
    ///
    /// **Outside the Button, not inside its label.** A `NavigationLink` nested
    /// in a `Button`'s label is two tap targets claiming the same pixels, and
    /// which one wins is a coin toss the user experiences as a broken header.
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title.uppercased())
                        .font(.system(size: 12.5, weight: .bold))
                        .kerning(0.6)
                        .foregroundStyle(Color.satchelSecondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.satchelTertiary)
                        // Rotated rather than swapped for `chevron.right`: the
                        // rotation animates and shows which way it is going, and
                        // a glyph swap at 9pt just blinks.
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    if !isExpanded, let note = collapsedNote ?? collapsedCount.map({ "\($0)" }) {
                        Text(note)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.satchelTertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
    }
}

extension SatchelCollapsibleSectionTitle where Trailing == EmptyView {
    init(title: String,
         isExpanded: Binding<Bool>,
         collapsedCount: Int? = nil,
         collapsedNote: String? = nil) {
        self.init(title: title,
                  isExpanded: isExpanded,
                  collapsedCount: collapsedCount,
                  collapsedNote: collapsedNote) { EmptyView() }
    }
}

// MARK: - Document mark
//
// The glyph-on-tinted-tile that identifies every document. Scope doc §5 says it
// appears in Kit tiles, list rows, the viewer header and the detail screen, so
// it is one component with size presets rather than four near-copies that drift.

struct SatchelDocumentMark: View {
    let icon: DocumentIcon
    let tint: DocumentTint
    var size: CGFloat = 38
    var cornerRadius: CGFloat = 11
    var glyphSize: CGFloat = 19
    /// Kit tiles use a full-width banner rather than a square.
    var stretchWidth: Bool = false

    init(
        icon: DocumentIcon,
        tint: DocumentTint,
        size: CGFloat = 38,
        cornerRadius: CGFloat = 11,
        glyphSize: CGFloat = 19,
        stretchWidth: Bool = false
    ) {
        self.icon = icon
        self.tint = tint
        self.size = size
        self.cornerRadius = cornerRadius
        self.glyphSize = glyphSize
        self.stretchWidth = stretchWidth
    }

    /// Convenience — reads the document's resolved icon and tint, so a
    /// never-scanned document still draws something sensible.
    init(
        _ doc: TraceMacDocument,
        size: CGFloat = 38,
        cornerRadius: CGFloat = 11,
        glyphSize: CGFloat = 19,
        stretchWidth: Bool = false
    ) {
        self.init(
            icon: doc.resolvedIcon,
            tint: doc.resolvedTint,
            size: size,
            cornerRadius: cornerRadius,
            glyphSize: glyphSize,
            stretchWidth: stretchWidth
        )
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(tint.background)
            .frame(width: stretchWidth ? nil : size, height: size)
            .frame(maxWidth: stretchWidth ? .infinity : nil)
            .overlay {
                Image(systemName: icon.sfSymbol)
                    .font(.system(size: glyphSize * 0.82, weight: .regular))
                    .foregroundStyle(tint.foreground)
            }
    }
}

// MARK: - Mark presets

extension SatchelDocumentMark {
    /// `.kit-tile .k-thumb` — full width, 52pt tall, 26pt glyph.
    static func kitTile(_ doc: TraceMacDocument) -> SatchelDocumentMark {
        SatchelDocumentMark(doc, size: 52, cornerRadius: 10, glyphSize: 26, stretchWidth: true)
    }
    /// `.doc-row .doc-icon` — 38pt square, 19pt glyph.
    static func row(_ doc: TraceMacDocument) -> SatchelDocumentMark {
        SatchelDocumentMark(doc, size: 38, cornerRadius: 11, glyphSize: 19)
    }
    /// `.kit-row .kr-icon` — 34pt square, 18pt glyph.
    static func compactRow(_ doc: TraceMacDocument) -> SatchelDocumentMark {
        SatchelDocumentMark(doc, size: 34, cornerRadius: 10, glyphSize: 18)
    }
    /// `.meta-mark` — 40pt square, viewer and detail headers.
    static func header(_ doc: TraceMacDocument) -> SatchelDocumentMark {
        SatchelDocumentMark(doc, size: 40, cornerRadius: 11, glyphSize: 21)
    }
    /// `.icon-swatch` at detail size — 58pt square.
    static func large(_ doc: TraceMacDocument) -> SatchelDocumentMark {
        SatchelDocumentMark(doc, size: 58, cornerRadius: 16, glyphSize: 26)
    }
}

// MARK: - Filing chip
//
// The small coloured chip on a document row saying what it is filed against.
// Colour carries the meaning, so the four cases are an enum rather than a
// free-form (String, Color) pair that would drift.

enum SatchelFiling: Hashable {
    case endeavor(String)
    case note(String)
    case place(String)
    case loose

    var label: String {
        switch self {
        case .endeavor(let name): return name
        case .note(let name):     return name
        case .place(let name):    return name
        case .loose:              return "Unfiled"
        }
    }

    var ink: Color {
        switch self {
        case .endeavor: return .satchelAuto                                    // #5856d6
        case .note:     return .satchelBlue                                    // #0a84ff
        case .place:    return Color(red: 0.141, green: 0.541, blue: 0.239)    // #248a3d
        case .loose:    return .satchelSecondary                               // #8e8e93
        }
    }

    var fill: Color {
        switch self {
        case .endeavor: return DocumentTint.indigo.background
        case .note:     return DocumentTint.blue.background
        case .place:    return DocumentTint.green.background
        case .loose:    return Color(red: 0.941, green: 0.941, blue: 0.949)    // #f0f0f2
        }
    }

    /// How a document describes itself. Endeavor wins over note, note over
    /// place — most specific filing first, matching how the mockup's Recent
    /// rows show a single chip each.
    static func of(_ doc: TraceMacDocument) -> SatchelFiling {
        if let name = doc.endeavorName, !name.isEmpty { return .endeavor(name) }
        if doc.endeavor != nil { return .endeavor("Endeavor") }
        // Uses the shared helper rather than stripping the path again here —
        // two implementations of the same rule is how a journal note ends up
        // rendering as "Home Bills" in one place and "2026-07-26" in another.
        if let name = noteDisplayName(doc.linkedNote) { return .note(name) }
        if doc.category == "Place" { return .place(doc.category) }
        return .loose
    }
}

struct SatchelChip: View {
    let filing: SatchelFiling

    var body: some View {
        Text(filing.label)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(filing.ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(filing.fill, in: RoundedRectangle(cornerRadius: 6))
            .lineLimit(1)
    }
}

// MARK: - Tag pill

struct SatchelTagPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            // One line, always. A pill is a word; a word broken across two
            // lines inside its own rounded rectangle reads as a rendering
            // fault, which is exactly how it read on the Medicare article.
            // The flow layout gives each pill its ideal width, so this only
            // ever bites in a container too narrow for one tag, and there a
            // tail ellipsis is the honest answer.
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(Color(red: 0.420, green: 0.420, blue: 0.439)) // #6b6b70
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Color.satchelFill, in: RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - AI badge

struct SatchelAIBadge: View {
    var body: some View {
        Text("AI")
            .font(.system(size: 9.5, weight: .bold))
            .kerning(0.3)
            .foregroundStyle(Color.satchelAI)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.satchelAIFill, in: RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - Private tag

/// `private` is a warning, not a topic, and it is drawn in four places.
///
/// **One rule in one function, because on the Mac the same change took three
/// renderers and one was missed** — David spotted a blue `private` chip in the
/// list an hour after the other two went orange. A safety marker that is orange
/// in some places and not others teaches the eye that the ordinary colour is
/// fine, which is worse than never having coloured it.
///
/// Orange matches the Mac's chips and Satchel's PRIVATE capture button, so the
/// button that creates the state, the tag that records it and the warning that
/// enforces it are one idea.
enum SatchelPrivateTag {

    static let name = "private"

    static func matches(_ tag: String) -> Bool {
        tag.caseInsensitiveCompare(name) == .orderedSame
    }

    /// Delegates to the model's own property, which is the single definition
    /// and the one the services enforce on. Two spellings of "is this private"
    /// is how the third leak happened.
    static func isPrivate(_ document: TraceMacDocument) -> Bool { document.isPrivate }

    static func isPrivate(_ tags: [String]) -> Bool {
        tags.contains(where: matches)
    }

    /// The colour a tag chip should use.
    static func tint(_ tag: String, base: Color) -> Color {
        matches(tag) ? .orange : base
    }
}

// MARK: - Cover thumbnail
//
// D418. The 52pt square on the right of every reading row.
//
// **Right, not left, and that is the whole reason it works.** With the cover on
// the left every title starts at a different place depending on whether the
// page yielded a picture; on the right the text column is one edge and the
// covers form their own. Instapaper does the same thing for the same reason.
//
// The picture is already on the phone: `SatchelLinkPreview` cached it when the
// link was saved (D387). Nothing is fetched here. When the cache has nothing —
// a page behind a login, or a cache iOS purged — the square draws the site's
// initial on a tint rather than disappearing, so rows keep one height and the
// list does not go ragged. That was the open question on mockup v2 and David
// took the tinted initial.
struct SatchelCoverThumb: View {

    let document: TraceMacDocument
    var side: CGFloat = 52

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.satchelFill
                    Text(initial)
                        .font(.system(size: side * 0.36, weight: .bold))
                        .foregroundStyle(Color.satchelSecondary)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.17, style: .continuous))
        // Cheap — a small JPEG off disk — but still off the render pass, and
        // keyed on the address so a row reused by the lazy stack reloads.
        .task(id: document.url) {
            image = SatchelLinkPreview.image(for: document.url)
        }
    }

    /// The site's first letter, which is what he recognises. Falls back to the
    /// title's, and then to a dash rather than an empty square.
    private var initial: String {
        let site = SatchelShelf.site(document)
        let source = site.isEmpty ? document.title : site
        guard let first = source.first(where: { $0.isLetter || $0.isNumber }) else { return "–" }
        return String(first).uppercased()
    }
}

// MARK: - Swipe row
//
// D418. Two actions, hand-rolled, because `.swipeActions` is a `List` modifier
// and every list in Satchel that is not the Shelf is a `VStack` of rows inside
// one `.satchelCard()`, inside the page's own `ScrollView`.
//
// **This is a deliberate second implementation, not a careless copy.** Trace
// has `TraceSwipeRow` in PeopleView.swift with a note saying to move it to
// TraceSkin.swift if a second list wants it. Satchel cannot have it: it
// compiles twelve named files out of Trace/ and TraceSkin.swift is not one of
// them, so sharing would mean pulling Trace's whole design system into this
// target for one gesture. This one also does something the Trace one does not —
// an action on each side. If a THIRD caller appears, the answer is a small
// shared file added to every target's membership, not a fourth copy.
//
// The gesture is the same fussy shape as Trace's, and for the same reasons:
// `minimumDistance: 20` so a plain tap still reaches the row; horizontal-only
// so a diagonal scroll keeps scrolling; `openID` owned by the caller so opening
// one row closes every other; and an action button hit-testable only while it
// is visible, because an invisible button under a row's tap target is how you
// mark something read by accident.
/// One revealed action. **Top level, not nested in the generic row**: nested in
/// `SatchelSwipeRow<Content>` it could only be named with its generic parameter
/// spelled out, which every call site would have to invent.
struct SatchelSwipeAction {
    let label: String
    let icon: String
    let tint: Color
    let run: () -> Void
}

struct SatchelSwipeRow<Content: View>: View {

    let id: String
    @Binding var openID: String?
    /// Revealed by dragging right. The everyday one: Read.
    var leading: SatchelSwipeAction? = nil
    /// Revealed by dragging left.
    var trailing: SatchelSwipeAction? = nil
    @ViewBuilder var content: () -> Content

    private let revealWidth: CGFloat = 80
    @State private var drag: CGFloat = 0
    /// Which side is showing, so the closed state is one value and not two.
    @State private var settled: CGFloat = 0

    private var isOpen: Bool { openID == id }

    private var offset: CGFloat {
        let raw = (isOpen ? settled : 0) + drag
        let low = trailing == nil ? 0 : -revealWidth
        let high = leading == nil ? 0 : revealWidth
        return max(low, min(high, raw))
    }

    var body: some View {
        ZStack {
            if let leading {
                button(leading, alignment: .leading)
                    .opacity(offset > 1 ? 1 : 0)
                    .allowsHitTesting(isOpen && settled > 0)
            }
            if let trailing {
                button(trailing, alignment: .trailing)
                    .opacity(offset < -1 ? 1 : 0)
                    .allowsHitTesting(isOpen && settled < 0)
            }
            content()
                .background(Color.satchelCard)
                .offset(x: offset)
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height)
                            else { return }
                            if openID != nil && !isOpen { openID = nil; settled = 0 }
                            drag = value.translation.width
                        }
                        .onEnded { value in
                            let end = (isOpen ? settled : 0) + value.translation.width
                            withAnimation(.snappy(duration: 0.22)) {
                                drag = 0
                                if end > revealWidth / 2, leading != nil {
                                    settled = revealWidth
                                    openID = id
                                } else if end < -revealWidth / 2, trailing != nil {
                                    settled = -revealWidth
                                    openID = id
                                } else {
                                    settled = 0
                                    openID = nil
                                }
                            }
                        }
                )
        }
        .onChange(of: isOpen) { _, open in
            drag = 0
            if !open { settled = 0 }
        }
        .clipped()
    }

    private func button(_ action: SatchelSwipeAction, alignment: Alignment) -> some View {
        HStack(spacing: 0) {
            if alignment == .trailing { Spacer(minLength: 0) }
            Button {
                withAnimation(.snappy(duration: 0.2)) { openID = nil; settled = 0 }
                action.run()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: action.icon)
                        .font(.system(size: 16, weight: .semibold))
                    Text(action.label)
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(width: revealWidth)
                .frame(maxHeight: .infinity)
                .background(action.tint)
            }
            .buttonStyle(.plain)
            if alignment == .leading { Spacer(minLength: 0) }
        }
    }
}
