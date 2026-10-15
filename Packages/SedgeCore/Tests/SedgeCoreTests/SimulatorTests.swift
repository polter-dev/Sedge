import Foundation
import GRDB
import Testing
@testable import SedgeCore

// MARK: - Day stepping and month lengths, on a small hand-made dataset

/// One person with a checking account and a card, "today" Jan 31, 2026:
/// - rent of 500 on the last day of Nov, Dec and Jan (so the series is anchored on a 31st),
/// - a paycheck of 800 every 14 days, last on Jan 30,
/// - one 28.00 cafe charge on the card in the last four weeks (so 1.00 a day of everyday spending),
/// - a 150 card payment on Jan 31, which sets the card's payment day to the 31st.
func handMadeDatabase(useReconciliation: Bool = true) throws -> SedgeDatabase {
    func account(_ id: String, _ name: String, _ type: String, _ balance: Double) -> Account {
        Account(account_id: id, name: name, type: type, subtype: type == "credit" ? "credit card" : "checking",
                balances: Balances(current: balance))
    }
    var count = 0
    func charge(_ account: String, _ date: String, _ name: String, _ amount: Double) -> Transaction {
        count += 1
        return Transaction(transaction_id: "t\(count)", account_id: account, date: date, name: name, amount: amount, pending: false)
    }
    let transactions = [
        charge("checking", "2025-11-30", "OAKWOOD APARTMENTS RENT", 500),
        charge("checking", "2025-12-31", "OAKWOOD APARTMENTS RENT", 500),
        charge("checking", "2026-01-31", "OAKWOOD APARTMENTS RENT", 500),
        charge("checking", "2026-01-02", "ACME PAYROLL", -800),
        charge("checking", "2026-01-16", "ACME PAYROLL", -800),
        charge("checking", "2026-01-30", "ACME PAYROLL", -800),
        charge("card", "2026-01-20", "CORNER CAFE", 28),
        charge("checking", "2026-01-31", "PAYMENT CREDIT CARD", 150),
        charge("card", "2026-01-31", "PAYMENT RECEIVED THANK YOU", -150),
    ]
    let database = try SedgeDatabase()
    try database.save(accounts: [account("checking", "Checking", "depository", 1000), account("card", "Credit Card", "credit", 200)],
                      transactions: transactions, asOf: "2026-01-31")
    try Organizer.organize(database, useReconciliation: useReconciliation)
    return database
}

func simulate(_ database: SedgeDatabase, days: Int, purchases: [Simulator.Purchase] = []) throws -> [Simulator.Day] {
    try database.dbQueue.read { db in try Simulator.simulate(db, days: days, purchases: purchases) }
}

/// Every day after today appears once, in order, across month ends: Feb 1 through Apr 1.
@Test func stepsOneDayAtATime() throws {
    let days = try simulate(handMadeDatabase(), days: 60)
    #expect(days.count == 60)
    #expect(days.first?.date == "2026-02-01")
    #expect(days.last?.date == "2026-04-01")
    for (before, after) in zip(days, days.dropFirst()) {
        let next = Simulator.calendar.date(byAdding: .day, value: 1, to: try Simulator.date(before.date))!
        #expect(after.date == Simulator.text(next))
    }
    // The card owes 1.00 more each day from everyday spending (no payment is due on Feb 1 or 2).
    #expect(days[0].balances["card"] == 201)
    #expect(days[1].balances["card"] == 202)
}

/// A bill on the 31st falls on Feb 28 (February is short) and then on Mar 31 again,
/// not on the 28th of every month after.
@Test func monthlyBillsFollowMonthLengths() throws {
    let days = try simulate(handMadeDatabase(), days: 60)
    let rentDays = days.filter { $0.bills.contains { $0.name == "Oakwood Apartments Rent" } }.map(\.date)
    #expect(rentDays == ["2026-02-28", "2026-03-31"])
    // The card is paid on its day (the 31st, so Feb 28 in February), the amount it owed at the
    // last month end: 200 on Jan 31, then 228 + 0 - 200 = 28 on Feb 28 after a month at 1.00 a day.
    let payments = days.flatMap { day in day.bills.filter { $0.name == "Credit Card payment" }.map { "\(day.date) \($0.amount)" } }
    #expect(payments == ["2026-02-28 200.0", "2026-03-31 28.0"])
}

