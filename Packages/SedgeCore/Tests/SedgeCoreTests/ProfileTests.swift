import Foundation
import GRDB
import Testing
@testable import SedgeCore

// Expected values come from tools/personas.md for the two training personas (maya and daniel).
// For every persona only the shape is checked, so nothing here is tuned on jordan or elena.

/// kind -> values, so a test can compare one kind of fact at a time.
func profile(_ database: SedgeDatabase) throws -> [String: [Profile.Value]] {
    Dictionary(grouping: try Profile.facts(in: database)) { $0.kind }.mapValues { $0.map(\.value) }
}

@Test(arguments: Persona.all)
func profileRunsForEveryPersona(persona: String) throws {
    let database = try organizedPersona(persona)
    let facts = try Profile.facts(in: database)
    let kindOf = try database.dbQueue.read { db in
        try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT transaction_id, kind FROM transactions")
            .map { ($0[0] as String, $0[1] as String) })
    }
    let accounts = try database.dbQueue.read { db in try Account.fetchCount(db) }
    #expect(facts.filter { $0.kind == "account" }.count == accounts)
    #expect(facts.contains { $0.kind == "income" })
    for fact in facts {
        #expect((0...1).contains(fact.confidence), "\(fact.id)")
        #expect(!fact.rule.isEmpty, "\(fact.id)")
        #expect(fact.kind == "account" || !fact.evidence.isEmpty, "\(fact.id)")
        // Transfers and card payments are never evidence of income or of a bill.
        let wanted = fact.kind == "income" ? "income" : "spending"
        #expect(fact.evidence.allSatisfy { kindOf[$0] == wanted }, "\(fact.id)")
    }
}

@Test func mayaProfile() throws {
    let facts = try profile(organizedPersona("maya"))
    #expect(facts["income"] == [Profile.Value(name: "Bean Street Coffee", amount: 520, schedule: "biweekly",
                                              monthly_average: 1126.67)])
    #expect(facts["housing"] == [Profile.Value(name: "Oakwood Apartments Rent", type: "rent", amount: 650, schedule: "monthly", day: 1)])
    #expect(facts["tuition"] == nil)
    #expect(facts["loan"] == nil)
    #expect(Set(facts["account"]!.map { $0.type! }) == ["checking", "credit card"])
}

@Test func danielProfile() throws {
    let facts = try profile(organizedPersona("daniel"))
    #expect(facts["income"] == [Profile.Value(name: "Northpoint Services Payroll", amount: 5200, schedule: "monthly",
                                              monthly_average: 5200)])
    #expect(facts["housing"] == [Profile.Value(name: "Home Mortgage", type: "mortgage", amount: 1850, schedule: "monthly", day: 1)])
    #expect(facts["loan"] == [Profile.Value(name: "Auto Loan Payment", type: "auto", amount: 325, schedule: "monthly", day: 7)])
    #expect(facts["tuition"] == nil)
    #expect(facts["account"]!.map { $0.type! }.sorted() == ["checking", "credit card", "credit card", "savings"])
}

@Test func correctionWinsAndSurvivesRebuild() throws {
    let database = try organizedPersona("maya")
    let id = try #require(try Profile.facts(in: database).first { $0.kind == "income" }).id
    let mine = Profile.Value(name: "Bean Street Coffee", amount: 600, schedule: "biweekly")
    try Profile.correct(id: id, kind: "income", value: mine, in: database)
    try Organizer.organize(database)

    let income = try Profile.facts(in: database).filter { $0.kind == "income" }
    #expect(income.count == 1)
    #expect(income.first?.value == mine)
    #expect(income.first?.confidence == 1 && income.first?.rule == "user_correction")
}

@Test func getProfileIsShort() throws {
    let answer = try call("get_profile", [:], on: organizedPersona("daniel"))
    let facts = rows(answer, "facts")
    #expect(facts.map { $0["kind"] as! String } == ["income", "housing", "loan", "account", "account", "account", "account"])
    // Evidence ids stay in the table; the model gets only what it needs to answer.
    #expect(facts.allSatisfy { Set($0.keys) == ["kind", "value", "confidence", "rule"] })
    #expect((facts[0]["value"] as? [String: Any])?["amount"] as? Double == 5200)
}

