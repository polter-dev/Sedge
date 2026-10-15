import Foundation
import GRDB
import Testing
@testable import SedgeCore
@testable import sedge_eval

// The eval runner, driven by the scripted model so no network is used.

let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../..").standardized
let questionBank = repoRoot.appending(path: "tools/eval/questions.csv")

@Test func csvCellsMayHoldQuotesCommasAndLineBreaks() {
    let text = "id,notes\r\na,\"one, two\"\nb,\"say \"\"hi\"\"\nthen stop\"\nc,"
    #expect(parseCSV(text) == [["id", "notes"], ["a", "one, two"], ["b", "say \"hi\"\nthen stop"], ["c", ""]])
}

@Test func questionBankLoads() throws {
    let questions = try loadQuestions(Data(contentsOf: questionBank))
    #expect(questions.prefix(3).map(\.id) == ["maya-ex-1", "maya-ex-2", "maya-ex-3"])
    #expect(questions[0].asOf == "2026-06-30" && questions[0].type == "aggregation")
    #expect(try select(questions, split: "all", ids: ["maya-ex-2"]).map(\.id) == ["maya-ex-2"])
    #expect(throws: EvalError.self) { try select(questions, split: "all", ids: ["nope"]) }
}

@Test func asOfLeavesOutLaterTransactions() throws {
    let database = try prepareDatabase(persona: "maya", asOf: "2026-03-31", dataFolder: repoRoot.appending(path: "tools/data"), flags: OrganizerFlags())
    #expect(try database.asOf() == "2026-03-31")
    #expect(try database.allTransactions().allSatisfy { $0.date <= "2026-03-31" })
}

@Test func ablationFlagsChangeTheOrganizer() throws {
    func count(_ flags: OrganizerFlags, _ sql: String) throws -> Int {
        let database = try prepareDatabase(persona: "maya", asOf: Persona.asOf, dataFolder: repoRoot.appending(path: "tools/data"), flags: flags)
        return try database.dbQueue.read { try Int.fetchOne($0, sql: sql)! }
    }
    let merchants = "SELECT COUNT(*) FROM entities WHERE kind = 'merchant'"
    let matched = "SELECT COUNT(*) FROM transactions WHERE kind IN ('transfer', 'card_payment')"
    // Without the graph every raw statement name is its own store, so there are more of them.
    #expect(try count(OrganizerFlags(useGraph: false), merchants) > count(OrganizerFlags(), merchants))
    #expect(try count(OrganizerFlags(), matched) > 0)
    #expect(try count(OrganizerFlags(useReconciliation: false), matched) == 0)
}

@Test func runSavesEveryAnswerAndResumesAfterAKill() async throws {
    let out = FileManager.default.temporaryDirectory.appending(path: "sedge-eval-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: out) }
    let options = Options(questions: questionBank, ids: ["maya-ex-1", "maya-ex-2", "maya-ex-3"],
                          flags: OrganizerFlags(useGraph: false), out: out)
    let answers = { (count: Int) in ScriptedBackend(Array(repeating: calling([("final_answer", answer100)]), count: count)) }

    try await run(options, backend: answers(3), repoRoot: repoRoot) { _ in }
    let results = out.appending(path: "results.jsonl")
    let full = try String(contentsOf: results, encoding: .utf8).split(separator: "\n")
    #expect(full.count == 3)
    let first = try JSONSerialization.jsonObject(with: Data(full[0].utf8)) as! [String: Any]
    #expect(first["id"] as? String == "maya-ex-1" && first["repeat"] as? Int == 1 && first["error_type"] == nil)
    #expect((first["final_answer"] as? [String: Any])?["value"] as? Double == 100.44)
    #expect((first["flags"] as? [String: Bool]) == ["use_graph": false, "use_reconciliation": true])

    let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: out.appending(path: "manifest.json"))) as! [String: Any]
    #expect((manifest["flags"] as? [String: Bool]) == ["use_graph": false, "use_reconciliation": true])
    #expect(manifest["results"] as? Int == 3 && manifest["ended_at"] is String && manifest["prompt_version"] as? String == "v1")

    // A kill partway through writing an answer, after another answer hit an API error
    // (e.g. the spending cap): both are asked again, the good answer is kept as it was.
    let apiError = "{\"error_type\":\"api_error\"," + full[2].dropFirst()
    try Data((full[0] + "\n" + apiError + "\n" + full[1].prefix(40)).utf8).write(to: results)
    var progress: [String] = []
    try await run(options, backend: answers(2), repoRoot: repoRoot) { progress.append($0) }
    let resumed = try String(contentsOf: results, encoding: .utf8).split(separator: "\n")
    #expect(resumed.count == 3 && resumed[0] == full[0])
    #expect(resumed.map { (try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any])["id"] as! String }
            == ["maya-ex-1", "maya-ex-2", "maya-ex-3"])
    #expect(progress.count == 4 && progress[0].hasPrefix("Asking 2 ") && progress[1].hasSuffix("already done"))
    #expect(!resumed[2].contains("api_error"))

    // Different switches in the same folder would mix two configurations, so it is refused.
    var other = options
    other.flags = OrganizerFlags()
    await #expect(throws: EvalError.self) { try await run(other, backend: answers(3), repoRoot: repoRoot) { _ in } }
}

