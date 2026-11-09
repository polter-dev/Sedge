//
//  SavedAnswersView.swift
//  Sedge
//

import SedgeCore
import SwiftUI

/// One saved answer, which Sedge uses instead of asking: a saved reply, or a
/// profile correction (which answers any question about its kind, e.g. all income questions).
struct SavedEntry: Identifiable {
    enum Source {
        /// A saved reply, by its fact key.
        case saved(String)
        case correction(Profile.Fact)
    }

    let id: String
    /// The question, in plain words.
    let question: String
    /// What is assumed, in plain words.
    let assumed: String
    let source: Source

    /// The SF Symbol for the row: a speech bubble for a saved reply, the About you icon for a correction.
    var symbol: String {
        switch source {
        case .saved: "text.bubble"
        case .correction: "person.text.rectangle"
        }
    }

    /// True when this entry answers questions saved under `key`, by the same rule `ask_user` uses.
    func covers(_ key: String) -> Bool {
        switch source {
        case .saved(let factKey): factKey == key
        case .correction(let fact): AskUser.covers(kind: fact.kind, id: fact.id, key: key)
        }
    }

    /// Saved replies first, then corrections: a saved reply wins when both cover a question.
    static func all(in database: SedgeDatabase) throws -> [SavedEntry] {
        let saved = try AskUser.saved(database).map {
            SavedEntry(id: "saved:" + $0.key, question: $0.question, assumed: $0.answer, source: .saved($0.key))
        }
        let corrections = try Profile.facts(in: database).filter { $0.rule == "user_correction" }.map { fact in
            let kind = (ProfileView.titles[fact.kind] ?? fact.kind).lowercased()
            let details = ProfileView.details(fact.value)
            return SavedEntry(id: "correction:" + fact.id, question: "Questions about \(kind)",
                              assumed: details.isEmpty ? fact.value.name : "\(fact.value.name) · \(details)",
                              source: .correction(fact))
        }
        return saved + corrections
    }
}

/// The Saved answers menu: every saved reply and profile correction Sedge answers with
/// instead of asking. Tap one to change it; swipe to remove it, so the question is asked again.
struct SavedAnswersView: View {
    let database: SedgeDatabase
    /// An entry to open for changing as soon as the menu shows (from an answer's "Assumed" line).
    var opening: String?
    @State private var entries: [SavedEntry] = []
    /// The entry open in the change sheet, either kind.
    @State private var editing: SavedEntry?
    /// True while the "Delete all saved answers?" question is showing, so a stray tap can't wipe them.
    @State private var confirmingDeleteAll = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        List {
            Section {
                ForEach(entries) { entry in
                    Button { editing = entry } label: {
                        let text = VStack(alignment: .leading, spacing: 2) {
                            Text(entry.question)
                            Text(entry.assumed)
                                .font(.subheadline)
                                .foregroundStyle(Color.muted)
                        }
                        // At the largest text sizes the icon squeezes the words, so it is left out.
                        if dynamicTypeSize.isAccessibilitySize {
                            text
                        } else {
                            Label { text } icon: {
                                Image(systemName: entry.symbol)
                                    .foregroundStyle(Color.accent)
                            }
                        }
                    }
                    .foregroundStyle(Color.ink)
                    .accessibilityHint("Change this answer")
                    .swipeActions {
                        // The swipe button's circle is the accent, so its icon takes the color made to sit on it.
                        Button("Remove", systemImage: "trash", role: .destructive) { remove(entry) }
                            .foregroundStyle(Color.contrast)
                    }
                }
            }
            .listRowBackground(Color.group)
        }
        .themedBackground()
        .overlay {
            if entries.isEmpty { ContentUnavailableView("No saved answers", systemImage: "tray") }
        }
        .toolbar {
            Button("Delete all", role: .destructive) { confirmingDeleteAll = true }
                .disabled(entries.isEmpty)
        }
        // Deleting can't be undone, so ask first. An alert always shows its Cancel button.
        .alert("Delete all saved answers?", isPresented: $confirmingDeleteAll) {
            Button("Delete", role: .destructive) { entries.forEach(remove) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
        // Both kinds edit in About you's form: a saved reply is a value with only a name.
        .sheet(item: $editing) { entry in
            switch entry.source {
            case .saved:
                CorrectFactView(value: Profile.Value(name: entry.assumed), title: "Change answer", nameLabel: "Answer",
                                header: entry.question, remove: { remove(entry) }) { save($0, for: entry) }
            case .correction(let fact):
                CorrectFactView(value: fact.value, title: "Change answer", header: entry.question,
                                remove: { remove(entry) }) { save($0, for: entry) }
            }
        }
        .task {
            reload()
            editing = entries.first { $0.id == opening }
        }
    }

    private func reload() {
        do {
            entries = try SavedEntry.all(in: database)
        } catch {
            print("Could not read saved answers:", error)
        }
    }

    /// A saved reply keeps only the typed name as its answer; a correction saves the whole value.
    private func save(_ value: Profile.Value, for entry: SavedEntry) {
        do {
            switch entry.source {
            case .saved(let key):
                let answer = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
                // An empty answer would read as "the person said nothing"; Remove is the way to clear one.
                guard !answer.isEmpty else { return }
                try AskUser.change(key, to: answer, in: database)
            case .correction(let fact):
                try Profile.correct(id: fact.id, kind: fact.kind, value: value, in: database)
            }
        } catch {
            print("Could not change the answer:", error)
        }
        reload()
    }

    private func remove(_ entry: SavedEntry) {
        do {
            switch entry.source {
            case .saved(let key): try AskUser.forget(key, in: database)
            case .correction(let fact): try Profile.removeCorrection(id: fact.id, in: database)
            }
        } catch {
            print("Could not remove the saved answer:", error)
        }
        reload()
    }
}

#Preview {
    NavigationStack {
        SavedAnswersView(database: try! .open("maya"))
            .navigationTitle("Saved answers")
    }
}
