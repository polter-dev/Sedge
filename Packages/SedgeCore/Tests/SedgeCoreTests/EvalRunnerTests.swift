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
