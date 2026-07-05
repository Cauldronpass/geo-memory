// TraceMacPhotosView.swift
// Photo gallery — grouped by category, list layout with enriched metadata.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

#if os(macOS)
import SwiftUI
import AppKit

// MARK: - Photo entry model

struct PhotoEntry: Identifiable {
    let id: String              // relative path — globally unique
    let relativePath: String
    let category: String        // "People", "Interactions", "Places", etc.
    let filename: String

    // Enriched from Notion data during load
    var displayName: String     // person name, interaction summary, etc.
    var subtitle: String?       // relationship, person names for interactions, etc.
    var entryDate: Date?        // parsed from filename or from Notion record

    // Navigation source
    var sourceType: String?     // "person" or "place"
    var sourceID: String?       // Notion record ID
    var sourceLabel: String?    // human label for the button, e.g. "Bryan Weiss" or "Wildfire"
}

// MARK: - Section model

struct PhotoSection: Identifiable {
    let id: String              // category name
    var entries: [PhotoEntry]
}

// MARK: - Root view

struct TraceMacPhotosView: View {
    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    @State private var sections: [PhotoSection] = []
    @State private var isLoading = true
    @State private var selectedPhoto: PhotoEntry? = nil
    @State private var searchText = ""

    private static let dateParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var filteredSections: [PhotoSection] {
        guard !searchText.isEmpty else { return sections }
        let q = searchText.lowercased()
        return sections.compactMap { section in
            let matching = section.entries.filter {
                $0.displayName.lowercased().contains(q) ||
                ($0.subtitle?.lowercased().contains(q) ?? false) ||
                $0.category.lowercased().contains(q)
            }
            return matching.isEmpty ? nil : PhotoSection(id: section.id, entries: matching)
        }
    }

