import Foundation
import GRDB
import Testing
@testable import SedgeCore

// Runs on all four personas' transactions. No answer key is read: every expected number here is
// worked out again from the raw data files or from the other tools.

/// Each persona's ranked list for a $200 monthly goal, printed so it can be checked by hand
/// (`swift test --filter savingsListsForAHandCheck`). The four lists must differ.
@Test func savingsListsForAHandCheck() throws {
    var lists: [[String]] = []
    for persona in Persona.all {
        let plan = try Savings.plan(in: organizedPersona(persona), goal: 200)
        print("\n\(persona): goal \(plan.goal_per_month)/month, cuts \(plan.total_per_month)/month, reached \(plan.reached)"
              + (plan.note.map { " (\($0))" } ?? ""))
        for (rank, cut) in plan.cuts.enumerated() {
            print("  \(rank + 1). \(cut.store) [\(cut.category)] \(cut.per_month)/month, value \(cut.value): \(cut.evidence)")
        }
        #expect(!plan.cuts.isEmpty, "\(persona)")
        lists.append(plan.cuts.map(\.store))
    }
    #expect(Set(lists).count == Persona.all.count)
}

/// Every store that can be suggested, per persona, checked by hand against the statement names in
/// transactions.json: the groceries, gas, dining, coffee, shopping and streaming stores, and none of
/// the rent, mortgage, utility, phone, internet, insurance, loan, installment, tuition, card payment
/// or transfer ones (nor maya's transit pass or jordan's monthly software and storage, which are
/// steady recurring charges, and maya's bookstore, which is education). Jordan's The Camera Store
/// is left out too: one purchase (54.43 on 2026-04-26), so stopping there saves nothing from now on.
@Test(arguments: [
    ("maya", ["Bean Street Coffee", "Corner Cafe", "Netflix", "Value Mart"]),
    ("daniel", ["Amazon", "Bean Street Coffee", "Corner Cafe", "Homegoods", "Netflix", "Shell Service Station", "Value Mart"]),
    ("jordan", ["Bean Street Coffee", "Camera Shop", "Corner Cafe", "Shell Oil", "Value Mart"]),
    ("elena", ["Bean Street Coffee", "Corner Cafe", "Home Goods", "Shell Oil", "Value Mart"]),
])
func fixedObligationsAreNeverSuggested(persona: String, stores: [String]) throws {
    let database = try organizedPersona(persona)
    let ranked = try database.dbQueue.read { try Savings.ranked($0) }
    #expect(ranked.map(\.store).sorted() == stores)
    // The statement names behind each store say nothing of a bill, and none is a transfer or card payment.
    let billWords = ["rent", "apartment", "mortgage", "utilit", "electric", "phone", "tmobile", "comcast", "xfinity",
                     "insurance", "loan", "installment", "tuition", "payment", "transfer", "autopay", "pmt"]
    for store in ranked.map(\.store) {
        let lines = try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT t.name, t.kind FROM transactions t JOIN entities m ON m.id = t.merchant_id WHERE m.name = ?",
                             arguments: [store])
        }
        for line in lines {
            let name = (line[0] as String).lowercased()
            #expect(!billWords.contains { name.contains($0) }, "\(persona): \(name)")
            // Income can share a store (maya's pay comes from Bean Street Coffee); only spending is cut.
            #expect(!["transfer", "card_payment"].contains(line[1] as String), "\(persona): \(name)")
        }
    }
}

/// Each cut is worth the store's real average month: total_spent at the store over all the data
/// (refunds counted against it), divided by the calendar months in transactions.json.
@Test(arguments: Persona.all)
func eachCutIsTheStoresAverageMonth(persona: String) throws {
    let database = try organizedPersona(persona)
    let raw = try JSONDecoder().decode([Transaction].self, from: Data(contentsOf: dataDirectory.appending(path: "\(persona)/transactions.json")))
        .filter { !$0.pending }
    let months = Double(Set(raw.map { $0.date.prefix(7) }).count)
    #expect(months == 6)
    let ranked = try database.dbQueue.read { try Savings.ranked($0) }
    for cut in ranked {
        let input = ["merchant": cut.store, "start_date": raw.map(\.date).min()!, "end_date": Persona.asOf]
        let spent = try #require(call("total_spent", input, on: database)["total"] as? Double)
        #expect(cut.per_month == cents(spent / months), "\(persona): \(cut.store)")
    }
}

