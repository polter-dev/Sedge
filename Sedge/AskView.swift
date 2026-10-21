//
//  AskView.swift
//  Sedge
//

import SedgeCore
import SwiftUI

/// Ask a question about the chosen data. No model is wired in yet, so asking only says so;
/// the saved answers that `ask_user` keeps can still be seen and reset from here.
struct AskView: View {
    let database: SedgeDatabase
    @State private var question = ""
    /// True after Ask is tapped, to show that nothing can answer yet.
    @State private var notConnected = false
    @State private var resetDone = false

    var body: some View {
        Form {
            Section {
                TextField("How much did I spend at Netflix this year?", text: $question, axis: .vertical)
                    .onSubmit(ask)
                Button("Ask", systemImage: "paperplane", action: ask)
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if notConnected {
                Text("The assistant isn't connected yet.")
            }
            Section {
                NavigationLink {
                    SavedAnswersView(database: database)
                        .navigationTitle("Saved answers")
                } label: {
                    Label("Saved answers", systemImage: "tray.full")
                }
                Button("Reset saved questions", systemImage: "arrow.counterclockwise", role: .destructive) {
                    resetDone = (try? AskUser.reset(database)) != nil
                }
            } footer: {
                Text(resetDone ? "Saved answers cleared." : "Answers to quick questions are saved, so each is asked only once.")
            }
        }
    }

    private func ask() {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        resetDone = false
        notConnected = true
    }
}

#Preview {
    NavigationStack {
        AskView(database: try! SedgeDatabase())
            .navigationTitle("Ask")
    }
}
