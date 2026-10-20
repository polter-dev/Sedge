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
    // Under the size rule, a $40 refund is a book or a fee, not tuition.
    #expect(tuition[0].paid == 1500 && tuition[0].refunded == 0 && tuition[0].refunds == [])

    // With reconciliation off the refund is income, so nothing is refunded and the payments still count.
    let ablated = try #require(try profile(tuitionWithRefund(useReconciliation: false))["tuition"])
    #expect(ablated[1].paid == 7350.65 && ablated[1].refunded == 0)
}

@Test func assistantSeesTuitionPaidAndRefunded() async throws {
    let answer = #"{"answer": "$1,200.30 was refunded.", "value": 1200.30, "items": null, "yes_no": null, "confidence": 0.9}"#
    let backend = ScriptedBackend([calling([("get_profile", "{}")]), calling([("final_answer", answer)])])
    let trace = await Assistant(backend: backend, database: try tuitionWithRefund()).ask("How much tuition was refunded?")
    #expect(trace.error == nil && trace.finalAnswer?.value == 1200.30)

    // What the model was handed back from get_profile.
    guard case .toolResults(let results) = await backend.received[1].last else { Issue.record("no tool results"); return }
    let answerJSON = try #require(try JSONSerialization.jsonObject(with: Data(results[0].content.utf8)) as? [String: Any])
    let values = (answerJSON["facts"] as? [[String: Any]] ?? []).compactMap { $0["value"] as? [String: Any] }
    let bursar = try #require(values.first { $0["name"] as? String == "State U Bursar" })
    #expect(bursar["paid"] as? Double == 7350.65 && bursar["refunded"] as? Double == 1200.30)
    #expect((bursar["payments"] as? [Any])?.count == 2 && (bursar["refunds"] as? [Any])?.count == 1)
}

/// A checking account with only the given (id, date, name, amount) charges, organized.
func housingData(_ charges: [(String, String, String, Double)]) throws -> SedgeDatabase {
    let database = try SedgeDatabase()
    try database.save(
        accounts: [Account(account_id: "chk", name: "Checking", type: "depository", balances: Balances())],
        transactions: charges.map { Transaction(transaction_id: $0.0, account_id: "chk", date: $0.1, name: $0.2, amount: $0.3, pending: false) },
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
