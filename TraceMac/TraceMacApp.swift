// TraceMacApp.swift
// Entry point for the Trace Mac companion app.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI

@main
struct TraceMacApp: App {
    @State private var noteStore = NoteStore.shared
    @State private var notionService = NotionService()

    var body: some Scene {
        WindowGroup {
            TraceMacContentView()
                .environment(noteStore)
                .environment(notionService)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") { }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}
