//
//  SavedAnswersView.swift
//  Sedge
//

import SedgeCore
import SwiftUI

/// One thing Sedge answers quick questions with instead of asking: a saved reply, or a
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
    /// The saved reply being changed, and the text typed for it.
    @State private var changing: SavedEntry?
    @State private var draft = ""
    @State private var correcting: Profile.Fact?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        List {
            Section {
                ForEach(entries) { entry in
                    Button { open(entry) } label: {
                        let text = VStack(alignment: .leading, spacing: 2) {
                            Text(entry.question)
                            Text(entry.assumed)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        // At the largest text sizes the icon squeezes the words, so it is left out.
                        if dynamicTypeSize.isAccessibilitySize {
                            text
                        } else {
                            Label { text } icon: {
                                Image(systemName: entry.symbol)
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityHint("Change this answer")
                    .swipeActions {
                        // The swipe button's circle is the accent, so its icon takes the color made to sit on it.
                        Button("Remove", systemImage: "trash", role: .destructive) { remove(entry) }
                            .foregroundStyle(Color.contrast)
                    }
                }
            } footer: {
                if !entries.isEmpty {
                    Text("Sedge uses these instead of asking, so a wrong one gives a wrong answer. Tap to change one, or swipe to remove it and be asked again next time.")
                        .foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color.group)
        }
        .themedBackground()
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("No saved answers", systemImage: "tray",
                                       description: Text("Replies to quick questions and your profile corrections show here."))
            }
        }
        .alert("Change answer", isPresented: Binding { changing != nil } set: { if !$0 { changing = nil } }, presenting: changing) { entry in
            TextField("Answer", text: $draft)
            Button("Save") { save(draft, for: entry) }
            Button("Remove", role: .destructive) { remove(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text(entry.question)
        }
        .sheet(item: $correcting) { fact in
            CorrectFactView(fact: fact) { value in
                do {
                    try Profile.correct(id: fact.id, kind: fact.kind, value: value, in: database)
                } catch {
                    print("Could not save the correction:", error)
                }
                reload()
            }
        }
        .task {
            reload()
            if let entry = entries.first(where: { $0.id == opening }) { open(entry) }
        }
    }

    private func reload() {
        do {
            entries = try SavedEntry.all(in: database)
        } catch {
            print("Could not read saved answers:", error)
        }
    }

    /// A saved reply opens a one-line edit; a correction opens the same form as About you.
    private func open(_ entry: SavedEntry) {
        switch entry.source {
        case .saved:
            draft = entry.assumed
            changing = entry
        case .correction(let fact):
            correcting = fact
        }
    }

    private func save(_ answer: String, for entry: SavedEntry) {
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty answer would read as "the person said nothing"; Remove is the way to clear one.
        guard case .saved(let key) = entry.source, !answer.isEmpty else { return }
        do {
            try AskUser.change(key, to: answer, in: database)
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