/// Two amounts added up by hand from maya's statement lines: Value Mart's three spellings
/// (197.51 + 194.75 + 182.38 = 574.64, over 6 months) and Netflix (6 × 16.74).
@Test func mayasAmountsByHand() throws {
    let ranked = try organizedPersona("maya").dbQueue.read { try Savings.ranked($0) }
    #expect(ranked.first { $0.store == "Value Mart" }?.per_month == 95.77)
    #expect(ranked.first { $0.store == "Netflix" }?.per_month == 16.74)
    // Netflix's score: one charge on the 3rd of each month, so kept up is the neutral 0.5; regular
    // 5 of 25 weeks = 0.2 (January 3 is before the oldest whole week); size 100.44 / 574.64 = 0.175
    // of Value Mart (her biggest flexible store); (0.5 + 0.2 + 0.175) / 3 = 0.292, shown as 0.29.
    let netflix = try #require(ranked.first { $0.store == "Netflix" })
    #expect(netflix.value == 0.29)
    #expect(netflix.evidence == "bought in 5 of 25 weeks; once a month at most, so not judged on lowest-balance weeks")
}

/// A made-up person, 2026-04-01 to 2026-06-30 (91 days, 13 whole weeks, 3 months). Rent (3,000)
/// leaves checking on the 10th of each month and pay (3,500) comes in on the 17th, so the balance
/// is low from the 10th to the 16th every month and rises 500 a month: 500, then 1,000, then 1,500
/// in those stretches, 3,500 to 5,000 the rest of the time. Purchases go on the card, so they don't
/// move the checking balance. Coffee is bought every day; the gadget shop every day except the
/// 10th to the 16th. `extra` adds more card purchases as (id, day, statement name, amount).
/// `idleChecking` adds a second checking account that sorts first by name but has one charge.
private func madeUpPerson(extra: [(String, String, String, Double)] = [], idleChecking: Bool = false) throws -> [Savings.Cut] {
    let database = try SedgeDatabase()
    var lines: [Transaction] = []
    func add(_ id: String, _ account: String, _ date: String, _ name: String, _ amount: Double) {
        lines.append(Transaction(transaction_id: id, account_id: account, date: date, name: name, amount: amount, pending: false))
    }
    for month in ["04", "05", "06"] {
        add("rent\(month)", "chk", "2026-\(month)-10", "OAKWOOD APARTMENTS RENT", 3000)
        add("pay\(month)", "chk", "2026-\(month)-17", "ACME PAYROLL", -3500)
        for day in 1...(month == "05" ? 31 : 30) {
            let date = "2026-\(month)-" + (day < 10 ? "0\(day)" : "\(day)")
            add("coffee\(date)", "card", date, "BEAN COFFEE", 2)
            if !(10...16).contains(day) { add("gadget\(date)", "card", date, "GADGET SHOP", 1) }
        }
    }
    for (id, date, name, amount) in extra { add(id, "card", date, name, amount) }
    var accounts = [Account(account_id: "chk", name: "Checking", type: "depository", subtype: "checking", balances: Balances(current: 5000)),
                    Account(account_id: "card", name: "Card", type: "credit", balances: Balances(current: 0))]
    if idleChecking {
        accounts.append(Account(account_id: "equipment", name: "An Equipment Checking", type: "depository", subtype: "checking",
                                balances: Balances(current: 440)))
        add("tools", "equipment", "2026-06-20", "TOOL DEPOT", 60)
    }
    try database.save(accounts: accounts, transactions: lines, asOf: "2026-06-30")
    try Organizer.organize(database)
    return try database.dbQueue.read { try Savings.ranked($0) }
}

