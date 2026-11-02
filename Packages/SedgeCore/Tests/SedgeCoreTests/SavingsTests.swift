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
    // Netflix's score: kept up 1, regular 5 of 25 weeks = 0.2, size 100.44 / 574.64 = 0.175 of
    // Value Mart (her biggest flexible store); (1 + 0.2 + 0.175) / 3 = 0.458, shown as 0.46.
    #expect(ranked.first { $0.store == "Netflix" }?.value == 0.46)
}

/// A made-up person, 2026-04-01 to 2026-06-30 (91 days, 13 whole weeks, 3 months). Rent (3,000)
/// leaves checking on the 10th of each month and pay (3,500) comes in on the 17th, so the balance
/// is low from the 10th to the 16th every month and rises 500 a month: 500, then 1,000, then 1,500
/// in those stretches, 3,500 to 5,000 the rest of the time. Purchases go on the card, so they don't
/// move the checking balance. Coffee is bought every day; the gadget shop every day except the
/// 10th to the 16th. `extra` adds more card purchases as (id, day, statement name, amount).
private func madeUpPerson(extra: [(String, String, String, Double)] = []) throws -> [Savings.Cut] {
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
    try database.save(accounts: [Account(account_id: "chk", name: "Checking", type: "depository", subtype: "checking",
                                         balances: Balances(current: 5000)),
                                 Account(account_id: "card", name: "Card", type: "credit", balances: Balances(current: 0))],
                      transactions: lines, asOf: "2026-06-30")
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
                    evidence: "bought in 12 of 13 weeks; 0% of usual in low-balance weeks"),
        Savings.Cut(store: "Bean Coffee", category: "coffee", per_month: 60.67, value: 1,
                    evidence: "bought in 13 of 13 weeks; 100% of usual in low-balance weeks"),
    ])
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

/// Daniel's flexible stores could reach $600 together, but his 5 least valued (324.85) can't.
@Test func goalPastFiveCutsSaysSo() throws {
    let answer = try call("savings_options", ["goal_amount": 600], on: organizedPersona("daniel"))
    #expect(answer["reached"] as? Bool == false)
    #expect(rows(answer, "cuts").count == Savings.maxCuts)
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
