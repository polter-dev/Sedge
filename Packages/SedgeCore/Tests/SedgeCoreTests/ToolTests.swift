import Foundation
import GRDB
import Testing
@testable import SedgeCore

// Expected values come from the answer keys of the two training personas (maya and daniel),
// joined to their raw transactions. jordan and elena are held out and never read here.

/// One transaction with its answer-key labels.
struct Truth {
    let id, date: String
    let amount: Double
    let merchant: String?
    let kind, recurring: String
}

func truth(_ persona: String) throws -> [Truth] {
    struct Key: Decodable { var transactions: [Label] }
    struct Label: Decodable { var transaction_id: String; var true_merchant: String?; var kind: String; var recurring: String }
    let folder = dataDirectory.appending(path: persona)
    let labels = try JSONDecoder().decode(Key.self, from: Data(contentsOf: folder.appending(path: "answer_key.json"))).transactions
    let byID = Dictionary(uniqueKeysWithValues: labels.map { ($0.transaction_id, $0) })
    return try JSONDecoder().decode([Transaction].self, from: Data(contentsOf: folder.appending(path: "transactions.json")))
        .filter { !$0.pending }
        .map { t in
            let label = byID[t.transaction_id]!
            return Truth(id: t.transaction_id, date: t.date, amount: t.amount, merchant: label.true_merchant,
                         kind: label.kind, recurring: label.recurring)
        }
}

/// The answer key's spending total (refunds are negative spending there), summed in cents.
func spent(_ rows: [Truth]) -> Double {
    Double(rows.filter { $0.kind == "spending" }.map { Int(($0.amount * 100).rounded()) }.reduce(0, +)) / 100
}