/// The gadget shop is skipped in every month's low stretch (the 10th to the 16th), the later,
/// higher-balance months included, so it is the one dropped when money is tight and ranks first.
@Test func spendingDroppedInEachMonthsTightStretchRanksFirst() throws {
    // Tight days: the 10th to the 16th of April, May and June, 21 days in all.
    // Gadget: 70 days × $1 = $70, none on a tight day, so kept up 0. Weeks are 7-day blocks back from
    // June 30, and June 10 to 16 is exactly one of them, so it was bought in 12 of 13 weeks.
    // Size 70 / 182 (coffee's 91 × $2). (0 + 12/13 + 70/182) / 3 = 0.436, shown as 0.44.
    // Coffee: $2 a day, the same in tight stretches as usual, so all three parts are 1.
    // Rent is housing, so it is never a cut. Monthly amounts are over 3 months: 70 / 3 and 182 / 3.
    #expect(try madeUpPerson() == [
        Savings.Cut(store: "Gadget Shop", category: "other", per_month: 23.33, value: 0.44,
                    evidence: "bought in 12 of 13 weeks; 0% of usual in each month's lowest-balance week"),
        Savings.Cut(store: "Bean Coffee", category: "coffee", per_month: 60.67, value: 1,
                    evidence: "bought in 13 of 13 weeks; 100% of usual in each month's lowest-balance week"),
    ])
}

/// An idle second checking account that sorts first by name changes nothing: the tight days are
/// read from the busier one, the account simulate_balance projects (#200).
@Test func tightDaysUseTheBusierCheckingAccount() throws {
    #expect(try madeUpPerson(idleChecking: true) == madeUpPerson())
}

/// Two subscriptions paid every month without a miss score the same, whatever day they bill on (review R2-1).
@Test func monthlyChargeScoreDoesNotDependOnBillingDay() throws {
    var extra: [(String, String, String, Double)] = []
    for month in ["04", "05", "06"] {
        extra.append(("netflix\(month)", "2026-\(month)-03", "NETFLIX.COM", 16.74))  // outside the 10th-16th low stretch
        extra.append(("spotify\(month)", "2026-\(month)-12", "SPOTIFY USA", 16.74))  // inside it
    }
    let cuts = try madeUpPerson(extra: extra)
    let early = try #require(cuts.first { $0.store == "Netflix" })
    let mid = try #require(cuts.first { $0.store == "Spotify Usa" })
    #expect(early.value == mid.value, "\(early.evidence) vs \(mid.evidence)")
}

/// A store bought from only once, and one bought from in two months but last on April 30 (61 days
/// before June 30), are never suggested, however low they would score. One bought last on May 1,
/// exactly 60 days back, still is.
@Test func oneOffAndStoppedStoresAreNeverSuggested() throws {
    let ranked = try madeUpPerson(extra: [
        ("once", "2026-06-20", "LAMP DEPOT", 54.43),
        ("old1", "2026-03-31", "KITE SHACK", 8), ("old2", "2026-04-30", "KITE SHACK", 8),
        ("edge1", "2026-04-02", "YARN BARN", 8), ("edge2", "2026-05-01", "YARN BARN", 8),
    ])
    #expect(ranked.map(\.store) == ["Yarn Barn", "Gadget Shop", "Bean Coffee"])
}

