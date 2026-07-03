// TraceMacApp.swift
// Entry point for the Trace Mac companion app.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI

@main
struct TraceMacApp: App {
    @State private var noteStore = NoteStore.shared
    @State private var notionService = NotionService()
    @State private var selectedSection: MacSection? = .daily

    var body: some Scene {
        WindowGroup {
            TraceMacContentView(selectedSection: $selectedSection)
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
            CommandMenu("Go") {
                Button("Daily")     { selectedSection = .daily }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Projects")  { selectedSection = .projects }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Places")    { selectedSection = .places }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Horizons")  { selectedSection = .horizons }
                    .keyboardShortcut("4", modifiers: .command)
                Button("People")    { selectedSection = .people }
                    .keyboardShortcut("5", modifiers: .command)
                Button("Documents") { selectedSection = .documents }
                    .keyboardShortcut("6", modifiers: .command)
                Button("Inbox")     { selectedSection = .inbox }
                    .keyboardShortcut("7", modifiers: .command)
            }
        }

        MenuBarExtra("Trace", systemImage: "mappin.circle.fill") {
            TraceMacMenuBarView()
                .environment(noteStore)
                .environment(notionService)
        }
        .menuBarExtraStyle(.window)

        Settings {
            TraceMacSettingsView()
        }
    }
}