/// Calls a tool with a JSON object of inputs and parses its JSON answer.
func call(_ tool: String, _ input: [String: Any], on database: SedgeDatabase) throws -> [String: Any] {
    let text = try #require(Tool.named(tool)).call(JSONSerialization.data(withJSONObject: input), database: database)
    return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

func rows(_ answer: [String: Any], _ key: String = "rows") -> [[String: Any]] { answer[key] as? [[String: Any]] ?? [] }

/// January through June, plus any other inputs.
func firstHalf(_ more: [String: Any] = [:]) -> [String: Any] {
    more.merging(["start_date": "2026-01-01", "end_date": "2026-06-30"]) { mine, _ in mine }
}

// MARK: - total_spent

@Test func mayaNetflixTotal() throws {
    let answer = try call("total_spent", firstHalf(["merchant": "Netflix"]), on: organizedPersona("maya"))
    let expected = try spent(truth("maya").filter { $0.merchant == "Netflix" })
    #expect(expected == 100.44)
    #expect(answer["total"] as? Double == expected)
    #expect(answer["count"] as? Int == 6)
    #expect(rows(answer).count == 6)
}

@Test(arguments: ["maya", "daniel"])
func totalSpentEverywhereMatchesTheKey(persona: String) throws {
    let answer = try call("total_spent", firstHalf(), on: organizedPersona(persona))
    #expect(answer["total"] as? Double == spent(try truth(persona)))
    // Rows are capped at 10 even though there are many more transactions.
    #expect(rows(answer).count == 10)
}

/// A category total equals the answer key's total for the one store in that category.
@Test(arguments: [("maya", "groceries", "Value Mart"), ("daniel", "gas", "Shell")])
func totalSpentInACategory(persona: String, category: String, store: String) throws {
    let input = ["category": category, "start_date": "2026-03-01", "end_date": "2026-05-31"]
    let answer = try call("total_spent", input, on: organizedPersona(persona))
    let expected = try spent(truth(persona).filter { $0.merchant == store && $0.date >= "2026-03-01" && $0.date <= "2026-05-31" })
    #expect(answer["total"] as? Double == expected)
}

@Test func unknownStoreSuggestsCloseNames() throws {
    let answer = try call("total_spent", firstHalf(["merchant": "netflx"]), on: organizedPersona("maya"))
    #expect(answer["error"] as? String == "Unknown store \"netflx\".")
    #expect((answer["hint"] as? String)?.hasPrefix("Close names: Netflix") == true)
    // Store names match without regard to case.
    let lower = try call("total_spent", firstHalf(["merchant": "NETFLIX"]), on: organizedPersona("maya"))
    #expect(lower["total"] as? Double == 100.44)
}

// MARK: - compare_periods

@Test func mayaNetflixJanuaryVersusJune() throws {
    let input = ["merchant": "netflix", "first_start": "2026-01-01", "first_end": "2026-01-31",
                 "second_start": "2026-06-01", "second_end": "2026-06-30"]
    let answer = try call("compare_periods", input, on: organizedPersona("maya"))
    let netflix = try truth("maya").filter { $0.merchant == "Netflix" }
    let january = spent(netflix.filter { $0.date.hasPrefix("2026-01") }), june = spent(netflix.filter { $0.date.hasPrefix("2026-06") })
    #expect(answer["first"] as? Double == january)
    #expect(answer["second"] as? Double == june)
    #expect(answer["difference"] as? Double == ((june - january) * 100).rounded() / 100)
    #expect(answer["percent_change"] as? Double == 16.1) // 15.49 to 17.99
}

@Test func danielFirstQuarterVersusSecond() throws {
    let input = ["first_start": "2026-01-01", "first_end": "2026-03-31", "second_start": "2026-04-01", "second_end": "2026-06-30"]
    let answer = try call("compare_periods", input, on: organizedPersona("daniel"))
    let all = try truth("daniel")
    let q1 = spent(all.filter { $0.date <= "2026-03-31" }), q2 = spent(all.filter { $0.date >= "2026-04-01" })
    #expect(answer["first"] as? Double == q1)
    #expect(answer["second"] as? Double == q2)
    #expect(answer["percent_change"] as? Double == ((q2 - q1) / q1 * 1000).rounded() / 10)
}

// MARK: - recurring_charges

/// Each answer-key series as "kind cadence amount next-date": the last charge's amount, and
/// its date plus one cadence. Yearly series are left out: the organizer only finds weekly,
/// biweekly and monthly ones (daniel's one yearly charge can't be seen as repeating in 6 months).
func expectedSeries(_ persona: String, kinds: Set<String>) throws -> Set<String> {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let series = Dictionary(grouping: try truth(persona).filter {
        kinds.contains($0.kind) && ["weekly", "biweekly", "monthly"].contains($0.recurring)
    }) { "\($0.merchant!)|\($0.kind)" }
    return try Set(series.values.map { charges in
        let last = charges.max { $0.date < $1.date }!
        let date = try Date(last.date + "T00:00:00Z", strategy: .iso8601)
        let next = last.recurring == "monthly" ? calendar.date(byAdding: .month, value: 1, to: date)!
            : calendar.date(byAdding: .day, value: last.recurring == "weekly" ? 7 : 14, to: date)!
        let kind = last.kind == "income" ? "income" : "bill"
        return "\(kind) \(last.recurring) \(abs(last.amount)) \(next.formatted(.iso8601.year().month().day()))"
    })
}

func series(_ answer: [String: Any]) -> Set<String> {
    Set(rows(answer, "series").map { "\($0["kind"]!) \($0["cadence"]!) \($0["amount"] as! Double) \($0["next"]!)" })
}

@Test(arguments: ["maya", "daniel"])
func recurringChargesMatchTheKey(persona: String) throws {
    let answer = try call("recurring_charges", ["kind": "all"], on: organizedPersona(persona))
    #expect(series(answer) == (try expectedSeries(persona, kinds: ["spending", "income"])))
}

@Test func mayaBillsAndPaychecksSeparately() throws {
    let database = try organizedPersona("maya")
    let bills = try call("recurring_charges", ["kind": "bills"], on: database)
    let income = try call("recurring_charges", ["kind": "income"], on: database)
    #expect(series(bills) == (try expectedSeries("maya", kinds: ["spending"])))
    #expect(series(income) == ["income biweekly 520.0 2026-07-03"])
    #expect(series(bills).count == 6)
}

// MARK: - top_merchants

/// The answer key's stores ranked by spending, as their totals.
func expectedTop(_ rows: [Truth]) -> [Double] {
    Dictionary(grouping: rows.filter { $0.kind == "spending" }) { $0.merchant! }
        .values.map(spent).filter { $0 > 0 }.sorted(by: >)
}

@Test(arguments: ["maya", "daniel"])
func topMerchantsMatchTheKey(persona: String) throws {
    let answer = try call("top_merchants", firstHalf(["limit": 5]), on: organizedPersona(persona))
    let expected = expectedTop(try truth(persona))
    #expect(rows(answer, "stores").map { $0["total"] as! Double } == Array(expected.prefix(5)))
    // Only that the list was cut: the exact store count depends on the organizer's grouping,
    // which splits maya's three campus bookstore names into separate stores.
    #expect((answer["total_count"] as? Int ?? 0) > 5)
}

@Test func mayaTopStoresInMarch() throws {
    let input: [String: Any] = ["start_date": "2026-03-01", "end_date": "2026-03-31", "limit": 3]
    let answer = try call("top_merchants", input, on: organizedPersona("maya"))
    let expected = expectedTop(try truth("maya").filter { $0.date.hasPrefix("2026-03") })
    #expect(rows(answer, "stores").map { $0["total"] as! Double } == Array(expected.prefix(3)))
    #expect(rows(answer, "stores").first?["store"] as? String == "Oakwood Apartments Rent")
}

// MARK: - find_transactions

@Test func findMayaNetflixCharges() throws {
    let answer = try call("find_transactions", ["merchant": "Netflix"], on: organizedPersona("maya"))
    let expected = try truth("maya").filter { $0.merchant == "Netflix" }.sorted { $0.date > $1.date }
    #expect(answer["total_count"] as? Int == expected.count)
    #expect(rows(answer).map { $0["date"] as! String } == expected.map(\.date))
    #expect(rows(answer).map { $0["amount"] as! Double } == expected.map(\.amount))
}

/// Large transactions of every kind (paychecks and transfers too), cut to 10 rows.
@Test(arguments: ["maya", "daniel"])
func findLargeTransactions(persona: String) throws {
    let answer = try call("find_transactions", ["min_amount": 500, "start_date": "2026-02-01"], on: organizedPersona(persona))
    let expected = try truth(persona).filter { abs($0.amount) >= 500 && $0.date >= "2026-02-01" }
    #expect(answer["total_count"] as? Int == expected.count)
    #expect(rows(answer).count == min(10, expected.count))
    // Newest first: the 10 rows are the 10 latest dates.
    #expect(rows(answer).map { $0["date"] as! String } == Array(expected.map(\.date).sorted(by: >).prefix(10)))
}

@Test func findSmallMarchCharges() throws {
    let input: [String: Any] = ["max_amount": 5, "start_date": "2026-03-01", "end_date": "2026-03-31"]
    let answer = try call("find_transactions", input, on: organizedPersona("maya"))
    let expected = try truth("maya").filter { abs($0.amount) <= 5 && $0.date.hasPrefix("2026-03") }
    #expect(answer["total_count"] as? Int == expected.count)
}

// MARK: - account_balances

@Test(arguments: ["maya", "daniel"])
func balancesMatchTheKey(persona: String) throws {
    struct Key: Decodable { var accounts: [Ending] }
    struct Ending: Decodable { var account_id: String; var ending_balance: Double }
    let folder = dataDirectory.appending(path: persona)
    let ending = try JSONDecoder().decode(Key.self, from: Data(contentsOf: folder.appending(path: "answer_key.json"))).accounts
    let names = try Dictionary(uniqueKeysWithValues: JSONDecoder()
        .decode([Account].self, from: Data(contentsOf: folder.appending(path: "accounts.json"))).map { ($0.account_id, $0.name) })
    let expected = Dictionary(uniqueKeysWithValues: ending.map { (names[$0.account_id]!, $0.ending_balance) })

    let answer = try call("account_balances", [:], on: organizedPersona(persona))
    let got = Dictionary(uniqueKeysWithValues: rows(answer, "accounts").map { ($0["name"] as! String, $0["balance"] as! Double) })
    #expect(got == expected)
    #expect(answer["as_of"] as? String == "2026-06-30")
}

// MARK: - Read-only, bad input, schema

@Test func aWriteInsideAToolFails() throws {
    let database = try organizedPersona("maya")
    let vandal = Tool(name: "vandal", description: "Tries to delete data.", inputs: []) { _, db in
        try db.execute(sql: "DELETE FROM transactions")
        return ["deleted": true]
    }
    let answer = vandal.call(Data("{}".utf8), database: database)
    #expect(answer.contains("\"error\""))
    #expect(answer.contains("readonly"))
    #expect(try database.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions") } == 130)
}

@Test(arguments: [
    ("top_merchants", #"{"start_date": "2026-01-01", "end_date": "2026-06-30"}"#, "Missing input \"limit\"."),
    ("top_merchants", #"{"start_date": "2026-01-01", "end_date": "2026-06-30", "limit": 11}"#, "Bad value for \"limit\"."),
    ("top_merchants", #"{"start_date": "2026-01-01", "end_date": "2026-06-30", "limit": 2.5}"#, "Bad value for \"limit\"."),
    ("total_spent", #"{"start_date": "2026-02-30", "end_date": "2026-06-30"}"#, "Bad value for \"start_date\"."),
    ("total_spent", #"{"start_date": "2026-06-30", "end_date": "2026-01-01"}"#, "start_date is after end_date."),
    ("total_spent", #"{"category": "pets", "start_date": "2026-01-01", "end_date": "2026-06-30"}"#, "Bad value for \"category\"."),
    ("recurring_charges", #"{"kind": "all", "store": "Netflix"}"#, "Unknown input \"store\"."),
    ("account_balances", #"[1, 2]"#, "The input must be a JSON object."),
])
func badInputReturnsAnError(tool: String, input: String, error: String) throws {
    let text = try #require(Tool.named(tool)).call(Data(input.utf8), database: organizedPersona("maya"))
    let answer = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    #expect(answer["error"] as? String == error)
    #expect(answer["hint"] is String)
}

/// Claude's strict mode accepts only part of JSON Schema: every object needs
/// `additionalProperties: false`, and number or length limits aren't allowed.
@Test(arguments: Tool.all.map(\.name))
func claudeSchemaFollowsStrictRules(name: String) throws {
    let tool = try #require(Tool.named(name))
    let schema = tool.claudeSchema
    #expect(JSONSerialization.isValidJSONObject(schema))
    #expect(Set(schema.keys) == ["name", "description", "strict", "input_schema"])
    #expect(schema["strict"] as? Bool == true)
    #expect(name.wholeMatch(of: /[a-z_]{1,64}/) != nil)
    #expect(!tool.description.isEmpty)

    let input = try #require(schema["input_schema"] as? [String: Any])
    #expect(input["type"] as? String == "object")
    #expect(input["additionalProperties"] as? Bool == false)
    let properties = try #require(input["properties"] as? [String: [String: Any]])
    let required = try #require(input["required"] as? [String])
    for (key, property) in properties {
        #expect(["string", "integer", "number"].contains(property["type"] as? String), "\(key)")
        #expect(property["description"] is String, "\(key)")
        #expect(Set(property.keys).isSubset(of: ["type", "description", "format", "enum"]), "\(key)")
        if let format = property["format"] { #expect(format as? String == "date", "\(key)") }
    }

    // The schema says exactly what the one definition says, so the forms can't drift.
    #expect(schema["name"] as? String == tool.name)
    #expect(schema["description"] as? String == tool.description)
    #expect(Set(properties.keys) == Set(tool.inputs.map(\.name)))
    #expect(required == tool.inputs.filter(\.required).map(\.name))
    for item in tool.inputs {
        if case .choice(let options) = item.kind { #expect(properties[item.name]?["enum"] as? [String] == options) }
        #expect(properties[item.name]?["description"] as? String == item.description)
    }
}

/// The six names and their inputs are frozen for v1. Later tools are added after them.
@Test func toolListIsTheFrozenV1() {
    #expect(Tool.all.map { "\($0.name)(\($0.inputs.map(\.name).joined(separator: ",")))" } == [
        "total_spent(merchant,category,start_date,end_date)",
        "compare_periods(merchant,category,first_start,first_end,second_start,second_end)",
        "recurring_charges(kind)",
        "top_merchants(start_date,end_date,limit)",
        "find_transactions(merchant,min_amount,max_amount,start_date,end_date)",
        "account_balances()",
        "get_profile()",
    ])
}
