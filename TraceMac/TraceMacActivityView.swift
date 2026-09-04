// TraceMacActivityView.swift
// Billiards, Fitness and Photos as one destination with local-state tabs.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.
//
// Session 63 (2026-08-02), design decision D1. Third and last of the container
// views, after `TraceMacNotesView` and `TraceMacDirectoryView`.
//
// The three are grouped because of how they are used, not what they hold: all
// three are **logged on the phone, where they happen**, and read here. That is
// also why none of them takes a deep link — nothing elsewhere in the app links
// into a workout — which makes this the simplest of the three containers.
//
// Tab state is local `@State`, for the reason recorded on `TraceMacNotesView`.

import SwiftUI

struct TraceMacActivityView: View {

    enum ActivityTab: String, CaseIterable, Identifiable {
        case billiards = "Billiards"
        case fitness   = "Fitness"
        case photos    = "Photos"
        var id: String { rawValue }
    }

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    @State private var tab: ActivityTab = .billiards

    var body: some View {
        VStack(spacing: 0) {
            // One shared header row — see `TraceMacSectionHeader.swift` for why
            // the title is here and why the tabs are leading rather than
            // trailing. The tab *state* stays local to this view.
            // D260 (Session 83): tab words over a masthead. Everything below
            // the rule is each room's own and is unchanged tonight.
            MacEditorialTabMasthead(kicker: "Activity",
                                    tabs: ActivityTab.allCases,
                                    selection: $tab) { $0.rawValue }

            Group {
                switch tab {
                case .billiards:
                    TraceMacBilliardsView()
                        .environment(notionService)
                case .fitness:
                    TraceMacFitnessView()
                        .environment(notionService)
                case .photos:
                    TraceMacPhotosView()
                        .environment(noteStore)
                        .environment(notionService)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
