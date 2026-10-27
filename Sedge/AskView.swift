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
    /// True while the "Delete all saved answers?" question is showing, so a stray tap can't wipe them.
    @State private var confirmingReset = false
    @FocusState private var questionFocused: Bool

    var body: some View {
        Form {
            Section("Question") {
                // The send button sits at the end of the box, like Messages, so the question
                // reads as the main thing on the screen. Bottom alignment keeps it by the last line.
                HStack(alignment: .bottom) {
                    // A growing text field cuts its placeholder to one line, so the example
                    // question is drawn behind the empty field instead, where it can wrap.
                    ZStack(alignment: .topLeading) {
                        if question.isEmpty {
                            Text("How much did I spend at Netflix this year?")
                                .foregroundStyle(Color(uiColor: .placeholderText))
                                .accessibilityHidden(true)
                                // The field is only one line tall, so a tap on the rest of the example starts typing too.
                                .onTapGesture { questionFocused = true }
                        }
                        TextField("Question", text: $question, prompt: Text(""), axis: .vertical)
                            .onSubmit(ask)
                            .focused($questionFocused)
                            .accessibilityHint("For example, how much did I spend at Netflix this year?")
                    }
                    // Icon only on screen; VoiceOver still reads the title "Ask".
                    Button("Ask", systemImage: "arrow.up.circle.fill", action: ask)
                        .labelStyle(.iconOnly)
                        .font(.title)
                        .buttonStyle(.borderless)
                        // The icon is smaller than Apple's 44-point minimum, so the tap area is padded out.
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                        .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if notConnected {
                Section("Answer") {
                    Label("The assistant isn't connected yet.", systemImage: "info.circle")
                }
            }
            Section {
                NavigationLink {
                    SavedAnswersView(database: database)
                        .navigationTitle("Saved answers")
                } label: {
                    Label("Saved answers", systemImage: "tray.full")
                }
                Button("Reset saved questions", systemImage: "arrow.counterclockwise", role: .destructive) {
                    confirmingReset = true
                }
                // A destructive button colors only its text; this makes the icon match.
                .foregroundStyle(.red)
                // Deleting can't be undone, so ask first. An alert always shows its Cancel button.
                .alert("Delete all saved answers?", isPresented: $confirmingReset) {
                    Button("Delete", role: .destructive) {
                        resetDone = (try? AskUser.reset(database)) != nil
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This can't be undone.")
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