/// Made-up data for the rules maya and daniel never reach: pay that isn't on a cadence,
/// tuition (named, and a large school charge), and a buy-now-pay-later plan.
@Test func irregularIncomeTuitionAndInstallments() throws {
    func line(_ id: String, _ date: String, _ name: String, _ amount: Double) -> Transaction {
        Transaction(transaction_id: id, account_id: "chk", date: date, name: name, amount: amount, pending: false)
    }
    let database = try SedgeDatabase()
    try database.save(
        accounts: [Account(account_id: "chk", name: "Checking", type: "depository", balances: Balances())],
        transactions: [
            line("g1", "2026-01-09", "GIGCO PAYOUT", -310), line("g2", "2026-02-20", "GIGCO PAYOUT", -455),
            line("g3", "2026-02-27", "GIGCO PAYOUT", -120), line("g4", "2026-03-15", "GIGCO PAYOUT", -390),
            line("t1", "2026-01-10", "STATE U TUITION", 4200), line("t2", "2026-02-10", "STATE U TUITION", 4200),
            line("c1", "2026-01-12", "RIVERSIDE COLLEGE", 1500), line("c2", "2026-02-12", "RIVERSIDE COLLEGE", 25),
            line("b1", "2026-01-14", "CAMPUS BOOKSTORE", 80),
            line("a1", "2026-01-05", "AFFIRM INC", 50), line("a2", "2026-02-05", "AFFIRM INC", 50),
            line("a3", "2026-03-05", "AFFIRM INC", 50),
        ],
        asOf: "2026-03-31")
    try Organizer.organize(database)
    let facts = Dictionary(grouping: try Profile.facts(in: database)) { $0.kind }

    let income = try #require(facts["income"]?.first)
    // 1275 over the three months in the data.
    #expect(income.value == Profile.Value(name: "Gigco Payout", amount: 390, schedule: "irregular", monthly_average: 425))
    #expect(income.rule == "repeated_deposits" && income.evidence.sorted() == ["g1", "g2", "g3", "g4"])

    let tuition = try #require(facts["tuition"])
    #expect(tuition.map(\.rule) == ["large_education_charge", "tuition_payment"])
    #expect(tuition[0].value.paid == 1500 && tuition[0].evidence == ["c1"])
    #expect(tuition[1].value == Profile.Value(name: "State U Tuition", amount: 4200, schedule: "irregular", paid: 8400, refunded: 0,
                                              payments: [.init(date: "2026-01-10", amount: 4200), .init(date: "2026-02-10", amount: 4200)],
                                              refunds: []))

    let loan = try #require(facts["loan"]?.first)
    #expect(loan.value == Profile.Value(name: "Affirm Inc", type: "installment", amount: 50, schedule: "monthly", day: 5))
    #expect(loan.rule == "recurring_loan_payment")
}

/// A school that took two tuition payments and later refunded part of the first, plus a
/// college whose only large charge is tuition and whose small refund is for a book.
func tuitionWithRefund(useReconciliation: Bool = true) throws -> SedgeDatabase {
    func line(_ id: String, _ date: String, _ name: String, _ amount: Double) -> Transaction {
        Transaction(transaction_id: id, account_id: "chk", date: date, name: name, amount: amount, pending: false)
    }
    let database = try SedgeDatabase()
    try database.save(
        accounts: [Account(account_id: "chk", name: "Checking", type: "depository", balances: Balances())],
        transactions: [
            line("p1", "2026-01-10", "STATE U BURSAR", 4250.55), line("r1", "2026-02-15", "REFUND STATE U BURSAR", -1200.30),
            line("p2", "2026-05-08", "STATE U BURSAR", 3100.10),
            line("c1", "2026-01-12", "RIVERSIDE COLLEGE", 1500), line("c2", "2026-01-20", "REFUND RIVERSIDE COLLEGE", -40),
        ],
        asOf: "2026-06-30")
    try Organizer.organize(database, useReconciliation: useReconciliation)
    return database
}

