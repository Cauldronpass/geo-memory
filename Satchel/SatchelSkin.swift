import SwiftUI

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
