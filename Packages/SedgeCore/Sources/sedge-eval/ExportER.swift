// `sedge-eval export-er` writes a sheet of transactions to label by hand, for checking how
// well the organizer names stores (entity resolution, "ER"). It only exports: the scoring
// is done elsewhere from the labeled sheet.
import Foundation
import GRDB
import SedgeCore

let exportUsage = """
    Usage: sedge-eval export-er [options]
      --source fake|plaid     fake personas, or Plaid Sandbox data saved by the app (default fake)
      --personas a,b          with fake: which personas (default jordan,elena)
      --db <file>             with plaid: the app's sedge.sqlite (printed by the app at launch)
      --n N                   how many rows (default 200; fewer if there aren't that many)
      --seed N                the same seed picks the same rows (default 7); sample_id starts with it
      --with-truth            fill true_merchant from the answer keys (off, so labels stay blind)
      --include-transfers     keep card payments and transfers between own accounts
      --out <csv>             where to save (default tools/eval/er/sample.csv)
    """

/// The columns of the sheet, in order. `my_label` is left blank for the person labeling.
let exportColumns = ["sample_id", "source", "persona", "transaction_id", "date", "raw_name", "amount",
                     "organizer_merchant_id", "organizer_merchant", "plaid_merchant_name", "true_merchant", "my_label"]

/// Everything `export-er` is told on the command line.
struct ExportOptions {
    var source = "fake"
    var personas = ["jordan", "elena"]
    var db: URL?
    var count = 200
    var seed: UInt64 = 7
    var withTruth = false
    var includeTransfers = false
    var out: URL
}

/// One transaction that can go on the sheet, with the organizer's merchant for it.
struct LabelRow: Equatable {
    var persona, transactionID, date, rawName: String
    var amount: Double
    var merchantID, merchant: String
    /// Plaid's own store name, only for comparison: filled for Plaid data, blank for fakes.
    var plaidMerchantName: String
    var trueMerchant = ""
}

/// Reads the options that follow `export-er`.
func parseExportOptions(_ arguments: [String], repoRoot: URL) throws -> ExportOptions {
    var options = ExportOptions(out: repoRoot.appending(path: "tools/eval/er/sample.csv"))
    var iterator = arguments.makeIterator()
    func value(_ option: String) throws -> String {
        guard let value = iterator.next() else { throw EvalError("\(option) needs a value.\n\n\(exportUsage)") }
        return value
    }
    while let argument = iterator.next() {
        switch argument {
        case "--source": options.source = try value(argument)
        case "--personas": options.personas = try value(argument).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        case "--db": options.db = URL(filePath: try value(argument))
        case "--n":
            guard let count = Int(try value(argument)), count > 0 else { throw EvalError("--n needs a whole number above 0.") }
            options.count = count
        case "--seed":
            guard let seed = UInt64(try value(argument)) else { throw EvalError("--seed needs a whole number of 0 or more.") }
            options.seed = seed
        case "--with-truth": options.withTruth = true
        case "--include-transfers": options.includeTransfers = true
        case "--out": options.out = URL(filePath: try value(argument))
        case "--help", "-h":
            print(exportUsage)
            exit(0)
        default: throw EvalError("Unknown option \(argument).\n\n\(exportUsage)")
        }
    }
    switch options.source {
    case "fake":
        if let unknown = options.personas.first(where: { !Persona.all.contains($0) }) { throw EvalError("Unknown persona \"\(unknown)\".") }
    case "plaid":
        guard options.db != nil else { throw EvalError("--source plaid needs --db, the app's sedge.sqlite.") }
        // Plaid Sandbox data has no answer key to take the truth from.
        if options.withTruth { throw EvalError("--with-truth only works with --source fake.") }
    default: throw EvalError("--source must be fake or plaid.")
    }
    return options
}

/// The transactions an organized database offers for labeling, oldest first. Card payments
/// and transfers are left out unless asked for: they are money moving between the person's
/// own accounts, not purchases at a store.
func labelRows(_ database: SedgeDatabase, persona: String, includeTransfers: Bool) throws -> [LabelRow] {
    try database.dbQueue.read { db in
        try Row.fetchAll(db, sql: """
            SELECT t.transaction_id, t.date, t.name, t.amount, t.merchant_id, e.name, t.merchant_name
            FROM transactions t LEFT JOIN entities e ON e.id = t.merchant_id
            WHERE ? OR t.kind NOT IN ('transfer', 'card_payment')
            ORDER BY t.date, t.transaction_id
            """, arguments: [includeTransfers]).map { row in
                LabelRow(persona: persona, transactionID: row[0], date: row[1], rawName: row[2], amount: row[3],
                         merchantID: row[4] ?? "", merchant: row[5] ?? "", plaidMerchantName: row[6] ?? "")
            }
    }
}