@Test func tuitionPaidAndRefundedAreKeptApart() throws {
    let tuition = try #require(try profile(tuitionWithRefund())["tuition"])
    // A partial refund never equals a payment, so it is found by store, and the payment stays whole.
    #expect(tuition[1] == Profile.Value(name: "State U Bursar", amount: 4250.55, schedule: "irregular", paid: 7350.65, refunded: 1200.30,
                                        payments: [.init(date: "2026-01-10", amount: 4250.55), .init(date: "2026-05-08", amount: 3100.10)],
                                        refunds: [.init(date: "2026-02-15", amount: 1200.30)]))
    // Tuition found only by the $1,000 rule still counts a refund of any size.
    #expect(tuition[0].paid == 1500 && tuition[0].refunded == 40 && tuition[0].refunds == [.init(date: "2026-01-20", amount: 40)])

    // With reconciliation off the refund is income, so nothing is refunded and the payments still count.
    let ablated = try #require(try profile(tuitionWithRefund(useReconciliation: false))["tuition"])
    #expect(ablated[1].paid == 7350.65 && ablated[1].refunded == 0)
}

@Test func getProfileShowsTuitionPaidAndRefunded() throws {
    // What a model is handed back from get_profile.
    let answerJSON = try call("get_profile", [:], on: tuitionWithRefund())
    let values = (answerJSON["facts"] as? [[String: Any]] ?? []).compactMap { $0["value"] as? [String: Any] }
    let bursar = try #require(values.first { $0["name"] as? String == "State U Bursar" })
    #expect(bursar["paid"] as? Double == 7350.65 && bursar["refunded"] as? Double == 1200.30)
    #expect((bursar["payments"] as? [Any])?.count == 2 && (bursar["refunds"] as? [Any])?.count == 1)
}

/// The $40 refund at the college (tuition found by size) can be looked up three ways, and all agree.
@Test func smallTuitionRefundIsFoundByEveryTool() throws {
    let database = try tuitionWithRefund()
    let values = rows(try call("get_profile", [:], on: database), "facts").compactMap { $0["value"] as? [String: Any] }
    let college = try #require(values.first { $0["name"] as? String == "Riverside College" })
    #expect(college["paid"] as? Double == 1500 && college["refunded"] as? Double == 40)

    // find_transactions lists the refund with its kind, so a model can add it up itself.
    let found = rows(try call("find_transactions", ["merchant": "Riverside College"], on: database))
    #expect(found.filter { $0["kind"] as? String == "refund" }.map { $0["amount"] as? Double } == [-40])
    #expect(found.filter { $0["kind"] as? String == "spending" }.map { $0["amount"] as? Double } == [1500])

    // total_spent nets the refund against the payment.
    let spent = try call("total_spent", firstHalf(["merchant": "Riverside College"]), on: database)
    #expect(spent["total"] as? Double == 1460 && spent["count"] as? Int == 2)
}

/// A refund named with the word last is a refund, not income, and counts as tuition refunded.
@Test func refundWordAtTheEndIsATuitionRefund() throws {
    let database = try housingData([("p1", "2026-01-10", "STATE U BURSAR", 4000), ("r1", "2026-02-01", "STATE U BURSAR REFUND", -650)])
    let kind = try database.dbQueue.read { db in try String.fetchOne(db, sql: "SELECT kind FROM transactions WHERE transaction_id = 'r1'") }
    #expect(kind == "refund")
    let tuition = try #require(try profile(database)["tuition"])
    #expect(tuition == [Profile.Value(name: "State U Bursar", amount: 4000, schedule: "irregular", paid: 4000, refunded: 650,
                                      payments: [.init(date: "2026-01-10", amount: 4000)], refunds: [.init(date: "2026-02-01", amount: 650)])])
    #expect(try profile(database)["income"] == nil)
}

/// With no earlier purchase at the store, a name ending in "REFUND" is money in, not a refund, so it
/// doesn't make June's spending negative.
@Test func refundWordAtTheEndWithNoPurchaseStaysIncome() throws {
    let database = try housingData([("g1", "2026-06-10", "VALUE MART", 120), ("g2", "2026-06-20", "VALUE MART", 80),
                                    ("tax", "2026-06-15", "STATE TAX REFUND", -800)])
    let kind = try database.dbQueue.read { db in try String.fetchOne(db, sql: "SELECT kind FROM transactions WHERE transaction_id = 'tax'") }
    #expect(kind == "income")
    let spent = try call("total_spent", ["start_date": "2026-06-01", "end_date": "2026-06-30"], on: database)
    #expect(spent["total"] as? Double == 200 && spent["count"] as? Int == 2)
}

