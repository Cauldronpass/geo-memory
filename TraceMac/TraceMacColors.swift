// TraceMacColors.swift
// Color utilities for Trace Mac.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI
import AppKit
import ImageIO

// MARK: - Hex color initializer — REMOVED, Session 64
//
// `Color(hex:)` had exactly six callers and every one of them was a colour
// that ignored appearance; five of the six failed a 3:1 contrast check in one
// appearance or the other. All six now go through `MacPalette` in
// MacColor.swift, which takes the same hex strings but resolves per
// appearance.
//
// The initialiser is gone rather than left unused, because an available
// `Color(hex:)` is precisely how the seventh literal gets written. Hex is
// still reachable — through `Color.macDynamic(light:dark:)`, which cannot be
// called without answering the question that produced this audit: what does
// it look like in the other appearance?
//
// Same principle as `MacType` having roles instead of sizes and `MacAvatar`
// having rungs instead of diameters. See D19.

// MARK: - Named Trace colors

extension Color {
    /// Trace brand orange.
    ///
    /// Session 64: was a flat #F4793A, which measures **2.33:1** against the
    /// light sidebar — under the 3:1 bar, in the appearance David actually
    /// uses. Now resolves per appearance; see `MacColor.swift` for the audit.
    ///
    /// Still divergent from iOS, which calls the same token #FF9500 in
    /// `TraceSkin.swift` (1.86:1 in light, worse). One token, two apps, two
    /// oranges. Not fixed here because this file cannot reach the iOS target.
    static let traceOrange = MacPalette.orange
}

// MARK: - NSImage → JPEG Data

extension NSImage {
    /// Returns JPEG-encoded bytes using CGImageDestination (explicit UTI "public.jpeg").
    /// NSBitmapImageRep silently falls back to PNG on images with alpha; CGImageDestination does not.
    func jpegData(compressionQuality: CGFloat = 0.8) -> Data? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let output = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            output, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, [
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return output as Data
    }
}
