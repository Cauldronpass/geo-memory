// DayflowBookingSheet.swift
// Dayflow
//
// The phone's booking editor (Session 88). `MacBookingSheet`'s DESIGN, not its
// code: the same fourteen Notion columns, the same labels out of
// `BookingKind.labels(for:)`, the same help text out of `BookingKind.help(for:)`,
// and the same rule that **the Name is written and never typed**.
//
// It exists because the bands shipped without it and that was the wrong call.
// David, looking at a Project with QUOTES and SCHEDULE on it: *"there is no
// plus sign to open anything for Quote, Schedule."* The bands were built with
// no `+` deliberately, on the Mac's own Session 86 reasoning that a door which
// is drawn and does not open is worse than no door. That reasoning is sound
// and the conclusion was still wrong: the answer to a band with no editor is
// the editor, not a band you can only read.
//
// **Nothing here re-derives what the Mac derives.** Every word on every label,
// every help sentence, the written name, the group rule that decides whether
// From and To survive a Kind change, and the three ledger seeds all come from
// `Models.swift`. That is why this file is a form and not a second opinion.
//
// **What the phone does NOT offer, deliberately: creating a person.** The Mac
// grew that because its own add-person sheet already lived beside this one.
// Adding it here would be a second place in the app that writes a Notion
// Person, and Who can be filled from people who already exist. Backlogged.

import SwiftUI

struct DayflowBookingSheet: View {

    /// Notion's seven Kind options, in the database's own order.
    private let kinds = ["Flight", "Shuttle", "Train", "Hotel", "Car rental", "Parking", "Other"]

    /// The endeavor this booking belongs to. Its slug is what gets written,
    /// and its own people are offered first under Who.
    let endeavor: Endeavor
    /// Nil creates, non-nil edits.
    let existing: Booking?
    /// True when the `+` that opened this was the LEDGER's rather than the
    /// schedule band's.
    ///
    /// It seeds three things and nothing else: no date, Kind `Other`, Status
    /// `Quoted`. **A ledger row is defined by having a cost and no date**, so a
    /// `+` on QUOTES that opened a dated Flight would be asking for the one
    /// shape the band it came from cannot show. `Other`'s labels are already
    /// Provider / Number / To, which is D268's own mapping for the work
    /// Bookings was not designed for: Provider is the contractor, Cost the
    /// quote, Number the job number. Every seed stays editable.
    var seedLedger: Bool = false

    @Environment(\.dismiss) private var dismiss
    @State private var notionService = NotionService.shared

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
    @State private var status: String? = nil
    @State private var notes        = ""

    @State private var personQuery  = ""
    @State private var showingHelp  = false
    @State private var saving       = false
    @State private var confirmingDelete = false
    @State private var failure: String? = nil
    /// Seeding runs once. A `.task` that re-seeded on every appearance would
    /// throw away typing the moment anything upstream published.
    @State private var seeded       = false

    private var isEdit: Bool { existing != nil }
    private var labels: BookingKind.Labels { BookingKind.labels(for: kind) }

    /// The endeavor's own people first, then everyone else, so the four names
    /// most likely to be on this booking are not behind a search.
    private var offeredPeople: [Person] {
        let attached = Set(endeavor.people.map { $0.lowercased() })
        return notionService.people
            .filter { attached.contains($0.name.lowercased()) || whoIDs.contains($0.id) }
            .sorted { $0.name < $1.name }
    }

    private var searchMatches: [Person] {
        let q = personQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard q.count >= 2 else { return [] }
        let alreadyOffered = Set(offeredPeople.map(\.id))
        return notionService.people
            .filter { !alreadyOffered.contains($0.id) && $0.name.lowercased().contains(q) }
            .sorted { $0.name < $1.name }
            .prefix(8)
            .map { $0 }
    }

