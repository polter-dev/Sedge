import Foundation
import Testing
@testable import SedgeCore
@testable import sedge_eval

// The store-name labeling export. Only maya and daniel are used here: jordan's and elena's
// answer keys are held out.

/// Runs `export-er` with these options into a temporary file and returns the parsed rows (header first).
func exportSheet(_ arguments: [String]) throws -> [[String]] {
    let out = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID().uuidString).csv")
    defer { try? FileManager.default.removeItem(at: out) }
    try exportER(arguments + ["--out", out.path], repoRoot: repoRoot) { _ in }
    return parseCSV(try String(contentsOf: out, encoding: .utf8))
}

@Test func sameSeedGivesTheSameRowsAndCoversEveryName() throws {
    let rows = try ["maya", "daniel"].flatMap { persona in
        try labelRows(prepareDatabase(persona: persona, asOf: Persona.asOf, dataFolder: repoRoot.appending(path: "tools/data"),
                                      flags: OrganizerFlags()), persona: persona, includeTransfers: false)
    }
    let first = sampleRows(rows, count: 80, seed: 7)
    #expect(first.count == 80)
    #expect(sampleRows(rows, count: 80, seed: 7) == first)
    #expect(sampleRows(rows, count: 80, seed: 8) != first)
    // Every persona's every statement name is in the sample at least once.
    #expect(Set(first.map { $0.persona + $0.rawName }) == Set(rows.map { $0.persona + $0.rawName }))
    // Asking for more rows than exist gives them all.
    #expect(sampleRows(rows, count: 10_000, seed: 7).count == rows.count)
}

@Test func transfersAreLeftOutUnlessAsked() throws {
    let database = try prepareDatabase(persona: "maya", asOf: Persona.asOf, dataFolder: repoRoot.appending(path: "tools/data"), flags: OrganizerFlags())
    let all = try database.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM transactions")! }
    let moved = try database.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM transactions WHERE kind IN ('transfer', 'card_payment')")! }
    #expect(moved > 0)
    #expect(try labelRows(database, persona: "maya", includeTransfers: false).count == all - moved)
    #expect(try labelRows(database, persona: "maya", includeTransfers: true).count == all)
}

@Test func sheetHasTheColumnsAndStaysBlindByDefault() throws {
    let blind = try exportSheet(["--personas", "maya", "--n", "30"])
    #expect(blind[0] == exportColumns)
    #expect(blind.count == 31 && blind.dropFirst().allSatisfy { $0.count == exportColumns.count })
    #expect(blind[1][0] == "seed7-001" && blind[1][2] == "maya")
    #expect(blind.dropFirst().allSatisfy { $0[10].isEmpty && $0[11].isEmpty }) // true_merchant, my_label
    // With the truth the same rows come back, now with true_merchant filled.
    let truth = try exportSheet(["--personas", "maya", "--n", "30", "--with-truth"])
    #expect(truth.map { $0.prefix(10) } == blind.map { $0.prefix(10) })
    #expect(truth.dropFirst().allSatisfy { !$0[10].isEmpty })
}

@Test func csvCellsAreQuotedForSpreadsheets() {
    let cells = ["plain", "has, comma", "say \"hi\"", "two\nlines", ""]
    #expect(parseCSV(csvLine(cells) + "\n") == [cells])
}

@Test func plaidSourceShowsPlaidNamesNextToTheOrganizers() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "plaid-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: file) }
    let saved = try SedgeDatabase(path: file.path)
    let account = Account(account_id: "a", name: "Checking", type: "depository",
                          balances: Balances(current: 100))
    let charge = Transaction(transaction_id: "t1", account_id: "a", date: "2026-05-01", name: "SQ *BEAN ST COFFEE 123",
                             amount: 4.5, pending: false, merchant_name: "Bean Street")
    try saved.save(accounts: [account], transactions: [charge], asOf: "2026-05-02")

    let sheet = try exportSheet(["--source", "plaid", "--db", file.path])
    #expect(sheet.count == 2)
    let row = sheet[1]
    #expect(row[1] == "plaid" && row[2] == "plaid" && row[3] == "t1")
    // The organizer's name comes from the raw text; Plaid's name only sits beside it.
    #expect(row[8] == "Bean Street Coffee" && row[9] == "Bean Street")
    #expect(throws: EvalError.self) { try exportSheet(["--source", "plaid", "--db", file.path, "--with-truth"]) }
}