/// The tool through `Tool.named`, as a model would call it: the reply's shape, the cuts adding
/// up, the same text every time, and no bill among the cuts.
@Test func savingsToolReply() throws {
    let database = try organizedPersona("daniel")
    let tool = try #require(Tool.named("savings_options"))
    let text = tool.call(Data(#"{"goal_amount": 200}"#.utf8), database: database)
    #expect(text == tool.call(Data(#"{"goal_amount": 200}"#.utf8), database: database))
    let answer = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    #expect(Set(answer.keys) == ["goal_per_month", "cuts", "total_per_month", "reached"])
    #expect(answer["goal_per_month"] as? Double == 200)
    #expect(answer["reached"] as? Bool == true)
    let cuts = rows(answer, "cuts")
    #expect((1...Savings.maxCuts).contains(cuts.count))
    for cut in cuts {
        #expect(Set(cut.keys) == ["store", "category", "per_month", "value", "evidence"])
        #expect(!["housing", "utilities", "phone_internet", "insurance", "loans", "education"].contains(cut["category"] as? String))
    }
    let total = cuts.compactMap { $0["per_month"] as? Double }.reduce(0, +)
    #expect(answer["total_per_month"] as? Double == cents(total))
    // Without the last cut the goal wasn't reached yet, so no cut is more than needed.
    #expect(cents(total - (cuts.last?["per_month"] as? Double ?? 0)) < 200)
    // Every bill daniel has is left out: mortgage, auto loan, insurance, electric, internet, card payments, savings transfers.
    for bill in ["Home Mortgage", "Auto Loan", "Auto Insurance", "City Electric", "Comcast", "Payment", "Transfer"] {
        #expect(!text.localizedCaseInsensitiveContains(bill), "\(bill)")
    }
}

/// A goal too big to hold in cents comes back as an error, not a crash (review R1-1).
@Test func hugeGoalReturnsAnError() throws {
    let text = try #require(Tool.named("savings_options")).call(Data(#"{"goal_amount": 1e307}"#.utf8), database: organizedPersona("maya"))
    #expect(text.contains("error"))
}

/// $300 by a day 45 days from today is $200 a month (a month is 30 days).
@Test func goalByADateIsSpreadOverItsMonths() throws {
    let answer = try call("savings_options", ["goal_amount": 300, "by_date": "2026-08-14"], on: organizedPersona("elena"))
    #expect(answer["goal_per_month"] as? Double == 200)
}

/// Daniel's flexible stores could reach $600 together, but his 5 least valued can't: Netflix
/// 16.74 + Homegoods 47.29 + Amazon 70.60 + Bean Street Coffee 10.21 + Corner Cafe 180.01 = 324.85.
/// Netflix, a monthly charge and so neutral on kept up, still ranks first: (0.5 + 5 of 25 weeks +
/// 100.44 / 2005.25 of Value Mart) / 3 = 0.25, below Homegoods' 0.49.
@Test func goalPastFiveCutsSaysSo() throws {
    let answer = try call("savings_options", ["goal_amount": 600], on: organizedPersona("daniel"))
    #expect(answer["reached"] as? Bool == false)
    #expect(rows(answer, "cuts").count == Savings.maxCuts)
    #expect(rows(answer, "cuts").first?["value"] as? Double == 0.25)
    #expect(answer["total_per_month"] as? Double == 324.85)
    #expect(answer["short_by"] as? Double == 275.15)
    #expect(answer["note"] as? String == "Short of the goal within 5 cuts.")
}

/// Maya's flexible spending (145.24 a month) can't reach $200, so the tool says bills would be needed.
@Test func goalPastFlexibleSpendingSaysSo() throws {
    let answer = try call("savings_options", ["goal_amount": 200], on: organizedPersona("maya"))
    #expect(answer["reached"] as? Bool == false)
    #expect(answer["total_per_month"] as? Double == 145.24)
    #expect(answer["short_by"] as? Double == 54.76)
    #expect(answer["note"] as? String == "Can't reach the goal without cutting bills.")
    #expect(rows(answer, "cuts").count == 4)
}

/// The shared wind-back (`Simulator.closingBalances`, which `Savings` reads its tight days from):
/// each day's closing checking balance is today's balance plus every posted checking transaction
/// after that day, summed here in SQL instead. `closingBalance(on:)` reads the same list.
@Test(arguments: ["maya", "daniel"])
func closingBalancesUndoLaterTransactions(persona: String) throws {
    let database = try organizedPersona(persona)
    try database.dbQueue.read { db in
        let account = try #require(try Simulator.checkingAccount(db))
        let closing = try #require(try Simulator.closingBalances(db, days: 200))
        #expect(closing.count == 200)
        for back in closing.indices {
            let day = Simulator.text(Simulator.calendar.date(byAdding: .day, value: -back, to: try Simulator.date(Persona.asOf))!)
            let expected = try #require(try Int.fetchOne(db, sql: """
                SELECT ROUND(json_extract(a.balances, '$.current') * 100)
                     + COALESCE((SELECT SUM(CAST(ROUND(t.amount * 100) AS INTEGER)) FROM transactions t
                                 WHERE t.account_id = a.account_id AND NOT t.pending AND t.date > ? AND t.date <= ?), 0)
                FROM accounts a WHERE a.account_id = ?
                """, arguments: [day, Persona.asOf, account]))
            #expect(closing[back] == expected, "\(persona) \(day)")
        }
        #expect(try Simulator.closingBalance(db, on: "2026-05-30") == closing[31])
        #expect(try Simulator.closingBalance(db, on: Persona.asOf) == closing[0])
        #expect(try Simulator.closingBalance(db, on: "2026-07-01") == nil)
    }
}

/// savings_options answers exactly as it did before the wind-back moved out of `Savings` (#232):
/// the replies and daniel's whole ranked list were recorded from the old code.
@Test func savingsOutputUnchangedByTheSharedWindBack() throws {
    let tool = try #require(Tool.named("savings_options"))
    #expect(tool.call(Data(#"{"goal_amount": 200}"#.utf8), database: try organizedPersona("maya")) == #"{"cuts":[{"category":"subscriptions","evidence":"bought in 5 of 25 weeks; once a month at most, so not judged on lowest-balance weeks","per_month":16.74,"store":"Netflix","value":0.29},{"category":"dining","evidence":"bought in 12 of 25 weeks; 27% of usual in each month's lowest-balance week","per_month":20.86,"store":"Corner Cafe","value":0.32},{"category":"coffee","evidence":"bought in 24 of 25 weeks; 88% of usual in each month's lowest-balance week","per_month":11.87,"store":"Bean Street Coffee","value":0.65},{"category":"groceries","evidence":"bought in 22 of 25 weeks; 87% of usual in each month's lowest-balance week","per_month":95.77,"store":"Value Mart","value":0.92}],"goal_per_month":200,"note":"Can't reach the goal without cutting bills.","reached":false,"short_by":54.76,"total_per_month":145.24}"#)
    let daniel = try organizedPersona("daniel")
    #expect(tool.call(Data(#"{"goal_amount": 1000}"#.utf8), database: daniel) == #"{"cuts":[{"category":"subscriptions","evidence":"bought in 5 of 25 weeks; once a month at most, so not judged on lowest-balance weeks","per_month":16.74,"store":"Netflix","value":0.25},{"category":"shopping","evidence":"bought in 8 of 25 weeks; 100% of usual in each month's lowest-balance week","per_month":47.29,"store":"Homegoods","value":0.49},{"category":"shopping","evidence":"bought in 7 of 25 weeks; 100% of usual in each month's lowest-balance week","per_month":70.6,"store":"Amazon","value":0.5},{"category":"coffee","evidence":"bought in 12 of 25 weeks; 100% of usual in each month's lowest-balance week","per_month":10.21,"store":"Bean Street Coffee","value":0.5},{"category":"dining","evidence":"bought in 22 of 25 weeks; 100% of usual in each month's lowest-balance week","per_month":180.01,"store":"Corner Cafe","value":0.81}],"goal_per_month":1000,"note":"Can't reach the goal without cutting bills.","reached":false,"short_by":675.15,"total_per_month":324.85}"#)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let ranked = try daniel.dbQueue.read { try Savings.ranked($0) }
    #expect(String(decoding: try encoder.encode(ranked), as: UTF8.self) == #"[{"category":"subscriptions","evidence":"bought in 5 of 25 weeks; once a month at most, so not judged on lowest-balance weeks","per_month":16.74,"store":"Netflix","value":0.25},{"category":"shopping","evidence":"bought in 8 of 25 weeks; 100% of usual in each month's lowest-balance week","per_month":47.29,"store":"Homegoods","value":0.49},{"category":"shopping","evidence":"bought in 7 of 25 weeks; 100% of usual in each month's lowest-balance week","per_month":70.6,"store":"Amazon","value":0.5},{"category":"coffee","evidence":"bought in 12 of 25 weeks; 100% of usual in each month's lowest-balance week","per_month":10.21,"store":"Bean Street Coffee","value":0.5},{"category":"dining","evidence":"bought in 22 of 25 weeks; 100% of usual in each month's lowest-balance week","per_month":180.01,"store":"Corner Cafe","value":0.81},{"category":"gas","evidence":"bought in 24 of 25 weeks; 100% of usual in each month's lowest-balance week","per_month":163.88,"store":"Shell Service Station","value":0.82},{"category":"groceries","evidence":"bought in 21 of 25 weeks; 72% of usual in each month's lowest-balance week","per_month":334.21,"store":"Value Mart","value":0.85}]"#)
}