/// Paychecks every 14 days from the last one, and the end balances add up by hand.
@Test func paychecksAndEndBalances() throws {
    let database = try handMadeDatabase()
    let days = try simulate(database, days: 60)
    let paydays = zip(days.dropFirst(), days).filter { $0.balances["checking"]! - $1.balances["checking"]! > 700 }.map(\.0.date)
    #expect(paydays == ["2026-02-13", "2026-02-27", "2026-03-13", "2026-03-27"])
    // 1000 - 2 rents (1000) - 2 card payments (228) + 4 paychecks (3200).
    #expect(days.last?.balances["checking"] == 2972)
    // 200 + 60 days at 1.00 - 228 paid.
    #expect(days.last?.balances["card"] == 32)

    // An extra purchase lowers that account from its day on, and not before.
    let extra = try simulate(database, days: 60, purchases: [Simulator.Purchase(amount: 75, date: "2026-02-10", account: "checking")])
    #expect(extra[8].balances["checking"] == days[8].balances["checking"])
    #expect(extra[9].balances["checking"] == days[9].balances["checking"]! - 75)
}

/// With reconciliation off the card payment is ordinary spending, so it is spread over the
/// everyday-spending average (150 / 28 a day) and no card payment is projected.
@Test func withoutReconciliationCardPaymentsAreEverydaySpending() throws {
    let days = try simulate(handMadeDatabase(useReconciliation: false), days: 3)
    #expect(days[0].balances["checking"] == cents(1000 - 150.0 / 28))
    #expect(days.allSatisfy { $0.bills.allSatisfy { !$0.name.hasSuffix("payment") } })
}

// MARK: - The proposal's question, on maya

/// "If I spend $400 on Friday, can I still pay rent this month?" a week before rent day.
/// Today is Wed Jun 24, rent (650) is due Jul 1. Maya's checking holds 1993.45 then, she is
/// next paid on Jul 3, and her everyday spending is all on the card, so by hand:
/// 1993.45 - 400 - 650 = 943.45 left on Jul 1.
@Test func mayaRentQuestion() throws {
    let database = try organizedPersona("maya", asOf: "2026-06-24")
    #expect(try database.dbQueue.read { db in
        try Double.fetchOne(db, sql: "SELECT json_extract(balances, '$.current') FROM accounts WHERE account_id = 'maya-checking'")
    } == 1993.45)
    let answer = try call("simulate_balance", ["days": 7, "extra_amount": 400, "extra_date": "2026-06-26"], on: database)
    #expect(answer["can_cover_bills"] as? Bool == true)
    #expect(answer["room_left"] as? Double == 943.45)
    #expect(answer["lowest_date"] as? String == "2026-07-01")
    let billDays = rows(answer, "bill_days")
    #expect(billDays.count == 1)
    #expect(billDays.first?["date"] as? String == "2026-07-01")
    #expect(billDays.first?["bills"] as? [String] == ["Oakwood Apartments Rent"])
    #expect(billDays.first?["balance"] as? Double == 943.45)

    // $1,500 on Friday doesn't leave enough for rent: 1993.45 - 1500 - 650 = -156.55.
    let tooMuch = try call("simulate_balance", ["days": 7, "extra_amount": 1500, "extra_date": "2026-06-26"], on: database)
    #expect(tooMuch["can_cover_bills"] as? Bool == false)
    #expect(tooMuch["room_left"] as? Double == -156.55)
}

// MARK: - Backtest

/// Maya's checking only has bills, paychecks and card payments, so from Jun 16 it is projected
/// to the cent; every account gets one row per day.
@Test func mayaBacktest() throws {
    let rows = try Simulator.backtest(persona: "maya", folder: dataDirectory.appending(path: "maya"),
                                      cutoff: "2026-06-16", days: 14, useReconciliation: true)
    #expect(rows.count == 14 * 2)
    #expect(rows.first?.date == "2026-06-17")
    #expect(rows.filter { $0.account == "maya-checking" }.allSatisfy { $0.projected == $0.actual })
    // The last day's actual balances are the data's own (as of Jun 30).
    #expect(rows.filter { $0.date == "2026-06-30" }.map(\.actual) == [1993.45, 138.01])
}

@Test func backtestStopsAtTheEndOfTheData() {
    #expect(throws: (any Error).self) {
        try Simulator.backtest(persona: "maya", folder: dataDirectory.appending(path: "maya"),
                               cutoff: "2026-06-20", days: 14, useReconciliation: true)
    }
}