/// A small random number generator that always gives the same numbers for the same seed
/// (SplitMix64). Swift's built-in generator is different on every run, so it can't repeat a sample.
struct SeededGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15 // &+ and &* wrap around instead of stopping on overflow
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Picks `count` rows, the same ones for the same seed and input. First one row for every
/// distinct raw statement name per persona, so every store shows up at least once however
/// the organizer grouped them; then random rows until there are `count`. The result is sorted
/// by persona and date, which is easier to label than a random order.
func sampleRows(_ rows: [LabelRow], count: Int, seed: UInt64) -> [LabelRow] {
    // Fisher-Yates shuffle written out by hand, so the order can't change with a new Swift version.
    var generator = SeededGenerator(state: seed), shuffled = rows
    for index in shuffled.indices.dropFirst().reversed() {
        shuffled.swapAt(index, Int(generator.next() % UInt64(index + 1)))
    }
    var seenNames = Set<String>(), firsts: [LabelRow] = [], rest: [LabelRow] = []
    for row in shuffled {
        if seenNames.insert(row.persona + "\n" + row.rawName).inserted { firsts.append(row) } else { rest.append(row) }
    }
    return (firsts + rest).prefix(count).sorted { ($0.persona, $0.date, $0.transactionID) < ($1.persona, $1.date, $1.transactionID) }
}

/// One CSV line. A cell holding a comma, quote or line break is wrapped in quotes, with each
/// quote doubled, which is how Numbers, Excel and Python's csv module read it.
func csvLine(_ cells: [String]) -> String {
    cells.map { cell in
        cell.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : cell
    }.joined(separator: ",")
}

/// The whole sheet: a header line, then one line per row numbered from 1.
func exportCSV(_ rows: [LabelRow], source: String, seed: UInt64) -> String {
    let lines = rows.enumerated().map { index, row in
        csvLine(["seed\(seed)-" + String(format: "%03d", index + 1), source, row.persona, row.transactionID, row.date,
                 row.rawName, String(format: "%.2f", row.amount), row.merchantID, row.merchant, row.plaidMerchantName,
                 row.trueMerchant, ""])
    }
    return ([csvLine(exportColumns)] + lines).joined(separator: "\n") + "\n"
}

/// Each transaction's true store from a persona's answer key, by transaction id.
func trueMerchants(_ answerKey: URL) throws -> [String: String] {
    struct Key: Decodable {
        struct Entry: Decodable { let transaction_id: String; let true_merchant: String? }
        let transactions: [Entry]
    }
    let key = try JSONDecoder().decode(Key.self, from: Data(contentsOf: answerKey))
    return Dictionary(key.transactions.map { ($0.transaction_id, $0.true_merchant ?? "") }, uniquingKeysWith: { first, _ in first })
}

/// Copies the app's saved Plaid data into a fresh in-memory database and organizes it there.
/// The app's file is opened read-only, so the export never changes it.
func organizedPlaidDatabase(_ file: URL) throws -> SedgeDatabase {
    var configuration = Configuration()
    configuration.readonly = true
    let saved = try DatabaseQueue(path: file.path(percentEncoded: false), configuration: configuration)
    let (accounts, transactions, asOf) = try saved.read { db in
        (try Account.fetchAll(db), try Transaction.fetchAll(db),
         try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'as_of'"))
    }
    guard let asOf else { throw EvalError("\(file.path) has no saved Plaid data yet. Connect a bank in the app first.") }
    let database = try SedgeDatabase()
    try database.save(accounts: accounts, transactions: transactions, asOf: asOf)
    try Organizer.organize(database)
    return database
}

/// Runs `sedge-eval export-er`: gathers the rows, samples them and writes the CSV.
func exportER(_ arguments: [String], repoRoot: URL, log: (String) -> Void) throws {
    let options = try parseExportOptions(arguments, repoRoot: repoRoot)
    var rows: [LabelRow] = []
    if options.source == "plaid" {
        rows = try labelRows(organizedPlaidDatabase(options.db!), persona: "plaid", includeTransfers: options.includeTransfers)
    } else {
        let dataFolder = repoRoot.appending(path: "tools/data")
        for persona in options.personas {
            let database = try prepareDatabase(persona: persona, asOf: Persona.asOf, dataFolder: dataFolder, flags: OrganizerFlags())
            rows += try labelRows(database, persona: persona, includeTransfers: options.includeTransfers)
        }
    }
    var sample = sampleRows(rows, count: options.count, seed: options.seed)
    // The answer keys are read only here, after the sample is drawn, so the truth can't steer which rows are picked.
    if options.withTruth {
        var truth: [String: String] = [:]
        for persona in options.personas {
            truth.merge(try trueMerchants(repoRoot.appending(path: "tools/data/\(persona)/answer_key.json"))) { first, _ in first }
        }
        for index in sample.indices { sample[index].trueMerchant = truth[sample[index].transactionID] ?? "" }
    }
    try FileManager.default.createDirectory(at: options.out.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(exportCSV(sample, source: options.source, seed: options.seed).utf8).write(to: options.out, options: .atomic)

    let names = Set(rows.map { $0.persona + "\n" + $0.rawName }).count
    if sample.count < options.count { log("Only \(sample.count) transactions qualify, so the sheet has \(sample.count) rows.") }
    if sample.count < names { log("Warning: \(names) distinct statement names but only \(sample.count) rows, so some stores are missing.") }
    log("Wrote \(sample.count) rows (\(names) distinct statement names, seed \(options.seed)) to \(options.out.path)")
}
