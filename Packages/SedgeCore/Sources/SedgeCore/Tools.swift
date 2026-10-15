import Foundation
import GRDB

/// One input a tool accepts. The same list produces the model-facing schema and the
/// checks `Tool.call` runs, so the two can't disagree.
public struct ToolInput: Sendable {
    public enum Kind: Sendable, Equatable {
        case text
        /// "YYYY-MM-DD".
        case date
        case integer(ClosedRange<Int>)
        case number
        /// One of a fixed list of strings.
        case choice([String])
    }

    public let name: String
    public let kind: Kind
    public let description: String
    public let required: Bool
}

/// A read-only question the assistant can ask the database. Each tool is defined once,
/// here, and every form a model sees (Claude's schema now, Apple's later) is built from it.
public struct Tool: Sendable {
    public let name: String
    public let description: String
    public let inputs: [ToolInput]
    /// The query itself. `input` is already checked against `inputs`, and `db` is a
    /// read-only connection, so a tool cannot change the data.
    let run: @Sendable (_ input: ToolArguments, _ db: Database) throws -> any Encodable

    /// Bump whenever a tool's name, inputs, description or output changes, like
    /// `SystemPrompt.version`: every eval run records it next to a hash of the definitions.
    public static let version = "v2"

    /// Every tool, in the order models see them.
    public static let all = [totalSpent, comparePeriods, recurringCharges, topMerchants, findTransactions, accountBalances,
                             getProfile]

    public static func named(_ name: String) -> Tool? { all.first { $0.name == name } }

    /// Runs the tool on a JSON object of inputs and returns compact JSON text. Bad input
    /// (or any other failure) comes back as `{"error": ..., "hint": ...}` instead of throwing,
    /// so the model can read what went wrong and try again.
    public func call(_ inputJSON: Data, database: SedgeDatabase) -> String {
        do {
            guard let object = try? JSONSerialization.jsonObject(with: inputJSON) as? [String: Any] else {
                throw ToolError("The input must be a JSON object.", hint: "Send the inputs as {\"name\": value}, or {} for none.")
            }
            let arguments = try ToolArguments(object, inputs: inputs)
            // GRDB's `read` opens the connection read-only: any INSERT, UPDATE or DELETE
            // inside a tool fails with an error instead of changing the file.
            let result = try database.dbQueue.read { db in try run(arguments, db) }
            return Self.json(result)
        } catch let error as ToolError {
            return Self.json(error)
        } catch {
            return Self.json(ToolError("The tool failed: \(error)"))
        }
    }

    /// Claude's tool definition with `strict: true`, so Claude's calls always match it.
    /// Strict mode needs `additionalProperties: false` and doesn't allow number limits
    /// (`minimum`, `maximum`), so allowed ranges go in the description and `call` checks them.
    public var claudeSchema: [String: Any] {
        var properties: [String: Any] = [:]
        for input in inputs {
            var property: [String: Any]
            switch input.kind {
            case .text: property = ["type": "string"]
            case .date: property = ["type": "string", "format": "date"]
            case .integer: property = ["type": "integer"]
            case .number: property = ["type": "number"]
            case .choice(let options): property = ["type": "string", "enum": options]
            }
            property["description"] = input.description
            properties[input.name] = property
        }
        return [
            "name": name,
            "description": description,
            "strict": true,
            "input_schema": [
                "type": "object",
                "properties": properties,
                "required": inputs.filter(\.required).map(\.name),
                "additionalProperties": false,
            ] as [String: Any],
        ]
    }

    /// Sorted keys so the same answer is always the same text.
    static func json(_ value: any Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(value), as: UTF8.self)
    }
}

/// The short error a tool returns instead of crashing.
struct ToolError: Error, Encodable {
    let error: String
    let hint: String?
    init(_ error: String, hint: String? = nil) {
        self.error = error
        self.hint = hint
    }
}

/// A tool's inputs after checking: dates and text are `String`, integers `Int`, numbers `Double`.
/// Optional inputs that were left out (or sent as null) are simply missing.
struct ToolArguments {
    private var values: [String: Any] = [:]