// Ways one results folder could still mix setups, or be changed by a run that was refused.

@Test func resumeWithDifferentQuestionBankIsRefused() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "sedge-eval-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let text = try String(contentsOf: questionBank, encoding: .utf8)
    let a = dir.appending(path: "a.csv"), b = dir.appending(path: "b.csv")
    try text.write(to: a, atomically: true, encoding: .utf8)
    let edited = text.replacingOccurrences(of: "Which bills do I pay every month?", with: "CHANGED TEXT?")
    #expect(edited != text)
    try edited.write(to: b, atomically: true, encoding: .utf8)
    let out = dir.appending(path: "out")
    let answers = { (n: Int) in ScriptedBackend(Array(repeating: calling([("final_answer", answer100)]), count: n)) }

    try await run(Options(questions: a, ids: ["maya-ex-1"], out: out), backend: answers(1), repoRoot: repoRoot) { _ in }
    await #expect(throws: EvalError.self) {
        try await run(Options(questions: b, ids: ["maya-ex-1", "maya-ex-2"], out: out), backend: answers(1), repoRoot: repoRoot) { _ in }
    }
}

@Test func refusedRerunLeavesResultsUntouched() async throws {
    let out = FileManager.default.temporaryDirectory.appending(path: "sedge-eval-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: out) }
    let options = Options(questions: questionBank, ids: ["maya-ex-1", "maya-ex-2"],
                          flags: OrganizerFlags(useGraph: false), out: out)
    let answers = { (count: Int) in ScriptedBackend(Array(repeating: calling([("final_answer", answer100)]), count: count)) }
    try await run(options, backend: answers(2), repoRoot: repoRoot) { _ in }
    let results = out.appending(path: "results.jsonl")
    let lines = try String(contentsOf: results, encoding: .utf8).split(separator: "\n")
    let apiError = "{\"error_type\":\"api_error\"," + lines[1].dropFirst()
    try Data((lines[0] + "\n" + apiError + "\n").utf8).write(to: results)
    let before = try Data(contentsOf: results)

    var other = options
    other.flags = OrganizerFlags()
    await #expect(throws: EvalError.self) { try await run(other, backend: answers(2), repoRoot: repoRoot) { _ in } }
    #expect(try Data(contentsOf: results) == before)
}

/// Saves one answer, damages the manifest, then resumes with other switches.
private func resumeAfterDamagingManifest(_ damage: (URL) throws -> Void) async throws {
    let out = FileManager.default.temporaryDirectory.appending(path: "sedge-eval-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: out) }
    let answers = { (count: Int) in ScriptedBackend(Array(repeating: calling([("final_answer", answer100)]), count: count)) }
    let first = Options(questions: questionBank, ids: ["maya-ex-1"], flags: OrganizerFlags(useGraph: false), out: out)
    try await run(first, backend: answers(1), repoRoot: repoRoot) { _ in }
    try damage(out.appending(path: "manifest.json"))
    let second = Options(questions: questionBank, ids: ["maya-ex-1", "maya-ex-2"], flags: OrganizerFlags(), out: out)
    try await run(second, backend: answers(1), repoRoot: repoRoot) { _ in }
}

@Test func deletedManifestIsRefused() async throws {
    await #expect(throws: EvalError.self) { try await resumeAfterDamagingManifest { try FileManager.default.removeItem(at: $0) } }
}

@Test func oldManifestMissingAFieldIsRefused() async throws {
    await #expect(throws: EvalError.self) {
        try await resumeAfterDamagingManifest { url in
            var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            manifest.removeValue(forKey: "tool_set_version")
            try JSONSerialization.data(withJSONObject: manifest).write(to: url)
        }
    }
}

// The context-stuffing baseline: raw data in the prompt, final_answer as the only tool.

@Test func contextConfigPutsRawDataInThePromptAndRefusesDataTools() async throws {
    let out = FileManager.default.temporaryDirectory.appending(path: "sedge-eval-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: out) }
    var options = Options(questions: questionBank, ids: ["maya-ex-1"], out: out)
    options.config = "context"
    // The model tries a data tool anyway; it must be turned away, not run.
    let backend = ScriptedBackend([calling([("total_spent", netflix)]), calling([("final_answer", answer100)])])
    try await run(options, backend: backend, repoRoot: repoRoot) { _ in }

    let system = try #require(await backend.systems.first)
    #expect(system.hasPrefix(SystemPrompt.text(asOf: "2026-06-30")))
    #expect(system.contains("date,name,amount,account\n2026-01-01,") && system.contains("OAKWOOD APARTMENTS RENT,650.00,Checking"))
    #expect(system.contains("name,type,balance\nChecking,checking,1993.45"))
    // Nothing from the grader's columns reaches the model.
    #expect(!system.contains("SELECT") && !system.contains("5804.56"))

    let line = try JSONSerialization.jsonObject(with: Data(contentsOf: out.appending(path: "results.jsonl"))) as! [String: Any]
    let calls = (line["trace"] as! [String: Any])["tool_calls"] as! [[String: Any]]
    #expect(calls.map { $0["name"] as! String } == ["total_spent", "final_answer"])
    #expect(calls[0]["error"] as? String == "Unknown tool \"total_spent\".")
    #expect(line["config"] as? String == "context" && line["input_tokens"] as? Int == 20)

    let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: out.appending(path: "manifest.json"))) as! [String: Any]
    #expect(manifest["config"] as? String == "context" && manifest["prompt_version"] as? String == "v1+context-v1")
    #expect(manifest["prompt_sha256"] as? String == sha256(Data(SystemPrompt.template(dataTools: false).utf8)))

    // A cloud run can't resume into a context folder.
    options.config = "cloud"
    await #expect(throws: EvalError.self) {
        try await run(options, backend: ScriptedBackend([calling([("final_answer", answer100)])]), repoRoot: repoRoot) { _ in }
    }
}

@Test func contextBackendOffersOnlyFinalAnswer() throws {
    let body = try ClaudeBackend(apiKey: "test", dataTools: false).body(system: "", messages: [.user("?")])
    let tools = (try JSONSerialization.jsonObject(with: body) as! [String: Any])["tools"] as! [[String: Any]]
    #expect(tools.map { $0["name"] as! String } == ["final_answer"])
}

@Test func contextCSVSurvivesCommasAndQuotes() {
    let rows = [["date", "name"], ["2026-01-01", "AMAZON, INC \"MKTP\""]]
    #expect(parseCSV(SystemPrompt.csv(rows) + "\n") == rows)
}
