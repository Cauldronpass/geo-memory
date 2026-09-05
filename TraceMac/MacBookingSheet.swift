// MacBookingSheet.swift
// One sheet for every Kind of booking, create and edit (D267, Session 86).
//
// **One sheet, not seven.** The thirteen Notion columns never change; only the
// words on the labels do, and those come from `BookingKind.labels(for:)` in
// Models.swift so the phone's sheet can reuse them rather than re-deriving a
// second set that drifts.
//
// **The Name is written, never typed.** `BookingKind.writtenName` builds it
// from Provider, Number, From and To, and the sheet shows what it will save
// under the fields so nothing is a surprise.
//
// **Delete is a confirm, then gone.** David's call: a booking is deleted rarely
// and deliberately, and Notion's own trash is the recovery path. No timed undo
// bar; that is a mechanism for a mistake a confirm already prevents.

import SwiftUI

struct MacBookingSheet: View {

    /// Notion's seven Kind options, in the database's own order.
    private let kinds = ["Flight", "Shuttle", "Train", "Hotel", "Car rental", "Parking", "Other"]

    /// The endeavor this booking belongs to. Its slug is written to `Endeavor`
    /// and its people are offered first in Who.
    let endeavor: Endeavor
    /// Nil creates, non-nil edits.
    let existing: Booking?
    /// Everyone in Notion People, for the search below the endeavor's own.
    let people: [Person]
    /// Names attached to this endeavor, in the rail's own order.
    let endeavorPeople: [String]

    let onSave: (Booking) async throws -> Void
    /// Only offered when editing. Nil hides the button entirely.
    var onDelete: ((Booking) async throws -> Void)? = nil
    /// Creates a person in Notion and returns them. Nil hides the offer.
    var onAddPerson: ((String) async throws -> Person)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var kind         = "Flight"
    @State private var whoIDs: [String] = []
    @State private var hasDate      = true
    @State private var hasTime      = true
    @State private var hasEnd       = true
    @State private var start        = Date()
    @State private var end          = Date()
    @State private var from         = ""
    @State private var to           = ""
    @State private var provider     = ""
    @State private var number       = ""
    @State private var confirmation = ""
    @State private var costText     = ""
    @State private var booked       = false
    @State private var notes        = ""

    @State private var personQuery  = ""
    @State private var saving       = false
    @State private var confirmingDelete = false
    @State private var failure: String? = nil
    @State private var seeded       = false
    /// People created from inside this sheet.
    ///
    /// `people` is a snapshot passed in at presentation, so someone added here
    /// would be selected and invisible: ticked in `whoIDs`, absent from every
    /// list that renders it. This keeps them on screen until the sheet closes
    /// and the real fetch catches up.
    @State private var created: [Person] = []

    /// Everyone this sheet can offer.
    private var pool: [Person] { people + created }

    private var isEdit: Bool { existing != nil }
    private var labels: BookingKind.Labels { BookingKind.labels(for: kind) }