    init(_ object: [String: Any], inputs: [ToolInput]) throws {
        let allowed = inputs.map(\.name).joined(separator: ", ")
        if let unknown = object.keys.sorted().first(where: { key in !inputs.contains { $0.name == key } }) {
            throw ToolError("Unknown input \"\(unknown)\".", hint: allowed.isEmpty ? "This tool takes no inputs." : "Inputs: \(allowed).")
        }
        for input in inputs {
            guard let raw = object[input.name], !(raw is NSNull) else {
                if input.required { throw ToolError("Missing input \"\(input.name)\".", hint: input.description) }
                continue
            }
            let bad = ToolError("Bad value for \"\(input.name)\".", hint: input.description)
            switch input.kind {
            case .text:
                guard let text = raw as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty else { throw bad }
                values[input.name] = text.trimmingCharacters(in: .whitespaces)
            case .date:
                // Parse and print the date again: "2026-02-30" would come back as March 2, so it is rejected.
                guard let text = raw as? String, text.count == 10,
                      let date = try? Date(text + "T00:00:00Z", strategy: .iso8601),
                      date.formatted(.iso8601.year().month().day()) == text else { throw bad }
                values[input.name] = text
            case .integer(let range):
                // `as? Int` fails for 2.5, so only whole numbers get through.
                guard let number = raw as? Int, range.contains(number) else { throw bad }
                values[input.name] = number
            case .number:
                guard let number = raw as? Double, number.isFinite else { throw bad }
                values[input.name] = number
            case .choice(let options):
                guard let text = raw as? String, options.contains(text) else { throw bad }
                values[input.name] = text
            }
        }
    }

    func text(_ name: String) -> String? { values[name] as? String }
    func int(_ name: String) -> Int? { values[name] as? Int }
    func number(_ name: String) -> Double? { values[name] as? Double }

    /// A required start and end date pair, checked to be in order.
    func range(_ start: String, _ end: String) throws -> (start: String, end: String) {
        let from = text(start)!, to = text(end)!
        guard from <= to else { throw ToolError("\(start) is after \(end).", hint: "Swap the two dates.") }
        return (from, to)
    }
}

// MARK: - Shared query pieces

/// SQL conditions and their arguments, joined with AND.
struct Filter {
    private var conditions: [String] = []
    var arguments = StatementArguments()

    mutating func add(_ condition: String, _ values: [any DatabaseValueConvertible] = []) {
        conditions.append(condition)
        arguments += StatementArguments(values)
    }

    var sql: String { conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ") }
}

/// One transaction as tools show it. Plaid's sign: a positive amount is money out.
struct TransactionRow: Codable, FetchableRecord {
    let date: String
    let store: String
    let amount: Double
    let kind: String
    /// Present only when true, to keep rows short.
    let pending: Bool?
}

/// At most this many rows in any answer, so results stay short for small models.
let maxRows = 10

/// Rounds to whole cents, so float sums like 100.43999999 print as 100.44.
func cents(_ value: Double) -> Double { (value * 100).rounded() / 100 }

/// The categories the organizer can give a merchant.
let categoryNames = Organizer.categoryKeywords.map(\.category) + ["other"]

/// Every transaction column a tool shows, with its store's display name.
let rowSelect = """
    SELECT t.date, COALESCE(m.name, t.name) AS store, ROUND(t.amount, 2) AS amount, t.kind,
           CASE WHEN t.pending THEN 1 END AS pending
    FROM transactions t LEFT JOIN entities m ON m.id = t.merchant_id
    """

/// Checks that a store name is known (ignoring case) and adds it to the filter. An unknown
/// name fails with up to 3 close names, so the model can retry with a real one.
func addMerchant(_ name: String, to filter: inout Filter, _ db: Database) throws {
    let merchants = try Row.fetchAll(db, sql: "SELECT id, name FROM entities WHERE kind = 'merchant'")
        .map { (id: $0["id"] as String, name: $0["name"] as String) }
    let names = merchants.map(\.name)
    let wanted = name.lowercased()
    // Matched in Swift, not with SQLite's NOCASE, which only folds A to Z ("É" would miss).
    // Every merchant with that name counts, which only matters when the graph is off and
    // two raw names differ just by case.
    let ids = merchants.filter { $0.name.lowercased() == wanted }.map(\.id)
    guard ids.isEmpty else {
        filter.add("t.merchant_id IN (\(ids.map { _ in "?" }.joined(separator: ", ")))", ids)
        return
    }
    // Names that contain what was asked come first, then the closest spellings.
    func closeness(_ candidate: String) -> Double {
        let lower = candidate.lowercased()
        return (lower.contains(wanted) || wanted.contains(lower) ? 1 : 0) + Organizer.similarity(wanted, lower)
    }
    let close = names.sorted { (closeness($0), $1) > (closeness($1), $0) }.prefix(3)
    throw ToolError("Unknown store \"\(name)\".", hint: "Close names: " + close.joined(separator: ", "))
}

/// Spending (refunds count against it) between two dates, optionally at one store or in one
/// category. Transfers and card payments are left out: that money was already counted at
/// the store. Pending charges are left out until they post.
func spendingFilter(_ input: ToolArguments, from start: String, to end: String, _ db: Database) throws -> Filter {
    var filter = Filter()
    filter.add("t.kind IN ('spending', 'refund') AND NOT t.pending")
    filter.add("t.date BETWEEN ? AND ?", [start, end])
    if let merchant = input.text("merchant") { try addMerchant(merchant, to: &filter, db) }
    if let category = input.text("category") {
        filter.add("t.merchant_id IN (SELECT source FROM edges WHERE kind = 'in_category' AND target = ?)", ["category:" + category])
    }
    return filter
}

/// Total in dollars and number of transactions matching a filter. Summed in whole cents.
func total(_ filter: Filter, _ db: Database) throws -> (total: Double, count: Int) {
    let row = try Row.fetchOne(db, sql: "SELECT COALESCE(SUM(ROUND(t.amount * 100)), 0), COUNT(*) FROM transactions t \(filter.sql)",
                               arguments: filter.arguments)!
    return (cents((row[0] as Double) / 100), row[1])
}

// MARK: - Input descriptions shared by several tools

let merchantInput = ToolInput(name: "merchant", kind: .text,
                              description: "Store name, e.g. \"Netflix\". Leave out for all stores.", required: false)
let categoryInput = ToolInput(name: "category", kind: .choice(categoryNames),
                              description: "Spending category. Leave out for all categories.", required: false)
func dateInput(_ name: String, _ description: String, required: Bool = true) -> ToolInput {
    ToolInput(name: name, kind: .date, description: description + " (YYYY-MM-DD).", required: required)
}

// MARK: - The six tools (v1, frozen: ask before changing a name or input)

extension Tool {
    static let totalSpent = Tool(
        name: "total_spent",
        description: "Total spending at one store or in one category over a date range.",
        inputs: [merchantInput, categoryInput,
                 dateInput("start_date", "First day, inclusive"), dateInput("end_date", "Last day, inclusive")],
        run: { input, db in
            struct Result: Encodable { let total: Double; let count: Int; let rows: [TransactionRow] }
            let dates = try input.range("start_date", "end_date")
            let filter = try spendingFilter(input, from: dates.start, to: dates.end, db)
            let sum = try total(filter, db)
            // `count` already says how many there are, so no separate total_count here.
            let rows = try TransactionRow.fetchAll(db, sql: "\(rowSelect) \(filter.sql) ORDER BY t.date DESC, t.transaction_id DESC LIMIT \(maxRows)",
                                                   arguments: filter.arguments)
            return Result(total: sum.total, count: sum.count, rows: rows)
        })

