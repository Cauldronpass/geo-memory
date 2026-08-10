// MacEmptyState.swift
// The component twenty-three views each invented separately.
//
// Session 64, following the type scale in MacType.swift.
//
// ── What was there ────────────────────────────────────────────────────────
//
// Twenty-four `Image(systemName:)` calls at 28pt and above. Every single one
// sat at the top of a centred VStack above a "nothing here" message. One job,
// and it was drawn with:
//
//     8 sizes     28 · 32 · 36 · 38 · 40 · 44 · 48 · 52
//     2 weights   .thin · .ultraLight
//     4 spacings  8 · 10 · 12 · 16
//
// Three files draw *the same empty state twice at two different sizes*,
// because the list version and the detail version were written weeks apart:
// Billiards 40 and 48, Fitness 40 and 48, Inbox 36 and 40. Nobody chose that.
//
// ── I said this was pure subtraction. It was not, quite. ──────────────────
//
// Reading all twenty-four together, they are not one state. They are two,
// and the split is not arbitrary — the old code already respected it without
// anyone naming it:
//
//   **placeholder** — "Select a person", "Select a document". Nothing is
//   *missing*; you simply have not picked yet, and the thing you would pick
//   is visible in the list beside it. These were consistently drawn larger
//   (40–52, leaning `.ultraLight`) with a single line of text at `.title3`.
//
//   **list** — "No visits yet", "Your inbox is clear.", "No documents linked
//   to Bronwyn Kelly". Something genuinely is not there. These were drawn
//   smaller (28–44, leaning `.thin`), at `.caption` or `.subheadline`, and
//   they are the ones that often carry a second explanatory line.
//
// So the sizes were noise but the *instinct* underneath them was real, and
// collapsing all twenty-four to one treatment would have thrown away a
// distinction the app had been making correctly by accident. Two roles.
//
// ── Deliberately not converted ────────────────────────────────────────────
//
// Four of the twenty-four are not empty states at all and keep their own
// drawing until each gets a decision of its own:
//
//   * `TraceMacDocumentsView` "Drop to import" — a drag-target overlay. It is
//     accent-coloured and it appears *because* something is about to happen.
//   * "Open in Default App" over a filename — an unsupported *file type*, with
//     an action. The content exists; we cannot draw it.
//   * "Image not available / It may still be downloading from iCloud" — a
//     pending-or-failed state. "Not yet" and "not there" are different claims
//     and should not share a component.
//   * "No project note linked", which has call-to-action buttons under it.
//     A real empty state, but the CTA pattern is a separate question.
//
// Absence, not-yet, unsupported, and unselected are four different things.
// The first two roles here cover two of them and are honest about the rest.

import SwiftUI

struct MacEmptyState: View {

    enum Kind {
        /// Nothing picked yet. The detail pane beside a populated list.
        case placeholder
        /// Nothing there. An empty list, tab, or filtered result.
        case list
    }

    let kind: Kind
    let icon: String
    let message: String
    var detail: String? = nil

    /// Nothing selected. Larger, lighter, one line.
    static func placeholder(_ icon: String, _ message: String) -> MacEmptyState {
        MacEmptyState(kind: .placeholder, icon: icon, message: message)
    }

    /// Nothing there. Smaller, with room for a second line that says what to
    /// do about it.
    static func list(_ icon: String, _ message: String, detail: String? = nil) -> MacEmptyState {
        MacEmptyState(kind: .list, icon: icon, message: message, detail: detail)
    }

    // Sizes chosen as the centre of what each role was already doing, not
    // invented: placeholders clustered 40–52 on `.ultraLight`, lists 28–44 on
    // `.thin`. The weight split is optical, not decorative — `.ultraLight` at
    // 32pt is nearly invisible on a Retina display, and `.thin` at 44pt reads
    // heavy next to a single line of secondary text.
    private var iconSize: CGFloat { kind == .placeholder ? 44 : 32 }
    private var iconWeight: Font.Weight { kind == .placeholder ? .ultraLight : .thin }
    private var spacing: CGFloat { kind == .placeholder ? 12 : 8 }
    private var messageFont: Font { kind == .placeholder ? MacType.body : MacType.meta }

    // No frame. Call sites already own how they centre — most with
    // `.frame(maxWidth: .infinity, maxHeight: .infinity)`, two with a pair of
    // `Spacer()`s — and baking one in would silently change the other.
    var body: some View {
        VStack(spacing: spacing) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: iconWeight))
                .foregroundStyle(.tertiary)

            Text(message)
                .font(messageFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let detail {
                Text(detail)
                    .font(MacType.meta)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
        }
    }
}
