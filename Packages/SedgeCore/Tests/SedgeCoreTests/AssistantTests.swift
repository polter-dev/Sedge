import Foundation
import Jinja
import Testing
@testable import SedgeCore

// The loop with the scripted fake model, and parity with the benchmark notebook.
//
// Fixtures/notebook.json was written from benchmarks/benchmark.ipynb with the notebook's own Python
// packages: its constants (system prompt, repair message, final_answer, step limit, token cap,
// temperature), the tool definitions its helper sends, chats rendered by transformers'
// apply_chat_template exactly as mlx_turn calls it, cases parsed by mlx_lm's qwen3_coder parser,
// and tool results passed through json.dumps(json.loads(...)). Fixtures/qwen-chat-template.jinja
// is the chat template shipped with the measured weights.

let fixtures = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")

/// The notebook fixture. Anything whose key order matters is stored as a list of pairs or as text.
// Read-only after loading, so sharing it between tests is safe.
nonisolated(unsafe) let notebook = try! JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appending(path: "notebook.json"))) as! [String: Any]
nonisolated(unsafe) let chat = notebook["chat"] as! [String: Any]

/// `[[key, value], ...]` from the fixture, in order.
func ordered(_ pairs: Any?) -> OrderedDictionary<String, Value> {
    OrderedDictionary(uniqueKeysWithValues: (pairs as! [[Any]]).map { ($0[0] as! String, $0[1] is NSNull ? .null : try! Value(any: $0[1])) })
}

/// The fixture chat's steps, as the loop keeps them.
func fixtureHistory() -> [Assistant.Step] {
    (chat["history"] as! [[String: Any]]).map { step in
        guard let name = step["name"] as? String else { return Assistant.Step(name: nil, text: step["text"] as! String) }
        return Assistant.Step(name: name, input: ordered(step["input"]), result: step["result"] as! String)
    }
}

@Suite struct NotebookParity {
    @Test func promptAndSettingsMatchTheNotebook() {
        #expect(Assistant.systemPrompt == notebook["system_prompt"] as? String)
        #expect(Assistant.repairMessage == notebook["repair_message"] as? String)
        #expect(Assistant.stepLimit == notebook["step_limit"] as? Int)
        #expect(QwenModel.maxTokens == notebook["max_tokens"] as? Int)
        #expect(Double(QwenModel.temperature) == notebook["test_temperature"] as? Double)
        #expect(QwenModel.repo == notebook["model"] as? String)
        #expect(Assistant.answerTypes == notebook["answer_types"] as? [String])
        #expect(Tool.version == notebook["tool_version"] as? String)
    }

    /// The tools as the template prints them (`tool | tojson`, i.e. json.dumps), key order included.
    @Test func toolDefinitionsMatchTheNotebook() throws {
        let expected = try #require(notebook["tools_json"] as? [String])
        #expect(Assistant.tools.count == 11)
        #expect(try Assistant.tools.map { try JSON.dumps($0, options: .init(ensureASCII: false)) } == expected)
    }

    /// The whole prompt: template, tools, system prompt, tool calls, tool results and the repair turn.
    @Test(arguments: [("first_rendered", 0), ("rendered", 3), ("rendered_repair", 4)])
    func renderedPromptMatchesTheNotebook(key: String, steps: Int) throws {
        let template = try QwenModel.template(String(contentsOf: fixtures.appending(path: "qwen-chat-template.jinja"), encoding: .utf8))
        let system = Assistant.systemPrompt.replacingOccurrences(of: "{today}", with: "2026-06-30")
        let messages = Assistant.messages(system: system, question: chat["question"] as! String, history: Array(fixtureHistory().prefix(steps)))
        let rendered = try QwenModel.render(template, messages: messages, tools: Assistant.tools)
        #expect(rendered == chat[key] as? String)
    }

    @Test func toolCallsAreReadLikeTheNotebookParser() throws {
        for expected in notebook["parses"] as! [[String: Any]] {
            let output = expected["text"] as! String
            #expect(Assistant.isComplete(output) == expected["complete"] as? Bool, "\(output)")
            if expected["error"] != nil {
                #expect(throws: Assistant.Malformed.self, "\(output)") { try Assistant.parseCall(output) }
            } else if let call = expected["call"] as? [String: Any] {
                let parsed = try #require(try Assistant.parseCall(output))
                #expect(parsed.0 == call["name"] as? String)
                #expect(parsed.1 == ordered(call["arguments"]), "\(output)")
            } else {
                #expect(try Assistant.parseCall(output) == nil)
            }
        }
    }