    /// Everyone the endeavor already names, resolved to a Notion person.
    ///
    /// The endeavor's own people first, which is the whole point: on a trip
    /// with one person on it, that person is already ticked and the field is
    /// finished before it is looked at.
    private var offeredPeople: [Person] {
        var seen = Set<String>()
        var out: [Person] = []
        for name in endeavorPeople {
            guard let match = pool.first(where: {
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) else { continue }
            if seen.insert(match.id).inserted { out.append(match) }
        }
        // Anyone already on the booking but not on the endeavor still belongs
        // in the list, ticked. Dropping them would silently unassign someone.
        for id in whoIDs where !seen.contains(id) {
            if let match = pool.first(where: { $0.id == id }) {
                seen.insert(id)
                out.append(match)
            }
        }
        return out
    }

    private var searchMatches: [Person] {
        let q = personQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let offered = Set(offeredPeople.map(\.id))
        return pool
            .filter { !$0.isArchived }
            .filter { !offered.contains($0.id) }
            .filter { $0.name.localizedCaseInsensitiveContains(q) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .prefix(6)
            .map { $0 }
    }

    /// The typed name, when it is worth offering to create.
    ///
    /// Two characters, because one is a typo. Nothing offered when the name
    /// already exists: that person is in `searchMatches` and picking them is
    /// the right move. `NotionService.addPerson` writes the Notion page AND
    /// the container note stub, so a person made here is a real person
    /// everywhere, not a name on one booking.
    private var createName: String? {
        guard onAddPerson != nil else { return nil }
        let q = personQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return nil }
        guard !pool.contains(where: {
            $0.name.localizedCaseInsensitiveCompare(q) == .orderedSame
        }) else { return nil }
        return q
    }

    /// The Kind picker's binding, and **the clear lives here rather than in an
    /// `onChange`.**
    ///
    /// David: *"i typed moms and hit save... when i went back to the edit
    /// screen mom was not there."* Opening the sheet on a hotel sets `kind`
    /// from its initial `Flight` to `Hotel`, and an `onChange(of: kind)` fired
    /// on that, saw a journey become a stay, and cleared From and To — after
    /// the seeding block had filled them. A flight was fine because its kind
    /// never changed, so only Hotel, Parking and Other lost their fields, and
    /// only on open.
    ///
    /// Warning ONE's shape: the behaviour was attached to the VALUE changing
    /// rather than to the user changing it. A binding is where a user change
    /// arrives and seeding never goes through one, so the rule cannot fire on
    /// a value the sheet set for itself.
    ///
    /// The rule itself is unchanged and is David's: keep a value when it still
    /// means the same thing. Flight to Shuttle keeps DEN and ORD; Flight to
    /// Hotel clears them, because offering "ORD" as the name of a hotel is
    /// worse than an empty field. Confirmation, Cost, Booked and Notes are
    /// never cleared: they mean the same thing whatever this is.
    private var kindBinding: Binding<String> {
        Binding(
            get: { kind },
            set: { new in
                let old = kind
                kind = new
                guard BookingKind.group(for: old) != BookingKind.group(for: new) else { return }
                from = ""
                to = ""
            }
        )
    }

    private var writtenName: String {
        BookingKind.writtenName(kind: kind, provider: provider, number: number,
                                from: from, to: to,
                                start: hasDate ? start : nil,
                                end: hasDate && hasEnd ? end : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isEdit ? "Edit Booking · \(endeavor.name)" : "New Booking · \(endeavor.name)")
                .font(MacType.heading)
                .lineLimit(1)
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)

            Form {
                Section {
                    Picker("Kind", selection: kindBinding) {
                        ForEach(kinds, id: \.self) { Text(shortKind($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section("Who") {
                    ForEach(offeredPeople) { person in
                        Toggle(person.name, isOn: binding(for: person.id))
                    }
                    TextField("Someone else…", text: $personQuery)
                    ForEach(searchMatches) { person in
                        Button {
                            whoIDs.append(person.id)
                            personQuery = ""
                        } label: {
                            Label(person.name, systemImage: "plus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                    if let createName {
                        Button { addPerson(named: createName) } label: {
                            Label("Add “\(createName)” to your people",
                                  systemImage: "person.badge.plus")
                        }
                        .buttonStyle(.plain)
                        .disabled(saving)
                    }
                }

                Section {
                    Toggle("Has a date", isOn: $hasDate)
                    if hasDate {
                        Toggle("Include times", isOn: $hasTime)
                        // `MacDateField`, the month graphic the New Endeavor
                        // sheet already uses. David: *"we have used a simple
                        // graphic of a month in the past so i just click the
                        // date."* A `DatePicker` in a Form renders as stepper
                        // fields, which makes you type your way to a day you
                        // could have pointed at. It gained an optional time in
                        // this session rather than being copied.
                        MacDateField(label: labels.start, date: $start, includesTime: hasTime)
                        Toggle("Has \(labels.end.lowercased())", isOn: $hasEnd)
                        if hasEnd {
                            MacDateField(label: labels.end, date: $end, includesTime: hasTime)
                        }
                    }
                }

                Section {
                    if let fromLabel = labels.from {
                        TextField(fromLabel, text: $from)
                    }
                    TextField(labels.to, text: $to)
                    TextField(labels.provider, text: $provider)
                    TextField(labels.number, text: $number)
                }

                Section {
                    TextField("Confirmation", text: $confirmation)
                    TextField("Cost", text: $costText)
                    Toggle("Booked", isOn: $booked)
                    TextField("Notes", text: $notes, axis: .vertical)
                }

                Section {
                    // What the app is about to write, so the one field you
                    // cannot type is the one you can always see.
                    LabeledContent("Will save as") {
                        Text(writtenName)
                            .font(MacType.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .formStyle(.grouped)

            if let failure {
                Text(failure)
                    .font(MacType.meta)
                    .foregroundStyle(MacEditorialColor.accent)
                    .padding(.horizontal, 20).padding(.bottom, 6)
            }

            Divider()
            HStack {
                if isEdit, onDelete != nil {
                    Button("Delete…", role: .destructive) { confirmingDelete = true }
                        .disabled(saving)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEdit ? "Save" : "Add") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 460)
        .confirmationDialog("Delete “\(existing?.name ?? "")”?",
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Archives the page in Notion. Recoverable from Notion's trash, not from here.")
        }
        .task {
            // Seeded once, not bound: an edit to a field must survive the next
            // re-render, and `.task` re-runs on identity change rather than on
            // every body evaluation. `MacEndeavorSheet`'s rule.
            guard !seeded else { return }
            seeded = true
            guard let b = existing else {
                // Creating. Default Who to the endeavor's people when there is
                // exactly one, which is the case this is for.
                if offeredPeople.count == 1, let only = offeredPeople.first {
                    whoIDs = [only.id]
                }
                return
            }
            kind         = kinds.contains(b.kind) ? b.kind : "Other"
            whoIDs       = b.whoIDs
            hasDate      = b.start != nil
            hasTime      = b.hasTime
            hasEnd       = b.end != nil
            if let s = b.start { start = s }
            if let e = b.end   { end   = e }
            from         = b.from ?? ""
            to           = b.to ?? ""
            provider     = b.provider ?? ""
            number       = b.number ?? ""
            confirmation = b.confirmation ?? ""
            costText     = b.cost.map { String(format: "%g", $0) } ?? ""
            booked       = b.booked
            notes        = b.notes ?? ""
        }
    }

    /// "Car rental" is the Notion option; "Car" is what fits seven segments.
    /// The tag is always the stored value, so the abbreviation never reaches
    /// the database.
    private func shortKind(_ kind: String) -> String {
        kind == "Car rental" ? "Car" : kind
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { whoIDs.contains(id) },
            set: { on in
                if on {
                    if !whoIDs.contains(id) { whoIDs.append(id) }
                } else {
                    whoIDs.removeAll { $0 == id }
                }
            }
        )
    }

    /// A typed cost, or nil. Strips anything that is not part of a number so
    /// "$318" and "318.00" both mean the same thing.
    private var parsedCost: Double? {
        let cleaned = costText.filter { $0.isNumber || $0 == "." }
        guard !cleaned.isEmpty, let value = Double(cleaned), value > 0 else { return nil }
        return value
    }

    private func draft() -> Booking {
        Booking(id: existing?.id ?? "",
                name: writtenName,
                kind: kind,
                endeavorID: endeavor.id,
                whoIDs: whoIDs,
                start: hasDate ? start : nil,
                end: hasDate && hasEnd ? end : nil,
                hasTime: hasDate && hasTime,
                from: labels.from == nil ? nil : from,
                to: to,
                provider: provider,
                number: number,
                confirmation: confirmation,
                notes: notes,
                cost: parsedCost,
                booked: booked)
    }

    private func addPerson(named name: String) {
        guard let onAddPerson else { return }
        saving = true
        failure = nil
        Task {
            do {
                let person = try await onAddPerson(name)
                created.append(person)
                if !whoIDs.contains(person.id) { whoIDs.append(person.id) }
                personQuery = ""
                saving = false
            } catch {
                failure = error.localizedDescription
                saving = false
            }
        }
    }

    private func save() {
        saving = true
        failure = nil
        Task {
            do {
                try await onSave(draft())
                dismiss()
            } catch {
                // Stays open with the typing intact. A sheet that closes on a
                // failed write throws away the work and says nothing.
                failure = error.localizedDescription
                saving = false
            }
        }
    }

    private func delete() {
        guard let existing, let onDelete else { return }
        saving = true
        failure = nil
        Task {
            do {
                try await onDelete(existing)
                dismiss()
            } catch {
                failure = error.localizedDescription
                saving = false
            }
        }
    }
}
