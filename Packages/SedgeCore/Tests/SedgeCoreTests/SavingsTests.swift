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
/// steady recurring charges, and maya's bookstore, which is education).
@Test(arguments: [
    ("maya", ["Bean Street Coffee", "Corner Cafe", "Netflix", "Value Mart"]),
    ("daniel", ["Amazon", "Bean Street Coffee", "Corner Cafe", "Homegoods", "Netflix", "Shell Service Station", "Value Mart"]),
    ("jordan", ["Bean Street Coffee", "Camera Shop", "Corner Cafe", "Shell Oil", "The Camera Store", "Value Mart"]),
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

/// A made-up person whose checking balance is low in weeks 1 and 2 (rent paid, pay not yet in).
/// Coffee is bought every week; the gadget shop is skipped in exactly those two weeks, so it is
/// the one dropped when money is tight and ranks first.
@Test func spendingDroppedInTightWeeksRanksFirst() throws {
    let database = try SedgeDatabase()
    /// The day `back` days before today (2026-06-30).
    func day(_ back: Int) -> String {
        Simulator.text(Simulator.calendar.date(byAdding: .day, value: -back, to: try! Simulator.date("2026-06-30"))!)
    }
    func line(_ id: String, _ account: String, _ back: Int, _ name: String, _ amount: Double) -> Transaction {
        Transaction(transaction_id: id, account_id: account, date: day(back), name: name, amount: amount, pending: false)
    }
    // Purchases go on the card, so only the rent and the pay move the checking balance:
    // 5,000 now, 2,000 from rent day (20 days back) until payday (7 days back).
    var lines = [line("rent", "chk", 20, "OAKWOOD APARTMENTS RENT", 3000), line("pay", "chk", 7, "ACME PAYROLL", -3000)]
    for week in 0..<8 {
        // The oldest day of each week, so the data is exactly 8 whole weeks.
        lines.append(line("coffee\(week)", "card", week * 7 + 6, "BEAN COFFEE", 5))
        if week != 1 && week != 2 { lines.append(line("gadget\(week)", "card", week * 7 + 6, "GADGET SHOP", 5)) }
    }
    try database.save(accounts: [Account(account_id: "chk", name: "Checking", type: "depository", subtype: "checking",
                                         balances: Balances(current: 5000)),
                                 Account(account_id: "card", name: "Card", type: "credit", balances: Balances(current: 0))],
                      transactions: lines, asOf: "2026-06-30")
    try Organizer.organize(database)
    let ranked = try database.dbQueue.read { try Savings.ranked($0) }
    // Gadget: kept up 0, regular 6/8, size 30/40, so (0 + 0.75 + 0.75) / 3 = 0.5. Coffee: all three are 1.
    // Rent is housing, so it is never a cut. Two calendar months (May and June) of data.
    #expect(ranked == [
        Savings.Cut(store: "Gadget Shop", category: "other", per_month: 15, value: 0.5,
                    evidence: "bought in 6 of 8 weeks; 0% of usual in low-balance weeks"),
        Savings.Cut(store: "Bean Coffee", category: "coffee", per_month: 20, value: 1,
                    evidence: "bought in 8 of 8 weeks; 100% of usual in low-balance weeks"),
    ])
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

/// Daniel's flexible stores could reach $600 together, but his 5 least valued (308.72) can't.
@Test func goalPastFiveCutsSaysSo() throws {
    let answer = try call("savings_options", ["goal_amount": 600], on: organizedPersona("daniel"))
    #expect(answer["reached"] as? Bool == false)
    #expect(rows(answer, "cuts").count == Savings.maxCuts)
    #expect(answer["total_per_month"] as? Double == 308.72)
    #expect(answer["short_by"] as? Double == 291.28)
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