/// "TAX REFUND" shares a first word with "TAX PREP SERVICES", so the two are one store, but the fee
/// isn't what the refund is for: it stays income.
@Test func taxRefundAfterTaxPrepStaysIncome() throws {
    let database = try housingData([("prep", "2026-03-02", "TAX PREP SERVICES", 200), ("g1", "2026-03-10", "VALUE MART", 120),
                                    ("tax", "2026-03-15", "TAX REFUND", -1500)])
    let kind = try database.dbQueue.read { db in try String.fetchOne(db, sql: "SELECT kind FROM transactions WHERE transaction_id = 'tax'") }
    #expect(kind == "income")
    let spent = try call("total_spent", ["start_date": "2026-03-01", "end_date": "2026-03-31"], on: database)
    #expect(spent["total"] as? Double == 320 && spent["count"] as? Int == 2)
}

/// The same with a refund smaller than the other store's purchase, so only the store name keeps it income.
@Test func noRefundAfterNoFrillsStaysIncome() throws {
    let database = try housingData([("nf", "2026-04-02", "NO FRILLS", 60), ("no", "2026-04-15", "NO REFUND", -40)])
    let kind = try database.dbQueue.read { db in try String.fetchOne(db, sql: "SELECT kind FROM transactions WHERE transaction_id = 'no'") }
    #expect(kind == "income")
    let spent = try call("total_spent", ["start_date": "2026-04-01", "end_date": "2026-04-30"], on: database)
    #expect(spent["total"] as? Double == 60 && spent["count"] as? Int == 1)
}

/// A refund named last counts only up to what was paid for it: a $900 tax refund after $400 of tax
/// paid is income, and so is $900 back from a store where only $500 was spent. A premium refund
/// after monthly charges at the same insurer is still a refund.
@Test func refundWordAtTheEndIsCappedByPurchases() throws {
    let database = try housingData([("irs1", "2026-02-01", "IRS TAX PAYMENT", 400), ("irs2", "2026-04-15", "IRS TAX REFUND", -900),
                                    ("u1", "2026-01-10", "STATE U", 500), ("u2", "2026-02-10", "STATE U REFUND", -900),
                                    ("g1", "2026-01-05", "GEICO", 90), ("g2", "2026-02-05", "GEICO", 90),
                                    ("g3", "2026-02-20", "GEICO PREMIUM REFUND", -120)])
    let kinds = try database.dbQueue.read { db in
        try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT transaction_id, kind FROM transactions WHERE amount < 0")
            .map { ($0[0] as String, $0[1] as String) })
    }
    #expect(kinds == ["irs2": "income", "u2": "income", "g3": "refund"])
}

/// "REFUND" first means a refund only for money in: three monthly $10 charges named "REFUND FEE SERVICE"
/// are purchases that form a monthly series, and $10 back under the same name is a refund of the last one.
@Test func chargeNamedRefundIsAPurchase() throws {
    let database = try housingData([("f1", "2026-03-05", "REFUND FEE SERVICE", 10), ("f2", "2026-04-05", "REFUND FEE SERVICE", 10),
                                    ("f3", "2026-05-05", "REFUND FEE SERVICE", 10), ("r1", "2026-05-20", "REFUND FEE SERVICE", -10)])
    let edges = try database.dbQueue.read { db in
        try Row.fetchAll(db, sql: "SELECT source, kind, target FROM edges WHERE kind IN ('recurring', 'refund_of') ORDER BY source")
            .map { "\($0[0] as String) \($0[1] as String) \($0[2] as String)" }
    }
    #expect(edges == ["f1 recurring merchant:fee service", "f2 recurring merchant:fee service",
                      "f3 recurring merchant:fee service", "r1 refund_of f3"])
    let kinds = try database.dbQueue.read { db in try String.fetchAll(db, sql: "SELECT kind FROM transactions ORDER BY transaction_id") }
    #expect(kinds == ["spending", "spending", "spending", "refund"])
}

/// Under the size rule only the $1,500 charge is tuition paid, so refunding the $40 charge too
/// can't make refunded larger than paid. Every refund is still listed.
@Test func tuitionRefundedIsCappedAtPaid() throws {
    let database = try housingData([("c1", "2026-01-12", "RIVERSIDE COLLEGE", 1500), ("c3", "2026-01-13", "RIVERSIDE COLLEGE", 40),
                                    ("c2", "2026-01-20", "REFUND RIVERSIDE COLLEGE", -1500), ("c4", "2026-01-21", "REFUND RIVERSIDE COLLEGE", -40)])
    let tuition = try #require(try profile(database)["tuition"]?.first)
    #expect(tuition.paid == 1500 && tuition.refunded == 1500 && tuition.refunds?.count == 2)
}

