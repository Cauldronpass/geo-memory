// TraceMacColors.swift
// Color utilities for Trace Mac.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI
import AppKit
import ImageIO

// MARK: - Hex color initializer

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8)  & 0xFF) / 255
        let b = Double(int         & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Named Trace colors

extension Color {
    /// Trace brand orange — #F4793A
    static let traceOrange = Color(hex: "F4793A")
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