    static let comparePeriods = Tool(
        name: "compare_periods",
        description: "Compare spending between two date ranges, overall or for one store or category.",
        inputs: [merchantInput, categoryInput,
                 dateInput("first_start", "First range's first day"), dateInput("first_end", "First range's last day"),
                 dateInput("second_start", "Second range's first day"), dateInput("second_end", "Second range's last day")],
        run: { input, db in
            struct Result: Encodable {
                let first, second, difference: Double
                /// Missing when the first total is 0, since a change from nothing has no percent.
                let percent_change: Double?
            }
            let one = try input.range("first_start", "first_end"), two = try input.range("second_start", "second_end")
            let first = try total(spendingFilter(input, from: one.start, to: one.end, db), db).total
            let second = try total(spendingFilter(input, from: two.start, to: two.end, db), db).total
            let percent = first == 0 ? nil : ((second - first) / abs(first) * 1000).rounded() / 10
            return Result(first: first, second: second, difference: cents(second - first), percent_change: percent)
        })

    static let recurringCharges = Tool(
        name: "recurring_charges",
        description: "List regular bills, subscriptions, and paychecks with amount, how often, and next date.",
        inputs: [ToolInput(name: "kind", kind: .choice(["bills", "income", "all"]),
                           description: "bills (money out), income (money in), or all.", required: true)],
        run: { input, db in
            struct Series: Codable, FetchableRecord {
                let store, kind, cadence: String
                let amount: Double
                let next: String
            }
            struct Result: Encodable { let series: [Series]; let total_count: Int? }
            // The organizer marks every charge in a series with the same cadence, amount and
            // next date, so one group per merchant and kind is one series. Card payments and
            // transfers are neither bills nor income, so they never show up here.
            // shortcut: a series that stopped (a cancelled subscription) is still listed, with a
            // next date before the dataset's as_of; have the organizer mark ended series if
            // real data or the eval shows one.
            let kinds = ["bills": "('spending')", "income": "('income')", "all": "('spending', 'income')"][input.text("kind")!]!
            let series = try Series.fetchAll(db, sql: """
                SELECT m.name AS store, CASE t.kind WHEN 'income' THEN 'income' ELSE 'bill' END AS kind,
                       e.cadence, ROUND(e.typical_amount, 2) AS amount, e.next_expected_date AS next
                FROM edges e JOIN transactions t ON t.transaction_id = e.source JOIN entities m ON m.id = e.target
                WHERE e.kind = 'recurring' AND t.kind IN \(kinds)
                GROUP BY e.target, t.kind ORDER BY next, store
                """)
            return Result(series: Array(series.prefix(maxRows)), total_count: series.count > maxRows ? series.count : nil)
        })