    private var totalCount: Int {
        filteredSections.reduce(0) { $0 + $1.entries.count }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(spacing: 10) {
                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Spacer()
                if !isLoading {
                    Text("\(totalCount) photo\(totalCount == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        Task { await loadPhotos() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Refresh")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if isLoading {
                Spacer()
                ProgressView("Loading photos…")
                Spacer()
            } else if filteredSections.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 44, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                    Text(sections.isEmpty ? "No photos yet." : "No matches.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(filteredSections) { section in
                        Section {
                            ForEach(section.entries) { entry in
                                PhotoListRow(entry: entry)
                                    .contentShape(Rectangle())
                                    .onTapGesture { selectedPhoto = entry }
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Text(section.id)
                                    .font(.subheadline.weight(.semibold))
                                Text("(\(section.entries.count))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .task { await loadPhotos() }
        .sheet(item: $selectedPhoto) { entry in
            PhotoDetailSheet(entry: entry)
                .environment(noteStore)
                .environment(notionService)
        }
    }

    // MARK: - Load + enrich

    private func loadPhotos() async {
        isLoading = true

        // Ensure Notion data is available for enrichment
        if notionService.people.isEmpty    { await notionService.fetchPeople() }
        if notionService.recentInteractions.isEmpty { await notionService.fetchRecentInteractions() }
        if notionService.places.isEmpty    { await notionService.fetchPlaces() }

        guard let baseURL = noteStore.containerURL else { isLoading = false; return }
        let photosURL = baseURL.appendingPathComponent("Photos")
        guard FileManager.default.fileExists(atPath: photosURL.path) else { isLoading = false; return }

        let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "gif", "webp"]
        let subfolders = (try? FileManager.default.contentsOfDirectory(atPath: photosURL.path))?
            .filter { !$0.hasPrefix(".") }.sorted() ?? []

        var result: [PhotoSection] = []

        for folder in subfolders {
            let subfolder = "Photos/\(folder)"
            guard let files = try? noteStore.listDocumentFiles(in: subfolder) else { continue }
            var entries: [PhotoEntry] = []
            for filename in files {
                let ext = (filename as NSString).pathExtension.lowercased()
                guard imageExts.contains(ext) else { continue }
                let relativePath = "\(subfolder)/\(filename)"
                var entry = PhotoEntry(
                    id: relativePath,
                    relativePath: relativePath,
                    category: folder,
                    filename: filename,
                    displayName: stem(filename),
                    subtitle: nil,
                    entryDate: nil
                )
                enrich(&entry, folder: folder)
                entries.append(entry)
            }
            if !entries.isEmpty {
                // Sort: interactions/visits newest first, people alphabetically
                if folder == "People" {
                    entries.sort { $0.displayName < $1.displayName }
                } else {
                    entries.sort { ($0.entryDate ?? .distantPast) > ($1.entryDate ?? .distantPast) }
                }
                result.append(PhotoSection(id: folder, entries: entries))
            }
        }

        sections = result
        isLoading = false
    }

    /// Enrich a PhotoEntry with resolved Notion metadata.
    private func enrich(_ entry: inout PhotoEntry, folder: String) {
        switch folder {
        case "People":
            let nameStem = stem(entry.filename).replacingOccurrences(of: "_", with: " ")
            if let person = notionService.people.first(where: {
                $0.name.localizedCaseInsensitiveCompare(nameStem) == .orderedSame
            }) {
                entry.displayName = person.name
                entry.subtitle = person.relationship.map { $0.capitalized }
                entry.sourceType  = "person"
                entry.sourceID    = person.id
                entry.sourceLabel = person.name
            } else {
                entry.displayName = nameStem
            }

        case "Interactions":
            // Filename: interaction-YYYY-MM-DD-HHmmss-N.jpg
            let s = stem(entry.filename)
            let parts = s.components(separatedBy: "-")
            if parts.count >= 4 {
                let dateStr = "\(parts[1])-\(parts[2])-\(parts[3])"
                if let date = Self.dateParser.date(from: dateStr) {
                    entry.entryDate = date
                    let cal = Calendar.current
                    if let ix = notionService.recentInteractions.first(where: {
                        cal.isDate($0.date, inSameDayAs: date)
                    }) {
                        let people = ix.personIDs.compactMap { pid in
                            notionService.people.first { $0.id == pid }
                        }
                        let names = people.map { $0.name }
                        entry.displayName = names.isEmpty ? ix.summary : names.joined(separator: ", ")
                        let summaryPart = ix.summary.isEmpty ? "" : " · \(ix.summary)"
                        entry.subtitle = "\(ix.type.capitalized)\(summaryPart)"
                        // Navigate to the first person linked to the interaction
                        if let first = people.first {
                            entry.sourceType  = "person"
                            entry.sourceID    = first.id
                            entry.sourceLabel = first.name
                        }
                    } else {
                        entry.displayName = "Interaction"
                        entry.subtitle = dateStr
                    }
                }
            }

        case "Places":
            let nameStem = stem(entry.filename).replacingOccurrences(of: "_", with: " ")
            if let place = notionService.places.first(where: {
                $0.name.localizedCaseInsensitiveCompare(nameStem) == .orderedSame
            }) {
                entry.displayName = place.name
                entry.subtitle = [place.city, place.category]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
                entry.sourceType  = "place"
                entry.sourceID    = place.id
                entry.sourceLabel = place.name
            } else {
                entry.displayName = nameStem
            }

        default:
            entry.displayName = stem(entry.filename)
        }
    }

    private func stem(_ filename: String) -> String {
        URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
    }
}

// MARK: - List row

private struct PhotoListRow: View {
    let entry: PhotoEntry
    @Environment(NoteStore.self) private var noteStore
    @State private var image: NSImage? = nil

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.08))
                if let img = image {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    ProgressView().scaleEffect(0.5)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Name + subtitle
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayName)
                    .font(.system(.body, weight: .medium))
                    .lineLimit(1)
                if let sub = entry.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Date
            if let date = entry.entryDate {
                Text(Self.dateFormat.string(from: date))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 90, alignment: .trailing)
            }

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .task { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        guard image == nil else { return }
        let delays: [UInt64] = [0, 500_000_000, 1_500_000_000, 4_000_000_000]
        for delay in delays {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            if let url = noteStore.resolvedURL(for: entry.relativePath),
               FileManager.default.fileExists(atPath: url.path),
               let img = NSImage(contentsOf: url) {
                await MainActor.run { image = img }
                return
            }
        }
    }
}

// MARK: - Detail sheet

private struct PhotoDetailSheet: View {
    let entry: PhotoEntry
    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService
    @Environment(\.dismiss)          private var dismiss
    @State private var image: NSImage? = nil

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.displayName)
                        .font(.title3.weight(.semibold))
                    if let sub = entry.subtitle, !sub.isEmpty {
                        Text(sub)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let date = entry.entryDate {
                        Text(Self.dateFormat.string(from: date))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Text(entry.category)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(categoryColor(entry.category).opacity(0.12), in: Capsule())
                        .foregroundStyle(categoryColor(entry.category))
                        .padding(.top, 2)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.escape, modifiers: [])
                    if let type = entry.sourceType,
                       let id   = entry.sourceID,
                       let label = entry.sourceLabel {
                        Button {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                NotificationCenter.default.post(
                                    name: .navigateToRecord,
                                    object: nil,
                                    userInfo: ["type": type, "id": id]
                                )
                            }
                        } label: {
                            Label("Go to \(label)", systemImage: "arrow.right.circle")
                                .font(.subheadline)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 18)

            Divider()

            // Photo
            Group {
                if let img = image {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .padding(20)
                } else {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 480, idealWidth: 640, minHeight: 480, idealHeight: 680)
        .task { await loadImage() }
    }

    private func categoryColor(_ cat: String) -> Color {
        switch cat {
        case "People":       return .indigo
        case "Interactions": return .purple
        case "Places":       return .green
        default:             return .secondary
        }
    }

    private func loadImage() async {
        let delays: [UInt64] = [0, 500_000_000, 1_500_000_000]
        for delay in delays {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            if let url = noteStore.resolvedURL(for: entry.relativePath),
               FileManager.default.fileExists(atPath: url.path),
               let img = NSImage(contentsOf: url) {
                await MainActor.run { image = img }
                return
            }
        }
    }
}

#endif // os(macOS)
