// SatchelRootView.swift
// Satchel only. D416/D417 — three tabs and one action.
//
// **Home · Shelf · All, then a +.** The first three are places; the + is a thing
// you do, which is why it sits at the END of the bar rather than splitting the
// tabs around it. Approved mockup:
// `System/Trace-Swift/satchel-reading-shelf-mockup-v3.html`.
//
// **Why a tab bar at all.** Home had grown four grey section headers — Browse,
// Kind, Due, Recent — stacked in a column, and David: *"the home screen is
// becoming cluttered."* Browse and Kind were never things to look at; they are
// ways of narrowing a list, and Home did not have the list. Moving them to the
// tab that does is the fix, and it is why All exists as a destination rather
// than a screen you reach through a "Show all" link.

import SwiftUI

enum SatchelTab: String {
    case home, shelf, all
}

struct SatchelRootView: View {

    var router: SatchelRouter = SatchelRouter()

    @State private var tab: SatchelTab = .home
    @State private var noteStore = NoteStore.shared

    /// **The stores live here, and that is the point of this view.** Three tabs
    /// read one library. A store per tab would be three scans of the same
    /// folder and three answers to "what is on the shelf", which start
    /// disagreeing the moment a swipe writes a sidecar.
    @State private var store = iOSDocumentStore()
    @State private var endeavorStore = SatchelEndeavorStore()
    /// Whether a full-screen surface has asked for the bar to go (D419).
    @State private var chrome = SatchelChrome()

    /// The room the bar needs under a screen's content. Zero while the reader is
    /// open, or the reader's own bottom bar would float above the bottom of the
    /// screen over an empty strip.
    ///
    /// **Was 72, which was the bar's HEIGHT and not a clearance** (D495).
    private var barInset: CGFloat { chrome.hidesTabBar ? 0 : SatchelTabBar.clearance }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $tab) {
                SatchelLibraryView(router: router, store: store, endeavorStore: endeavorStore)
                    .toolbar(.hidden, for: .tabBar)
                    .tag(SatchelTab.home)

                // `safeAreaPadding` stands in for the inset the system bar
                // used to provide, so a list stops above the band instead of
                // sliding under it. Home already ends in its own bottom
                // padding, which is why it is not repeated there.
                NavigationStack {
                    SatchelShelfView(store: store)
                }
                .toolbar(.hidden, for: .tabBar)
                .safeAreaPadding(.bottom, barInset)
                .tag(SatchelTab.shelf)

                NavigationStack {
                    SatchelAllDocumentsView(documents: store.documents, store: store)
                }
                .toolbar(.hidden, for: .tabBar)
                .safeAreaPadding(.bottom, barInset)
                .tag(SatchelTab.all)
            }
            // The system bar is hidden and replaced, the same shape Dayflow uses
            // (`DayflowRootView`), because the + needs a weight no `tabItem`
            // can give it and the unread dot needs to sit where it is drawn.
            if !chrome.hidesTabBar {
                SatchelTabBar(tab: $tab,
                              unreadOnShelf: hasUnread,
                              onCapture: capture)
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: chrome.hidesTabBar)
        .environment(chrome)
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    /// Something readable and unread is waiting. **A dot, never a count.**
    /// A number on a reading queue is an invitation to get it to zero, and
    /// no-triage is the whole design (D407): an article nobody touches sits in
    /// New forever and costs nothing.
    private var hasUnread: Bool {
        !SatchelShelf.newArrivals(store.documents).isEmpty
    }

    /// The + menu's four ways in.
    ///
    /// **Routed through `SatchelRouter`, not presented here.** The capture sheet
    /// and everything that follows it — the AI pass, the text sweep, the article
    /// fetch, the reload — all live on the Home screen and are tested there.
    /// Presenting a second copy from the root would be two capture paths, which
    /// is how one of them quietly stops running a step the other does.
    private func capture(_ source: SatchelCaptureSource, isPrivate: Bool) {
        tab = .home
        router.pendingCaptureIsPrivate = isPrivate
        router.pendingCapture = source
    }
}

// MARK: - Chrome