    static let topMerchants = Tool(
        name: "top_merchants",
        description: "Rank stores by spending over a date range.",
        inputs: [dateInput("start_date", "First day, inclusive"), dateInput("end_date", "Last day, inclusive"),
                 ToolInput(name: "limit", kind: .integer(1...maxRows), description: "How many stores, 1 to 10.", required: true)],
        run: { input, db in
            struct Store: Codable, FetchableRecord { let store: String; let total: Double; let count: Int }
            struct Result: Encodable { let stores: [Store]; let total_count: Int? }
            let dates = try input.range("start_date", "end_date")
            let filter = try spendingFilter(input, from: dates.start, to: dates.end, db)
            // Stores whose refunds cancel out their spending (total 0 or less) aren't "spending".
            let stores = try Store.fetchAll(db, sql: """
                SELECT m.name AS store, SUM(ROUND(t.amount * 100)) / 100.0 AS total, COUNT(*) AS count
                FROM transactions t JOIN entities m ON m.id = t.merchant_id \(filter.sql)
                GROUP BY t.merchant_id HAVING total > 0 ORDER BY total DESC, store
                """, arguments: filter.arguments)
            let limit = input.int("limit")!
            let shown = stores.prefix(limit).map { Store(store: $0.store, total: cents($0.total), count: $0.count) }
            return Result(stores: shown, total_count: stores.count > limit ? stores.count : nil)
        })

    static let findTransactions = Tool(
        name: "find_transactions",
        description: "Find individual transactions by store, amount, or date.",
        inputs: [merchantInput,
                 ToolInput(name: "min_amount", kind: .number, description: "Smallest amount in dollars, ignoring sign.", required: false),
                 ToolInput(name: "max_amount", kind: .number, description: "Largest amount in dollars, ignoring sign.", required: false),
                 dateInput("start_date", "First day, inclusive", required: false),
                 dateInput("end_date", "Last day, inclusive", required: false)],
        run: { input, db in
            struct Result: Encodable { let rows: [TransactionRow]; let total_count: Int }
            // Every kind is shown (with its `kind`), including transfers and pending charges:
            // this tool finds transactions, it doesn't total spending.
            var filter = Filter()
            if let merchant = input.text("merchant") { try addMerchant(merchant, to: &filter, db) }
            if let min = input.number("min_amount") { filter.add("ABS(t.amount) >= ?", [min - 0.005]) }
            if let max = input.number("max_amount") { filter.add("ABS(t.amount) <= ?", [max + 0.005]) }
            if let start = input.text("start_date") { filter.add("t.date >= ?", [start]) }
            if let end = input.text("end_date") { filter.add("t.date <= ?", [end]) }
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions t \(filter.sql)", arguments: filter.arguments)!
            let rows = try TransactionRow.fetchAll(db, sql: "\(rowSelect) \(filter.sql) ORDER BY t.date DESC, t.transaction_id DESC LIMIT \(maxRows)",
                                                   arguments: filter.arguments)
            return Result(rows: rows, total_count: count)
        })

    static let accountBalances = Tool(
        name: "account_balances",
        description: "Current balance of every account.",
        inputs: [],
        run: { _, db in
            struct Balance: Codable, FetchableRecord {
                let name, type: String
                /// For a credit card this is the amount owed.
                let balance: Double?
            }
            struct Result: Encodable { let as_of: String?; let accounts: [Balance]; let total_count: Int? }
            let accounts = try Balance.fetchAll(db, sql: """
                SELECT name, COALESCE(subtype, type) AS type, ROUND(json_extract(balances, '$.current'), 2) AS balance
                FROM accounts ORDER BY name
                """)
            // "Current" means as of the dataset's today, never the device clock.
            let asOf = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'as_of'")
            return Result(as_of: asOf, accounts: Array(accounts.prefix(maxRows)),
                          total_count: accounts.count > maxRows ? accounts.count : nil)
        })
}