/// Kept on purpose: a plain school-name line ("STATE U") merges the school's bookstore and
/// tuition into one store, so a bookstore refund there counts as tuition refunded.
@Test func bookstoreRefundAtAMergedSchoolStoreCountsAsTuition() throws {
    let database = try housingData([("t1", "2026-01-10", "STATE U TUITION", 4000), ("s1", "2026-01-11", "STATE U", 200),
                                    ("b1", "2026-01-12", "STATE U BOOKSTORE", 120), ("r1", "2026-01-20", "REFUND STATE U BOOKSTORE", -45)])
    let tuition = try #require(try profile(database)["tuition"])
    #expect(tuition.count == 1)
    #expect(tuition[0].paid == 4320 && tuition[0].refunded == 45 && tuition[0].refunds == [.init(date: "2026-01-20", amount: 45)])
}

/// At a store the profile finds as tuition, a refund naming only the school ("STATE U REFUND")
/// is for the tuition payment ("STATE U TUITION"), so it nets against it.
@Test func schoolNamedRefundAfterTuitionPaymentIsATuitionRefund() throws {
    let database = try housingData([("t1", "2026-01-10", "STATE U TUITION", 1500), ("r1", "2026-02-10", "STATE U REFUND", -500)])
    #expect(try kindOf("r1", database) == "refund")
    #expect(try profile(database)["tuition"]?.first?.refunded == 500)
    let spent = try call("total_spent", firstHalf(), on: database)
    #expect(spent["total"] as? Double == 1000 && spent["count"] as? Int == 2)
    // The same with a bursar payment.
    let bursar = try housingData([("t1", "2026-01-10", "STATE UNIVERSITY BURSAR", 1500), ("r1", "2026-02-10", "STATE UNIVERSITY REFUND", -500)])
    #expect(try kindOf("r1", bursar) == "refund")
}

/// A "*" descriptor ending in the word ("AMAZON.COM*AB12C REFUND") is a refund like "AMAZON REFUND".
@Test func refundWordAfterAStarDescriptorIsARefund() throws {
    #expect(Organizer.clean("AMAZON.COM*AB12C REFUND") == ("amazon", true))
    let database = try housingData([("p", "2026-01-10", "AMAZON.COM*AB12C", 40), ("r", "2026-01-12", "AMAZON.COM*AB12C REFUND", -10)])
    #expect(try kindOf("r", database) == "refund")
}

/// Each refund named last counts only up to what is left after earlier refunds: $500 paid, then
/// $300 back twice, makes the second one income, and spending $200.
@Test func partialRefundsTogetherStopAtWhatWasPaid() throws {
    let database = try housingData([("t1", "2026-01-10", "STATE U", 500), ("r1", "2026-02-10", "STATE U REFUND", -300),
                                    ("r2", "2026-03-10", "STATE U REFUND", -300)])
    #expect(try kindOf("r1", database) == "refund" && kindOf("r2", database) == "income")
    let spent = try call("total_spent", firstHalf(), on: database)
    #expect(spent["total"] as? Double == 200 && spent["count"] as? Int == 2)
}

/// A store whose category is housing is never tuition to the profile, so a refund naming only the
/// school there stays income even though one of its lines says TUITION.
@Test func shortRefundAtAHousingStoreWithATuitionLineStaysIncome() throws {
    let database = try housingData([("a1", "2026-01-01", "STATE U APARTMENTS", 800), ("a2", "2026-02-01", "STATE U APARTMENTS", 800),
                                    ("a3", "2026-03-01", "STATE U APARTMENTS", 800), ("p", "2026-01-05", "STATE U", 50),
                                    ("t", "2026-01-10", "STATE U TUITION", 1500), ("r", "2026-02-10", "STATE U REFUND", -500)])
    #expect(try profile(database)["tuition"] == nil)
    #expect(try kindOf("r", database) == "income")
    let spent = try call("total_spent", firstHalf(), on: database)
    #expect(spent["total"] as? Double == 3950 && spent["count"] as? Int == 5)
}