/// **The tab bar is drawn by the root, over everything, so a pushed screen
/// cannot hide it the system way.** `.toolbar(.hidden, for: .tabBar)` only
/// reaches the system bar, which is already hidden (D417). The reader is the
/// first screen that must have the whole height, so it says so here and the
/// root listens. An environment object rather than a preference: preferences
/// from a `NavigationStack` destination do not reliably reach the stack's
/// ancestors, and a bar that sometimes stays over the article is worse than
/// none.
@Observable
final class SatchelChrome {
    var hidesTabBar = false
}

// MARK: - The bar

struct SatchelTabBar: View {

    /// **The one number for this bar** (D495, and D333's lesson about the
    /// category list applied to a measurement).
    ///
    /// There were three. The root padded Shelf and All by 72, the viewer by 72,
    /// and Home by 110 - one bar, three answers, and nothing naming which was
    /// right. David, on the viewer: *"the pills at the bottom are slightly still
    /// too low. they seem to be riding the bottom pane with the home, shelf, all
    /// icons."*
    ///
    /// **He is describing the 72 exactly, because 72 IS the bar.** Measured off
    /// this view rather than guessed: `.padding(.top, 9)` + the item (a 20pt
    /// icon, 3pt of spacing, a 10pt caption ≈ 35) + `.padding(.bottom, 26)` ≈
    /// **70 points**. So a 72-point inset stops the content two points above the
    /// bar's top edge - not under it, which is what D444 fixed, but flush against
    /// it, which is what it looks like.
    ///
    /// **110 is the number Home has been using all along** and the one screen
    /// nobody has complained about: the bar plus about 40 points of actual gap.
    /// Adopted rather than invented, and named here so the next screen cannot
    /// pick a fourth.
    static let clearance: CGFloat = 110

    @Binding var tab: SatchelTab
    let unreadOnShelf: Bool
    let onCapture: (SatchelCaptureSource, Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            item(.home, symbol: "house", label: "Home", dot: false)
            item(.shelf, symbol: "book", label: "Shelf", dot: unreadOnShelf)
            item(.all, symbol: "square.grid.2x2", label: "All", dot: false)
            plus
        }
        .padding(.top, 9)
        .padding(.bottom, 26)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.satchelHairline).frame(height: 0.5)
        }
    }

    private func item(_ which: SatchelTab, symbol: String, label: String, dot: Bool) -> some View {
        let active: Bool = tab == which
        let tint: Color = active ? Color.satchelBlue : Color.satchelTertiary
        let glyph: String = active ? symbol + ".fill" : symbol
        return Button {
            tab = which
        } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: glyph)
                        .font(.system(size: 18, weight: .regular))
                        .frame(height: 20)
                    if dot {
                        Circle()
                            .fill(Color.satchelBlue)
                            .frame(width: 6, height: 6)
                            .offset(x: 7, y: -1)
                    }
                }
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// **Tinted, not filled** (D416). David, on the filled version: *"Do you
    /// think the big blue button is appropriate? Is it distracting?"* It was:
    /// the most saturated thing on screen, permanently, on two tabs whose whole
    /// job is to make an article look worth opening. A plain bar item was the
    /// other option and goes too far — most of his documents are photographed
    /// confirmations, so capture is a several-times-a-week action. Tinted is
    /// the same target, the same tap, without competing with the headline.
    private var plus: some View {
        Menu {
            Button { onCapture(.scan, false) } label: {
                Label("Scan", systemImage: "doc.viewfinder")
            }
            Button { onCapture(.photo, false) } label: {
                Label("Take photo", systemImage: "camera")
            }
            Button { onCapture(.library, false) } label: {
                Label("Choose from library", systemImage: "photo")
            }
            Button { onCapture(.file, false) } label: {
                Label("Import file", systemImage: "folder")
            }
            Button { onCapture(.paste, false) } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            Divider()
            // **Its own words and its own colour, never anonymous in a list.**
            // It is the only item here with a consequence, and the orange
            // button it replaces existed so this could not be hit while aiming
            // at Scan. A menu is an acceptable home for it; an unlabelled one
            // would not be.
            Button { onCapture(.scan, true) } label: {
                Label("Private capture", systemImage: "lock.fill")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Color.satchelBlue)
                .frame(width: 36, height: 36)
                .background(Color.satchelBlue.opacity(0.13), in: Circle())
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .frame(height: 33)
    }
}
