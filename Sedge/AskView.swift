//
//  AskView.swift
//  Sedge
//

import Foundation
import SedgeCore
import SwiftUI

/// Ask a question about the chosen data; shows the answer and, under Show work, every
/// tool call the model made with the rows it got back.
struct AskView: View {
    let database: SedgeDatabase
    @State private var question = ""
    @State private var trace: Trace?
    @State private var isAsking = false
    @State private var missingKey = false
    /// The clarifying question the model is waiting on, if any.
    @State private var waiting: Waiting?
    @State private var resetDone = false

    /// A question on screen, and the way to hand the tapped reply back to the paused model.
    struct Waiting {
        let clarification: Clarification
        let reply: CheckedContinuation<String?, Never>
    }

    /// `trace` fills the screen with an earlier answer (used by the preview).
    init(database: SedgeDatabase, trace: Trace? = nil) {
        self.database = database
        _trace = State(initialValue: trace)
        _question = State(initialValue: trace?.question ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("How much did I spend at Netflix this year?", text: $question, axis: .vertical)
                    .onSubmit(ask)
                Button("Ask", systemImage: "paperplane", action: ask)
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAsking)
            }
            if missingKey {
                Text("No ANTHROPIC_API_KEY is set, so there's no model to ask. See Secrets.xcconfig.")
            }
            if let waiting {
                Section("Quick question") {
                    Text(waiting.clarification.question)
                        .accessibilityIdentifier("clarify-question")
                    ForEach(waiting.clarification.options, id: \.self) { option in
                        Button(option) { answer(option) }
                    }
                    Button("Skip", role: .cancel) { answer(nil) }
                }
            } else if isAsking {
                ProgressView("Thinking…")
            } else if let trace {
                Section {
                    Text(Self.answer(trace))
                    // Only the cloud model exists for now; on-device models come later.
                    Label("Cloud", systemImage: "cloud")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    DisclosureGroup("Show work") {
                        Text("Took \(trace.latencySeconds, format: .number.precision(.fractionLength(1))) s · \(trace.reportedModel ?? trace.model) · \(trace.turns) replies")
                            .font(.caption)
                        ForEach(Array(trace.toolCalls.enumerated()), id: \.offset) { _, call in
                            VStack(alignment: .leading, spacing: 4) {
                                Label(call.name, systemImage: call.valid ? "wrench.and.screwdriver" : "exclamationmark.triangle")
                                    .font(.subheadline.bold())
                                Text(call.input)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(Self.pretty(call.result))
                                    .font(.caption2.monospaced())
                            }
                        }
                    }
                }
            }
            Section {
                Button("Reset saved questions", systemImage: "arrow.counterclockwise", role: .destructive) {
                    resetDone = (try? AskUser.reset(database)) != nil
                }
                .disabled(isAsking)
            } footer: {
                Text(resetDone ? "Saved answers cleared." : "Answers to quick questions are saved, so each is asked only once.")
            }
        }
    }

    /// Hands the tapped reply (nil for Skip) back to the waiting model, exactly once.
    private func answer(_ reply: String?) {
        waiting?.reply.resume(returning: reply)
        waiting = nil
    }

    private func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAsking else { return }
        guard let key = ClaudeBackend.apiKey() else {
            // No key means no answer; say so instead of failing quietly.
            trace = nil
            missingKey = true
            return
        }
        isAsking = true
        resetDone = false
        // ask_user pauses the model here until a button on the card is tapped.
        let askPerson: AskPerson = { clarification in
            await withCheckedContinuation { reply in
                Task { @MainActor in waiting = Waiting(clarification: clarification, reply: reply) }
            }
        }
        Task {
            trace = await Assistant(backend: ClaudeBackend(apiKey: key), database: database, askPerson: askPerson).ask(text)
            isAsking = false
        }
    }

    /// The sentence to show: the final answer, or why there isn't one.
    static func answer(_ trace: Trace) -> String {
        if let answer = trace.finalAnswer?.answer { return answer }
        if let error = trace.error { return "No answer: \(error)" }
        // The model replied in plain text instead of final_answer; show it as it came.
        return trace.text
    }

    /// A tool's JSON reply with one row per line. It only adds line breaks: decoding and
    /// re-encoding the JSON would print 17.99 as 17.989999999999998.
    static func pretty(_ json: String) -> String {
        json.replacingOccurrences(of: "},{", with: "},\n{")
    }
}

#Preview {
    // A saved answer, so the preview needs neither the network nor a key.
    let trace = try! JSONDecoder().decode(Trace.self, from: Data(#"""
        {"question": "How much did I spend at Netflix this year?", "model": "claude-sonnet-5-5",
         "reportedModel": "claude-sonnet-5-5", "effort": "medium", "promptVersion": "v1",
         "askedUser": false, "clarifications": [], "toolCalls": [
           {"name": "spending_total", "input": "{\"merchant\":\"Netflix\",\"start_date\":\"2026-01-01\",\"end_date\":\"2026-06-30\"}",
            "valid": true, "resultBytes": 120,
            "result": "{\"total\":100.44,\"count\":6,\"rows\":[{\"date\":\"2026-06-15\",\"store\":\"Netflix\",\"amount\":17.99,\"kind\":\"spending\"}]}"},
           {"name": "final_answer", "input": "{\"answer\":\"You spent $100.44 at Netflix this year.\"}",
            "valid": true, "resultBytes": 2, "result": "{}"}],
         "turns": 2, "splitTurns": 0, "latencySeconds": 4.2, "inputTokens": 3000, "outputTokens": 200,
         "finalAnswer": {"answer": "You spent $100.44 at Netflix this year.", "value": 100.44},
         "formatError": false, "text": ""}
        """#.utf8))
    NavigationStack {
        AskView(database: try! SedgeDatabase(), trace: trace)
            .navigationTitle("Ask")
    }
}