    /// **The clear-on-group-change rule lives on the CONTROL, not on the
    /// state.** D267's bug, and warning ELEVEN: seeding this sheet from an
    /// existing hotel changes `kind` from its initial `Flight`, and a rule
    /// attached to the VALUE fired on that and wiped the fields the seeding
    /// had just filled. A rule about "when the user does X" belongs where the
    /// user's action arrives.
    ///
    /// Keep a value when it still means the same thing: Flight to Shuttle
    /// keeps DEN and ORD, Flight to Hotel clears them, because offering "ORD"
    /// as the name of a hotel is worse than an empty field. Confirmation,
    /// Cost, Booked and Notes are never cleared: they mean the same thing
    /// whatever this is.
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

    private static let statuses = [BookingStatus.quoted,
                                   BookingStatus.accepted,
                                   BookingStatus.declined]

    /// Optional Status as a non-optional selection, `""` meaning none. SwiftUI
    /// can tag an optional and every call site then has to spell
    /// `String?.none`; mapping once is cheaper than remembering.
    private var statusBinding: Binding<String> {
        Binding(
            get: { status ?? "" },
            set: { status = $0.isEmpty ? nil : $0 }
        )
    }

    private var writtenName: String {
        BookingKind.writtenName(kind: kind, provider: provider, number: number,
                                from: from, to: to,
                                start: hasDate ? start : nil,
                                end: hasDate && hasEnd ? end : nil)
    }

    /// A typed cost, or nil. Strips anything that is not part of a number so
    /// "$318" and "318.00" mean the same thing.
    private var parsedCost: Double? {
        let cleaned = costText.filter { $0.isNumber || $0 == "." }
        guard !cleaned.isEmpty, let value = Double(cleaned), value > 0 else { return nil }
        return value
    }

