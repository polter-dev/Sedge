//
//  AskView.swift
//  Sedge
//

import SedgeCore
import SwiftUI

/// Ask a question about the chosen data. No model is wired in yet, so asking only says so.
/// The saved answers that `ask_user` keeps are seen and reset from the Accounts tab.
struct AskView: View {
    /// The data questions are answered from, once a model is connected.
    let database: SedgeDatabase
    @State private var question = ""
    /// True after Ask is tapped, to show that nothing can answer yet.
    @State private var notConnected = false
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
            .listRowBackground(Color.group)
            if notConnected {
                Section("Answer") {
                    Label("The assistant isn't connected yet.", systemImage: "info.circle")
                }
                .listRowBackground(Color.group)
            }
        }
        .themedBackground()
    }

    private func ask() {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        notConnected = true
    }
}

#Preview {
    NavigationStack {
        AskView(database: try! SedgeDatabase())
            .navigationTitle("Ask")
    }
}
