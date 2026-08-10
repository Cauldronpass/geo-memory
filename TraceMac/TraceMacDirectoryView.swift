// TraceMacDirectoryView.swift
// People, Places, Visits and Discover as one destination with local-state tabs.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.
//
// Session 63 (2026-08-02), design decision D1. Second of the three container
// views; `TraceMacNotesView` was the first and is the pattern.
//
// Why local `@State` for the tab: three earlier attempts drove tabs from the
// app-level `selectedSection`, which the sidebar's `List(selection:)` also
// reads, and none of them responded to a click. Every tab bar in this app that
// works — Archive, Place detail, People, the document pane, the project hub —
// owns its selection locally. This does too.

import SwiftUI

struct TraceMacDirectoryView: View {

    enum DirectoryTab: String, CaseIterable, Identifiable {
        case people   = "People"
        case places   = "Places"
        case visits   = "Visits"
        case discover = "Discover"
        var id: String { rawValue }
    }

    /// Set by `TraceMacContentView` when a wikilink, a Home row, or a
    /// `navigateToRecord` post asks to open a specific record. Non-nil selects
    /// the matching tab; the destination view then consumes and clears it, the
    /// same handoff that already worked when these were separate sections.
    var deepLinkPersonID: Binding<String?>? = nil
    var deepLinkPlaceID:  Binding<String?>? = nil

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    @State private var tab: DirectoryTab = .people

    var body: some View {
        VStack(spacing: 0) {
            // One shared header row — see `TraceMacSectionHeader.swift` for why
            // the title is here and why the tabs are leading rather than
            // trailing. The tab *state* stays local to this view.
            MacSectionHeader("Directory") {
                MacTabStrip(options: DirectoryTab.allCases,
                            selection: $tab) { $0.rawValue }
            }

            Group {
                switch tab {
                case .people:
                    TraceMacPeopleView(deepLinkPersonID: deepLinkPersonID)
                        .environment(notionService)
                case .places:
                    TraceMacPlacesView(deepLinkPlaceID: deepLinkPlaceID)
                        .environment(noteStore)
                        .environment(notionService)
                case .visits:
                    // Was a sheet layered on top of Places until this session, so
                    // the full history of everywhere you have been was a modal
                    // you dismissed to get back. A visit belongs to a person and
                    // a place equally, which makes it a peer of both.
                    MacAllVisitsView()
                        .environment(notionService)
                case .discover:
                    TraceMacDiscoverView()
                        .environment(notionService)
                        .environment(noteStore)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Select the tab before the value is consumed: the destination view has
        // to be on screen to receive it. Setting the tab mounts it, and its own
        // `.task(id:)` then takes the id and clears the binding.
        .task(id: deepLinkPersonID?.wrappedValue) {
            if deepLinkPersonID?.wrappedValue != nil { tab = .people }
        }
        .task(id: deepLinkPlaceID?.wrappedValue) {
            if deepLinkPlaceID?.wrappedValue != nil { tab = .places }
        }
    }
}
