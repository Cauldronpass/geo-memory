import SwiftUI
import UIKit

// MARK: - DayflowUndoStack
//
// Undo for deletes (Session 78 — David: "Is there any way to have an undo
// option in the settings maybe?"). Not a setting: EventKit reminder deletes
// are PERMANENT (no trash, no recently-deleted for reminders), so the only
// honest undo is app-level — snapshot what is about to go, and offer one
// quiet pill for a few seconds to put it back. Recreation restores title,
// notes, date and list; a recurrence rule or alarm on the deleted task does
// not survive the round trip (a new EKReminder gets a new identity), which
// is acceptable for the accidental-delete case this exists for.
//
// Two producers: the selection bar's confirmed bulk delete
// (DayflowRootView.deleteSelected) and the Inbox card's ask-nothing Delete
// (its locked no-confirmation behavior is exactly why it earns an undo).
// One consumer: the pill in DayflowRootView's bottom overlay, floating
// above the tab bar on whichever tab is up.

@Observable
final class DayflowUndoStack {
    static let shared = DayflowUndoStack()

    struct Snapshot {
        let title: String
        let notes: String?
        let date: Date?
        let list: String?
    }

    private(set) var snapshots: [Snapshot] = []
    var visible = false
    /// Bumped on every record/undo so a stale auto-hide can't close a newer
    /// pill (the same generation-token shape as the app's other timers).
    private var generation = 0

    private init() {}

    func record(_ tasks: [ThingsTask]) {
        guard !tasks.isEmpty else { return }
        snapshots = tasks.map {
            Snapshot(title: $0.title, notes: $0.notes, date: $0.date, list: $0.list)
        }
        generation += 1
        let g = generation
        withAnimation(.easeOut(duration: 0.2)) { visible = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.generation == g else { return }
            withAnimation(.easeIn(duration: 0.25)) { self.visible = false }
        }
    }

    func undo() {
        let batch = snapshots
        snapshots = []
        generation += 1
        withAnimation(.easeIn(duration: 0.15)) { visible = false }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            for snap in batch {
                _ = await ReminderTaskStore.shared.addTask(title: snap.title,
                                                           date: snap.date,
                                                           list: snap.list,
                                                           notes: snap.notes)
            }
        }
    }

    var label: String {
        if snapshots.count == 1 {
            return "Deleted \u{201C}\(snapshots[0].title)\u{201D}"
        }
        return "Deleted \(snapshots.count) tasks"
    }
}

// MARK: - The pill

struct DayflowUndoPill: View {
    @State private var undo = DayflowUndoStack.shared

    var body: some View {
        HStack(spacing: 16) {
            Text(undo.label)
                .font(.system(size: 13))
                .foregroundStyle(Color.dayflowPaper)
                .lineLimit(1)
            Button { undo.undo() } label: {
                Text("UNDO")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(Color.dayflowAccent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
        .background(Color.dayflowInk, in: Capsule())
        .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 5)
    }
}