    @Test func toolResultsAreWrittenLikePythonJSONDumps() {
        for pair in notebook["dumps"] as! [[String]] {
            #expect(Assistant.pythonJSON(pair[0]) == pair[1])
        }
    }
}

@Suite struct AssistantLoop {
    let maya = try! organizedPersona("maya")
    let finalAnswer = ScriptedModel.call("final_answer", ["answer_type": "number", "value": "$574.64", "note": "You spent $574.64."])
    let answer = Assistant.Outcome.answer(.init(answerType: "number", value: "$574.64", note: "You spent $574.64."))

    /// The text of the last message the model saw on turn `turn`.
    func lastMessage(_ model: ScriptedModel, turn: Int) async -> String {
        guard case .object(let message) = await model.seen[turn].last, case .string(let text) = message["content"] else { return "" }
        return text
    }

    @Test func runsAToolThenAnswers() async throws {
        let model = ScriptedModel([ScriptedModel.call("total_spent", ["merchant": "Value Mart", "start_date": "2026-01-01",
                                                                     "end_date": "2026-06-30"]), finalAnswer])
        #expect(await Assistant.run("How much at Value Mart?", database: maya, model: model, askPerson: nil) == answer)
        // The model reads the tool's own result, in json.dumps form.
        let expected = Tool.named("total_spent")!.call(try JSONSerialization.data(withJSONObject: [
            "merchant": "Value Mart", "start_date": "2026-01-01", "end_date": "2026-06-30"]), database: maya)
        #expect(await lastMessage(model, turn: 1) == Assistant.pythonJSON(expected))
        #expect(await model.seen.count == 2)
    }

    @Test func stopsAtTheStepLimit() async {
        let model = ScriptedModel(Array(repeating: ScriptedModel.call("account_balances"), count: 20))
        #expect(await Assistant.run("Balances?", database: maya, model: model, askPerson: nil) == .stepLimit)
        #expect(await model.seen.count == Assistant.stepLimit)
    }

    @Test func badFinalAnswerIsAnErrorTheModelReads() async {
        let model = ScriptedModel([ScriptedModel.call("final_answer", ["answer_type": "maybe", "value": "1", "note": "."]), finalAnswer])
        #expect(await Assistant.run("Q", database: maya, model: model, askPerson: nil) == answer)
        #expect(await lastMessage(model, turn: 1).hasPrefix(#"{"error": "Bad final_answer input.""#))
    }

    @Test func aPlainTextEndingGetsOneRepairTurn() async {
        let model = ScriptedModel([.success("You spent $574.64."), finalAnswer])
        #expect(await Assistant.run("Q", database: maya, model: model, askPerson: nil) == answer)
        #expect(await lastMessage(model, turn: 1) == Assistant.repairMessage)

        let twice = ScriptedModel([.success("One."), .success("Two.")])
        #expect(await Assistant.run("Q", database: maya, model: twice, askPerson: nil) == .crashed("malformed"))
    }

    @Test func theRepairTurnMayGoPastTheStepLimit() async {
        let steps = Array(repeating: ScriptedModel.call("get_profile"), count: Assistant.stepLimit - 1)
        let model = ScriptedModel(steps + [.success("Done."), finalAnswer])
        #expect(await Assistant.run("Q", database: maya, model: model, askPerson: nil) == answer)
        #expect(await model.seen.count == Assistant.stepLimit + 1)
    }

    @Test func unreadableCallsAndCutOffRepliesCrash() async {
        let malformed = ScriptedModel([.success("<tool_call>\n<function=get_profile>\n</tool_call>")])
        #expect(await Assistant.run("Q", database: maya, model: malformed, askPerson: nil) == .crashed("malformed"))
        let cutOff = ScriptedModel([.failure(.maxTokens)])
        #expect(await Assistant.run("Q", database: maya, model: cutOff, askPerson: nil) == .crashed("max_tokens"))
    }

