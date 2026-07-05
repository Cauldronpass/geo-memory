// TraceDocumentModels.swift
// Shared document model types used by both iOS and Mac targets.
// Add this file to: Trace (iOS), TraceMac targets. Do NOT add to Widget or Share Extension.

import Foundation

// MARK: - Document model

struct TraceMacDocument: Identifiable, Hashable {
    let id: UUID = UUID()
    let relativePath: String     // "Documents/Inbox/2026-07-02-receipt.pdf"
    let filename: String         // "2026-07-02-receipt.pdf"
    let category: String         // "Inbox", "Project", "Place", "Trip", etc.
    let fileExtension: String    // "pdf", "jpg", "png", etc. (lowercased)
    var title: String            // from sidecar or derived from filename
    var tags: [String]           // from sidecar frontmatter
    var created: Date?           // from sidecar or filesystem
    var linkedNote: String?      // from sidecar `linked_note` field
    var people: [String]         // from sidecar `people` field
    var description: String      // from sidecar `description` field

    var isPDF: Bool   { fileExtension == "pdf" }
    var isImage: Bool { ["jpg","jpeg","png","heic","gif","webp"].contains(fileExtension) }

    var sidecarPath: String {
        let base = relativePath.hasSuffix(".\(fileExtension)")
            ? String(relativePath.dropLast(fileExtension.count + 1))
            : relativePath
        return "\(base).md"
    }
}

// MARK: - Scan result

struct DocumentScanResult {
    let tags: [String]        // suggested tags (lowercased)
    let description: String   // 1–2 sentence summary
    let title: String?        // suggested title; nil if filename is already human-readable
}