    var body: some View {
        NavigationStack {
            Form {
                kindSection
                whenSection
                detailsSection
                moneySection
                whoSection
                notesSection
                if isEdit { deleteSection }
                if let failure {
                    Section {
                        Text(failure)
                            .font(.footnote)
                            .foregroundStyle(Color.dayflowAccent)
                    }
                }
            }
            .navigationTitle(isEdit ? "Booking" : "New booking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    // The `i`, in the header rather than one per row. **Six of
                    // the labels are rewritten by Kind**, so per-field help
                    // would be authored seven times or fit none of the seven.
                    Button { showingHelp = true } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("What each field is")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(saving)
                }
            }
            .sheet(isPresented: $showingHelp) { helpSheet }
            .confirmationDialog("Delete this booking?",
                                isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("It is archived in Notion, so it can be recovered there.")
            }
            .task { seed() }
        }
    }

    // MARK: Sections

    private var kindSection: some View {
        Section {
            // `.navigationLink`, not the default menu. The details sheet's
            // Type picker was a plain `Picker` in a Form and its menu did not
            // present at all inside a sheet - found on David's simulator the
            // same session this file was written. Seven options is a list.
            Picker("Kind", selection: kindBinding) {
                ForEach(kinds, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.navigationLink)
        } footer: {
            // **The name is shown, not typed.** `writtenName` builds it from
            // Provider, Number, From and To, and a field that saves under a
            // name you cannot see is a surprise waiting for the row to appear.
            Text("Saves as \u{201C}\(writtenName)\u{201D}")
        }
    }

    private var whenSection: some View {
        Section {
            Toggle("Has a date", isOn: $hasDate)
            if hasDate {
                DatePicker(labels.start, selection: $start,
                           displayedComponents: hasTime ? [.date, .hourAndMinute] : .date)
                Toggle("Has a time", isOn: $hasTime)
                Toggle("Has an end", isOn: $hasEnd)
                if hasEnd {
                    DatePicker(labels.end, selection: $end,
                               displayedComponents: hasTime ? [.date, .hourAndMinute] : .date)
                }
            }
        } header: {
            Text("When")
        } footer: {
            // The rule about somewhere else, said in one clause, because this
            // is the field where you forget it.
            Text("A cost with no date is what makes a row a quote rather than a booking.")
        }
    }

    private var detailsSection: some View {
        Section {
            TextField(labels.provider, text: $provider)
            TextField(labels.number, text: $number)
            if let fromLabel = labels.from {
                TextField(fromLabel, text: $from)
            }
            TextField(labels.to, text: $to)
            TextField("Confirmation", text: $confirmation)
        } header: {
            Text("Details")
        }
    }

    private var moneySection: some View {
        Section {
            TextField("Cost", text: $costText)
                .keyboardType(.decimalPad)
            Toggle("Booked", isOn: $booked)
            Picker("Status", selection: statusBinding) {
                Text("None").tag("")
                ForEach(Self.statuses, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.navigationLink)
        } header: {
            Text("Cost and state")
        } footer: {
            // **Two fields, two questions, opposite polarity.** On an
            // itinerary the row you are looking for is the UNbooked one; on a
            // ledger it is the accepted one. A checkbox has two states and a
            // quote has three, which is why Status is not Booked renamed.
            Text("Booked is whether it is confirmed. Status is which of three a quote is, and is offered on every Kind.")
        }
    }

    @ViewBuilder
    private var whoSection: some View {
        Section {
            ForEach(offeredPeople) { person in
                Toggle(person.name, isOn: binding(for: person.id))
            }
            TextField("Search everyone", text: $personQuery)
            ForEach(searchMatches) { person in
                Toggle(person.name, isOn: binding(for: person.id))
            }
        } header: {
            Text("Who")
        } footer: {
            if notionService.peopleLoad == .failed {
                // Warning TWELVE. An empty Who because Notion did not answer
                // is not the same statement as a booking nobody is on.
                Text("Notion did not answer, so this list may be incomplete.")
            } else {
                Text("People attached to this endeavor are listed first.")
            }
        }
    }

    private var notesSection: some View {
        Section {
            TextField("Notes", text: $notes, axis: .vertical)
                .lineLimit(3...8)
        } header: {
            Text("Notes")
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) { confirmingDelete = true } label: {
                Text("Delete booking")
            }
            .disabled(saving)
        }
    }

    /// The field help, presented rather than hovered.
    ///
    /// **The words are `BookingKind.help(for:)`, in Models.swift.** They were
    /// put there in D278 precisely so this sheet would get the same sentences
    /// as the Mac's rather than a second set that disagrees the first time a
    /// field changes. This file holds the presentation and nothing else.
    private var helpSheet: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(BookingKind.help(for: kind)) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.label)
                                .font(.system(size: 14, weight: .semibold))
                            Text(entry.text)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                    }
                } footer: {
                    Text("The wording follows the Kind. These are the words for \(shortKind(kind)).")
                }
            }
            .navigationTitle("What each field is")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingHelp = false }
                }
            }
        }
    }

    // MARK: Plumbing

    /// "Car rental" is the Notion option; "Car" is what reads in a sentence.
    /// The tag is always the stored value, so the short form never reaches the
    /// database.
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

    /// Fills the fields once, from the row being edited or from the ledger
    /// seeds.
    ///
    /// **Every write here goes straight to `kind`, never through
    /// `kindBinding`.** The binding carries the clear-on-group-change rule and
    /// that rule is about what the USER does; firing it on the sheet's own
    /// seeding is D267's bug in the place it was born.
    private func seed() {
        guard !seeded else { return }
        seeded = true
        if let b = existing {
            kind = b.kind
            whoIDs = b.whoIDs
            hasDate = b.start != nil
            hasTime = b.hasTime
            hasEnd = b.end != nil
            start = b.start ?? Date()
            end = b.end ?? b.start ?? Date()
            from = b.from ?? ""
            to = b.to ?? ""
            provider = b.provider ?? ""
            number = b.number ?? ""
            confirmation = b.confirmation ?? ""
            costText = b.cost.map { String(format: "%g", $0) } ?? ""
            booked = b.booked
            status = b.status
            notes = b.notes ?? ""
        } else if seedLedger {
            kind = "Other"
            hasDate = false
            hasEnd = false
            status = BookingStatus.initial
        }
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
                booked: booked,
                status: status)
    }

    private func save() {
        saving = true
        failure = nil
        Task {
            do {
                try await notionService.saveBooking(draft())
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
        guard let existing else { return }
        saving = true
        failure = nil
        Task {
            do {
                try await notionService.deleteBooking(id: existing.id)
                dismiss()
            } catch {
                failure = error.localizedDescription
                saving = false
            }
        }
    }
}