    @Test func askUserWaitsForThePersonAndSavesTheReply() async throws {
        let database = try organizedPersona("maya")
        let ask = ScriptedModel.call("ask_user", ["question": "Does food include groceries?",
                                                  "options": #"["Groceries", "Everything"]"#, "fact_key": "food_test"])
        let person = Person("Groceries")
        let model = ScriptedModel([ask, finalAnswer])
        #expect(await Assistant.run("Food?", database: database, model: model, askPerson: person.ask) == answer)
        #expect(person.asked.withLock { $0 } == 1)
        #expect(await lastMessage(model, turn: 1) == #"{"answer": "Groceries"}"#)
        #expect(try AskUser.saved(database).contains { $0.key == "food_test" && $0.answer == "Groceries" })

        // Skipped ("Later"): nothing saved, and the model is told so.
        let skipped = ScriptedModel([ScriptedModel.call("ask_user", ["question": "Which?", "options": #"["A", "B"]"#,
                                                                     "fact_key": "which_test"]), finalAnswer])
        #expect(await Assistant.run("Q", database: database, model: skipped, askPerson: Person(nil).ask) == answer)
        #expect(await lastMessage(skipped, turn: 1).hasPrefix(#"{"note": "The person didn't answer."#))
    }

    /// The follow-up "is that a lot?" on its own, as the real model handled it on daniel: an ask_user
    /// with too many options, one the person skips, a bad category, then the answer.
    @Test func aVagueFollowUpAsksThenAnswers() async throws {
        let daniel = try organizedPersona("daniel")
        let model = ScriptedModel([
            ScriptedModel.call("ask_user", ["fact_key": "context", "question": "What do you mean?",
                                            "options": #"["What?", "Spending", "Savings", "Balance", "Something else"]"#]),
            ScriptedModel.call("ask_user", ["fact_key": "context", "question": "What do you mean?",
                                            "options": #"["Spending", "Savings", "Balance", "Other"]"#]),
            ScriptedModel.call("total_spent", ["category": "all", "start_date": "2026-05-16", "end_date": "2026-06-30"]),
            ScriptedModel.call("total_spent", ["start_date": "2026-05-16", "end_date": "2026-06-30"]),
            finalAnswer,
        ])
        let person = Person(nil)
        #expect(await Assistant.run("is that a lot?", database: daniel, model: model, askPerson: person.ask) == answer)
        #expect(person.asked.withLock { $0 } == 1) // the five-option call never reached the person
        #expect(await lastMessage(model, turn: 1).hasPrefix(#"{"error": "Bad value for \"options\".""#))
        #expect(await lastMessage(model, turn: 2).hasPrefix(#"{"note": "The person didn't answer."#))
        #expect(await lastMessage(model, turn: 3).hasPrefix(#"{"error": "Bad value for \"category\".""#))
    }

    @Test func noMemoryForATurnEndsTheQuestion() async {
        let model = ScriptedModel([ScriptedModel.call("account_balances"), .failure(.memory)])
        #expect(await Assistant.run("Q", database: maya, model: model, askPerson: nil) == .crashed("memory"))
        // A 3,300-token turn needs about 1.4 GB; a turn near the 16,384-token cap about 1.8 GB.
        #expect(QwenModel.fits(3_313, available: 1_500 << 20))
        #expect(!QwenModel.fits(3_313, available: 1 << 30))
        #expect(!QwenModel.fits(16_000, available: 1_700 << 20))
    }

    @Test func aContextOverflowIsCompactedOnceThenReportsTheLimit() async {
        // First overflow: start again from the question and only the latest step.
        let model = ScriptedModel([ScriptedModel.call("get_profile"), ScriptedModel.call("account_balances"),
                                   .failure(.context), finalAnswer])
        #expect(await Assistant.run("Q", database: maya, model: model, askPerson: nil) == answer)
        // system + question + the kept call and its result.
        #expect(await model.seen[3].count == 4)

        let twice = ScriptedModel([ScriptedModel.call("get_profile"), .failure(.context), .failure(.context)])
        #expect(await Assistant.run("Q", database: maya, model: twice, askPerson: nil) == .contextFull)
    }
}
