//
//  CashFlowTests.swift
//  SedgeTests
//

import Foundation
import GRDB
import SedgeCore
import Testing
@testable import Sedge

/// A persona's data in memory, organized, so these tests never touch the files the other tests reopen.
func inMemory(_ persona: String) throws -> SedgeDatabase {
    let database = try SedgeDatabase()
    try Persona.load(accounts: try #require(Bundle.main.url(forResource: "\(persona).accounts", withExtension: "json")),
                     transactions: try #require(Bundle.main.url(forResource: "\(persona).transactions", withExtension: "json")),
                     into: database)
    try Organizer.organize(database)
    return database
}

/// The lowest projected balance and its day are the simulator's minimum checking balance and the
/// first day it happens, for 30, 60 and 90 days.
@Test(arguments: Persona.all) func lowestIsTheSimulatorsMinimum(persona: String) throws {
    let database = try inMemory(persona)
    for days in [30, 60, 90] {
        let cashFlow = try #require(try CashFlow.load(database, days: days))
        let simulated = try database.dbQueue.read { try Simulator.simulate($0, days: days) }
        let minimum = try #require(simulated.map { $0.balances[cashFlow.account]! }.min())
        let lowest = try #require(cashFlow.lowest(cashFlow.shown))
        #expect(simulated.count == days)
        #expect(lowest.balance == minimum)
        #expect(lowest.date == simulated.first { $0.balances[cashFlow.account] == minimum }?.date)
    }
}

/// The balance the chart shows under a finger is the simulator's balance for that day, on the
/// first, a middle and the last day of 30, 60 and 90 days, for both lines when a purchase is on.
@Test(arguments: ["maya", "daniel"]) func readoutIsTheSimulatorsBalance(persona: String) throws {
    let database = try inMemory(persona)
    for days in [30, 60, 90] {
        let plan = try #require(try CashFlow.load(database, days: days))
        let simulated = try database.dbQueue.read { try Simulator.simulate($0, days: days) }
        let picks = [0, days / 2, days - 1]
        for index in picks {
            let day = simulated[index]
            #expect(plan.balance(on: day.date, in: plan.shown) == day.balances[plan.account], "\(persona) \(days) \(day.date)")
        }
        // A $500 purchase mid-way: the shown line is the simulator's with it, the dashed plan the one without.
        let middle = simulated[days / 2].date
        let changed = try #require(try CashFlow.load(database, days: days, purchases: [(500, middle)]))
        let withPurchase = try database.dbQueue.read {
            try Simulator.simulate($0, days: days, purchases: [.init(amount: 500, date: middle, account: plan.account)])
        }
        for index in picks {
            let date = simulated[index].date
            #expect(changed.balance(on: date, in: changed.shown) == withPurchase[index].balances[plan.account], "\(persona) \(days) \(date)")
            #expect(changed.balance(on: date, in: changed.without) == simulated[index].balances[plan.account], "\(persona) \(days) \(date)")
        }
    }
}

/// Maya pays Netflix and rent from checking, so cancelling Netflix from tomorrow adds back every
/// Netflix charge in the projection, and rent +$200 from tomorrow takes $200 per rent charge.
@Test func scenariosMoveTheEndBalanceByTheirCharges() throws {
    let database = try inMemory("maya")
    for days in [30, 60, 90] {
        let plan = try #require(try CashFlow.load(database, days: days))
        let tomorrow = try #require(plan.without.first?.date)
        let end = plan.balance(try #require(plan.without.last))
        func charged(_ name: String) -> [Double] {
            plan.without.flatMap(\.bills).filter { $0.name == name && $0.account == plan.account }.map(\.amount)
        }
        #expect(plan.bills.contains { $0.name == "Netflix" && $0.isSubscription })
        #expect(plan.bills.first?.name == "Oakwood Apartments Rent")
        // Rent comes out tomorrow and Maya is paid later, so tomorrow is her lowest day.
        #expect(plan.lowReason == "After Oakwood Apartments Rent")

        let cancelled = try #require(try CashFlow.load(database, days: days, changes: [.init(cancelling: "Netflix", from: tomorrow)]))
        let netflix = charged("Netflix")
        #expect(!netflix.isEmpty)
        #expect(abs(cancelled.balance(try #require(cancelled.with?.last)) - end - netflix.reduce(0, +)) < 0.005)

        let raised = try #require(try CashFlow.load(database, days: days,
                                                    changes: [.init(merchant: "Oakwood Apartments Rent", from: tomorrow, by: 200)]))
        let rent = charged("Oakwood Apartments Rent")
        #expect(!rent.isEmpty)
        #expect(abs(raised.balance(try #require(raised.with?.last)) - (end - 200 * Double(rent.count))) < 0.005)
    }
}

/// Pending charges and deposits inside June's window leave the cash flow card's Money in and Money
/// out as they were, so Money out still equals June's total above the card, which counts posted only.
@Test func cardLeavesOutPendingAsTheTotalDoes() throws {
    let database = try inMemory("maya")
    let posted = try SpendingView.monthFlow(in: database, month: "2026-06", asOf: "2026-06-30").money
    try database.dbQueue.write { db in
        for (id, amount, kind) in [("pending-out", 42.50, "spending"), ("pending-in", -300.0, "income")] {
            try db.execute(sql: """
                INSERT INTO transactions (transaction_id, account_id, date, name, amount, pending, kind)
                SELECT ?, account_id, '2026-06-20', 'TEST', ?, 1, ? FROM accounts WHERE type = 'depository' LIMIT 1
                """, arguments: [id, amount, kind])
        }
    }
    let flow = try SpendingView.monthFlow(in: database, month: "2026-06", asOf: "2026-06-30").money
    let june = try #require(SpendingView.bars(try SpendingTotal.all(in: database, throughDay: 30), category: nil, asOf: "2026-06-30").last)
    #expect(june.month == "2026-06")
    #expect(flow.moneyOut == Int((june.total * 100).rounded()))
    #expect(flow == posted)
}

/// The card's account label is the checking account's nickname when the person gave one, else its name.
@Test func cardAccountLabelIsTheNicknameElseTheName() throws {
    let database = try inMemory("maya")
    let label = { try SpendingView.monthFlow(in: database, month: "2026-05", asOf: "2026-06-30").accountName }
    #expect(try label() == "Checking")
    let id = try #require(try database.dbQueue.read { try Simulator.checkingAccount($0) })
    try Answers.setNickname("Bills", account: id, in: database)
    #expect(try label() == "Bills")
}
