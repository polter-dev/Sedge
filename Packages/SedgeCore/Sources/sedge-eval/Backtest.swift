import Foundation
import SedgeCore

/// `sedge-eval backtest`: for every persona and cutoff, projects each account's balance from the
/// cutoff and writes it next to the real balance, one CSV row per account per day, for the
/// forecast-error measurement. The error itself is computed elsewhere.
func backtest(_ arguments: [String]) throws {
    var cutoffs: [String] = [], days = 14, useReconciliation = true, out: String?
    var rest = arguments[...]
    while let flag = rest.popFirst() {
        switch flag {
        case "--cutoff": if let value = rest.popFirst() { cutoffs.append(value) }
        case "--days": days = rest.popFirst().flatMap { Int($0) } ?? 0
        case "--no-reconciliation": useReconciliation = false
        case "--out": out = rest.popFirst()
        default: fail("Unknown flag \(flag).")
        }
    }
    guard !cutoffs.isEmpty, cutoffs.allSatisfy({ $0.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil }) else {
        fail("Give at least one --cutoff YYYY-MM-DD.")
    }
    guard (1...60).contains(days) else { fail("--days must be 1 to 60.") }

    // The repository root is four folders up from the folder this file is in.
    let root = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../..").standardized
    let file = out.map { URL(filePath: $0) }
        ?? root.appending(path: "tools/eval/results/backtest\(useReconciliation ? "" : "-no-reconciliation").csv")

    var csv = "persona,cutoff,account,date,projected,actual\n"
    for persona in Persona.all {
        for cutoff in cutoffs {
            let rows = try Simulator.backtest(persona: persona, folder: root.appending(path: "tools/data/\(persona)"),
                                              cutoff: cutoff, days: days, useReconciliation: useReconciliation)
            for row in rows {
                csv += "\(row.persona),\(row.cutoff),\(row.account),\(row.date),"
                    + String(format: "%.2f,%.2f\n", row.projected, row.actual)
            }
        }
    }
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try csv.write(to: file, atomically: true, encoding: .utf8)
    print("Wrote \(file.path)")
}

func fail(_ message: String) -> Never {
    print(message)
    exit(2)
}