/// A pending charge isn't paid yet: it neither raises the refund cap nor makes the store a school.
@Test func pendingChargeIsNotPaidForTheRefundCap() throws {
    let capped = try housingData([("a", "2026-06-01", "STATE U", 100), ("b", "2026-06-25", "STATE U", 400),
                                  ("r", "2026-06-27", "STATE U REFUND", -300)], pending: ["b"])
    #expect(try kindOf("r", capped) == "income")
    let school = try housingData([("a", "2026-06-01", "STATE U BOOKS", 50), ("b", "2026-06-20", "STATE U TUITION", 1200),
                                  ("r", "2026-06-27", "STATE U REFUND", -40)], pending: ["b"])
    #expect(try profile(school)["tuition"] == nil)
    #expect(try kindOf("r", school) == "income")
}

/// A refund named last counts when it is no more than the purchases it names and no more than what is
/// left at the store: $590 paid, $500 back for "GEICO AUTO", then $90 back for "GEICO" is a refund too.
@Test func refundCapUsesWhatIsLeftAtTheStore() throws {
    let database = try housingData([("p1", "2026-01-05", "GEICO", 90), ("p2", "2026-01-10", "GEICO AUTO", 500),
                                    ("r1", "2026-02-01", "GEICO AUTO REFUND", -500), ("r2", "2026-02-05", "GEICO REFUND", -90)])
    #expect(try kindOf("r1", database) == "refund")
    #expect(try kindOf("r2", database) == "refund")
    let spent = try call("total_spent", firstHalf(), on: database)
    #expect(spent["total"] as? Double == 0 && spent["count"] as? Int == 4)
}

/// One transaction's kind, as the organizer saved it.
func kindOf(_ id: String, _ database: SedgeDatabase) throws -> String? {
    try database.dbQueue.read { db in try String.fetchOne(db, sql: "SELECT kind FROM transactions WHERE transaction_id = ?", arguments: [id]) }
}

/// A checking account with only the given (id, date, name, amount) charges, organized. The ids
/// in `pending` are still pending.
func housingData(_ charges: [(String, String, String, Double)], pending: Set<String> = []) throws -> SedgeDatabase {
    let database = try SedgeDatabase()
    try database.save(
        accounts: [Account(account_id: "chk", name: "Checking", type: "depository", balances: Balances())],
        transactions: charges.map { Transaction(transaction_id: $0.0, account_id: "chk", date: $0.1, name: $0.2, amount: $0.3,
                                                pending: pending.contains($0.0)) },
        asOf: "2026-06-30")
    try Organizer.organize(database)
    return database
}

/// Rent with utilities folded in: one landlord, four months, amounts too far apart for a steady series.
func irregularRent() throws -> SedgeDatabase {
    try housingData([("r1", "2026-02-01", "MAPLE COURT RENT", 812.40), ("r2", "2026-03-01", "MAPLE COURT RENT", 1210.15),
                     ("r3", "2026-04-01", "MAPLE COURT RENT", 640.00), ("r4", "2026-05-01", "MAPLE COURT RENT", 990.75)])
}

@Test func rentThatChangesAmountIsStillHousing() throws {
    let housing = try Profile.facts(in: irregularRent()).filter { $0.kind == "housing" }
    // The median (upper middle of 640.00, 812.40, 990.75, 1210.15), in cents.
    #expect(housing.map(\.value) == [Profile.Value(name: "Maple Court Rent", type: "rent", amount: 990.75, schedule: "irregular")])
    #expect(housing.first?.rule == "repeated_housing_bill" && housing.first?.confidence == Profile.guessConfidence)
    #expect(housing.first?.evidence.sorted() == ["r1", "r2", "r3", "r4"])
}

@Test func rentInOnlyOneOrTwoMonthsIsNotHousing() throws {
    // Three payments, but only two months; and one month at another landlord.
    let database = try housingData([("a1", "2026-03-01", "MAPLE COURT RENT", 900), ("a2", "2026-03-15", "MAPLE COURT RENT", 300),
                                    ("a3", "2026-04-01", "MAPLE COURT RENT", 1400), ("b1", "2026-05-01", "BIRCH LANE APARTMENTS", 1100)])
    #expect(try profile(database)["housing"] == nil)
}

@Test func steadyRentKeepsTheRecurringRule() throws {
    let database = try housingData((1...4).map { ("s\($0)", "2026-0\($0 + 1)-03", "MAPLE COURT RENT", 1500) })
    let housing = try Profile.facts(in: database).filter { $0.kind == "housing" }
    #expect(housing.map(\.value) == [Profile.Value(name: "Maple Court Rent", type: "rent", amount: 1500, schedule: "monthly", day: 3)])
    #expect(housing.first?.rule == "recurring_housing_bill" && housing.first?.confidence == Profile.keywordConfidence)
    #expect(housing.first?.evidence.sorted() == ["s1", "s2", "s3", "s4"])
}

/// Rent split into two halves on the 1st and 16th, March to June: twice-monthly housing that
/// costs two halves a month. Pay twice a month averages two paychecks a month.
@Test func twiceMonthlyRentAndPayCountTwoPaymentsAMonth() throws {
    let days = (3...6).flatMap { ["2026-0\($0)-01", "2026-0\($0)-16"] }
    let database = try housingData(days.enumerated().map { ("h\($0.offset)", $0.element, "MAPLE COURT RENT", 750) })
    let housing = try Profile.facts(in: database).filter { $0.kind == "housing" }
    #expect(housing.map(\.value) == [Profile.Value(name: "Maple Court Rent", type: "rent", amount: 750, schedule: "twice_monthly",
                                                   monthly_average: 1500)])
    #expect(housing.first?.rule == "recurring_housing_bill" && housing.first?.evidence.count == 8)

    let pay = try seriesDatabase(asOf: "2026-06-30", paydays: days, paycheck: 800)
    #expect(try profile(pay)["income"] == [Profile.Value(name: "Acme Payroll", amount: 800, schedule: "twice_monthly", monthly_average: 1600)])
}

/// Rent paid in two unequal halves, 1000 on the 1st and 900 on the 16th, March to June 2026:
/// it costs 1900 a month, and each day is projected at its own amount.
@Test func twiceMonthlyUnequalHalvesKeepTheirOwnAmounts() throws {
    let charges = (3...6).flatMap { m in [("a\(m)", "2026-0\(m)-01", "MAPLE COURT RENT", 1000.0),
                                          ("b\(m)", "2026-0\(m)-16", "MAPLE COURT RENT", 900.0)] }
    let database = try housingData(charges)
    let housing = try #require(try Profile.facts(in: database).first { $0.kind == "housing" })
    #expect(housing.value.schedule == "twice_monthly")
    #expect(housing.value.monthly_average == 1900)
    let rent = try simulate(database, days: 47).flatMap { day in day.bills.map { "\(day.date) \($0.amount)" } }
    #expect(rent == ["2026-07-01 1000.0", "2026-07-16 900.0", "2026-08-01 1000.0", "2026-08-16 900.0"])
}

/// The same rent with the May 1 charge still pending: the organizer's series has it, but the
/// profile leaves pending charges out, so the days no longer take turns in what it sees. Each
/// charge still goes with its own day, so the month still costs 1000 + 900, not 900 + 900.
@Test func twiceMonthlyRentWithAPendingChargeKeepsEachDaysAmount() throws {
    let charges = (3...6).flatMap { m in [("a\(m)", "2026-0\(m)-01", "MAPLE COURT RENT", 1000.0),
                                          ("b\(m)", "2026-0\(m)-16", "MAPLE COURT RENT", 900.0)] }
    let database = try housingData(charges, pending: ["a5"])
    let housing = try #require(try Profile.facts(in: database).first { $0.kind == "housing" })
    #expect(housing.value.schedule == "twice_monthly" && housing.value.monthly_average == 1900)
    #expect(housing.evidence.count == 7)
}

@Test func personsHousingCorrectionReplacesIrregularRent() throws {
    let database = try irregularRent()
    let id = try #require(try Profile.facts(in: database).first { $0.kind == "housing" }).id
    let mine = Profile.Value(name: "Maple Court Rent", type: "rent", amount: 950, schedule: "monthly", day: 1)
    try Profile.correct(id: id, kind: "housing", value: mine, in: database)
    try Organizer.organize(database)

    let housing = try Profile.facts(in: database).filter { $0.kind == "housing" }
    #expect(housing.map(\.value) == [mine])
    #expect(housing.first?.rule == "user_correction" && housing.first?.confidence == 1)
}
